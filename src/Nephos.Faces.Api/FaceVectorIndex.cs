using Npgsql;

namespace Nephos.Faces.Api;

public sealed record FaceMatchCandidate(Guid PersonId, Guid RootId, float[] Vector);

/// <summary>
/// Vector-retrieval boundary for face clustering. Currently backed by per-person centroids
/// in PostgreSQL; can be swapped for pgvector/VectorChord or an external vector service.
/// </summary>
public interface IFaceVectorIndex
{
    Task<IReadOnlyList<FaceMatchCandidate>> SearchCandidatesAsync(
        NpgsqlConnection connection, string owner, string pipelineVersion, float[] query, CancellationToken ct);
    Task RecomputePersonAsync(
        NpgsqlConnection connection, string owner, string pipelineVersion, Guid personId, CancellationToken ct);
}

public sealed class PostgresCentroidVectorIndex : IFaceVectorIndex
{
    private const int CandidateLimit = 64;
    private const int RepresentativesPerPerson = 8;

    public async Task<IReadOnlyList<FaceMatchCandidate>> SearchCandidatesAsync(
        NpgsqlConnection connection, string owner, string pipelineVersion, float[] query, CancellationToken ct)
    {
        var centroids = new List<(Guid PersonId, float[] Centroid)>();
        await using (var cmd = new NpgsqlCommand("""
            SELECT person_id, centroid FROM person_centroids
            WHERE owner=$1 AND pipeline_version=$2
            """, connection))
        {
            cmd.Parameters.AddWithValue(owner);
            cmd.Parameters.AddWithValue(pipelineVersion);
            await using var reader = await cmd.ExecuteReaderAsync(ct);
            while (await reader.ReadAsync(ct))
                centroids.Add((reader.GetGuid(0), reader.GetFieldValue<float[]>(1)));
        }

        // Self-heal once if centroids have not yet been populated for pre-existing people of this owner.
        if (centroids.Count == 0)
        {
            await BackfillOwnerAsync(connection, owner, pipelineVersion, ct);
            await using var reload = new NpgsqlCommand("""
                SELECT person_id, centroid FROM person_centroids
                WHERE owner=$1 AND pipeline_version=$2
                """, connection);
            reload.Parameters.AddWithValue(owner);
            reload.Parameters.AddWithValue(pipelineVersion);
            await using var reader = await reload.ExecuteReaderAsync(ct);
            while (await reader.ReadAsync(ct))
                centroids.Add((reader.GetGuid(0), reader.GetFieldValue<float[]>(1)));
            if (centroids.Count == 0) return [];
        }

        var topPeople = centroids
            .Select(c => (c.PersonId, Score: Clustering.Similarity(query, c.Centroid)))
            .OrderByDescending(c => c.Score)
            .Take(CandidateLimit)
            .Select(c => c.PersonId)
            .ToArray();
        if (topPeople.Length == 0) return [];

        var results = new List<FaceMatchCandidate>();
        // Expand merged groups so all unmerged source clusters under a top candidate root are evaluated accurately.
        await using (var cmd = new NpgsqlCommand("""
            WITH top_roots AS (
                SELECT DISTINCT resolve_person($1, p) AS root FROM unnest($3::uuid[]) AS p
            ),
            group_people AS (
                SELECT id AS person_id, resolve_person($1, id) AS root
                FROM people WHERE owner=$1 AND resolve_person($1, id) IN (SELECT root FROM top_roots)
            ),
            candidates AS (
                SELECT CASE WHEN t.manual_override THEN t.manual_person_id ELSE o.generated_person_id END AS person,
                       o.embedding, o.confidence, j.created_at, o.id
                FROM observations o
                JOIN jobs j ON j.id=o.job_id
                JOIN face_tracks t ON t.id=o.track_id
                WHERE o.owner=$1 AND j.pipeline_version=$2 AND j.status='complete' AND o.embedding IS NOT NULL
            ),
            scoped AS (
                SELECT c.person, gp.root, c.embedding,
                       row_number() OVER (PARTITION BY c.person ORDER BY c.confidence DESC, c.created_at DESC, c.id DESC) AS pos
                FROM candidates c JOIN group_people gp ON gp.person_id=c.person
            )
            SELECT person, root, embedding FROM scoped WHERE pos <= $4
            """, connection))
        {
            cmd.Parameters.AddWithValue(owner);
            cmd.Parameters.AddWithValue(pipelineVersion);
            cmd.Parameters.AddWithValue(topPeople);
            cmd.Parameters.AddWithValue(RepresentativesPerPerson);
            await using var reader = await cmd.ExecuteReaderAsync(ct);
            while (await reader.ReadAsync(ct))
                results.Add(new(reader.GetGuid(0), reader.GetGuid(1), reader.GetFieldValue<float[]>(2)));
        }
        return results;
    }

    public async Task RecomputePersonAsync(
        NpgsqlConnection connection, string owner, string pipelineVersion, Guid personId, CancellationToken ct)
    {
        var vectors = new List<float[]>();
        await using (var cmd = new NpgsqlCommand("""
            SELECT o.embedding
            FROM observations o
            JOIN jobs j ON j.id=o.job_id
            JOIN face_tracks t ON t.id=o.track_id
            WHERE o.owner=$1 AND j.pipeline_version=$2 AND j.status='complete' AND o.embedding IS NOT NULL
              AND (CASE WHEN t.manual_override THEN t.manual_person_id ELSE o.generated_person_id END) = $3
            ORDER BY o.confidence DESC, j.created_at DESC, o.id DESC
            LIMIT 256
            """, connection))
        {
            cmd.Parameters.AddWithValue(owner);
            cmd.Parameters.AddWithValue(pipelineVersion);
            cmd.Parameters.AddWithValue(personId);
            await using var reader = await cmd.ExecuteReaderAsync(ct);
            while (await reader.ReadAsync(ct))
                vectors.Add(reader.GetFieldValue<float[]>(0));
        }

        if (vectors.Count == 0)
        {
            await using var delete = new NpgsqlCommand("""
                DELETE FROM person_centroids WHERE owner=$1 AND pipeline_version=$2 AND person_id=$3
                """, connection);
            delete.Parameters.AddWithValue(owner);
            delete.Parameters.AddWithValue(pipelineVersion);
            delete.Parameters.AddWithValue(personId);
            await delete.ExecuteNonQueryAsync(ct);
            return;
        }

        var sum = new double[128];
        var validCount = 0;
        foreach (var vec in vectors)
        {
            if (vec.Length != 128) continue;
            validCount++;
            for (var i = 0; i < 128; i++) sum[i] += vec[i];
        }
        if (validCount == 0) return;

        double normSq = 0;
        for (var i = 0; i < 128; i++) normSq += sum[i] * sum[i];
        var norm = Math.Sqrt(normSq);
        if (norm <= 0 || !double.IsFinite(norm)) return;

        var centroid = new float[128];
        for (var i = 0; i < 128; i++) centroid[i] = (float)(sum[i] / norm);

        await using var upsert = new NpgsqlCommand("""
            INSERT INTO person_centroids(owner, pipeline_version, person_id, centroid, observation_count, updated_at)
            VALUES($1, $2, $3, $4, $5, now())
            ON CONFLICT(owner, pipeline_version, person_id)
            DO UPDATE SET centroid=EXCLUDED.centroid, observation_count=EXCLUDED.observation_count, updated_at=now()
            """, connection);
        upsert.Parameters.AddWithValue(owner);
        upsert.Parameters.AddWithValue(pipelineVersion);
        upsert.Parameters.AddWithValue(personId);
        upsert.Parameters.AddWithValue(centroid);
        upsert.Parameters.AddWithValue(validCount);
        await upsert.ExecuteNonQueryAsync(ct);
    }

    private async Task BackfillOwnerAsync(
        NpgsqlConnection connection, string owner, string pipelineVersion, CancellationToken ct)
    {
        var people = new List<Guid>();
        await using (var cmd = new NpgsqlCommand("""
            SELECT DISTINCT CASE WHEN t.manual_override THEN t.manual_person_id ELSE o.generated_person_id END AS person_id
            FROM observations o
            JOIN jobs j ON j.id=o.job_id
            JOIN face_tracks t ON t.id=o.track_id
            WHERE o.owner=$1 AND j.pipeline_version=$2 AND j.status='complete' AND o.embedding IS NOT NULL
            """, connection))
        {
            cmd.Parameters.AddWithValue(owner);
            cmd.Parameters.AddWithValue(pipelineVersion);
            await using var reader = await cmd.ExecuteReaderAsync(ct);
            while (await reader.ReadAsync(ct))
                if (!reader.IsDBNull(0)) people.Add(reader.GetGuid(0));
        }
        foreach (var personId in people)
            await RecomputePersonAsync(connection, owner, pipelineVersion, personId, ct);
    }
}
