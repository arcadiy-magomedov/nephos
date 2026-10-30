using Microsoft.Extensions.Diagnostics.HealthChecks;
using Npgsql;

namespace Nephos.Library.Api;

public sealed class PersistenceHealthCheck(NpgsqlDataSource dataSource) : IHealthCheck
{
    public async Task<HealthCheckResult> CheckHealthAsync(
        HealthCheckContext context, CancellationToken cancellationToken = default)
    {
        await using var command = dataSource.CreateCommand("SELECT 1 FROM principals LIMIT 1");
        await command.ExecuteScalarAsync(cancellationToken);
        return HealthCheckResult.Healthy();
    }
}
