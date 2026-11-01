using Npgsql;
using NpgsqlTypes;
using static Nephos.Library.Api.Assets.PostgresGalleryJournal;

namespace Nephos.Library.Api.Assets;

public sealed record TrashItem(Asset Asset, DateTimeOffset DeletedAt, DateTimeOffset PurgeAfter);
public sealed record TrashCursor(DateTimeOffset DeletedAt, Guid Id);
public sealed record TrashPage(IReadOnlyList<TrashItem> Items, TrashCursor? NextCursor);
public sealed record PurgeClaim(Guid AssetId, string Subject, Guid LeaseId);
public enum RestoreResult { Restored, NotFound, Expired }

public interface ITrashRepository
{
    Task<TrashPage> ListAsync(string subject, TrashCursor? before, int limit, CancellationToken token);
    Task<Asset?> FindAsync(string subject, Guid id, CancellationToken token);
    Task<RestoreResult> RestoreAsync(string subject, Guid id, CancellationToken token);
    Task<PurgeClaim?> ClaimAsync(CancellationToken token);
    Task<bool> CompleteAsync(Guid assetId, Guid leaseId, CancellationToken token);
}

public sealed class PostgresTrashRepository(NpgsqlDataSource source) : ITrashRepository
{
    private const string Owned = """
        a.uploaded_by=$1 AND EXISTS(SELECT 1 FROM principals p
            JOIN library_members m ON m.subject=p.subject
            WHERE p.subject=$1 AND p.enabled AND m.library_id=a.library_id)
        """;
    private const string Columns = "a.id,a.library_id,a.file_name,a.media_type,a.size,a.sha256,a.has_preview,a.created_at,a.resource_set_id";
    private static Asset Read(NpgsqlDataReader r) => new(r.GetGuid(0), r.GetGuid(1), r.GetString(2), r.GetString(3),
        r.GetInt64(4), r.GetString(5), r.GetBoolean(6), r.GetFieldValue<DateTimeOffset>(7), r.IsDBNull(8) ? null : r.GetGuid(8));

    public async Task<TrashPage> ListAsync(string subject, TrashCursor? before, int limit, CancellationToken token)
    {
        await using var query = source.CreateCommand($"""
            SELECT {Columns},a.deleted_at,a.deleted_at+interval '30 days' FROM assets a
            WHERE {Owned} AND a.deleted_at IS NOT NULL AND a.purged_at IS NULL
                AND a.purge_started_at IS NULL
                AND (NOT a.hidden OR a.resource_set_id IS NULL)
                AND ($2::timestamptz IS NULL OR (a.deleted_at,a.id)<($2,$3))
            ORDER BY a.deleted_at DESC,a.id DESC LIMIT $4
            """);
        query.Parameters.AddWithValue(subject);
        query.Parameters.Add(new NpgsqlParameter { NpgsqlDbType = NpgsqlDbType.TimestampTz, Value = (object?)before?.DeletedAt ?? DBNull.Value });
        query.Parameters.AddWithValue(before?.Id ?? Guid.Empty);
        query.Parameters.AddWithValue(limit + 1);
        var rows = new List<TrashItem>();
        await using var reader = await query.ExecuteReaderAsync(token);
        while (await reader.ReadAsync(token))
            rows.Add(new(Read(reader), reader.GetFieldValue<DateTimeOffset>(9), reader.GetFieldValue<DateTimeOffset>(10)));
        var items = rows.Take(limit).ToArray();
        return new(items, rows.Count > limit ? new(items[^1].DeletedAt, items[^1].Asset.Id) : null);
    }

    public async Task<Asset?> FindAsync(string subject, Guid id, CancellationToken token)
    {
        await using var query = source.CreateCommand($"""
            SELECT {Columns} FROM assets a WHERE {Owned} AND a.id=$2
                AND a.deleted_at IS NOT NULL AND a.purge_started_at IS NULL AND a.purged_at IS NULL
            """);
        query.Parameters.AddWithValue(subject);
        query.Parameters.AddWithValue(id);
        await using var reader = await query.ExecuteReaderAsync(token);
        return await reader.ReadAsync(token) ? Read(reader) : null;
    }

    public async Task<RestoreResult> RestoreAsync(string subject, Guid id, CancellationToken token)
    {
        await using var connection = await source.OpenConnectionAsync(token);
        await using var transaction = await connection.BeginTransactionAsync(token);
        Guid library;
        await using (var lookup = Command(connection, transaction,
            "SELECT lock_asset_owner($1,$2)", subject, id))
        {
            if (await lookup.ExecuteScalarAsync(token) is not Guid value) return RestoreResult.NotFound;
            library = value;
        }
        var revision = await LockAsync(connection, transaction, library, token);
        Guid? group;
        await using (var target = Command(connection, transaction,
            "SELECT coalesce(resource_set_id,pending_resource_set_id) FROM assets WHERE id=$1 FOR UPDATE", id))
        {
            var value = await target.ExecuteScalarAsync(token);
            group = value is Guid set ? set : null;
        }
        object[] parameters = group is Guid resourceSet ? [library, subject, id, resourceSet] : [library, subject, id];
        var groupFilter = group is null ? "a.id=$3" : "(a.id=$3 OR coalesce(a.resource_set_id,a.pending_resource_set_id)=$4)";
        var changes = new List<(Asset Asset, bool Visible)>();
        await using (var query = Command(connection, transaction, $"""
            SELECT {Columns},a.hidden,a.deleted_at IS NOT NULL,
                a.purge_started_at IS NOT NULL OR a.purged_at IS NOT NULL OR a.deleted_at<=now()-interval '30 days'
            FROM assets a WHERE a.library_id=$1 AND a.uploaded_by=$2 AND {groupFilter}
            ORDER BY a.id FOR UPDATE
            """, parameters))
        await using (var reader = await query.ExecuteReaderAsync(token))
        {
            while (await reader.ReadAsync(token))
            {
                if (!reader.IsDBNull(11) && reader.GetBoolean(11)) return RestoreResult.Expired;
                if (reader.GetBoolean(10)) changes.Add((Read(reader), !reader.GetBoolean(9)));
            }
        }
        if (changes.Count != 0)
        {
            var ids = changes.Select(x => x.Asset.Id).ToArray();
            await using (var restore = Command(connection, transaction,
                "UPDATE assets SET deleted_at=NULL WHERE id=ANY($1)", ids))
                await restore.ExecuteNonQueryAsync(token);
            await using (var publications = Command(connection, transaction, """
                UPDATE face_publications SET delivered_at=NULL,lease_id=NULL,lease_until=NULL,
                    next_attempt_at=now(),last_status=NULL WHERE asset_id=ANY($1)
                """, ids))
                await publications.ExecuteNonQueryAsync(token);
            await AppendAsync(connection, transaction, library, revision + 1, changes, token);
        }
        await transaction.CommitAsync(token);
        return RestoreResult.Restored;
    }

    public async Task<PurgeClaim?> ClaimAsync(CancellationToken token)
    {
        // Row locking shares the same serialization point as restore's asset locks.
        await using var query = source.CreateCommand("""
            WITH candidate AS (
                SELECT id FROM assets WHERE deleted_at<=now()-interval '30 days' AND purged_at IS NULL
                    AND (purge_lease_until IS NULL OR purge_lease_until<now())
                ORDER BY deleted_at,id FOR UPDATE SKIP LOCKED LIMIT 1
            )
            UPDATE assets a SET purge_started_at=coalesce(a.purge_started_at,now()),
                purge_lease_id=$1,purge_lease_until=now()+interval '10 minutes'
            FROM candidate c WHERE a.id=c.id RETURNING a.id,a.uploaded_by,a.purge_lease_id
            """);
        query.Parameters.AddWithValue(Guid.NewGuid());
        await using var reader = await query.ExecuteReaderAsync(token);
        return await reader.ReadAsync(token) ? new(reader.GetGuid(0), reader.GetString(1), reader.GetGuid(2)) : null;
    }

    public async Task<bool> CompleteAsync(Guid assetId, Guid leaseId, CancellationToken token)
    {
        await using var query = source.CreateCommand("""
            UPDATE assets SET purged_at=coalesce(purged_at,now()),purge_lease_until=NULL
            WHERE id=$1 AND purge_lease_id=$2 AND purge_started_at IS NOT NULL
                AND (purged_at IS NOT NULL OR purge_lease_until>now())
            """);
        query.Parameters.AddWithValue(assetId);
        query.Parameters.AddWithValue(leaseId);
        return await query.ExecuteNonQueryAsync(token) == 1;
    }
}
