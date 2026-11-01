using Nephos.ServiceDefaults;

namespace Nephos.Library.Api.Assets;

public sealed record CompletePurgeRequest(Guid LeaseId);

public static class TrashEndpoints
{
    public static void MapTrash(this WebApplication app)
    {
        app.MapGet("/v1/trash", async (int? limit, DateTimeOffset? before, Guid? beforeId,
            HttpContext context, ITrashRepository repository, CancellationToken token) =>
        {
            context.Response.Headers.CacheControl = "private, no-store";
            var size = limit ?? 50;
            if (size is < 1 or > 100 || before.HasValue != beforeId.HasValue)
                return Results.Problem(statusCode: 400, title: "Invalid trash page size or cursor.");
            var subject = context.User.FindFirst("sub")?.Value;
            return subject is null ? Results.Forbid() : Results.Ok(await repository.ListAsync(subject,
                before is null ? null : new(before.Value.ToUniversalTime(), beforeId!.Value), size, token));
        }).RequireAuthorization();

        app.MapPost("/v1/assets/{id:guid}/restore", async (Guid id, HttpContext context,
            ITrashRepository repository, CancellationToken token) =>
        {
            context.Response.Headers.CacheControl = "private, no-store";
            var subject = context.User.FindFirst("sub")?.Value;
            if (subject is null) return Results.Forbid();
            return await repository.RestoreAsync(subject, id, token) switch
            {
                RestoreResult.Restored => Results.NoContent(),
                RestoreResult.Expired => Results.Problem(statusCode: 409, title: "The resource's recovery period has expired."),
                _ => Results.NotFound()
            };
        }).RequireAuthorization();

        app.MapGet("/v1/trash/{id:guid}/preview", async (Guid id, int? size, HttpContext context,
            ITrashRepository repository, IHttpClientFactory clients, IConfiguration configuration, CancellationToken token) =>
        {
            context.Response.Headers.CacheControl = "private, no-store";
            if (!PreviewSizes.Supports(size ?? 512))
                return Results.Problem(statusCode: 400, title: "Preview size must be 512, 1280 or 2560.");
            var subject = context.User.FindFirst("sub")?.Value;
            if (subject is null || await repository.FindAsync(subject, id, token) is null)
                return Results.NotFound();
            using var request = new HttpRequestMessage(HttpMethod.Get,
                $"{configuration["Services:Storage"]}/internal/v1/assets/{id}/preview?size={size ?? 512}");
            request.Headers.Add("X-Nephos-Service-Key", configuration["Services:Key"]);
            using var response = await clients.CreateClient("storage").SendAsync(request, token);
            if (!response.IsSuccessStatusCode) return Results.StatusCode((int)response.StatusCode);
            context.Response.Headers.XContentTypeOptions = "nosniff";
            return Results.Bytes(await response.Content.ReadAsByteArrayAsync(token),
                response.Content.Headers.ContentType?.ToString() ?? "image/jpeg");
        }).RequireAuthorization();

        app.MapInternalV1("/cleanup/claim", ["POST"], async (HttpContext context, IConfiguration configuration,
            ITrashRepository repository, CancellationToken token) =>
        {
            if (!MediaProtocol.IsInternal(context, configuration)) return Results.Unauthorized();
            var claim = await repository.ClaimAsync(token);
            return claim is null ? Results.NoContent() : Results.Ok(claim);
        });
        app.MapInternalV1("/cleanup/{assetId:guid}/complete", ["POST"], async (Guid assetId,
            CompletePurgeRequest request, HttpContext context, IConfiguration configuration,
            ITrashRepository repository, CancellationToken token) =>
        {
            if (!MediaProtocol.IsInternal(context, configuration)) return Results.Unauthorized();
            return await repository.CompleteAsync(assetId, request.LeaseId, token)
                ? Results.NoContent() : Results.Conflict();
        });
    }
}
