using Nephos.ServiceDefaults;
using Npgsql;

namespace Nephos.Storage.Api.Uploads;

public sealed record StorageAdministrationSummary(DateTimeOffset CheckedAt, long CapacityBytes, long FreeBytes,
    long UsedBytes, long BlobCount, long BlobBytes, long Uploading, long Verifying, long FailedLastDay,
    double VerificationAgeSeconds, long OutboxPending);

public sealed class StorageAdministrationRepository(NpgsqlDataSource data, IUploadRepository uploads, IConfiguration config)
{
    public async Task<StorageAdministrationSummary> SummaryAsync(CancellationToken token)
    {
        var metrics = await uploads.MetricsAsync(token);
        var root = config["Storage:Root"] ?? throw new InvalidOperationException("Storage:Root is required.");
        if (!Directory.Exists(root)) throw new IOException("Storage is not mounted.");
        var volume = new DriveInfo(root);
        var capacity = volume.TotalSize;
        var free = volume.AvailableFreeSpace;
        await using var query = data.CreateCommand("SELECT count(*),coalesce(sum(size),0)::bigint FROM blobs");
        query.CommandTimeout = 10;
        await using var r = await query.ExecuteReaderAsync(token);
        await r.ReadAsync(token);
        return new(DateTimeOffset.UtcNow, capacity, free, capacity - volume.TotalFreeSpace, r.GetInt64(0),
            r.GetInt64(1), metrics.Uploading, metrics.Verifying, metrics.Failed, metrics.VerificationAge, metrics.Outbox);
    }
}

public static class StorageAdministrationEndpoints
{
    public static void MapStorageAdministration(this WebApplication app)
    {
        app.MapInternalV1("/admin/summary", ["GET"], async (HttpContext context, IConfiguration config,
            StorageAdministrationRepository repository, CancellationToken token) =>
        {
            if (!MediaProtocol.IsInternal(context, config, "Administration:Key")) return Results.Unauthorized();
            try { return Results.Ok(await repository.SummaryAsync(token)); }
            catch (Exception e) when (e is NpgsqlException or IOException or UnauthorizedAccessException or TimeoutException)
            { return Results.Problem(statusCode: 503, title: "Storage summary unavailable."); }
        });
    }
}
