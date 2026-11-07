using Microsoft.Extensions.Diagnostics.HealthChecks;
using Nephos.ServiceDefaults;
using Nephos.Storage.Api.Uploads;
using Npgsql;

var builder = WebApplication.CreateBuilder(args);
builder.AddServiceDefaults("nephos-storage");
builder.Services.AddSingleton(_ => NpgsqlDataSource.Create(
    builder.Configuration.GetConnectionString("Storage")
    ?? throw new InvalidOperationException("ConnectionStrings:Storage is required.")));
builder.Services.AddHealthChecks().AddCheck<StorageHealthCheck>("storage");
builder.WebHost.ConfigureKestrel(options => options.Limits.MaxRequestBodySize = MediaProtocol.ChunkSize);
builder.Services.AddSingleton<IVolumeStore, VolumeStore>();
builder.Services.AddSingleton<IUploadRepository, PostgresUploadRepository>();
builder.Services.AddSingleton<StorageAdministrationRepository>();
builder.Services.AddSingleton<BlobCleanupRepository>();
builder.Services.AddHttpClient("derivatives", client => client.Timeout = TimeSpan.FromSeconds(55))
    .ConfigurePrimaryHttpMessageHandler(() => new HttpClientHandler { AllowAutoRedirect = false });
builder.Services.AddHttpClient<LibraryAccess>(client => client.Timeout = TimeSpan.FromSeconds(15))
    .ConfigurePrimaryHttpMessageHandler(() => new HttpClientHandler { AllowAutoRedirect = false });
builder.Services.AddExceptionHandler<UploadExceptionHandler>();
if (builder.Configuration.GetValue<bool>("Worker:Enabled"))
{
    builder.Services.AddHostedService<UploadWorker>();
    builder.Services.AddHostedService<StorageTelemetry>();
}
var app = builder.Build();
app.UseExceptionHandler();
app.UseAuthentication();
app.UseActiveTokenStatus();
app.UseAuthorization();
app.MapServiceHealth();
app.MapUploads();
app.MapBlobCleanup();
app.MapStorageAdministration();
app.Run();

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
            return HealthCheckResult.Unhealthy("Storage volume is not writable.");
        }
        return HealthCheckResult.Healthy();
    }
}
