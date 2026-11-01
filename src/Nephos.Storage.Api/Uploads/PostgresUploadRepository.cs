using System.Data;
using System.Diagnostics;
using System.Text.Json;
using Nephos.ServiceDefaults;
using Npgsql;

namespace Nephos.Storage.Api.Uploads;

public interface IUploadRepository
{
    Task<Upload> CreateAsync(UploadIntent intent, string subject, CancellationToken token);
    Task<Upload?> FindAsync(Guid id, CancellationToken token);
    Task<int[]> PartsAsync(Guid id, CancellationToken token);
    Task PutAsync(Guid id, int part, Stream source, long? length, CancellationToken token);
    Task SealAsync(Guid id, CancellationToken token);
    Task CancelAsync(Guid id, CancellationToken token);
    Task<bool> VerifyNextAsync(CancellationToken token);
    Task<bool> PublishNextAsync(Func<byte[], CancellationToken, Task> publish, CancellationToken token);
    Task CleanupAsync(CancellationToken token);
    Task<(Guid HoldId, DateTimeOffset RetainedUntil)> RetainAsync(Guid id, CancellationToken token);
    Task<StorageMetrics> MetricsAsync(CancellationToken token);
}

public sealed class PostgresUploadRepository(NpgsqlDataSource dataSource, IVolumeStore volume) : IUploadRepository
{
    public async Task<StorageMetrics> MetricsAsync(CancellationToken token)
    {
        await using var query = dataSource.CreateCommand("""
            SELECT count(*) FILTER(WHERE state='uploading'),
                count(*) FILTER(WHERE state='verifying'),
                count(*) FILTER(WHERE state='failed' AND updated_at>now()-interval '1 day'),
                coalesce(extract(epoch FROM now()-min(updated_at) FILTER(WHERE state='verifying')),0)::double precision,
                (SELECT count(*) FROM outbox WHERE sent_at IS NULL)
            FROM uploads WHERE state IN ('uploading','verifying','failed')
            """);
        query.CommandTimeout = 10;
        await using var reader = await query.ExecuteReaderAsync(token);
        await reader.ReadAsync(token);
        return new(reader.GetInt64(0), reader.GetInt64(1), reader.GetInt64(2), reader.GetDouble(3), reader.GetInt64(4), 0, 0);
    }

    private const string Columns = "id,subject,library_id,file_name,media_type,size,expected_hash,state,sha256,has_preview,error,coalesce(captured_at,created_at),trace_parent,resource_set_id";
    private static NpgsqlCommand Command(NpgsqlConnection connection, NpgsqlTransaction? transaction, string sql, params object[] values)
    {
        var command = new NpgsqlCommand(sql, connection, transaction);
        foreach (var value in values) command.Parameters.AddWithValue(value);
        return command;
    }

    private static Upload Read(NpgsqlDataReader reader) => new(
        reader.GetGuid(0), reader.GetString(1), reader.GetGuid(2), reader.GetString(3), reader.GetString(4),
        reader.GetInt64(5), reader.GetString(6), reader.GetString(7), reader.IsDBNull(8) ? null : reader.GetString(8),
        reader.GetBoolean(9), reader.IsDBNull(10) ? null : reader.GetString(10), reader.GetFieldValue<DateTimeOffset>(11),
        reader.IsDBNull(12) ? null : reader.GetString(12), reader.IsDBNull(13) ? null : reader.GetGuid(13));

    public async Task<(Guid HoldId, DateTimeOffset RetainedUntil)> RetainAsync(Guid id, CancellationToken token)
    {
        await using var connection = await dataSource.OpenConnectionAsync(token);
        await using var transaction = await connection.BeginTransactionAsync(token);
        await BlobCleanupRepository.LockAsync(connection, transaction, token);
        var upload = await SingleAsync(Command(connection, transaction,
            $"SELECT {Columns} FROM uploads WHERE id=$1 AND released_at IS NULL", id), token);
        if (upload is not { State: "stored", Sha256: not null }) throw new UploadConflictException("Original is not committed.");
        await using (var stream = File.OpenRead(volume.OriginalPath(upload.Sha256)))
        {
            var hash = Convert.ToHexStringLower(await System.Security.Cryptography.SHA256.HashDataAsync(stream, token));
            if (stream.Length != upload.Size || hash != upload.Sha256) throw new IOException("Original integrity check failed.");
        }
        await using var command = Command(connection, transaction, """
            INSERT INTO retention_holds(asset_id,hold_id,retained_until) VALUES($1,$2,now()+interval '30 days')
            ON CONFLICT(asset_id) DO UPDATE SET retained_until=greatest(retention_holds.retained_until,EXCLUDED.retained_until)
            RETURNING hold_id,retained_until
            """);
        command.Parameters.AddWithValue(id);
        command.Parameters.AddWithValue(Guid.NewGuid());
        (Guid HoldId, DateTimeOffset RetainedUntil) hold;
        await using (var reader = await command.ExecuteReaderAsync(token))
        {
            await reader.ReadAsync(token);
            hold = (reader.GetGuid(0), reader.GetFieldValue<DateTimeOffset>(1));
        }
        await transaction.CommitAsync(token);
        return hold;
    }

    private static async Task<Upload?> SingleAsync(NpgsqlCommand command, CancellationToken token)
    {
        await using (command)
        await using (var reader = await command.ExecuteReaderAsync(token))
            return await reader.ReadAsync(token) ? Read(reader) : null;
    }

    public async Task<Upload?> FindAsync(Guid id, CancellationToken token)
    {
        await using var connection = await dataSource.OpenConnectionAsync(token);
        return await SingleAsync(Command(connection, null, $"SELECT {Columns} FROM uploads WHERE id=$1 AND released_at IS NULL", id), token);
    }

    public async Task<Upload> CreateAsync(UploadIntent intent, string subject, CancellationToken token)
    {
        await using var connection = await dataSource.OpenConnectionAsync(token);
        await using var transaction = await connection.BeginTransactionAsync(token);
        await using (var gate = Command(connection, transaction, "SELECT pg_advisory_xact_lock(48465002)"))
            await gate.ExecuteNonQueryAsync(token);
        await using (var released = Command(connection, transaction,
            "SELECT EXISTS(SELECT 1 FROM cleanup_releases WHERE asset_id=$1)", intent.Id))
            if ((bool)(await released.ExecuteScalarAsync(token))!)
                throw new UploadConflictException("A purged upload ID cannot be reused.");
        await using (var deleting = Command(connection, transaction,
            "SELECT EXISTS(SELECT 1 FROM blobs WHERE sha256=$1 AND deleting)", intent.Sha256))
            if ((bool)(await deleting.ExecuteScalarAsync(token))!)
                throw new UploadConflictException("Blob cleanup is pending. Retry with the same intent later.");
        var previous = await SingleAsync(Command(connection, transaction, $"SELECT {Columns} FROM uploads WHERE id=$1", intent.Id), token);
        if (previous is not null)
        {
            if (previous.Subject != subject || previous.LibraryId != intent.LibraryId || previous.ExpectedHash != intent.Sha256 ||
                previous.Size != intent.Size || previous.FileName != intent.FileName || previous.MediaType != intent.MediaType ||
                previous.ResourceSetId != intent.ResourceSetId)
                throw new UploadConflictException("The idempotency ID is already bound to a different intent.");
            return previous;
        }
        var duplicate = await SingleAsync(Command(connection, transaction, $"""
            SELECT {Columns} FROM uploads WHERE subject=$1 AND library_id=$2 AND expected_hash=$3 AND size=$4 AND state='stored' AND released_at IS NULL
            ORDER BY (resource_set_id IS NULL) DESC,created_at,id LIMIT 1
            """, subject, intent.LibraryId, intent.Sha256, intent.Size), token);
        if (duplicate is not null && intent.ResourceSetId is null && duplicate.ResourceSetId is null) return duplicate;
        if (duplicate is not null)
        {
            var file = new FileInfo(volume.OriginalPath(duplicate.ExpectedHash));
            if (!file.Exists || file.Length != intent.Size) throw new IOException("Previously stored original is unavailable.");
            await InsertIntentAsync(connection, transaction, intent, subject, token);
            var copy = new Upload(intent.Id, subject, intent.LibraryId, intent.FileName, intent.MediaType, intent.Size,
                intent.Sha256, "stored", intent.Sha256, duplicate.HasPreview, null,
                (intent.CapturedAt ?? DateTimeOffset.UtcNow).ToUniversalTime(), Activity.Current?.Id, intent.ResourceSetId);
            await StoreAsync(connection, transaction, copy, intent.Sha256, duplicate.HasPreview, token);
            await transaction.CommitAsync(token);
            return copy;
        }
        await using (var quota = Command(connection, transaction, """
            SELECT count(*) FILTER(WHERE subject=$1), coalesce(sum(size),0)
            FROM uploads WHERE state IN ('uploading','verifying')
            """, subject))
        await using (var reader = await quota.ExecuteReaderAsync(token))
        {
            await reader.ReadAsync(token);
            if (reader.GetInt64(0) >= 16 || reader.GetFieldValue<decimal>(1) + intent.Size > 64L * 1024 * 1024 * 1024)
                throw new UploadQuotaException("Pending upload budget exhausted. Complete existing uploads first.");
        }
        if (!volume.HasSpace(intent.Size * 2)) throw new UploadQuotaException("Insufficient storage headroom for staging and verification.");
        await InsertIntentAsync(connection, transaction, intent, subject, token);
        await transaction.CommitAsync(token);
        return (await FindAsync(intent.Id, token))!;
    }

    private static async Task InsertIntentAsync(NpgsqlConnection connection, NpgsqlTransaction transaction,
        UploadIntent intent, string subject, CancellationToken token)
    {
        await using var insert = Command(connection, transaction, """
            INSERT INTO uploads(id,subject,library_id,file_name,media_type,size,expected_hash,state,captured_at,resource_set_id)
            VALUES($1,$2,$3,$4,$5,$6,$7,'uploading',$8,$9)
            """, intent.Id, subject, intent.LibraryId, intent.FileName, intent.MediaType, intent.Size, intent.Sha256,
            (intent.CapturedAt ?? DateTimeOffset.UtcNow).ToUniversalTime());
        insert.Parameters.Add(new NpgsqlParameter { NpgsqlDbType = NpgsqlTypes.NpgsqlDbType.Uuid, Value = (object?)intent.ResourceSetId ?? DBNull.Value });
        await insert.ExecuteNonQueryAsync(token);
    }

    private static async Task StoreAsync(NpgsqlConnection connection, NpgsqlTransaction transaction,
        Upload upload, string hash, bool preview, CancellationToken token)
    {
        var message = new AssetMessage(upload.Id, upload.LibraryId, upload.Subject, upload.FileName,
            upload.MediaType, upload.Size, hash, preview, upload.CreatedAt, Activity.Current?.Id, upload.ResourceSetId);
        await using (var blob = Command(connection, transaction,
            "INSERT INTO blobs(sha256,size) VALUES($1,$2) ON CONFLICT DO NOTHING", hash, upload.Size))
            await blob.ExecuteNonQueryAsync(token);
        await using (var reference = Command(connection, transaction,
            "INSERT INTO blob_references(asset_id,sha256) VALUES($1,$2) ON CONFLICT DO NOTHING", upload.Id, hash))
            await reference.ExecuteNonQueryAsync(token);
        await using (var messageInsert = Command(connection, transaction,
            "INSERT INTO outbox(id,payload) VALUES($1,$2::jsonb) ON CONFLICT DO NOTHING", upload.Id, JsonSerializer.Serialize(message)))
            await messageInsert.ExecuteNonQueryAsync(token);
        await using (var commit = Command(connection, transaction,
            "UPDATE uploads SET state='stored',sha256=$2,has_preview=$3,updated_at=now() WHERE id=$1", upload.Id, hash, preview))
            await commit.ExecuteNonQueryAsync(token);
    }

    public async Task<int[]> PartsAsync(Guid id, CancellationToken token)
    {
        await using var command = dataSource.CreateCommand("SELECT part FROM upload_parts WHERE upload_id=$1 ORDER BY part");
        command.Parameters.AddWithValue(id);
        await using var reader = await command.ExecuteReaderAsync(token);
        var parts = new List<int>();
        while (await reader.ReadAsync(token)) parts.Add(reader.GetInt32(0));
        return parts.ToArray();
    }

    public async Task PutAsync(Guid id, int part, Stream source, long? length, CancellationToken token)
    {
        await using var connection = await dataSource.OpenConnectionAsync(token);
        await using var transaction = await connection.BeginTransactionAsync(token);
        var upload = await SingleAsync(Command(connection, transaction, $"SELECT {Columns} FROM uploads WHERE id=$1 FOR UPDATE", id), token)
            ?? throw new UploadConflictException("Upload not found.");
        if (upload.State != "uploading") throw new UploadConflictException("Upload is sealed.");
        var expected = Math.Min(MediaProtocol.ChunkSize, upload.Size - (long)part * MediaProtocol.ChunkSize);
        if (part < 0 || expected <= 0 || expected != length) throw new UploadConflictException("Invalid part index or Content-Length.");
        if (!volume.HasSpace(expected)) throw new UploadQuotaException("Storage is below its safety reserve.");
        var hash = await volume.SavePartAsync(id, part, source, (int)expected, token);
        await using (var command = Command(connection, transaction, """
            INSERT INTO upload_parts(upload_id,part,sha256) VALUES($1,$2,$3) ON CONFLICT DO NOTHING
            """, id, part, hash))
            await command.ExecuteNonQueryAsync(token);
        await using (var touch = Command(connection, transaction, "UPDATE uploads SET updated_at=now() WHERE id=$1", id))
            await touch.ExecuteNonQueryAsync(token);
        await transaction.CommitAsync(token);
    }

    public async Task SealAsync(Guid id, CancellationToken token)
    {
        await using var connection = await dataSource.OpenConnectionAsync(token);
        await using var transaction = await connection.BeginTransactionAsync(token);
        var upload = await SingleAsync(Command(connection, transaction, $"SELECT {Columns} FROM uploads WHERE id=$1 FOR UPDATE", id), token)
            ?? throw new UploadConflictException("Upload not found.");
        if (upload.State is "stored" or "verifying") return;
        if (upload.State == "failed") throw new UploadConflictException("Failed uploads require a new intent.");
        await using (var count = Command(connection, transaction, "SELECT count(*) FROM upload_parts WHERE upload_id=$1", id))
            if ((long)(await count.ExecuteScalarAsync(token))! != (upload.Size + MediaProtocol.ChunkSize - 1) / MediaProtocol.ChunkSize)
                throw new UploadConflictException("One or more chunks are missing.");
        await using (var seal = Command(connection, transaction,
            "UPDATE uploads SET state='verifying',updated_at=now(),trace_parent=$2 WHERE id=$1", id, Activity.Current?.Id ?? ""))
            await seal.ExecuteNonQueryAsync(token);
        await transaction.CommitAsync(token);
    }

    public async Task CancelAsync(Guid id, CancellationToken token)
    {
        await using var command = dataSource.CreateCommand("""
            UPDATE uploads SET state='failed',error='Cancelled by uploader.',updated_at=now()
            WHERE id=$1 AND state IN ('uploading','failed')
            """);
        command.Parameters.AddWithValue(id);
        if (await command.ExecuteNonQueryAsync(token) == 0)
            throw new UploadConflictException("Sealed or committed uploads cannot be cancelled.");
    }

    public async Task<bool> VerifyNextAsync(CancellationToken token)
    {
        await using var connection = await dataSource.OpenConnectionAsync(token);
        await using var transaction = await connection.BeginTransactionAsync(IsolationLevel.ReadCommitted, token);
        await BlobCleanupRepository.LockAsync(connection, transaction, token);
        var upload = await SingleAsync(Command(connection, transaction, $"""
            SELECT {Columns} FROM uploads WHERE state='verifying' ORDER BY created_at LIMIT 1 FOR UPDATE SKIP LOCKED
            """), token);
        if (upload is null) return false;
        ActivityContext.TryParse(upload.TraceParent, null, out var parent);
        using var activity = MediaProtocol.Activities.StartActivity("verify original", ActivityKind.Consumer, parent);
        try
        {
            var hash = await volume.AssembleAsync(upload, token);
            var preview = await volume.CreatePreviewAsync(hash, upload.MediaType, token);
            await StoreAsync(connection, transaction, upload, hash, preview, token);
        }
        catch (UploadConflictException exception)
        {
            await using var fail = Command(connection, transaction,
                "UPDATE uploads SET state='failed',error=$2,updated_at=now() WHERE id=$1", upload.Id, exception.Message);
            await fail.ExecuteNonQueryAsync(token);
        }
        await transaction.CommitAsync(token);
        return true;
    }

    public async Task<bool> PublishNextAsync(Func<byte[], CancellationToken, Task> publish, CancellationToken token)
    {
        await using var connection = await dataSource.OpenConnectionAsync(token);
        await using var transaction = await connection.BeginTransactionAsync(token);
        Guid id;
        string payload;
        await using (var query = Command(connection, transaction,
            "SELECT id,payload::text FROM outbox WHERE sent_at IS NULL LIMIT 1 FOR UPDATE SKIP LOCKED"))
        await using (var reader = await query.ExecuteReaderAsync(token))
        {
            if (!await reader.ReadAsync(token)) return false;
            id = reader.GetGuid(0);
            payload = reader.GetString(1);
        }
        await publish(System.Text.Encoding.UTF8.GetBytes(payload), token);
        await using (var update = Command(connection, transaction, "UPDATE outbox SET sent_at=now() WHERE id=$1", id))
            await update.ExecuteNonQueryAsync(token);
        await transaction.CommitAsync(token);
        return true;
    }

    public async Task CleanupAsync(CancellationToken token)
    {
        await using var connection = await dataSource.OpenConnectionAsync(token);
        await using var transaction = await connection.BeginTransactionAsync(token);
        await using (var expire = Command(connection, transaction, """
            UPDATE uploads SET state='failed',error='Upload expired after 24 hours without progress.'
            WHERE state='uploading' AND updated_at < now()-interval '24 hours'
            """))
            await expire.ExecuteNonQueryAsync(token);
        var ids = new List<Guid>();
        await using (var find = Command(connection, transaction, """
            SELECT id FROM uploads WHERE state IN ('stored','failed')
            AND NOT staging_cleaned LIMIT 32 FOR UPDATE SKIP LOCKED
            """))
        await using (var reader = await find.ExecuteReaderAsync(token))
            while (await reader.ReadAsync(token)) ids.Add(reader.GetGuid(0));
        foreach (var id in ids)
        {
            volume.RemoveStaging(id);
            await using (var remove = Command(connection, transaction, "DELETE FROM upload_parts WHERE upload_id=$1", id))
                await remove.ExecuteNonQueryAsync(token);
            await using (var cleaned = Command(connection, transaction, "UPDATE uploads SET staging_cleaned=true WHERE id=$1", id))
                await cleaned.ExecuteNonQueryAsync(token);
        }
        await transaction.CommitAsync(token);
    }
}
