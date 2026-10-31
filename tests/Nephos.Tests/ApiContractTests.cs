using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.TestHost;
using Nephos.ServiceDefaults;

namespace Nephos.Tests;

public sealed class ApiContractTests
{
    [Fact]
    public async Task Internal_aliases_preserve_handlers_filters_and_version_boundaries()
    {
        var builder = WebApplication.CreateBuilder();
        builder.WebHost.UseTestServer();
        await using var app = builder.Build();
        var calls = 0;
        app.MapInternalV1("/echo", ["POST"], () =>
        {
            calls++;
            return Results.Ok(new { value = "v1" });
        }).AddEndpointFilter((context, next) =>
            context.HttpContext.Request.Headers.ContainsKey("X-Test-Peer")
                ? next(context) : ValueTask.FromResult<object?>(Results.Unauthorized()));
        await app.StartAsync();
        using var client = app.GetTestClient();
        foreach (var path in new[] { "/internal/echo", "/internal/v1/echo" })
        {
            Assert.Equal(HttpStatusCode.Unauthorized, (await client.PostAsync(path, null)).StatusCode);
            using var request = new HttpRequestMessage(HttpMethod.Post, path);
            request.Headers.Add("X-Test-Peer", "fixture");
            using var response = await client.SendAsync(request);
            Assert.Equal(HttpStatusCode.OK, response.StatusCode);
            Assert.Equal("{\"value\":\"v1\"}", await response.Content.ReadAsStringAsync());
            Assert.Equal(path == "/internal/echo", response.Headers.Contains("Link"));
            Assert.Equal(HttpStatusCode.MethodNotAllowed, (await client.GetAsync(path)).StatusCode);
        }
        Assert.Equal(2, calls);
        Assert.Equal(HttpStatusCode.NotFound, (await client.PostAsync("/internal/v2/echo", null)).StatusCode);
        Assert.Equal(HttpStatusCode.NotFound, (await client.PostAsync("/internal/v1/unknown", null)).StatusCode);
    }

    [Fact]
    public async Task Public_v1_discovery_keeps_required_wire_fields_without_unversioned_fallback()
    {
        await using var factory = new ApiFactory();
        using var client = factory.CreateClient();
        var config = await client.GetFromJsonAsync<JsonElement>("/v1/config");
        Assert.Equal(JsonValueKind.String, config.GetProperty("serverId").ValueKind);
        Assert.Equal(ApiFactory.Issuer, config.GetProperty("issuer").GetString());
        Assert.Equal("nephos-ios", config.GetProperty("clientId").GetString());
        Assert.Equal(MediaProtocol.MaxUploadBytes, config.GetProperty("maxUploadBytes").GetInt64());
        Assert.Equal(MediaProtocol.ChunkSize, config.GetProperty("chunkSize").GetInt32());
        Assert.Equal(HttpStatusCode.NotFound, (await client.GetAsync("/config")).StatusCode);
        Assert.Equal(HttpStatusCode.NotFound, (await client.GetAsync("/v2/config")).StatusCode);
    }
}
