using System.Diagnostics.Metrics;
using Microsoft.Extensions.Hosting;

namespace Nephos.ServiceDefaults;

internal sealed class ServiceHeartbeat(string serviceName) : IHostedService, IDisposable
{
    private readonly Meter meter = new("Nephos.Health");

    public Task StartAsync(CancellationToken cancellationToken)
    {
        meter.CreateObservableGauge("nephos.service.heartbeat", () => new Measurement<long>(
            DateTimeOffset.UtcNow.ToUnixTimeSeconds(), new KeyValuePair<string, object?>("service", serviceName)));
        return Task.CompletedTask;
    }

    public Task StopAsync(CancellationToken cancellationToken) => Task.CompletedTask;
    public void Dispose() => meter.Dispose();
}
