using Nephos.ServiceDefaults;

namespace Nephos.Library.Api.Assets;

public static class AssetEndpoints
{
    public static void MapAssets(this WebApplication app)
    {
        app.MapGet("/v1/assets/{id:guid}", async (Guid id, HttpContext context, IAssetRepository repository, CancellationToken token) =>
        {
            var subject = context.User.FindFirst("sub")?.Value;
            var asset = subject is null ? null : await repository.FindAsync(subject, id, token);
            context.Response.Headers.CacheControl = "private, no-store";
            return asset is null ? Results.NotFound() : Results.Ok(asset);
        }).RequireAuthorization();
        app.MapGet("/v1/config", (IConfiguration configuration) => Results.Ok(new
        {
            serverId = configuration["Platform:ServerId"] ?? "nephos-development",
            issuer = configuration["Authentication:Authority"],
            clientId = "nephos-ios",
            maxUploadBytes = MediaProtocol.MaxUploadBytes,
            chunkSize = MediaProtocol.ChunkSize
        }));
        app.MapGet("/v1/libraries/{id:guid}", async (Guid id, bool? upload, HttpContext context, IAssetRepository repository, CancellationToken token) =>
        {
            var subject = context.User.FindFirst("sub")?.Value;
            return subject is not null && (upload == true ? await repository.CanUploadAsync(subject, id, token) : await repository.CanAccessAsync(subject, id, token))
                ? Results.Ok(new { id }) : Results.NotFound();
        }).RequireAuthorization();
        app.MapGet("/v1/libraries/{id:guid}/assets", async (
            Guid id, int? limit, DateTimeOffset? before, Guid? beforeId,
            HttpContext context, IAssetRepository repository, CancellationToken token) =>
        {
            var size = limit ?? 50;
            if (size is < 1 or > 100 || before.HasValue != beforeId.HasValue)
                return Results.Problem(statusCode: 400, title: "Invalid gallery page size or cursor.");
            var subject = context.User.FindFirst("sub")?.Value;
            if (subject is null || !await repository.CanAccessAsync(subject, id, token)) return Results.NotFound();
            var rows = await repository.ListAsync(subject, id, before is null ? null : new(before.Value.ToUniversalTime(), beforeId!.Value), size + 1, token);
            var items = rows.Take(size).ToArray();
            return Results.Ok(new AssetPage(items, rows.Count > size ? new(items[^1].CreatedAt, items[^1].Id) : null));
        }).RequireAuthorization();
        app.MapGet("/v1/libraries/{id:guid}/timeline", async (Guid id, int? year, int? month, HttpContext context,
            IAssetRepository repository, CancellationToken token) =>
        {
            if (year is < 1800 or > 2200 || month is < 1 or > 12 || month is not null && year is null)
                return Results.Problem(statusCode: 400, title: "Invalid timeline year/month.");
            var subject = context.User.FindFirst("sub")?.Value;
            if (subject is null || !await repository.CanAccessAsync(subject, id, token)) return Results.NotFound();
            return Results.Ok(new { items = await repository.TimelineAsync(subject, id, year, month, token) });
        }).RequireAuthorization();
        app.MapMethods("/v1/assets/{id:guid}/{kind}", ["GET", "HEAD", "POST"], async (
            Guid id, string kind, int? size, HttpContext context, IAssetRepository repository,
            IHttpClientFactory clients, IConfiguration configuration, CancellationToken token) =>
        {
            if (kind is not ("original" or "preview" or "backup" or "retention") ||
                (kind == "retention") != HttpMethods.IsPost(context.Request.Method))
            {
                context.Response.StatusCode = 404;
                return;
            }
            var subject = context.User.FindFirst("sub")?.Value;
            var asset = subject is null ? null : await repository.FindAsync(subject, id, token, owned: kind == "retention");
            if (asset is null)
            {
                context.Response.StatusCode = 404;
                return;
            }
            if (kind == "preview" && !PreviewSizes.Supports(size ?? 512))
            {
                await Results.Problem(statusCode: 400, title: "Preview size must be 512, 1280 or 2560.").ExecuteAsync(context);
                return;
            }
            using var request = new HttpRequestMessage(new HttpMethod(context.Request.Method),
                $"{configuration["Services:Storage"]}/internal/v1/assets/{id}/{kind}" +
                (kind == "preview" ? $"?size={size ?? 512}" : ""));
            request.Headers.Add("X-Nephos-Service-Key", configuration["Services:Key"]);
            foreach (var header in new[] { "Range", "If-Range", "If-None-Match" })
                if (context.Request.Headers.TryGetValue(header, out var value))
                    request.Headers.TryAddWithoutValidation(header, value.ToArray());
            using var response = await clients.CreateClient("storage").SendAsync(request, HttpCompletionOption.ResponseHeadersRead, token);
            context.Response.StatusCode = (int)response.StatusCode;
            context.Response.Headers.CacheControl = "private, no-store";
            context.Response.Headers.XContentTypeOptions = "nosniff";
            foreach (var header in new[] { "Content-Type", "Content-Length", "Content-Disposition", "Content-Range", "ETag", "Accept-Ranges", "Last-Modified" })
            {
                if (response.Content.Headers.TryGetValues(header, out var contentValues))
                    context.Response.Headers[header] = contentValues.ToArray();
                else if (response.Headers.TryGetValues(header, out var values))
                    context.Response.Headers[header] = values.ToArray();
            }
            await response.Content.CopyToAsync(context.Response.Body, token);
        }).RequireAuthorization();
    }
}
