namespace Nephos.Library.Api.Assets;

public static class GalleryEndpoints
{
    public static void MapGallery(this WebApplication app)
    {
        var routes = app.MapGroup("/v1/libraries/{library:guid}").RequireAuthorization();
        routes.MapPost("/snapshots", async (Guid library, HttpContext context, IGalleryRepository repository, CancellationToken token) =>
            Results.Ok(await repository.CreateAsync(context.User.FindFirst("sub")?.Value ?? "", library, token)));
        routes.MapGet("/snapshots/{snapshot:guid}/assets", async (Guid library, Guid snapshot, int? limit,
            DateTimeOffset? before, Guid? beforeId, HttpContext context, IGalleryRepository repository, CancellationToken token) =>
        {
            var size = limit ?? 50;
            if (size is < 1 or > 100 || before.HasValue != beforeId.HasValue)
                return Results.Problem(statusCode: 400, title: "Invalid retained gallery page size or cursor.");
            return Results.Ok(await repository.PageAsync(context.User.FindFirst("sub")?.Value ?? "", library, snapshot,
                before is null ? null : new(before.Value.ToUniversalTime(), beforeId!.Value), size, token));
        });
        routes.MapGet("/snapshots/{snapshot:guid}/timeline", async (Guid library, Guid snapshot, int? year,
            int? month, HttpContext context, IGalleryRepository repository, CancellationToken token) =>
        {
            if (year is < 1800 or > 2200 || month is < 1 or > 12 || month is not null && year is null)
                return Results.Problem(statusCode: 400, title: "Invalid timeline year/month.");
            return Results.Ok(new { items = await repository.TimelineAsync(context.User.FindFirst("sub")?.Value ?? "", library, snapshot, year, month, token) });
        });
        routes.MapGet("/changes", async (Guid library, long after, long through, int? limit, HttpContext context,
            IGalleryRepository repository, CancellationToken token) =>
        {
            var size = limit ?? 20;
            if (after < 0 || through < after || size is < 1 or > 50)
                return Results.Problem(statusCode: 400, title: "Invalid gallery delta frontier or page size.");
            return Results.Ok(await repository.ChangesAsync(context.User.FindFirst("sub")?.Value ?? "", library, after, through, size, token));
        });
    }
}
