using Nephos.Library.Api.Libraries;
using Nephos.ServiceDefaults;

namespace Nephos.Library.Api.Analysis;

public sealed record AuthorizeAssetsRequest(Guid[] AssetIds);

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

        app.MapInternalV1("/analysis/owners/{subject}/access", ["GET"], async (
            string subject, HttpContext context, IConfiguration configuration,
            ILibraryRepository libraries, CancellationToken token) =>
        {
            context.Response.Headers.CacheControl = "no-store";
            if (!MediaProtocol.IsInternal(context, configuration)) return Results.Unauthorized();
            if (string.IsNullOrWhiteSpace(subject) || subject.Length > 256) return Results.BadRequest();
            return await libraries.IsEnabledAsync(subject, token) ? Results.NoContent() : Results.Forbid();
        });

        app.MapInternalV1("/analysis/owners/{subject}/assets/{assetId:guid}", ["GET"], async (
            string subject, Guid assetId, HttpContext context, IConfiguration configuration,
            IAnalysisRepository repository, CancellationToken token) =>
        {
            context.Response.Headers.CacheControl = "no-store";
            if (!MediaProtocol.IsInternal(context, configuration)) return Results.Unauthorized();
            var source = await repository.FindSourceAsync(subject, assetId, token);
            return source is null ? Results.NotFound() : Results.Ok(source);
        });

        app.MapInternalV1("/analysis/owners/{subject}/assets/authorize", ["POST"], async (
            string subject, AuthorizeAssetsRequest request, HttpContext context, IConfiguration configuration,
            IAnalysisRepository repository, CancellationToken token) =>
        {
            context.Response.Headers.CacheControl = "no-store";
            if (!MediaProtocol.IsInternal(context, configuration)) return Results.Unauthorized();
            if (string.IsNullOrWhiteSpace(subject) || subject.Length > 256 ||
                request.AssetIds is not { Length: >= 1 and <= 100 } || request.AssetIds.Any(id => id == Guid.Empty))
                return Results.BadRequest();
            var ids = request.AssetIds.Distinct().ToArray();
            var authorized = await repository.FilterAuthorizedSourcesAsync(subject, ids, token);
            return Results.Ok(new { authorizedIds = authorized.ToArray() });
        });
    }
}
