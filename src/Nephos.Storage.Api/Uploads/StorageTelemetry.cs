using System.Diagnostics.Metrics;

namespace Nephos.Storage.Api.Uploads;

public sealed record StorageMetrics(long Uploading, long Verifying, long Failed, double VerificationAge,
    long Outbox, long FreeBytes, long SampledAt);

public sealed class StorageTelemetry(IUploadRepository repository, IConfiguration configuration,
    ILogger<StorageTelemetry> logger) : BackgroundService
{
    private StorageMetrics current = new(0, 0, 0, 0, 0, 0, 0);

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        using var meter = new Meter("Nephos.Storage");
        meter.CreateObservableGauge("nephos.storage.uploading", () => Volatile.Read(ref current).Uploading);
        meter.CreateObservableGauge("nephos.storage.verifying", () => Volatile.Read(ref current).Verifying);
        meter.CreateObservableGauge("nephos.storage.failed", () => Volatile.Read(ref current).Failed);
        meter.CreateObservableGauge("nephos.storage.verification.age", () => Volatile.Read(ref current).VerificationAge);
        meter.CreateObservableGauge("nephos.storage.outbox", () => Volatile.Read(ref current).Outbox);
        meter.CreateObservableGauge("nephos.storage.free.bytes", () => Volatile.Read(ref current).FreeBytes);
        meter.CreateObservableGauge("nephos.storage.sampled.at", () => Volatile.Read(ref current).SampledAt);
        var root = configuration["Storage:Root"] ?? throw new InvalidOperationException("Storage:Root is required.");
        while (!stoppingToken.IsCancellationRequested)
        {
            try
            {
                var sample = await repository.MetricsAsync(stoppingToken);
                Volatile.Write(ref current, sample with
                {
                    FreeBytes = new DriveInfo(root).AvailableFreeSpace,
                    SampledAt = DateTimeOffset.UtcNow.ToUnixTimeSeconds()
                });
            }
            catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested) { break; }
            catch (Exception exception) when (exception is Npgsql.NpgsqlException or IOException or TimeoutException)
            {
                logger.LogError("Storage operational metrics could not be refreshed ({ErrorType})", exception.GetType().Name);
            }
            await Task.Delay(TimeSpan.FromSeconds(15), stoppingToken);
        }
    }
}
