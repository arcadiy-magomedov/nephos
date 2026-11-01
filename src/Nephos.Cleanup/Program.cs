using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
namespace Nephos.Cleanup;

internal static class Program
{
    private static async Task<int> Main(string[] args)
    {
        var once = args.Contains("--once", StringComparer.Ordinal);
        var builder = Host.CreateApplicationBuilder(args.Where(a => a != "--once").ToArray());
        builder.Services.AddHttpClient<CleanupJob>(client => client.Timeout = TimeSpan.FromMinutes(2))
            .ConfigurePrimaryHttpMessageHandler(() => new HttpClientHandler { AllowAutoRedirect = false });
        using var host = builder.Build();
        await host.StartAsync();
        var job = host.Services.GetRequiredService<CleanupJob>();
        var configuration = host.Services.GetRequiredService<IConfiguration>();
        var logger = host.Services.GetRequiredService<ILogger<CleanupJob>>();
        var stopping = host.Services.GetRequiredService<IHostApplicationLifetime>().ApplicationStopping;
        var interval = TimeSpan.FromHours(configuration.GetValue("Cleanup:IntervalHours", 24));
        if (interval < TimeSpan.FromHours(1)) throw new InvalidOperationException("Cleanup:IntervalHours must be at least 1.");
        do
        {
            try
            {
                await job.RunAsync(stopping);
            }
            catch (OperationCanceledException) when (stopping.IsCancellationRequested) { break; }
            catch (Exception error)
            {
                logger.LogError(error, "Cleanup run failed; durable claims and GC fences will retry on the next schedule");
                if (once) return 1;
            }
            if (once) break;
            try { await Task.Delay(interval, stopping); }
            catch (OperationCanceledException) when (stopping.IsCancellationRequested) { break; }
        } while (!stopping.IsCancellationRequested);
        await host.StopAsync();
        return 0;
    }
}
