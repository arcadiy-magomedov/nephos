using System.Net;
using Microsoft.AspNetCore.Hosting;
using Microsoft.Extensions.Configuration;
using Nephos.Faces.Api;
using Npgsql;

namespace Nephos.Faces.Tests;

[Collection("face-database")]
public sealed class AdministrationTests
{
    [DatabaseFact]
    public async Task Summary_counts_real_durable_statuses_and_live_leases_under_runtime_role()
    {
        var connection = Environment.GetEnvironmentVariable("FACES_TEST_CONNECTION")!;
        await using var owner = NpgsqlDataSource.Create(connection);
        var runtime = new NpgsqlConnectionStringBuilder(connection) { Options = "-c role=faces_app" };
        await using var db = NpgsqlDataSource.Create(runtime.ConnectionString);
        var repository = new FaceAdministrationRepository(db);
        var before = await repository.SummaryAsync(default);
        var fixtureOwner = "summary-test-" + Guid.NewGuid().ToString("N");
        try
        {
            foreach (var status in new[] { "queued", "running", "complete", "no_faces", "error", "denied" })
            {
                await using var insert = owner.CreateCommand("""
                INSERT INTO jobs(id,owner,asset_id,source_sha256,pipeline_version,status,lease_until)
                VALUES($1,$5,$2,$3,'test',$4,now()+interval '1 minute')
                """);
                insert.Parameters.AddWithValue(Guid.NewGuid());
                insert.Parameters.AddWithValue(Guid.NewGuid());
                insert.Parameters.AddWithValue(new string('a', 64));
                insert.Parameters.AddWithValue(status);
                insert.Parameters.AddWithValue(fixtureOwner);
                await insert.ExecuteNonQueryAsync();
            }
            var after = await repository.SummaryAsync(default);
            Assert.Equal(before.Queued + 1, after.Queued);
            Assert.Equal(before.Running + 1, after.Running);
            Assert.Equal(before.Complete + 1, after.Complete);
            Assert.Equal(before.NoFaces + 1, after.NoFaces);
            Assert.Equal(before.Error + 1, after.Error);
            Assert.Equal(before.Denied + 1, after.Denied);
            Assert.Equal(before.ActiveLeases + 1, after.ActiveLeases);
            Assert.True(after.OldestPendingAgeSeconds >= 0);
        }
        finally
        {
            await using var cleanup = owner.CreateCommand("DELETE FROM jobs WHERE owner=$1");
            cleanup.Parameters.AddWithValue(fixtureOwner);
            await cleanup.ExecuteNonQueryAsync();
        }
    }
    [Theory]
    [InlineData("/internal/v1/admin/summary")]
    [InlineData("/internal/admin/summary")]
    public async Task Summary_denies_anonymous_calls_without_database_access(string path)
    {
        await using var baseline = new FacesApplication();
        await using var app = baseline.WithWebHostBuilder(builder => builder.ConfigureAppConfiguration((_, config) =>
            config.AddInMemoryCollection(new Dictionary<string, string?>
            {
                ["ConnectionStrings:Faces"] = "Host=localhost;Database=unused;Username=unused",
                ["Administration:Key"] = "test-private-key"
            })));
        using var client = app.CreateClient();
        Assert.Equal(HttpStatusCode.Unauthorized, (await client.GetAsync(path)).StatusCode);
    }
}
