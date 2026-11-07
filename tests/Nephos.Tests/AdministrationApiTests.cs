using System.Net;
using System.Net.Http.Json;
using Microsoft.AspNetCore.Hosting;
using Microsoft.Extensions.Configuration;
using Nephos.Library.Api.Administration;

namespace Nephos.Tests;

public sealed class AdministrationApiTests
{
    private static void Configure(IWebHostBuilder builder) => builder.ConfigureAppConfiguration((_, config) =>
        config.AddInMemoryCollection(new Dictionary<string, string?>
        {
            ["Administration:Enabled"] = "true",
            ["Administration:Key"] = ApiFactory.InternalKey,
            ["ConnectionStrings:LibraryAdmin"] = "Host=localhost;Database=unused;Username=unused"
        }));
    [Theory]
    [InlineData("/internal/v1/admin/summary")]
    [InlineData("/internal/v1/admin/users")]
    [InlineData("/internal/v1/admin/libraries")]
    [InlineData("/internal/v1/admin/operations")]
    [InlineData("/internal/admin/users")]
    public async Task Private_routes_reject_missing_and_wrong_service_keys_without_querying_database(string path)
    {
        await using var baseline = new ApiFactory();
        await using var app = baseline.WithWebHostBuilder(Configure);
        using var client = app.CreateClient();
        Assert.Equal(HttpStatusCode.Unauthorized, (await client.GetAsync(path)).StatusCode);
        client.DefaultRequestHeaders.Add("X-Nephos-Service-Key", "wrong");
        Assert.Equal(HttpStatusCode.Unauthorized, (await client.GetAsync(path)).StatusCode);
    }
    [Theory]
    [InlineData("/internal/v1/admin/users?limit=0")]
    [InlineData("/internal/v1/admin/users?limit=101")]
    [InlineData("/internal/v1/admin/libraries?limit=101")]
    [InlineData("/internal/v1/admin/operations?status=bogus")]
    public async Task Bounded_queries_reject_invalid_inputs_before_database_access(string path)
    {
        await using var baseline = new ApiFactory();
        await using var app = baseline.WithWebHostBuilder(Configure);
        using var client = app.CreateClient();
        client.DefaultRequestHeaders.Add("X-Nephos-Service-Key", ApiFactory.InternalKey);
        Assert.Equal(HttpStatusCode.BadRequest, (await client.GetAsync(path)).StatusCode);
    }
    [Fact]
    public async Task Provisioning_fails_explicitly_when_identity_reconciliation_is_not_configured()
    {
        await using var baseline = new ApiFactory();
        await using var app = baseline.WithWebHostBuilder(Configure);
        using var client = app.CreateClient();
        client.DefaultRequestHeaders.Add("X-Nephos-Service-Key", ApiFactory.InternalKey);
        client.DefaultRequestHeaders.Add("X-Nephos-Operator-Subject", Guid.NewGuid().ToString());
        var input = new ProvisionCommand(Guid.NewGuid(), "valid-login", "Name", false, "Personal");
        Assert.Equal(HttpStatusCode.ServiceUnavailable, (await client.PostAsJsonAsync("/internal/v1/admin/operations", input)).StatusCode);
        Assert.Equal(HttpStatusCode.BadRequest, (await client.PostAsJsonAsync("/internal/v1/admin/operations", input with { Login = "bad login" })).StatusCode);
    }
}
