namespace Nephos.Faces.Api;

public static class FaceEndpoints
{
    private static string Owner(HttpContext c) => c.User.FindFirst("sub")!.Value;
    private static bool ValidLimit(int? limit) => limit is null or >= 1 and <= 100;
    private static IResult Paged<T>(IReadOnlyList<T> rows, int limit, Func<T, Guid> id) =>
        Results.Ok(new Page<T>(rows.Take(limit).ToArray(), rows.Count > limit ? id(rows[limit - 1]) : null));

    public static void MapFaceEndpoints(this WebApplication app)
    {
        var group = app.MapGroup("/v1/faces").RequireAuthorization();
        group.AddEndpointFilter(async (context, next) =>
        {
            var http = context.HttpContext;
            if (string.IsNullOrWhiteSpace(http.User.FindFirst("sub")?.Value)) return Results.Forbid();
            var access = http.RequestServices.GetRequiredService<IAnalysisSourceClient>();
            if (!await access.IsEnabledAsync(http, http.RequestAborted)) return Results.Forbid();
            return await next(context);
        });

        group.MapPost("/jobs/{assetId:guid}", async (Guid assetId, HttpContext c, IAnalysisSourceClient access, IFaceRepository r, CancellationToken ct) =>
        {
            var source = await access.SourceAsync(Owner(c), assetId, ct);
            if (source is null) return Results.NotFound();
            var job = await r.EnqueueAsync(Owner(c), source, ct);
            return Results.Accepted($"/v1/faces/jobs/{job.Id}", new { job.Id, job.AssetId, job.Status, job.PipelineVersion });
        });
        app.MapPost("/internal/faces/jobs", async (EnqueueRequest request, HttpContext c, IConfiguration config,
            IAnalysisSourceClient access, IFaceRepository r, CancellationToken ct) =>
        {
            if (!ServiceAuthentication.Valid(c, config)) return Results.Unauthorized();
            if (string.IsNullOrWhiteSpace(request.Subject) || request.Subject.Length > 256) return Results.BadRequest();
            var source = await access.SourceAsync(request.Subject, request.AssetId, ct);
            if (source is null) return Results.NotFound();
            var job = await r.EnqueueAsync(request.Subject, source, ct);
            return Results.Accepted(value: new { job.Id, job.Status });
        });
        group.MapGet("/jobs", async (HttpContext c, IFaceRepository r, int? limit, Guid? after, CancellationToken ct) =>
        {
            if (!ValidLimit(limit)) return Results.BadRequest();
            var rows = await r.JobsAsync(Owner(c), after, (limit ?? 50) + 1, ct);
            return Paged(rows.Select(j => new { j.Id, j.AssetId, j.SourceSha256, j.PipelineVersion, j.Status, j.Attempts, j.Error }).ToArray(),
                limit ?? 50, j => j.Id);
        });
        group.MapPost("/jobs/{id:guid}/retry", async (Guid id, HttpContext c, IFaceRepository r, CancellationToken ct) =>
            await r.RetryAsync(Owner(c), id, ct) ? Results.Accepted() : Results.NotFound());
        group.MapGet("/jobs/{id:guid}", async (Guid id, HttpContext c, IFaceRepository r, CancellationToken ct) =>
        {
            var job = await r.JobAsync(Owner(c), id, ct);
            return job is null ? Results.NotFound() :
                Results.Ok(new { job.Id, job.AssetId, job.SourceSha256, job.PipelineVersion, job.Status, job.Attempts, job.Error });
        });
        group.MapGet("/people", async (HttpContext c, IFaceRepository r, int? limit, Guid? after, string? name, CancellationToken ct) =>
        {
            if (!ValidLimit(limit) || name?.Length > 120) return Results.BadRequest();
            return Paged(await r.PeopleAsync(Owner(c), after, (limit ?? 50) + 1, name, ct), limit ?? 50, p => p.Id);
        });
        group.MapGet("/people/{id:guid}", async (Guid id, HttpContext c, IFaceRepository r, CancellationToken ct) =>
            await r.PersonAsync(Owner(c), id, ct) is { } p ? Results.Ok(p) : Results.NotFound());
        group.MapPut("/people/{id:guid}/name", async (Guid id, NameRequest request, HttpContext c, IFaceRepository r, CancellationToken ct) =>
        {
            if (request.Name?.Length > 120 || request.Aliases?.Length > 10 || request.Aliases?.Any(a => string.IsNullOrWhiteSpace(a) || a.Length > 120) == true)
                return Results.BadRequest();
            return await r.NameAsync(Owner(c), id, request, ct) ? Results.NoContent() : Results.NotFound();
        });
        group.MapPost("/people/{id:guid}/merge", async (Guid id, MergeRequest request, HttpContext c, IFaceRepository r, CancellationToken ct) =>
            await r.MergeAsync(Owner(c), id, request.TargetId, ct) ? Results.NoContent() : Results.Conflict());
        group.MapDelete("/people/{id:guid}/merge", async (Guid id, HttpContext c, IFaceRepository r, CancellationToken ct) =>
            await r.MergeAsync(Owner(c), id, null, ct) ? Results.NoContent() : Results.Conflict());
        group.MapPost("/people/{id:guid}/negative-matches", async (Guid id, NegativeRequest request, HttpContext c, IFaceRepository r, CancellationToken ct) =>
            await r.NegativeAsync(Owner(c), id, request.OtherId, ct) ? Results.NoContent() : Results.Conflict());
        group.MapDelete("/people/{id:guid}/negative-matches/{otherId:guid}", async (Guid id, Guid otherId, HttpContext c, IFaceRepository r, CancellationToken ct) =>
            await r.RemoveNegativeAsync(Owner(c), id, otherId, ct) ? Results.NoContent() : Results.NotFound());
        group.MapPut("/observations/{id:guid}/person", async (Guid id, AssignmentRequest request, HttpContext c, IFaceRepository r, CancellationToken ct) =>
        {
            if (request.NewPerson && request.PersonId is not null) return Results.BadRequest();
            return await r.AssignAsync(Owner(c), id, request, ct) ? Results.NoContent() : Results.NotFound();
        });
        group.MapGet("/observations", async (HttpContext c, IAnalysisSourceClient access, IFaceRepository r,
            Guid? assetId, Guid? personId, int? limit, Guid? after, CancellationToken ct) =>
        {
            if (!ValidLimit(limit)) return Results.BadRequest();
            var rows = await r.FacesAsync(Owner(c), assetId, personId, after, (limit ?? 50) + 1, ct);
            var allowed = new Dictionary<Guid, bool>();
            foreach (var asset in rows.Select(f => f.AssetId).Distinct())
                allowed[asset] = await access.SourceAsync(Owner(c), asset, ct) is not null;
            var pageSize = limit ?? 50;
            // Advance over revoked rows as well: filtering must not trap a cursor on inaccessible assets.
            return Results.Ok(new Page<Face>(rows.Take(pageSize).Where(f => allowed[f.AssetId]).ToArray(),
                rows.Count > pageSize ? rows[pageSize - 1].Id : null));
        });
        group.MapGet("/people/{id:guid}/assets", async (Guid id, HttpContext c, IAnalysisSourceClient access,
            IFaceRepository r, int? limit, Guid? after, CancellationToken ct) =>
        {
            if (!ValidLimit(limit)) return Results.BadRequest();
            var rows = await r.AssetsAsync(Owner(c), id, after, (limit ?? 50) + 1, ct);
            var authorized = new List<Guid>();
            foreach (var asset in rows.Take(limit ?? 50))
                if (await access.SourceAsync(Owner(c), asset, ct) is not null) authorized.Add(asset);
            return Results.Ok(new Page<Guid>(authorized, rows.Count > (limit ?? 50) ? rows[(limit ?? 50) - 1] : null));
        });
        group.MapGet("/corrections", async (HttpContext c, IFaceRepository r, int? limit, Guid? after, CancellationToken ct) =>
        {
            if (!ValidLimit(limit)) return Results.BadRequest();
            return Paged(await r.CorrectionsAsync(Owner(c), after, (limit ?? 50) + 1, ct), limit ?? 50, x => x.Id);
        });
    }
}
