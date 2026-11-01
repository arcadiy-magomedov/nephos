using System.Text.Json;
using Npgsql;
using NpgsqlTypes;
using static Nephos.Library.Api.Assets.PostgresGalleryJournal;

namespace Nephos.Library.Api.Assets;

public sealed record GallerySnapshot(Guid Id, long Revision, long AccessGeneration, DateTimeOffset ExpiresAt, long TotalCount);
public sealed record GalleryDelta(long FromRevision, long ToRevision, long TargetRevision, bool HasMore, IReadOnlyList<GalleryChange> Changes);
public sealed class GalleryExpiredException() : Exception("The retained gallery view expired or its access generation changed. Request a new snapshot.");
public sealed class GalleryAccessException() : Exception("Library access is unavailable.");
public sealed class ResourceConflictException(string message) : Exception(message);

public interface IGalleryRepository
{
    Task<GallerySnapshot> CreateAsync(string subject, Guid library, CancellationToken token);
    Task<AssetPage> PageAsync(string subject, Guid library, Guid snapshot, AssetCursor? before, int limit, CancellationToken token);
    Task<IReadOnlyList<TimelineBucket>> TimelineAsync(string subject, Guid library, Guid snapshot, int? year, int? month, CancellationToken token);
    Task<GalleryDelta> ChangesAsync(string subject, Guid library, long after, long through, int limit, CancellationToken token);
}

public sealed class PostgresGalleryRepository(NpgsqlDataSource source) : IGalleryRepository
{
    private static async Task<long> GenerationAsync(NpgsqlConnection connection, NpgsqlTransaction? transaction,
        string subject, Guid library, CancellationToken token)
    {
        await using var query = Command(connection, transaction, """
            SELECT p.access_generation+p.share_generation FROM principals p
            WHERE p.subject=$1 AND can_read_library($1,$2)
            """, subject, library);
        return await query.ExecuteScalarAsync(token) is long generation ? generation : throw new GalleryAccessException();
    }

    private static GallerySnapshot Read(NpgsqlDataReader reader) => new(reader.GetGuid(0), reader.GetInt64(1),
        reader.GetInt64(2), reader.GetFieldValue<DateTimeOffset>(3), reader.GetInt64(4));

    private static async Task<GallerySnapshot> SnapshotAsync(NpgsqlConnection connection, string subject,
        Guid library, Guid id, CancellationToken token)
    {
        var generation = await GenerationAsync(connection, null, subject, library, token);
        await using var query = Command(connection, null, """
            SELECT id,revision,access_generation,expires_at,total_count FROM gallery_snapshots
            WHERE id=$1 AND subject=$2 AND library_id=$3 AND access_generation=$4 AND expires_at>now()
            """, id, subject, library, generation);
        await using var reader = await query.ExecuteReaderAsync(token);
        return await reader.ReadAsync(token) ? Read(reader) : throw new GalleryExpiredException();
    }

    public async Task<GallerySnapshot> CreateAsync(string subject, Guid library, CancellationToken token)
    {
        await using var connection = await source.OpenConnectionAsync(token);
        await using var transaction = await connection.BeginTransactionAsync(token);
        var generation = await GenerationAsync(connection, transaction, subject, library, token);
        var revision = await LockAsync(connection, transaction, library, token);
        await using (var cleanup = Command(connection, transaction,
            "DELETE FROM gallery_snapshots WHERE library_id=$1 AND subject=$2 AND (expires_at<=now() OR access_generation<>$3)", library, subject, generation))
            await cleanup.ExecuteNonQueryAsync(token);
        await using (var reuse = Command(connection, transaction, """
            SELECT id,revision,access_generation,expires_at,total_count FROM gallery_snapshots
            WHERE library_id=$1 AND subject=$2 AND revision=$3 AND access_generation=$4 AND expires_at>now()+interval '1 hour' LIMIT 1
            """, library, subject, revision, generation))
        await using (var reader = await reuse.ExecuteReaderAsync(token))
        {
            if (await reader.ReadAsync(token))
            {
                var existing = Read(reader);
                await reader.DisposeAsync();
                await transaction.CommitAsync(token);
                return existing;
            }
        }
        await using (var quota = Command(connection, transaction,
            "SELECT count(*) FROM gallery_snapshots WHERE library_id=$1 AND subject=$2", library, subject))
            if ((long)(await quota.ExecuteScalarAsync(token))! >= 20000)
                throw new ResourceConflictException("Active gallery snapshot budget reached. Reuse an existing retained view.");
        await using var insert = Command(connection, transaction, """
            INSERT INTO gallery_snapshots(id,library_id,subject,revision,access_generation,total_count)
            SELECT $1,$2,$3,$4,$5,count(*) FROM gallery_versions
            WHERE library_id=$2 AND visible AND from_revision<=$4 AND (to_revision IS NULL OR to_revision>$4)
                AND can_read_asset($3,asset_id)
            RETURNING id,revision,access_generation,expires_at,total_count
            """, Guid.NewGuid(), library, subject, revision, generation);
        GallerySnapshot result;
        await using (var reader = await insert.ExecuteReaderAsync(token))
        {
            await reader.ReadAsync(token);
            result = Read(reader);
        }
        await transaction.CommitAsync(token);
        return result;
    }

    public async Task<AssetPage> PageAsync(string subject, Guid library, Guid snapshot, AssetCursor? before, int limit, CancellationToken token)
    {
        await using var connection = await source.OpenConnectionAsync(token);
        var view = await SnapshotAsync(connection, subject, library, snapshot, token);
        await using var query = Command(connection, null, """
            SELECT v.body::text,CASE WHEN a.uploaded_by<>$6 THEN coalesce(owner.display_name,'Known user') END
            FROM gallery_versions v JOIN assets a ON a.id=v.asset_id JOIN principals owner ON owner.subject=a.uploaded_by
            WHERE v.library_id=$1 AND v.visible AND v.from_revision<=$2 AND (v.to_revision IS NULL OR v.to_revision>$2)
            AND a.deleted_at IS NULL AND can_read_asset($6,a.id)
            AND ($3::timestamptz IS NULL OR (v.created_at,v.asset_id)<($3,$4))
            ORDER BY v.created_at DESC,v.asset_id DESC LIMIT $5
            """, library, view.Revision);
        query.Parameters.Add(new NpgsqlParameter { NpgsqlDbType = NpgsqlDbType.TimestampTz, Value = (object?)before?.CreatedAt ?? DBNull.Value });
        query.Parameters.AddWithValue(before?.Id ?? Guid.Empty);
        query.Parameters.AddWithValue(limit + 1);
        query.Parameters.AddWithValue(subject);
        await using var reader = await query.ExecuteReaderAsync(token);
        var rows = new List<Asset>();
        while (await reader.ReadAsync(token)) rows.Add(JsonSerializer.Deserialize<Asset>(reader.GetString(0), Json)! with
        { SharedBy = reader.IsDBNull(1) ? null : reader.GetString(1) });
        var items = rows.Take(limit).ToArray();
        return new(items, rows.Count > limit ? new(items[^1].CreatedAt, items[^1].Id) : null);
    }

    public async Task<IReadOnlyList<TimelineBucket>> TimelineAsync(string subject, Guid library, Guid snapshot, int? year, int? month, CancellationToken token)
    {
        await using var connection = await source.OpenConnectionAsync(token);
        var view = await SnapshotAsync(connection, subject, library, snapshot, token);
        var start = new DateTimeOffset(year ?? 1800, month ?? 1, 1, 0, 0, 0, TimeSpan.Zero);
        var end = month is not null ? start.AddMonths(1) : year is not null ? start.AddYears(1) : new DateTimeOffset(2201, 1, 1, 0, 0, 0, TimeSpan.Zero);
        await using var query = Command(connection, null, """
            SELECT to_char(date_trunc($3,created_at AT TIME ZONE 'UTC'),'YYYY-MM-DD') AS bucket,count(*)
            FROM gallery_versions WHERE library_id=$1 AND visible AND from_revision<=$2 AND (to_revision IS NULL OR to_revision>$2)
            AND EXISTS(SELECT 1 FROM assets a WHERE a.id=gallery_versions.asset_id AND a.deleted_at IS NULL)
            AND can_read_asset($6,asset_id) AND created_at >= $4 AND created_at < $5
            GROUP BY bucket ORDER BY bucket DESC
            """, library, view.Revision, month is not null ? "day" : year is not null ? "month" : "year", start, end, subject);
        await using var reader = await query.ExecuteReaderAsync(token);
        var rows = new List<TimelineBucket>();
        while (await reader.ReadAsync(token)) rows.Add(new(reader.GetString(0), reader.GetInt64(1)));
        return rows;
    }

    public async Task<GalleryDelta> ChangesAsync(string subject, Guid library, long after, long through, int limit, CancellationToken token)
    {
        await using var connection = await source.OpenConnectionAsync(token);
        var generation = await GenerationAsync(connection, null, subject, library, token);
        await using (var valid = Command(connection, null, """
            SELECT EXISTS(SELECT 1 FROM gallery_snapshots WHERE library_id=$1 AND subject=$2 AND access_generation=$3
                AND expires_at>now() AND revision=$4)
            AND EXISTS(SELECT 1 FROM gallery_snapshots WHERE library_id=$1 AND subject=$2 AND access_generation=$3
                AND expires_at>now() AND revision<=$5)
            """, library, subject, generation, through, after))
            if (!(bool)(await valid.ExecuteScalarAsync(token))!) throw new GalleryExpiredException();
        var revisions = new List<long>();
        await using (var query = Command(connection, null, """
            SELECT DISTINCT revision FROM gallery_changes WHERE library_id=$1 AND revision>$2 AND revision<=$3
            AND can_read_asset($5,asset_id)
            ORDER BY revision LIMIT $4
            """, library, after, through, limit + 1, subject))
        await using (var reader = await query.ExecuteReaderAsync(token))
            while (await reader.ReadAsync(token)) revisions.Add(reader.GetInt64(0));
        var more = revisions.Count > limit;
        var last = more ? revisions[limit - 1] : through;
        var batches = new SortedDictionary<long, List<AssetChange>>();
        await using (var query = Command(connection, null, """
            SELECT c.revision,c.operation,c.asset_id,c.body::text,
                CASE WHEN a.uploaded_by<>$4 THEN coalesce(owner.display_name,'Known user') END
            FROM gallery_changes c JOIN assets a ON a.id=c.asset_id JOIN principals owner ON owner.subject=a.uploaded_by
            WHERE c.library_id=$1 AND c.revision>$2 AND c.revision<=$3 AND can_read_asset($4,a.id) ORDER BY c.revision,c.ordinal
            """, library, after, last, subject))
        await using (var reader = await query.ExecuteReaderAsync(token))
            while (await reader.ReadAsync(token))
            {
                var revision = reader.GetInt64(0);
                if (!batches.TryGetValue(revision, out var changes)) batches[revision] = changes = [];
                changes.Add(new(reader.GetString(1), reader.GetGuid(2), reader.IsDBNull(3) ? null :
                    JsonSerializer.Deserialize<Asset>(reader.GetString(3), Json)! with { SharedBy = reader.IsDBNull(4) ? null : reader.GetString(4) }));
            }
        return new(after, last, through, more, batches.Select(pair => new GalleryChange(pair.Key, pair.Value)).ToArray());
    }
}
