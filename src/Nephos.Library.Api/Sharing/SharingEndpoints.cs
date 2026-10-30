using Nephos.Library.Api.Libraries;

namespace Nephos.Library.Api.Sharing;

public static class SharingEndpoints
{
    public static void MapSharing(this WebApplication app)
    {
        app.MapGet("/v1/users", async (string? after, int? limit, HttpContext context, ISharingRepository repository,
            ILibraryRepository membership, CancellationToken token) =>
        {
            if (!await membership.IsEnabledAsync(context.User.FindFirst("sub")?.Value ?? "", token)) return Results.Forbid();
            var size = limit ?? 50;
            if (size is < 1 or > 100 || after is { Length: > 200 }) return Results.Problem(statusCode: 400, title: "Invalid directory cursor.");
            var rows = await repository.DirectoryAsync(context.User.FindFirst("sub")?.Value ?? "", after, size + 1, token);
            var items = rows.Take(size).ToArray();
            return Results.Ok(new { items, nextCursor = rows.Count > size ? items[^1].Id : null });
        }).RequireAuthorization();
        app.MapGet("/v1/shares", async (Guid? after, int? limit, HttpContext context, ISharingRepository repository,
            ILibraryRepository membership, CancellationToken token) =>
        {
            if (!await membership.IsEnabledAsync(context.User.FindFirst("sub")?.Value ?? "", token)) return Results.Forbid();
            var size = limit ?? 50;
            if (size is < 1 or > 100) return Results.Problem(statusCode: 400, title: "Invalid share page size.");
            var rows = await repository.ListAsync(context.User.FindFirst("sub")?.Value ?? "", after, size + 1, token);
            var items = rows.Take(size).ToArray();
            return Results.Ok(new { items, nextCursor = rows.Count > size ? (Guid?)items[^1].Id : null });
        }).RequireAuthorization();
        app.MapPut("/v1/shares/{id:guid}", async (Guid id, ShareInput input, HttpContext context, ISharingRepository repository, CancellationToken token) =>
            id == Guid.Empty || !input.IsValid() ? Results.Problem(statusCode: 400, title: "Invalid share selection.") :
            Results.Ok(await repository.PutAsync(context.User.FindFirst("sub")?.Value ?? "", id, input, token))).RequireAuthorization();
        app.MapDelete("/v1/shares/{id:guid}", async (Guid id, HttpContext context, ISharingRepository repository, CancellationToken token) =>
            await repository.DeleteAsync(context.User.FindFirst("sub")?.Value ?? "", id, token) ? Results.NoContent() : Results.NotFound()).RequireAuthorization();
    }
}
