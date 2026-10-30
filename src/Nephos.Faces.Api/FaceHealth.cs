using Microsoft.Extensions.Diagnostics.HealthChecks;
using Npgsql;

namespace Nephos.Faces.Api;

public sealed class FaceHealth(NpgsqlDataSource data) : IHealthCheck
{
    public async Task<HealthCheckResult> CheckHealthAsync(HealthCheckContext context, CancellationToken cancellationToken = default)
    {
        try
        {
            await using var command = data.CreateCommand("SELECT 1 FROM jobs LIMIT 1");
            await command.ExecuteScalarAsync(cancellationToken);
            return HealthCheckResult.Healthy();
        }
        catch (NpgsqlException) { return HealthCheckResult.Unhealthy("Face persistence unavailable"); }
    }
}
