using Nephos.ServiceDefaults;
using Microsoft.AspNetCore.Mvc;
using Npgsql;

namespace Nephos.Storage.Api.Uploads;

public sealed record CleanupReleaseRequest(string Subject);

public sealed class BlobCleanupRepository(NpgsqlDataSource dataSource, IVolumeStore volume)
{
    // Strict lock DAG order (never invert): QuotaGate -> UploadIdLock -> HashLock.
    // The committed deleting bit fences new writers across process crashes.
    public const long QuotaGate = 48465001;
    public const long Gate = 48465002;
    public const long UploadGate = 48465003;

    internal static async Task LockQuotaAsync(NpgsqlConnection connection, NpgsqlTransaction transaction, CancellationToken token)
    {
        await using var command = new NpgsqlCommand($"SELECT pg_advisory_xact_lock({QuotaGate})", connection, transaction);
        await command.ExecuteNonQueryAsync(token);
    }

    internal static async Task LockUploadAsync(NpgsqlConnection connection, NpgsqlTransaction transaction, Guid assetId, CancellationToken token)
    {
        await using var command = new NpgsqlCommand(
            $"SELECT pg_advisory_xact_lock(hashtextextended($1, {UploadGate}))", connection, transaction);
        command.Parameters.AddWithValue(assetId.ToString("N"));
        await command.ExecuteNonQueryAsync(token);
    }

    public static async Task LockHashAsync(NpgsqlConnection connection, NpgsqlTransaction transaction, string sha256, CancellationToken token)
    {
        await using var command = new NpgsqlCommand(
            $"SELECT pg_advisory_xact_lock(hashtextextended($1, {Gate}))", connection, transaction);
        command.Parameters.AddWithValue(sha256);
        await command.ExecuteNonQueryAsync(token);
    }

    public async Task ReleaseAsync(Guid assetId, string subject, CancellationToken token)
    {
        await using var connection = await dataSource.OpenConnectionAsync(token);
        await using var transaction = await connection.BeginTransactionAsync(token);
        await LockUploadAsync(connection, transaction, assetId, token);
        string? hash = null;
        await using (var query = new NpgsqlCommand("""
            SELECT subject,state,released_at,coalesce(sha256,expected_hash),
                EXISTS(SELECT 1 FROM outbox WHERE id=$1 AND sent_at IS NULL)
            FROM uploads WHERE id=$1
            """, connection, transaction))
        {
            query.Parameters.AddWithValue(assetId);
            await using var reader = await query.ExecuteReaderAsync(token);
            if (await reader.ReadAsync(token))
            {
                if (reader.GetString(0) != subject)
                    throw new UploadConflictException("Cleanup owner does not match the upload.");
                if (reader.IsDBNull(2) && (reader.GetString(1) != "stored" || reader.GetBoolean(4)))
                    throw new UploadConflictException("Upload or publication is still active.");
                hash = reader.GetString(3);
            }
        }
        if (hash is not null) await LockHashAsync(connection, transaction, hash, token);
        await using (var insert = new NpgsqlCommand("""
            INSERT INTO cleanup_releases(asset_id,subject) VALUES($1,$2)
            ON CONFLICT(asset_id) DO NOTHING;
            """, connection, transaction))
        {
            insert.Parameters.AddWithValue(assetId);
            insert.Parameters.AddWithValue(subject);
            await insert.ExecuteNonQueryAsync(token);
        }
        await using (var check = new NpgsqlCommand("SELECT subject FROM cleanup_releases WHERE asset_id=$1", connection, transaction))
        {
            check.Parameters.AddWithValue(assetId);
            if ((string?)await check.ExecuteScalarAsync(token) != subject)
                throw new UploadConflictException("Cleanup ID is bound to a different owner.");
        }
        foreach (var sql in new[]
        {
            "DELETE FROM blob_references WHERE asset_id=$1",
            "UPDATE uploads SET released_at=coalesce(released_at,now()) WHERE id=$1"
        })
        {
            await using var release = new NpgsqlCommand(sql, connection, transaction);
            release.Parameters.AddWithValue(assetId);
            await release.ExecuteNonQueryAsync(token);
        }
        await transaction.CommitAsync(token);
    }

    private const string Eligible = """
        NOT EXISTS(SELECT 1 FROM blob_references r WHERE r.sha256=b.sha256)
        AND NOT EXISTS(SELECT 1 FROM uploads u WHERE u.expected_hash=b.sha256 AND u.state IN ('uploading','verifying'))
        AND NOT EXISTS(SELECT 1 FROM retention_holds h JOIN uploads u ON u.id=h.asset_id
            WHERE u.sha256=b.sha256 AND h.retained_until>now())
        AND NOT EXISTS(SELECT 1 FROM outbox o JOIN uploads u ON u.id=o.id
            WHERE u.sha256=b.sha256 AND o.sent_at IS NULL)
        """;

    public async Task<bool> CollectNextAsync(CancellationToken token)
    {
        await using var connection = await dataSource.OpenConnectionAsync(token);
        string? hash;
        await using (var select = new NpgsqlCommand($"""
            SELECT b.sha256 FROM blobs b WHERE {Eligible}
            ORDER BY b.deleting DESC,b.created_at,b.sha256 LIMIT 1
            """, connection))
        {
            hash = (string?)await select.ExecuteScalarAsync(token);
            if (hash is null) return false;
        }
        // Commit intent under per-hash lock before unlinking. A crash leaves a durable fence, never live references.
        await using (var transaction = await connection.BeginTransactionAsync(token))
        {
            await LockHashAsync(connection, transaction, hash, token);
            await using var recheck = new NpgsqlCommand($"""
                SELECT count(*) FROM blobs b WHERE b.sha256=$1 AND {Eligible}
                """, connection, transaction);
            recheck.Parameters.AddWithValue(hash);
            if ((long)(await recheck.ExecuteScalarAsync(token))! == 0) return false;
            await using var fence = new NpgsqlCommand("UPDATE blobs SET deleting=true WHERE sha256=$1", connection, transaction);
            fence.Parameters.AddWithValue(hash);
            await fence.ExecuteNonQueryAsync(token);
            await transaction.CommitAsync(token);
        }
        await using (var transaction = await connection.BeginTransactionAsync(token))
        {
            await LockHashAsync(connection, transaction, hash, token);
            await using var check = new NpgsqlCommand($"""
                SELECT count(*) FROM blobs b WHERE b.sha256=$1 AND b.deleting AND {Eligible}
                """, connection, transaction);
            check.Parameters.AddWithValue(hash);
            if ((long)(await check.ExecuteScalarAsync(token))! == 0) return true;
            volume.RemoveBlob(hash);
            await using var remove = new NpgsqlCommand("DELETE FROM blobs WHERE sha256=$1 AND deleting", connection, transaction);
            remove.Parameters.AddWithValue(hash);
            await remove.ExecuteNonQueryAsync(token);
            await transaction.CommitAsync(token);
        }
        return true;
    }

    public async Task<bool> EnsurePreviewAsync(Guid id, int size, CancellationToken token)
    {
        string hash, mediaType;
        await using (var connection = await dataSource.OpenConnectionAsync(token))
        await using (var query = new NpgsqlCommand("""
            SELECT u.sha256,u.media_type FROM uploads u JOIN blobs b ON b.sha256=u.sha256
            WHERE u.id=$1 AND u.state='stored' AND u.released_at IS NULL AND NOT b.deleting
            """, connection))
        {
            query.Parameters.AddWithValue(id);
            await using var reader = await query.ExecuteReaderAsync(token);
            if (!await reader.ReadAsync(token)) return false;
            hash = reader.GetString(0);
            mediaType = reader.GetString(1);
        }
        if (File.Exists(volume.ResolvePreviewPath(hash, size))) return true;
        var original = volume.OriginalPath(hash);
        if (!File.Exists(original)) return false;
        // Render into lease-private temp files completely outside DB transactions/locks.
        Dictionary<int, string>? prepared;
        try
        {
            prepared = await volume.PreparePreviewsAsync(original, hash, mediaType, Guid.NewGuid(), token, size);
        }
        catch (FileNotFoundException) { return false; }
        if (prepared is null) return false;
        try
        {
            await using var connection = await dataSource.OpenConnectionAsync(token);
            await using var transaction = await connection.BeginTransactionAsync(token);
            await LockHashAsync(connection, transaction, hash, token);
            await using var alive = new NpgsqlCommand(
                "SELECT EXISTS(SELECT 1 FROM blobs WHERE sha256=$1 AND NOT deleting)", connection, transaction);
            alive.Parameters.AddWithValue(hash);
            if (!(bool)(await alive.ExecuteScalarAsync(token))!)
            {
                volume.CleanupPreparedPreviews(prepared);
                return false;
            }
            volume.PublishPreparedPreviews(hash, prepared);
            await transaction.CommitAsync(token);
            return File.Exists(volume.ResolvePreviewPath(hash, size));
        }
        catch
        {
            volume.CleanupPreparedPreviews(prepared);
            throw;
        }
    }
}

public static class BlobCleanupEndpoints
{
    public static void MapBlobCleanup(this WebApplication app)
    {
        app.MapInternalV1("/cleanup/{assetId:guid}", ["DELETE"], async (
            Guid assetId, [FromBody] CleanupReleaseRequest request, HttpContext context, IConfiguration configuration,
            BlobCleanupRepository repository, CancellationToken token) =>
        {
            if (!MediaProtocol.IsInternal(context, configuration)) return Results.Unauthorized();
            if (string.IsNullOrWhiteSpace(request.Subject) || request.Subject.Length > 256) return Results.BadRequest();
            await repository.ReleaseAsync(assetId, request.Subject, token);
            return Results.NoContent();
        });
        app.MapInternalV1("/cleanup/gc", ["POST"], async (
            HttpContext context, IConfiguration configuration, BlobCleanupRepository repository, CancellationToken token) =>
        {
            if (!MediaProtocol.IsInternal(context, configuration)) return Results.Unauthorized();
            var collected = 0;
            while (collected < 100 && await repository.CollectNextAsync(token)) collected++;
            return Results.Ok(new { collected });
        });
    }
}
