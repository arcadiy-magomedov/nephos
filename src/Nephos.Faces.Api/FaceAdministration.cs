using Nephos.ServiceDefaults;
using Npgsql;

namespace Nephos.Faces.Api;

public sealed record FaceAdministrationSummary(DateTimeOffset CheckedAt, long Queued, long Running, long Complete,
    long NoFaces, long Error, long Denied, long ActiveLeases, double OldestPendingAgeSeconds);

public sealed class FaceAdministrationRepository(NpgsqlDataSource data)
{
    public async Task<FaceAdministrationSummary> SummaryAsync(CancellationToken token)
    {
        await using var query = data.CreateCommand("""
            SELECT now(),count(*) FILTER(WHERE status='queued'),count(*) FILTER(WHERE status='running'),
              count(*) FILTER(WHERE status='complete'),count(*) FILTER(WHERE status='no_faces'),
              count(*) FILTER(WHERE status='error'),count(*) FILTER(WHERE status='denied'),
              count(*) FILTER(WHERE status='running' AND lease_until>now()),
              coalesce(extract(epoch FROM now()-min(created_at) FILTER(WHERE status IN ('queued','running'))),0)::double precision
            FROM jobs
            """);
        query.CommandTimeout = 10;
        await using var r = await query.ExecuteReaderAsync(token);
        await r.ReadAsync(token);
        return new(r.GetFieldValue<DateTimeOffset>(0), r.GetInt64(1), r.GetInt64(2), r.GetInt64(3),
            r.GetInt64(4), r.GetInt64(5), r.GetInt64(6), r.GetInt64(7), r.GetDouble(8));
    }
}

public static class FaceAdministrationEndpoints
{
    public static void MapFaceAdministration(this WebApplication app)
    {
        app.MapInternalV1("/admin/summary", ["GET"], async (HttpContext context, IConfiguration config,
            FaceAdministrationRepository repository, CancellationToken token) =>
        {
            if (!MediaProtocol.IsInternal(context, config, "Administration:Key")) return Results.Unauthorized();
            try { return Results.Ok(await repository.SummaryAsync(token)); }
            catch (Exception e) when (e is NpgsqlException or TimeoutException)
            { return Results.Problem(statusCode: 503, title: "Processing summary unavailable."); }
        });
    }
}
