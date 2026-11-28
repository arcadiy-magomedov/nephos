using Nephos.Storage.Api;
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
