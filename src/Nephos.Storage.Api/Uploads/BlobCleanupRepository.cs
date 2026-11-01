using Nephos.ServiceDefaults;
using Microsoft.AspNetCore.Mvc;
using Npgsql;

namespace Nephos.Storage.Api.Uploads;

public sealed record CleanupReleaseRequest(string Subject);

public sealed class BlobCleanupRepository(NpgsqlDataSource dataSource, IVolumeStore volume)
{
    // All reference creation, hold creation and file publication share this gate.
    // The committed deleting bit fences new writers across process crashes.
    public const long Gate = 48465002;

    internal static async Task LockAsync(NpgsqlConnection connection, NpgsqlTransaction transaction, CancellationToken token)
    {
        await using var command = new NpgsqlCommand($"SELECT pg_advisory_xact_lock({Gate})", connection, transaction);
        await command.ExecuteNonQueryAsync(token);
    }

    public async Task ReleaseAsync(Guid assetId, string subject, CancellationToken token)
    {
        await using var connection = await dataSource.OpenConnectionAsync(token);
        await using var transaction = await connection.BeginTransactionAsync(token);
        await LockAsync(connection, transaction, token);
        await using (var query = new NpgsqlCommand("""
            SELECT subject,state,released_at,
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
                if (reader.IsDBNull(2) && (reader.GetString(1) != "stored" || reader.GetBoolean(3)))
                    throw new UploadConflictException("Upload or publication is still active.");
            }
        }
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
        // Commit intent before unlinking. A crash leaves a durable fence, never live references.
        await using (var transaction = await connection.BeginTransactionAsync(token))
        {
            await LockAsync(connection, transaction, token);
            await using var select = new NpgsqlCommand($"""
                SELECT b.sha256 FROM blobs b WHERE {Eligible}
                ORDER BY b.deleting DESC,b.created_at,b.sha256 LIMIT 1
                """, connection, transaction);
            hash = (string?)await select.ExecuteScalarAsync(token);
            if (hash is null) return false;
            await using var fence = new NpgsqlCommand("UPDATE blobs SET deleting=true WHERE sha256=$1", connection, transaction);
            fence.Parameters.AddWithValue(hash);
            await fence.ExecuteNonQueryAsync(token);
            await transaction.CommitAsync(token);
        }
        await using (var transaction = await connection.BeginTransactionAsync(token))
        {
            await LockAsync(connection, transaction, token);
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
        await using var connection = await dataSource.OpenConnectionAsync(token);
        await using var transaction = await connection.BeginTransactionAsync(token);
        await LockAsync(connection, transaction, token);
        await using var query = new NpgsqlCommand("""
            SELECT sha256,media_type FROM uploads WHERE id=$1 AND state='stored' AND released_at IS NULL
            """, connection, transaction);
        query.Parameters.AddWithValue(id);
        string hash, mediaType;
        await using (var reader = await query.ExecuteReaderAsync(token))
        {
            if (!await reader.ReadAsync(token)) return false;
            hash = reader.GetString(0);
            mediaType = reader.GetString(1);
        }
        return await volume.CreatePreviewAsync(hash, mediaType, token, size);
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
