using Nephos.Faces.Api;
using Nephos.ServiceDefaults;
using Npgsql;

var builder = WebApplication.CreateBuilder(args);
builder.AddServiceDefaults("nephos-faces");
builder.WebHost.ConfigureKestrel(options => options.Limits.MaxRequestBodySize = 16384);
builder.Services.AddSingleton(_ => NpgsqlDataSource.Create(builder.Configuration.GetConnectionString("Faces")
    ?? throw new InvalidOperationException("ConnectionStrings:Faces is required.")));
builder.Services.AddSingleton<IFaceRepository, PostgresFaceRepository>();
builder.Services.AddSingleton<IAnalysisSourceClient, AnalysisSourceClient>();
builder.Services.AddSingleton<IInferenceClient, InferenceClient>();
foreach (var (name, setting, timeout) in new[] { ("library", "Services:Library", 10), ("storage", "Services:Storage", 30), ("inference", "Inference:Url", 55) })
    builder.Services.AddHttpClient(name, client =>
    {
        client.BaseAddress = new Uri(builder.Configuration[setting] ?? throw new InvalidOperationException($"{setting} is required."));
        client.Timeout = TimeSpan.FromSeconds(timeout);
        client.MaxResponseContentBufferSize = name == "inference" ? 1024 * 1024 : Pipeline.MaxBytes;
    }).ConfigurePrimaryHttpMessageHandler(() => new HttpClientHandler { AllowAutoRedirect = false });
if (builder.Configuration.GetValue<bool>("Worker:Enabled")) builder.Services.AddHostedService<FaceWorker>();
builder.Services.AddHealthChecks().AddCheck<FaceHealth>("faces-postgres");
var app = builder.Build();
app.UseExceptionHandler();
app.Use(async (context, next) =>
{
    context.Response.Headers.CacheControl = "no-store";
    try { await next(); }
    catch (HttpRequestException) { context.Response.StatusCode = 503; }
    catch (OperationCanceledException) when (!context.RequestAborted.IsCancellationRequested) { context.Response.StatusCode = 503; }
});
app.UseAuthentication();
app.UseActiveTokenStatus();
app.UseAuthorization();
app.MapServiceHealth();
app.MapFaceEndpoints();
app.Run();

public partial class Program;
