namespace Nephos.Library.Api.Assets;

public sealed record RetainedResource(Guid Id, string Sha256, long Size, bool Available, Guid HoldId,
    DateTimeOffset RetainedUntil, string Assurance);

public static class ResourceSetEndpoints
{
    public static void MapResourceSets(this WebApplication app)
    {
        app.MapPut("/v1/libraries/{library:guid}/resource-sets/{id:guid}", async (Guid library, Guid id,
            ResourceSetInput input, HttpContext context, IResourceSetRepository repository, CancellationToken token) =>
        {
            if (id == Guid.Empty || !input.IsValid()) return Results.Problem(statusCode: 400, title: "Invalid complete resource manifest.");
            return Results.Ok(await repository.CommitAsync(context.User.FindFirst("sub")?.Value ?? "", library, id, input, token));
        }).RequireAuthorization();
        app.MapGet("/v1/resource-sets/{id:guid}", async (Guid id, HttpContext context, IResourceSetRepository repository, CancellationToken token) =>
        {
            var manifest = await repository.FindAsync(context.User.FindFirst("sub")?.Value ?? "", id, false, token);
            return manifest is null ? Results.NotFound() : Results.Ok(manifest);
        }).RequireAuthorization();
        app.MapGet("/v1/assets/{id:guid}/resources", async (Guid id, HttpContext context, IResourceSetRepository repository, CancellationToken token) =>
        {
            var manifest = await repository.ForAssetAsync(context.User.FindFirst("sub")?.Value ?? "", id, token);
            return manifest is null ? Results.NotFound() : Results.Ok(manifest);
        }).RequireAuthorization();
        app.MapPost("/v1/resource-sets/{id:guid}/retention", async (Guid id, HttpContext context, IResourceSetRepository repository,
            IHttpClientFactory clients, IConfiguration configuration, CancellationToken token) =>
        {
            var subject = context.User.FindFirst("sub")?.Value ?? "";
            var manifest = await repository.FindAsync(subject, id, true, token);
            if (manifest is null) return Results.NotFound();
            var retained = new List<RetainedResource>();
            foreach (var resource in manifest.Resources)
            {
                using var request = new HttpRequestMessage(HttpMethod.Post,
                    $"{configuration["Services:Storage"]}/internal/assets/{resource.AssetId}/retention");
                request.Headers.Add("X-Nephos-Service-Key", configuration["Services:Key"]);
                using var response = await clients.CreateClient("storage").SendAsync(request, token);
                response.EnsureSuccessStatusCode();
                var hold = await response.Content.ReadFromJsonAsync<RetainedResource>(token);
                if (hold is null || hold.Id != resource.AssetId || hold.Sha256 != resource.Sha256 || hold.Size != resource.Size ||
                    !hold.Available || hold.HoldId == Guid.Empty || hold.RetainedUntil <= DateTimeOffset.UtcNow.AddHours(1) ||
                    hold.Assurance != "single-volume-no-independent-backup")
                    throw new HttpRequestException("Storage did not provide matching resource retention evidence.");
                retained.Add(hold);
            }
            if (await repository.FindAsync(subject, id, true, token) is null) return Results.NotFound();
            return Results.Ok(new
            {
                id,
                assurance = "single-volume-no-independent-backup",
                retainedUntil = retained.Min(r => r.RetainedUntil),
                resources = retained
            });
        }).RequireAuthorization();
    }
}
