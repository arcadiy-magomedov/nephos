using Microsoft.Extensions.Diagnostics.HealthChecks;
using Npgsql;

namespace Nephos.Storage.Api;

public sealed class StorageHealthCheck(
    NpgsqlDataSource dataSource, IConfiguration configuration) : IHealthCheck
{
    public async Task<HealthCheckResult> CheckHealthAsync(
        HealthCheckContext context, CancellationToken cancellationToken = default)
    {
        await using var command = dataSource.CreateCommand("SELECT 1 FROM uploads LIMIT 1");
        await command.ExecuteScalarAsync(cancellationToken);
        var root = configuration["Storage:Root"]
            ?? throw new InvalidOperationException("Storage:Root is required.");
        if (!Directory.Exists(root))
        {
            return HealthCheckResult.Unhealthy("Storage volume is not mounted.");
        }
        var probe = Path.Combine(root, $".health-{Guid.NewGuid():N}");
        try
        {
            await using var stream = new FileStream(
                probe, FileMode.CreateNew, FileAccess.Write, FileShare.None,
                1, FileOptions.Asynchronous | FileOptions.DeleteOnClose);
            await stream.WriteAsync(new byte[] { 1 }, cancellationToken);
            await stream.FlushAsync(cancellationToken);
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
        {
            return HealthCheckResult.Unhealthy("Storage volume is not writable.", exception);
        }
        return HealthCheckResult.Healthy();
    }
}
