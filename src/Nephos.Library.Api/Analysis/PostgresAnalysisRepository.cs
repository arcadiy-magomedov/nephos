using Npgsql;
using NpgsqlTypes;

namespace Nephos.Library.Api.Analysis;

public sealed record AnalysisSource(Guid Id, Guid LibraryId, string Subject, string MediaType, long Size, string Sha256);
public sealed record FacePublication(Guid AssetId, string Subject, Guid LeaseId, int Attempts);
public sealed record FaceDeletion(Guid AssetId, string Subject, Guid LeaseId, int Attempts);

public interface IAnalysisRepository
{
    Task<AnalysisSource?> FindSourceAsync(string subject, Guid assetId, CancellationToken token);
    Task<FacePublication?> ClaimAsync(CancellationToken token);
    Task CompleteAsync(FacePublication publication, int? status, CancellationToken token);
    Task<FaceDeletion?> ClaimDeletionAsync(CancellationToken token);
    Task CompleteDeletionAsync(FaceDeletion deletion, int? status, CancellationToken token);
}

public sealed class PostgresAnalysisRepository(NpgsqlDataSource source) : IAnalysisRepository
{
    public async Task<AnalysisSource?> FindSourceAsync(string subject, Guid assetId, CancellationToken token)
    {
        await using var query = source.CreateCommand("""
            SELECT id,library_id,subject,media_type,size,sha256 FROM analysis_sources WHERE id=$1 AND subject=$2
            """);
        query.Parameters.AddWithValue(assetId);
        query.Parameters.AddWithValue(subject);
        await using var reader = await query.ExecuteReaderAsync(token);
        return await reader.ReadAsync(token)
            ? new(reader.GetGuid(0), reader.GetGuid(1), reader.GetString(2), reader.GetString(3), reader.GetInt64(4), reader.GetString(5))
            : null;
    }

    public async Task<FacePublication?> ClaimAsync(CancellationToken token)
    {
        var lease = Guid.NewGuid();
        await using var query = source.CreateCommand("""
            WITH candidate AS (
                SELECT asset_id FROM face_publications
                WHERE delivered_at IS NULL AND next_attempt_at<=now()
                  AND (lease_until IS NULL OR lease_until<now())
                ORDER BY next_attempt_at,asset_id FOR UPDATE SKIP LOCKED LIMIT 1
            )
            UPDATE face_publications p SET lease_id=$1,lease_until=now()+interval '90 seconds',
                attempts=least(p.attempts+1,30)
            FROM candidate c,assets a WHERE p.asset_id=c.asset_id AND a.id=p.asset_id
            RETURNING p.asset_id,a.uploaded_by,p.attempts
            """);
        query.Parameters.AddWithValue(lease);
        await using var reader = await query.ExecuteReaderAsync(token);
        return await reader.ReadAsync(token) ? new(reader.GetGuid(0), reader.GetString(1), lease, reader.GetInt32(2)) : null;
    }

    public async Task CompleteAsync(FacePublication publication, int? status, CancellationToken token)
    {
        await using var update = source.CreateCommand("""
            UPDATE face_publications SET lease_id=NULL,lease_until=NULL,last_status=$3,
                delivered_at=CASE WHEN $3 IN (202,404) THEN now() END,
                next_attempt_at=now()+make_interval(secs=>$4)
            WHERE asset_id=$1 AND lease_id=$2
            """);
        update.Parameters.AddWithValue(publication.AssetId);
        update.Parameters.AddWithValue(publication.LeaseId);
        update.Parameters.Add(new NpgsqlParameter { NpgsqlDbType = NpgsqlDbType.Integer, Value = (object?)status ?? DBNull.Value });
        update.Parameters.AddWithValue(Math.Min(300, 1 << Math.Min(publication.Attempts, 8)));
        await update.ExecuteNonQueryAsync(token);
    }

    public async Task<FaceDeletion?> ClaimDeletionAsync(CancellationToken token)
    {
        await using var query = source.CreateCommand("""
            WITH candidate AS (
                SELECT asset_id FROM face_deletions
                WHERE next_attempt_at<=now() AND (lease_until IS NULL OR lease_until<now())
                ORDER BY next_attempt_at,asset_id FOR UPDATE SKIP LOCKED LIMIT 1
            )
            UPDATE face_deletions d SET lease_id=$1,lease_until=now()+interval '90 seconds',
                attempts=least(d.attempts+1,30)
            FROM candidate c WHERE d.asset_id=c.asset_id
            RETURNING d.asset_id,d.subject,d.lease_id,d.attempts
            """);
        query.Parameters.AddWithValue(Guid.NewGuid());
        await using var reader = await query.ExecuteReaderAsync(token);
        return await reader.ReadAsync(token)
            ? new(reader.GetGuid(0), reader.GetString(1), reader.GetGuid(2), reader.GetInt32(3))
            : null;
    }

    public async Task CompleteDeletionAsync(FaceDeletion deletion, int? status, CancellationToken token)
    {
        if (status is 204 or 404)
        {
            await using var remove = source.CreateCommand(
                "DELETE FROM face_deletions WHERE asset_id=$1 AND lease_id=$2");
            remove.Parameters.AddWithValue(deletion.AssetId);
            remove.Parameters.AddWithValue(deletion.LeaseId);
            await remove.ExecuteNonQueryAsync(token);
            return;
        }
        await using var retry = source.CreateCommand("""
            UPDATE face_deletions SET lease_id=NULL,lease_until=NULL,last_status=$3,
                next_attempt_at=now()+make_interval(secs=>$4)
            WHERE asset_id=$1 AND lease_id=$2
            """);
        retry.Parameters.AddWithValue(deletion.AssetId);
        retry.Parameters.AddWithValue(deletion.LeaseId);
        retry.Parameters.Add(new NpgsqlParameter { NpgsqlDbType = NpgsqlDbType.Integer, Value = (object?)status ?? DBNull.Value });
        retry.Parameters.AddWithValue(Math.Min(300, 1 << Math.Min(deletion.Attempts, 8)));
        await retry.ExecuteNonQueryAsync(token);
    }
}
