using System.Text.Json;
using Npgsql;
using NpgsqlTypes;

namespace Nephos.Faces.Api;

public sealed class PostgresFaceRepository(NpgsqlDataSource data) : IFaceRepository
{
    private static NpgsqlCommand Command(NpgsqlConnection connection, string sql, params object?[] values)
    {
        var command = new NpgsqlCommand(sql, connection);
        foreach (var value in values)
            command.Parameters.Add(value is null
                ? new NpgsqlParameter { NpgsqlDbType = NpgsqlDbType.Unknown, Value = DBNull.Value }
                : new NpgsqlParameter { Value = value });
        return command;
    }

    private static async Task Lock(NpgsqlConnection connection, string owner, CancellationToken ct)
    {
        await using var command = Command(connection, "SELECT pg_advisory_xact_lock(hashtextextended($1, 84701))", owner);
        await command.ExecuteNonQueryAsync(ct);
    }

    private static async Task<int> Execute(NpgsqlConnection c, string sql, CancellationToken ct, params object?[] args)
    {
        await using var command = Command(c, sql, args);
        return await command.ExecuteNonQueryAsync(ct);
    }

    private static async Task<Guid?> ScalarId(NpgsqlConnection c, string sql, CancellationToken ct, params object?[] args)
    {
        await using var command = Command(c, sql, args);
        return await command.ExecuteScalarAsync(ct) is Guid id ? id : null;
    }

    private static FaceJob ReadJob(NpgsqlDataReader r) => new(r.GetGuid(0), r.GetString(1), r.GetGuid(2), r.GetString(3),
        r.GetString(4), r.GetString(5), r.GetInt32(6), r.IsDBNull(7) ? null : r.GetString(7), r.IsDBNull(8) ? null : r.GetGuid(8));
    private const string JobColumns = "id,owner,asset_id,source_sha256,pipeline_version,status,attempts,error,lease_token";

    public async Task<FaceJob> EnqueueAsync(string owner, AnalysisSource source, CancellationToken ct)
    {
        await using var c = await data.OpenConnectionAsync(ct);
        await using var command = Command(c, $"""
            INSERT INTO jobs(id,owner,asset_id,source_sha256,pipeline_version) VALUES($1,$2,$3,$4,$5)
            ON CONFLICT(owner,asset_id,source_sha256,pipeline_version) DO UPDATE SET owner=EXCLUDED.owner
            RETURNING {JobColumns}
            """, Guid.NewGuid(), owner, source.Id, source.Sha256.ToLowerInvariant(), Pipeline.Version);
        await using var reader = await command.ExecuteReaderAsync(ct);
        await reader.ReadAsync(ct);
        return ReadJob(reader);
    }

    public async Task<FaceJob?> ClaimAsync(CancellationToken ct)
    {
        await using var c = await data.OpenConnectionAsync(ct);
        await Execute(c, """
            UPDATE jobs SET status='error',error='retry_exhausted',lease_token=NULL,lease_until=NULL
            WHERE status='running' AND lease_until<now() AND attempts>=5
            """, ct);
        await using var command = Command(c, $"""
            UPDATE jobs SET status='running',attempts=attempts+1,lease_token=$1,lease_until=now()+interval '3 minutes',error=NULL
            WHERE id=(SELECT id FROM jobs WHERE pipeline_version=$2 AND attempts<5 AND
              ((status='queued' AND available_at<=now()) OR (status='running' AND lease_until<now()))
              ORDER BY available_at,id FOR UPDATE SKIP LOCKED LIMIT 1)
            RETURNING {JobColumns}
            """, Guid.NewGuid(), Pipeline.Version);
        await using var reader = await command.ExecuteReaderAsync(ct);
        return await reader.ReadAsync(ct) ? ReadJob(reader) : null;
    }

    public async Task FailAsync(FaceJob job, string error, bool permanent, CancellationToken ct)
    {
        await using var c = await data.OpenConnectionAsync(ct);
        await Execute(c, """
            UPDATE jobs SET status=$1,error=$2,lease_token=NULL,lease_until=NULL,
                available_at=now()+make_interval(secs=>least(300,attempts*attempts*5))
            WHERE id=$3 AND lease_token=$4 AND status='running'
            """, ct, permanent ? (error == "access_denied" ? "denied" : "error") : job.Attempts >= 5 ? "error" : "queued",
            error, job.Id, job.LeaseToken);
    }

    private sealed record Track(Guid Id, double X, double Y, double Width, double Height, bool Manual, Guid? Person);

    public async Task CompleteAsync(FaceJob job, InferenceResult result, CancellationToken ct)
    {
        Clustering.Validate(result, job);
        await using var c = await data.OpenConnectionAsync(ct);
        await using var tx = await c.BeginTransactionAsync(ct);
        await Lock(c, job.Owner, ct);
        if (await ScalarId(c, "SELECT id FROM jobs WHERE id=$1 AND lease_token=$2 AND status='running' AND lease_until>now() FOR UPDATE",
                ct, job.Id, job.LeaseToken) is null) return;
        var tracks = new List<Track>();
        await using (var command = Command(c, """
            SELECT t.id,t.x,t.y,t.width,t.height,t.manual_override,
              CASE WHEN t.manual_override THEN t.manual_person_id ELSE
                (SELECT o.generated_person_id FROM observations o JOIN jobs j ON j.id=o.job_id
                 WHERE o.track_id=t.id ORDER BY j.created_at DESC LIMIT 1) END
            FROM face_tracks t WHERE t.owner=$1 AND t.asset_id=$2 AND t.source_sha256=$3 LIMIT 128
            """, job.Owner, job.AssetId, job.SourceSha256))
        await using (var reader = await command.ExecuteReaderAsync(ct))
            while (await reader.ReadAsync(ct))
                tracks.Add(new(reader.GetGuid(0), reader.GetDouble(1), reader.GetDouble(2), reader.GetDouble(3), reader.GetDouble(4),
                    reader.GetBoolean(5), reader.IsDBNull(6) ? null : reader.GetGuid(6)));

        var representatives = new List<(Guid Person, Guid Root, float[] Vector)>();
        await using (var command = Command(c, """
            WITH candidates AS (
              SELECT CASE WHEN t.manual_override THEN t.manual_person_id ELSE o.generated_person_id END person,
                     o.embedding, o.id
              FROM observations o JOIN jobs j ON j.id=o.job_id JOIN face_tracks t ON t.id=o.track_id
              WHERE o.owner=$1 AND j.pipeline_version=$2 AND j.status='complete' AND o.embedding IS NOT NULL),
            ranked AS (SELECT *,row_number() OVER (PARTITION BY person ORDER BY id DESC) AS position FROM candidates WHERE person IS NOT NULL)
            SELECT person,resolve_person($1,person),embedding FROM ranked WHERE position<=8 ORDER BY id DESC LIMIT 2000
            """, job.Owner, Pipeline.Version))
        await using (var reader = await command.ExecuteReaderAsync(ct))
            while (await reader.ReadAsync(ct)) representatives.Add((reader.GetGuid(0), reader.GetGuid(1), reader.GetFieldValue<float[]>(2)));

        var used = new HashSet<Guid>();
        foreach (var face in result.Faces)
        {
            var track = tracks.Where(t => !used.Contains(t.Id))
                .OrderByDescending(t => Clustering.Intersection(t.X, t.Y, t.Width, t.Height, face))
                .FirstOrDefault(t => Clustering.Intersection(t.X, t.Y, t.Width, t.Height, face) >= 0.6);
            var trackId = track?.Id ?? Guid.NewGuid();
            used.Add(trackId);
            if (track is null)
                await Execute(c, """
                    INSERT INTO face_tracks(id,owner,asset_id,source_sha256,x,y,width,height) VALUES($1,$2,$3,$4,$5,$6,$7,$8)
                    """, ct, trackId, job.Owner, job.AssetId, job.SourceSha256, face.X, face.Y, face.Width, face.Height);
            Guid? person = track?.Person;
            if (face.Embedding is { } vector && person is null && track?.Manual != true)
            {
                var scores = representatives.GroupBy(r => r.Root)
                    .Select(g =>
                    {
                        var best = g.OrderByDescending(r => Clustering.Similarity(vector, r.Vector)).First();
                        return (Person: best.Person, Root: g.Key, Score: Clustering.Similarity(vector, best.Vector));
                    })
                    .Where(s => s.Score >= Pipeline.Threshold).OrderByDescending(s => s.Score).ToArray();
                foreach (var candidate in scores)
                {
                    if (scores.Any(s => s.Root != candidate.Root && s.Score >= candidate.Score - 0.05)) break;
                    if (await ScalarId(c, """
                        SELECT person_id FROM track_exclusions WHERE owner=$1 AND track_id=$2
                        AND resolve_person(owner,person_id)=$3 LIMIT 1
                        """, ct, job.Owner, trackId, candidate.Root) is null)
                    { person = candidate.Person; break; }
                }
                if (person is null)
                {
                    person = Guid.NewGuid();
                    await Execute(c, "INSERT INTO people(id,owner) VALUES($1,$2)", ct, person, job.Owner);
                }
                var root = await ScalarId(c, "SELECT resolve_person($1,$2)", ct, job.Owner, person) ?? person.Value;
                representatives.Add((person.Value, root, vector));
            }
            Guid? cluster = null;
            if (person is not null)
                cluster = await ScalarId(c, """
                    INSERT INTO generated_clusters(id,owner,pipeline_version,person_id) VALUES($1,$2,$3,$4)
                    ON CONFLICT(owner,pipeline_version,person_id) DO UPDATE SET person_id=EXCLUDED.person_id RETURNING id
                    """, ct, Guid.NewGuid(), job.Owner, job.PipelineVersion, person);
            await Execute(c, """
                INSERT INTO observations(id,job_id,track_id,owner,generated_person_id,embedding,quality,confidence,
                    x,y,width,height,image_width,image_height,model_version,preprocess_version,cluster_id)
                VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13,$14,$15,$16,$17)
                """, ct, Guid.NewGuid(), job.Id, trackId, job.Owner, person, face.Embedding, face.Quality, face.Confidence,
                face.X, face.Y, face.Width, face.Height, result.Width, result.Height, result.ModelVersion, result.PreprocessVersion, cluster);
        }
        await Execute(c, "UPDATE jobs SET status=$1,lease_token=NULL,lease_until=NULL WHERE id=$2", ct,
            result.Faces.Length == 0 ? "no_faces" : "complete", job.Id);
        await tx.CommitAsync(ct);
    }

    public async Task<IReadOnlyList<FaceJob>> JobsAsync(string owner, Guid? after, int limit, CancellationToken ct)
    {
        await using var c = await data.OpenConnectionAsync(ct);
        await using var command = Command(c, $"SELECT {JobColumns} FROM jobs WHERE owner=$1 AND ($2::uuid IS NULL OR id>$2) ORDER BY id LIMIT $3", owner, after, limit);
        await using var reader = await command.ExecuteReaderAsync(ct);
        var rows = new List<FaceJob>();
        while (await reader.ReadAsync(ct)) rows.Add(ReadJob(reader));
        return rows;
    }

    public async Task<bool> RetryAsync(string owner, Guid id, CancellationToken ct)
    {
        await using var c = await data.OpenConnectionAsync(ct);
        return await Execute(c, """
            UPDATE jobs SET status='queued',attempts=0,error=NULL,available_at=now()
            WHERE owner=$1 AND id=$2 AND pipeline_version=$3 AND status IN ('error','denied')
            """, ct, owner, id, Pipeline.Version) == 1;
    }

    public async Task<FaceJob?> JobAsync(string owner, Guid id, CancellationToken ct)
    {
        await using var c = await data.OpenConnectionAsync(ct);
        await using var command = Command(c, $"SELECT {JobColumns} FROM jobs WHERE owner=$1 AND id=$2", owner, id);
        await using var reader = await command.ExecuteReaderAsync(ct);
        return await reader.ReadAsync(ct) ? ReadJob(reader) : null;
    }

    private static Person ReadPerson(NpgsqlDataReader r) => new(r.GetGuid(0), r.IsDBNull(1) ? null : r.GetString(1),
        r.GetFieldValue<string[]>(2), r.IsDBNull(3) ? null : r.GetGuid(3));

    public async Task<IReadOnlyList<Person>> PeopleAsync(string owner, Guid? after, int limit, string? name, CancellationToken ct)
    {
        await using var c = await data.OpenConnectionAsync(ct);
        await using var command = Command(c, """
            SELECT id,name,aliases,redirect_id FROM people WHERE owner=$1 AND ($2::uuid IS NULL OR id>$2)
            AND ($4::text IS NULL OR lower(name)=lower($4) OR EXISTS(SELECT 1 FROM unnest(aliases) a WHERE lower(a)=lower($4)))
            ORDER BY id LIMIT $3
            """, owner, after, limit, name);
        await using var reader = await command.ExecuteReaderAsync(ct);
        var rows = new List<Person>();
        while (await reader.ReadAsync(ct)) rows.Add(ReadPerson(reader));
        return rows;
    }

    public async Task<Person?> PersonAsync(string owner, Guid id, CancellationToken ct)
    {
        await using var c = await data.OpenConnectionAsync(ct);
        await using var command = Command(c, "SELECT id,name,aliases,redirect_id FROM people WHERE owner=$1 AND id=$2", owner, id);
        await using var reader = await command.ExecuteReaderAsync(ct);
        return await reader.ReadAsync(ct) ? ReadPerson(reader) : null;
    }

    private static Task<int> Audit(NpgsqlConnection c, string owner, string kind, Guid subject, Guid? target, CancellationToken ct, object? details = null) =>
        Execute(c, "INSERT INTO corrections(id,owner,kind,subject_id,target_id,details) VALUES($1,$2,$3,$4,$5,$6::jsonb)",
            ct, Guid.NewGuid(), owner, kind, subject, target, JsonSerializer.Serialize(details ?? new { }));

    public async Task<bool> NameAsync(string owner, Guid id, NameRequest request, CancellationToken ct)
    {
        await using var c = await data.OpenConnectionAsync(ct);
        await using var tx = await c.BeginTransactionAsync(ct);
        await Lock(c, owner, ct);
        if (await Execute(c, "UPDATE people SET name=$1,aliases=$2 WHERE owner=$3 AND id=$4", ct,
            request.Name, request.Aliases ?? [], owner, id) != 1) return false;
        await Audit(c, owner, "name", id, null, ct, request);
        await tx.CommitAsync(ct);
        return true;
    }

    public async Task<bool> MergeAsync(string owner, Guid source, Guid? target, CancellationToken ct)
    {
        await using var c = await data.OpenConnectionAsync(ct);
        await using var tx = await c.BeginTransactionAsync(ct);
        await Lock(c, owner, ct);
        var root = target is null ? null : await ScalarId(c, "SELECT resolve_person($1,$2)", ct, owner, target);
        if (target is not null && (root is null || root == source)) return false;
        if (root is not null && await ScalarId(c, """
            WITH RECURSIVE incoming AS (
              SELECT id,0 depth FROM people WHERE owner=$1 AND id=$2
              UNION ALL SELECT p.id,i.depth+1 FROM people p JOIN incoming i ON p.redirect_id=i.id
              WHERE p.owner=$1 AND i.depth<32)
            SELECT id FROM incoming WHERE depth=32 LIMIT 1
            """, ct, owner, source) is not null) return false;
        if (root is not null && await ScalarId(c, """
            SELECT person_id FROM negative_matches WHERE owner=$1 AND
             ((resolve_person(owner,person_id)=$2 AND resolve_person(owner,other_id)=$3) OR
              (resolve_person(owner,person_id)=$3 AND resolve_person(owner,other_id)=$2)) LIMIT 1
            """, ct, owner, source, root) is not null) return false;
        if (await Execute(c, """
            UPDATE people SET redirect_id=$1 WHERE owner=$2 AND id=$3
            AND (($1::uuid IS NULL AND redirect_id IS NOT NULL) OR ($1::uuid IS NOT NULL AND redirect_id IS NULL))
            """, ct, root, owner, source) != 1) return false;
        await Audit(c, owner, target is null ? "unmerge" : "merge", source, root, ct);
        await tx.CommitAsync(ct);
        return true;
    }

    public async Task<bool> AssignAsync(string owner, Guid faceId, AssignmentRequest request, CancellationToken ct)
    {
        await using var c = await data.OpenConnectionAsync(ct);
        await using var tx = await c.BeginTransactionAsync(ct);
        await Lock(c, owner, ct);
        if (await ScalarId(c, "SELECT id FROM face_tracks WHERE owner=$1 AND id=$2", ct, owner, faceId) is null) return false;
        Guid? target = request.PersonId;
        if (request.NewPerson)
        {
            target = Guid.NewGuid();
            await Execute(c, "INSERT INTO people(id,owner) VALUES($1,$2)", ct, target, owner);
        }
        else if (target is not null && await ScalarId(c, "SELECT id FROM people WHERE owner=$1 AND id=$2", ct, owner, target) is null)
            return false;
        await Execute(c, """
            INSERT INTO track_exclusions(owner,track_id,person_id)
            SELECT $1,$2,generated_person_id FROM observations WHERE owner=$1 AND track_id=$2 AND generated_person_id IS NOT NULL
            ON CONFLICT DO NOTHING
            """, ct, owner, faceId);
        await Execute(c, "UPDATE face_tracks SET manual_override=true,manual_person_id=$1 WHERE owner=$2 AND id=$3", ct, target, owner, faceId);
        await Audit(c, owner, request.NewPerson ? "split" : "assign", faceId, target, ct);
        await tx.CommitAsync(ct);
        return true;
    }

    public async Task<bool> NegativeAsync(string owner, Guid personId, Guid otherId, CancellationToken ct)
    {
        await using var c = await data.OpenConnectionAsync(ct);
        await using var tx = await c.BeginTransactionAsync(ct);
        await Lock(c, owner, ct);
        var first = await ScalarId(c, "SELECT resolve_person($1,$2)", ct, owner, personId);
        var second = await ScalarId(c, "SELECT resolve_person($1,$2)", ct, owner, otherId);
        if (first is null || second is null || first == second) return false;
        await Execute(c, """
            INSERT INTO negative_matches(owner,person_id,other_id) VALUES($1,$2,$3),($1,$3,$2) ON CONFLICT DO NOTHING
            """, ct, owner, personId, otherId);
        await Audit(c, owner, "negative", personId, otherId, ct);
        await tx.CommitAsync(ct);
        return true;
    }

    public async Task<bool> RemoveNegativeAsync(string owner, Guid personId, Guid otherId, CancellationToken ct)
    {
        await using var c = await data.OpenConnectionAsync(ct);
        await using var tx = await c.BeginTransactionAsync(ct);
        await Lock(c, owner, ct);
        if (await Execute(c, """
            DELETE FROM negative_matches WHERE owner=$1 AND
              ((person_id=$2 AND other_id=$3) OR (person_id=$3 AND other_id=$2))
            """, ct, owner, personId, otherId) == 0) return false;
        await Audit(c, owner, "negative_removed", personId, otherId, ct);
        await tx.CommitAsync(ct);
        return true;
    }

    private const string VisibleFaces = """
        SELECT t.id,t.asset_id,resolve_person(o.owner,CASE WHEN t.manual_override THEN t.manual_person_id ELSE o.generated_person_id END) person,
          o.x,o.y,o.width,o.height,o.quality,j.source_sha256,o.model_version,o.preprocess_version,o.image_width,o.image_height
        FROM observations o JOIN face_tracks t ON t.id=o.track_id JOIN jobs j ON j.id=o.job_id
        WHERE o.owner=$1 AND j.pipeline_version=$2 AND j.status='complete'
        """;

    public async Task<IReadOnlyList<Face>> FacesAsync(string owner, Guid? assetId, Guid? personId, Guid? after, int limit, CancellationToken ct)
    {
        await using var c = await data.OpenConnectionAsync(ct);
        await using var command = Command(c, $"""
            WITH visible AS ({VisibleFaces}) SELECT * FROM visible
            WHERE ($3::uuid IS NULL OR asset_id=$3) AND ($4::uuid IS NULL OR person=resolve_person($1,$4))
              AND ($5::uuid IS NULL OR id>$5) ORDER BY id LIMIT $6
            """, owner, Pipeline.Version, assetId, personId, after, limit);
        await using var reader = await command.ExecuteReaderAsync(ct);
        var rows = new List<Face>();
        while (await reader.ReadAsync(ct))
            rows.Add(new(reader.GetGuid(0), reader.GetGuid(1), reader.IsDBNull(2) ? null : reader.GetGuid(2),
                reader.GetDouble(3), reader.GetDouble(4), reader.GetDouble(5), reader.GetDouble(6), reader.GetString(7),
                reader.GetString(8), reader.GetString(9), reader.GetString(10), reader.GetInt32(11), reader.GetInt32(12)));
        return rows;
    }

    public async Task<IReadOnlyList<Guid>> AssetsAsync(string owner, Guid personId, Guid? after, int limit, CancellationToken ct)
    {
        await using var c = await data.OpenConnectionAsync(ct);
        await using var command = Command(c, $"""
            WITH visible AS ({VisibleFaces}) SELECT DISTINCT asset_id FROM visible
            WHERE person=resolve_person($1,$3) AND ($4::uuid IS NULL OR asset_id>$4) ORDER BY asset_id LIMIT $5
            """, owner, Pipeline.Version, personId, after, limit);
        await using var reader = await command.ExecuteReaderAsync(ct);
        var rows = new List<Guid>();
        while (await reader.ReadAsync(ct)) rows.Add(reader.GetGuid(0));
        return rows;
    }

    public async Task<IReadOnlyList<Correction>> CorrectionsAsync(string owner, Guid? after, int limit, CancellationToken ct)
    {
        await using var c = await data.OpenConnectionAsync(ct);
        await using var command = Command(c, """
            SELECT id,kind,subject_id,target_id,created_at FROM corrections
            WHERE owner=$1 AND ($2::uuid IS NULL OR id>$2) ORDER BY id LIMIT $3
            """, owner, after, limit);
        await using var reader = await command.ExecuteReaderAsync(ct);
        var rows = new List<Correction>();
        while (await reader.ReadAsync(ct))
            rows.Add(new(reader.GetGuid(0), reader.GetString(1), reader.GetGuid(2), reader.IsDBNull(3) ? null : reader.GetGuid(3),
                reader.GetFieldValue<DateTimeOffset>(4)));
        return rows;
    }
}
