using System.IdentityModel.Tokens.Jwt;
using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Security.Claims;
using System.Security.Cryptography;
using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;
using Microsoft.Extensions.Logging.Abstractions;
using Microsoft.IdentityModel.Protocols;
using Microsoft.IdentityModel.Protocols.OpenIdConnect;
using Microsoft.IdentityModel.Tokens;
using Nephos.Faces.Api;

namespace Nephos.Faces.Tests;

public sealed class ControlledSource : IAnalysisSourceClient
{
    public bool Enabled = true;
    public readonly Dictionary<Guid, (AnalysisSource Source, byte[] Bytes)> Sources = [];
    public Task<bool> IsEnabledAsync(HttpContext context, CancellationToken ct) => Task.FromResult(Enabled);
    public Task<AnalysisSource?> SourceAsync(string owner, Guid assetId, CancellationToken ct) =>
        Task.FromResult(Enabled && Sources.TryGetValue(assetId, out var item) && item.Source.Subject == owner ? item.Source : null);
    public Task<byte[]> OriginalAsync(AnalysisSource source, CancellationToken ct) => Task.FromResult(Sources[source.Id].Bytes);
}

public sealed class FacesApplication : WebApplicationFactory<Program>
{
    public ControlledSource Source { get; } = new();
    private readonly RSA rsa = RSA.Create(2048);
    public string Token(string subject, string audience = "faces-test") => new JwtSecurityTokenHandler().WriteToken(
        new JwtSecurityToken("https://test.invalid", audience, [new Claim("sub", subject)], DateTime.UtcNow.AddMinutes(-1),
            DateTime.UtcNow.AddMinutes(10), new SigningCredentials(new RsaSecurityKey(rsa) { KeyId = "test-key" }, SecurityAlgorithms.RsaSha256)));

    protected override void ConfigureWebHost(IWebHostBuilder builder)
    {
        builder.UseEnvironment("Testing");
        builder.ConfigureAppConfiguration((_, c) => c.AddInMemoryCollection(new Dictionary<string, string?>
        {
            ["Authentication:Authority"] = "https://test.invalid",
            ["Authentication:Audience"] = "faces-test",
            ["Authentication:IntrospectionEndpoint"] = "http://identity.test/realms/nephos/protocol/openid-connect/token/introspect",
            ["Authentication:IntrospectionClientId"] = "nephos-api-introspection",
            ["Authentication:IntrospectionClientSecret"] = new string('i', 48),
            ["ConnectionStrings:Faces"] = Environment.GetEnvironmentVariable("FACES_TEST_CONNECTION"),
            ["Services:Library"] = "http://127.0.0.1:1",
            ["Services:Storage"] = "http://127.0.0.1:1",
            ["Services:Key"] = new string('s', 64),
            ["Inference:Url"] = "http://127.0.0.1:1",
            ["Inference:Key"] = new string('i', 64),
            ["Worker:Enabled"] = "false",
            ["OTEL_EXPORTER_OTLP_ENDPOINT"] = "http://127.0.0.1:1"
        }));
        builder.ConfigureServices(services =>
        {
            services.AddHttpClient("keycloak-introspection")
                .ConfigurePrimaryHttpMessageHandler(() => new ActiveIntrospectionHandler());
            services.RemoveAll<IAnalysisSourceClient>();
            services.AddSingleton<IAnalysisSourceClient>(Source);
            services.PostConfigure<JwtBearerOptions>(JwtBearerDefaults.AuthenticationScheme, options =>
            {
                var config = new OpenIdConnectConfiguration { Issuer = "https://test.invalid" };
                config.SigningKeys.Add(new RsaSecurityKey(rsa) { KeyId = "test-key" });
                options.ConfigurationManager = new StaticConfigurationManager<OpenIdConnectConfiguration>(config);
            });
        });
    }

    private sealed class ActiveIntrospectionHandler : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) =>
            Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK)
            {
                Content = new StringContent("{\"active\":true}", System.Text.Encoding.UTF8, "application/json")
            });
    }

    public HttpClient Authenticated(string owner)
    {
        var client = CreateClient();
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue("Bearer", Token(owner));
        return client;
    }
}

[Collection("face-database")]
public sealed class ApiTests
{
    private sealed class DisableDuringInference(ControlledSource source, string hash) : IInferenceClient
    {
        public Task<InferenceResult> AnalyzeAsync(byte[] bytes, CancellationToken ct)
        {
            source.Enabled = false;
            return Task.FromResult(PersistenceTests.Result(hash));
        }
    }

    [DatabaseFact]
    public async Task ValidJwtIsRequiredAndLiveDisableBlocksEveryPublicRoute()
    {
        await using var app = new FacesApplication();
        using var anonymous = app.CreateClient();
        Assert.Equal(HttpStatusCode.Unauthorized, (await anonymous.GetAsync("/v1/faces/people")).StatusCode);
        anonymous.DefaultRequestHeaders.Authorization = new("Bearer", app.Token("test", "wrong-audience"));
        Assert.Equal(HttpStatusCode.Unauthorized, (await anonymous.GetAsync("/v1/faces/people")).StatusCode);
        using var client = app.Authenticated("api-" + Guid.NewGuid());
        Assert.Equal(HttpStatusCode.OK, (await client.GetAsync("/v1/faces/people?limit=1")).StatusCode);
        Assert.Equal(HttpStatusCode.BadRequest, (await client.GetAsync("/v1/faces/people?limit=101")).StatusCode);
        Assert.Equal(HttpStatusCode.BadRequest, (await client.GetAsync("/v1/faces/jobs?limit=0")).StatusCode);
        app.Source.Enabled = false;
        foreach (var route in new[] { "/people", "/jobs", "/observations", "/corrections", $"/people/{Guid.NewGuid()}/assets" })
            Assert.Equal(HttpStatusCode.Forbidden, (await client.GetAsync("/v1/faces" + route)).StatusCode);
        Assert.Equal(HttpStatusCode.Forbidden, (await client.PostAsync($"/v1/faces/jobs/{Guid.NewGuid()}", null)).StatusCode);
        Assert.Equal(HttpStatusCode.Forbidden, (await client.PutAsJsonAsync($"/v1/faces/people/{Guid.NewGuid()}/name", new NameRequest("name", []))).StatusCode);
        Assert.Equal(HttpStatusCode.Unauthorized, (await client.PostAsJsonAsync("/internal/faces/jobs", new EnqueueRequest(Guid.NewGuid(), "owner"))).StatusCode);
    }

    [DatabaseFact]
    public async Task OwnerIsTakenFromJwtAndSharedOrGuessedAssetsCannotBeEnqueued()
    {
        await using var app = new FacesApplication();
        var owner = "owner-" + Guid.NewGuid();
        var source = PersistenceTests.Source(owner);
        app.Source.Sources[source.Id] = (source, []);
        using var client = app.Authenticated(owner);
        using var other = app.Authenticated("recipient-" + Guid.NewGuid());
        Assert.Equal(HttpStatusCode.NotFound, (await other.PostAsync($"/v1/faces/jobs/{source.Id}", null)).StatusCode);
        Assert.Equal(HttpStatusCode.Accepted, (await client.PostAsync($"/v1/faces/jobs/{source.Id}", null)).StatusCode);
        var repo = app.Services.GetRequiredService<IFaceRepository>();
        var claim = (await repo.ClaimAsync(default))!;
        await repo.CompleteAsync(claim, PersistenceTests.Result(source.Sha256), default);
        var face = (await repo.FacesAsync(owner, null, null, null, 100, default)).Single();
        Assert.Equal(HttpStatusCode.NotFound, (await other.GetAsync($"/v1/faces/people/{face.PersonId}")).StatusCode);
        Assert.Equal(HttpStatusCode.NotFound, (await other.PutAsJsonAsync($"/v1/faces/people/{face.PersonId}/name", new NameRequest("stolen", []))).StatusCode);
        app.Source.Sources.Remove(source.Id);
        var page = await client.GetFromJsonAsync<Page<Face>>("/v1/faces/observations");
        Assert.Empty(page!.Items);
    }

    [DatabaseFact]
    public async Task Internal_asset_deletion_requires_service_key_and_removes_face_data()
    {
        await using var app = new FacesApplication();
        var owner = "delete-" + Guid.NewGuid();
        var source = PersistenceTests.Source(owner);
        var repository = app.Services.GetRequiredService<IFaceRepository>();
        await repository.EnqueueAsync(owner, source, default);
        await repository.CompleteAsync((await repository.ClaimAsync(default))!, PersistenceTests.Result(source.Sha256), default);
        Assert.Single(await repository.FacesAsync(owner, source.Id, null, null, 100, default));
        using var client = app.CreateClient();
        var path = $"/internal/v1/faces/assets/{source.Id}";
        var payload = new DeleteAssetRequest(owner);
        Assert.Equal(HttpStatusCode.Unauthorized, (await client.SendAsync(
            new HttpRequestMessage(HttpMethod.Delete, path) { Content = JsonContent.Create(payload) })).StatusCode);
        client.DefaultRequestHeaders.Add("X-Nephos-Service-Key", new string('x', 64));
        Assert.Equal(HttpStatusCode.Unauthorized, (await client.SendAsync(
            new HttpRequestMessage(HttpMethod.Delete, path) { Content = JsonContent.Create(payload) })).StatusCode);
        client.DefaultRequestHeaders.Remove("X-Nephos-Service-Key");
        client.DefaultRequestHeaders.Add("X-Nephos-Service-Key", new string('s', 64));
        Assert.Equal(HttpStatusCode.NoContent, (await client.SendAsync(
            new HttpRequestMessage(HttpMethod.Delete, path) { Content = JsonContent.Create(payload) })).StatusCode);
        Assert.Empty(await repository.FacesAsync(owner, source.Id, null, null, 100, default));
        Assert.Empty(await repository.JobsAsync(owner, null, 100, default));
    }

    [DatabaseFact]
    public async Task DisablingOwnerDuringInferencePreventsResultsFromBeingPublished()
    {
        await using var app = new FacesApplication();
        using var client = app.Authenticated("disable-" + Guid.NewGuid());
        var owner = "worker-" + Guid.NewGuid();
        var source = PersistenceTests.Source(owner);
        app.Source.Sources[source.Id] = (source, []);
        var r = app.Services.GetRequiredService<IFaceRepository>();
        var job = await r.EnqueueAsync(owner, source, default);
        var worker = new FaceWorker(r, app.Source, new DisableDuringInference(app.Source, source.Sha256), NullLogger<FaceWorker>.Instance);
        await worker.ProcessAsync((await r.ClaimAsync(default))!, default);
        Assert.Equal("denied", (await r.JobAsync(owner, job.Id, default))!.Status);
        Assert.Empty(await r.FacesAsync(owner, null, null, null, 100, default));
        Assert.Equal(HttpStatusCode.Forbidden, (await client.GetAsync("/v1/faces/people")).StatusCode);
    }
}
