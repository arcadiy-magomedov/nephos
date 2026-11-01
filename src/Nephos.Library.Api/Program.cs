using System.Diagnostics.Metrics;
using Nephos.Library.Api;
using Nephos.Library.Api.Libraries;
using Nephos.Library.Api.Assets;
using Nephos.Library.Api.Administration;
using Nephos.ServiceDefaults;
using Nephos.Library.Api.Sharing;
using Nephos.Library.Api.Analysis;
using Npgsql;

var builder = WebApplication.CreateBuilder(args);
builder.AddServiceDefaults("nephos-library");
builder.Services.AddSingleton(_ => NpgsqlDataSource.Create(
    builder.Configuration.GetConnectionString("Library")
    ?? throw new InvalidOperationException("ConnectionStrings:Library is required.")));
builder.Services.AddSingleton<ILibraryRepository, PostgresLibraryRepository>();
builder.Services.AddExceptionHandler<PersistenceExceptionHandler>();
builder.Services.AddHealthChecks().AddCheck<PersistenceHealthCheck>("postgresql");
builder.Services.AddSingleton<IAssetRepository, PostgresAssetRepository>();
builder.Services.AddSingleton<ITrashRepository, PostgresTrashRepository>();
builder.Services.AddSingleton<IGalleryRepository, PostgresGalleryRepository>();
builder.Services.AddSingleton<IResourceSetRepository, PostgresResourceSetRepository>();
builder.Services.AddSingleton<ISharingRepository, PostgresSharingRepository>();
builder.Services.AddSingleton<IAnalysisRepository, PostgresAnalysisRepository>();
builder.Services.AddSingleton<IAdministrationRepository, PostgresAdministrationRepository>();
builder.Services.AddHttpClient("storage", client => client.Timeout = TimeSpan.FromMinutes(2))
    .ConfigurePrimaryHttpMessageHandler(() => new HttpClientHandler { AllowAutoRedirect = false });
if (builder.Configuration.GetValue<bool>("Worker:Enabled")) builder.Services.AddHostedService<ProjectionWorker>();
if (builder.Configuration.GetValue<bool>("Analysis:Enabled"))
{
    builder.Services.AddHttpClient("faces", client => client.Timeout = TimeSpan.FromSeconds(30))
        .ConfigurePrimaryHttpMessageHandler(() => new HttpClientHandler { AllowAutoRedirect = false });
    builder.Services.AddHostedService<FacePublicationWorker>();
}

var app = builder.Build();
app.UseExceptionHandler();
app.UseAuthentication();
app.UseAuthorization();
app.MapServiceHealth();
app.MapAssets();
app.MapTrash();
app.MapGallery();
app.MapResourceSets();
app.MapSharing();
app.MapAnalysis();
if (builder.Configuration.GetValue<bool>("Administration:Enabled")) app.MapAdministration();

using var meter = new Meter("Nephos.Library");
var requests = meter.CreateCounter<long>("nephos.library.list.requests");
app.MapGet("/v1/libraries", async (
    HttpContext context, ILibraryRepository repository, ILogger<Program> logger,
    int? limit, Guid? after, CancellationToken cancellationToken) =>
{
    var subject = context.User.FindFirst("sub")?.Value;
    if (string.IsNullOrWhiteSpace(subject))
    {
        return Results.Forbid();
    }
    var pageSize = limit ?? 50;
    if (pageSize is < 1 or > 100)
    {
        return Results.Problem(statusCode: 400, title: "Limit must be between 1 and 100.");
    }
    if (!await repository.IsEnabledAsync(subject, cancellationToken))
    {
        return Results.Forbid();
    }
    var rows = await repository.ListAsync(subject, after, pageSize + 1, cancellationToken);
    var items = rows.Take(pageSize).ToArray();
    Guid? next = rows.Count > pageSize ? items[^1].Id : null;
    requests.Add(1);
    logger.LogInformation("Library page served with {ItemCount} items", items.Length);
    return Results.Ok(new LibraryPage(items, next));
}).RequireAuthorization();

app.Run();

public partial class Program;
