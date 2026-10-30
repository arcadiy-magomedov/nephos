using Nephos.ServiceDefaults;
using Npgsql;
using NpgsqlTypes;

namespace Nephos.Library.Api.Assets;

public sealed record Asset(
    Guid Id, Guid LibraryId, string FileName, string MediaType, long Size, string Sha256,
    bool HasPreview, DateTimeOffset CreatedAt, Guid? ResourceSetId = null, string? SharedBy = null);
public sealed record AssetCursor(DateTimeOffset CreatedAt, Guid Id);
public sealed record AssetPage(IReadOnlyList<Asset> Items, AssetCursor? NextCursor);
public sealed record TimelineBucket(string Date, long Count);

public interface IAssetRepository
{
    Task<bool> CanAccessAsync(string subject, Guid library, CancellationToken token);
    Task<bool> CanUploadAsync(string subject, Guid library, CancellationToken token);
    Task<IReadOnlyList<Asset>> ListAsync(string subject, Guid library, AssetCursor? before, int limit, CancellationToken token);
    Task<Asset?> FindAsync(string subject, Guid id, CancellationToken token, bool owned = false);
    Task<bool> ProjectAsync(AssetMessage message, CancellationToken token);
    Task<IReadOnlyList<TimelineBucket>> TimelineAsync(string subject, Guid library, int? year, int? month, CancellationToken token);
}

public sealed class PostgresAssetRepository(NpgsqlDataSource source) : IAssetRepository
{
    private const string Columns = "a.id,a.library_id,a.file_name,a.media_type,a.size,a.sha256,a.has_preview,a.created_at,a.resource_set_id";
    private static Asset Read(NpgsqlDataReader reader) => new(reader.GetGuid(0), reader.GetGuid(1), reader.GetString(2),
        reader.GetString(3), reader.GetInt64(4), reader.GetString(5), reader.GetBoolean(6), reader.GetFieldValue<DateTimeOffset>(7),
        reader.IsDBNull(8) ? null : reader.GetGuid(8), reader.IsDBNull(9) ? null : reader.GetString(9));

    public async Task<IReadOnlyList<TimelineBucket>> TimelineAsync(string subject, Guid library, int? year, int? month, CancellationToken token)
    {
        var start = new DateTimeOffset(year ?? 1800, month ?? 1, 1, 0, 0, 0, TimeSpan.Zero);
        var end = month is not null ? start.AddMonths(1) : year is not null ? start.AddYears(1) : DateTimeOffset.UtcNow.AddDays(2);
        await using var command = source.CreateCommand("""
            SELECT to_char(date_trunc($3, a.created_at AT TIME ZONE 'UTC'),'YYYY-MM-DD') AS bucket,count(*)
            FROM assets a
            WHERE can_read_asset($1,a.id) AND a.library_id=$2 AND NOT a.hidden AND a.created_at >= $4 AND a.created_at < $5
            GROUP BY bucket ORDER BY bucket DESC
            """);
        foreach (var value in new object[] { subject, library, month is not null ? "day" : year is not null ? "month" : "year", start, end })
            command.Parameters.AddWithValue(value);
        await using var reader = await command.ExecuteReaderAsync(token);
        var rows = new List<TimelineBucket>();
        while (await reader.ReadAsync(token)) rows.Add(new(reader.GetString(0), reader.GetInt64(1)));
        return rows;
    }

    public async Task<bool> CanAccessAsync(string subject, Guid library, CancellationToken token)
    {
        await using var query = source.CreateCommand("SELECT can_read_library($1,$2)");
        query.Parameters.AddWithValue(subject);
        query.Parameters.AddWithValue(library);
        return (bool)(await query.ExecuteScalarAsync(token))!;
    }

    public async Task<bool> CanUploadAsync(string subject, Guid library, CancellationToken token)
    {
        await using var command = source.CreateCommand("""
            SELECT EXISTS(SELECT 1 FROM library_members m JOIN principals p ON p.subject=m.subject
            WHERE m.subject=$1 AND m.library_id=$2 AND p.enabled)
            """);
        command.Parameters.AddWithValue(subject);
        command.Parameters.AddWithValue(library);
        return (bool)(await command.ExecuteScalarAsync(token))!;
    }

    public async Task<IReadOnlyList<Asset>> ListAsync(string subject, Guid library, AssetCursor? before, int limit, CancellationToken token)
    {
        await using var command = source.CreateCommand($"""
            SELECT {Columns},CASE WHEN a.uploaded_by<>$1 THEN coalesce(owner.display_name,'Known user') END FROM assets a
            JOIN principals owner ON owner.subject=a.uploaded_by
            WHERE can_read_asset($1,a.id) AND a.library_id=$2 AND NOT a.hidden
            AND ($3::timestamptz IS NULL OR (a.created_at,a.id)<($3,$4))
            ORDER BY a.created_at DESC,a.id DESC LIMIT $5
            """);
        command.Parameters.AddWithValue(subject);
        command.Parameters.AddWithValue(library);
        command.Parameters.Add(new NpgsqlParameter { NpgsqlDbType = NpgsqlDbType.TimestampTz, Value = (object?)before?.CreatedAt ?? DBNull.Value });
        command.Parameters.AddWithValue(before?.Id ?? Guid.Empty);
        command.Parameters.AddWithValue(limit);
        await using var reader = await command.ExecuteReaderAsync(token);
        var assets = new List<Asset>();
        while (await reader.ReadAsync(token)) assets.Add(Read(reader));
        return assets;
    }

    public async Task<Asset?> FindAsync(string subject, Guid id, CancellationToken token, bool owned = false)
    {
        await using var command = source.CreateCommand($"""
            SELECT {Columns},CASE WHEN a.uploaded_by<>$2 THEN coalesce(owner.display_name,'Known user') END FROM assets a
            JOIN principals owner ON owner.subject=a.uploaded_by
            WHERE a.id=$1 AND can_read_asset($2,a.id) AND (NOT $3 OR a.uploaded_by=$2)
            """);
        command.Parameters.AddWithValue(id);
        command.Parameters.AddWithValue(subject);
        command.Parameters.AddWithValue(owned);
        await using var reader = await command.ExecuteReaderAsync(token);
        return await reader.ReadAsync(token) ? Read(reader) : null;
    }

    public async Task<bool> ProjectAsync(AssetMessage message, CancellationToken token)
    {
        await using var connection = await source.OpenConnectionAsync(token);
        await using var transaction = await connection.BeginTransactionAsync(token);
        await using (var membership = PostgresGalleryJournal.Command(connection, transaction,
            "SELECT 1 FROM library_members WHERE library_id=$1 AND subject=$2", message.LibraryId, message.Subject))
            if (await membership.ExecuteScalarAsync(token) is null) return false;
        long revision;
        try { revision = await PostgresGalleryJournal.LockAsync(connection, transaction, message.LibraryId, token); }
        catch (PostgresException exception) when (exception.SqlState == PostgresErrorCodes.ForeignKeyViolation) { return false; }
        await using (var existing = PostgresGalleryJournal.Command(connection, transaction,
            "SELECT EXISTS(SELECT 1 FROM assets WHERE id=$1)", message.Id))
            if ((bool)(await existing.ExecuteScalarAsync(token))!) return true;
        await using var command = new NpgsqlCommand("""
            INSERT INTO assets(id,library_id,uploaded_by,file_name,media_type,size,sha256,has_preview,created_at,pending_resource_set_id,hidden)
            SELECT $1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11
            WHERE EXISTS(SELECT 1 FROM library_members WHERE library_id=$2 AND subject=$3)
            ON CONFLICT DO NOTHING
            """, connection, transaction);
        foreach (var value in new object[] { message.Id, message.LibraryId, message.Subject, message.FileName,
            message.MediaType, message.Size, message.Sha256, message.HasPreview, message.CreatedAt })
            command.Parameters.AddWithValue(value);
        command.Parameters.Add(new NpgsqlParameter { NpgsqlDbType = NpgsqlDbType.Uuid, Value = (object?)message.ResourceSetId ?? DBNull.Value });
        command.Parameters.AddWithValue(message.ResourceSetId is not null);
        if (await command.ExecuteNonQueryAsync(token) == 0) return false;
        if (message.ResourceSetId is null)
            await PostgresGalleryJournal.AppendAsync(connection, transaction, message.LibraryId, revision + 1,
                [(new(message.Id, message.LibraryId, message.FileName, message.MediaType, message.Size, message.Sha256,
                    message.HasPreview, message.CreatedAt), true)], token);
        await transaction.CommitAsync(token);
        return true;
    }
}
