using Nephos.Library.Api.Libraries;
using Nephos.ServiceDefaults;

namespace Nephos.Library.Api.Analysis;

public static class AnalysisEndpoints
{
    public static void MapAnalysis(this WebApplication app)
    {
        app.MapGet("/v1/analysis/access", async (HttpContext context, ILibraryRepository repository, CancellationToken token) =>
        {
            context.Response.Headers.CacheControl = "no-store";
            var subject = context.User.FindFirst("sub")?.Value;
            return subject is not null && await repository.IsEnabledAsync(subject, token)
                ? Results.NoContent() : Results.Forbid();
        }).RequireAuthorization();

        app.MapGet("/internal/analysis/owners/{subject}/assets/{assetId:guid}", async (
            string subject, Guid assetId, HttpContext context, IConfiguration configuration,
            IAnalysisRepository repository, CancellationToken token) =>
        {
            context.Response.Headers.CacheControl = "no-store";
            if (!MediaProtocol.IsInternal(context, configuration)) return Results.Unauthorized();
            var source = await repository.FindSourceAsync(subject, assetId, token);
            return source is null ? Results.NotFound() : Results.Ok(source);
        });
    }
}
