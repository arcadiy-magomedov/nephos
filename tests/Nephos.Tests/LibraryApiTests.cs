using System.IdentityModel.Tokens.Jwt;
using System.Net;
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Security.Claims;
using System.Security.Cryptography;
using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;
using Microsoft.IdentityModel.Protocols.OpenIdConnect;
using Microsoft.IdentityModel.Protocols;
using Microsoft.IdentityModel.Tokens;
using Nephos.Library.Api.Libraries;
using Nephos.Library.Api.Analysis;
using Npgsql;

namespace Nephos.Tests;

public sealed class LibraryApiTests
{
    [Fact]
    public async Task Anonymous_requests_are_rejected()
    {
        await using var factory = new ApiFactory();
        using var client = factory.CreateClient();
        Assert.Equal(HttpStatusCode.Unauthorized, (await client.GetAsync("/v1/libraries")).StatusCode);
        Assert.Equal(0, factory.Repository.Calls);
    }

    [Theory]
    [InlineData("https://wrong.example", "nephos-api", false)]
    [InlineData(ApiFactory.Issuer, "wrong-audience", false)]
    [InlineData(ApiFactory.Issuer, "nephos-api", true)]
    public async Task Invalid_tokens_are_rejected(string issuer, string audience, bool expired)
    {
        await using var factory = new ApiFactory();
        using var client = factory.CreateClient();
        client.DefaultRequestHeaders.Authorization = new AuthenticationHeaderValue(
            "Bearer", factory.Token("known", issuer, audience, expired));
        Assert.Equal(HttpStatusCode.Unauthorized, (await client.GetAsync("/v1/libraries")).StatusCode);
        Assert.Equal(0, factory.Repository.Calls);
    }

    [Fact]
    public async Task Forged_signature_is_rejected()
    {
        await using var factory = new ApiFactory();
        await using var attacker = new ApiFactory();
        using var client = factory.CreateClient();
        client.DefaultRequestHeaders.Authorization = new("Bearer", attacker.Token("known"));
        Assert.Equal(HttpStatusCode.Unauthorized, (await client.GetAsync("/v1/libraries")).StatusCode);
    }

    [Fact]
    public async Task Disabled_or_unknown_members_cannot_read_libraries()
    {
        await using var factory = new ApiFactory();
        using var client = factory.CreateClient();
        client.DefaultRequestHeaders.Authorization = new("Bearer", factory.Token("unknown"));
        Assert.Equal(HttpStatusCode.Forbidden, (await client.GetAsync("/v1/libraries")).StatusCode);
    }

    [Fact]
    public async Task Pages_are_bounded_and_use_an_explicit_continuation()
    {
        await using var factory = new ApiFactory();
        using var client = factory.CreateClient();
        client.DefaultRequestHeaders.Authorization = new("Bearer", factory.Token("known"));
        var page = await client.GetFromJsonAsync<LibraryPage>("/v1/libraries?limit=1");
        Assert.NotNull(page);
        Assert.Single(page.Items);
        Assert.Equal(page.Items[0].Id, page.NextCursor);
        Assert.Equal(2, factory.Repository.RequestedLimit);
    }

    [Theory]
    [InlineData("limit=0")]
    [InlineData("limit=101")]
    [InlineData("after=invalid")]
    public async Task Invalid_pagination_is_rejected(string query)
    {
        await using var factory = new ApiFactory();
        using var client = factory.CreateClient();
        client.DefaultRequestHeaders.Authorization = new("Bearer", factory.Token("known"));
        Assert.Equal(HttpStatusCode.BadRequest, (await client.GetAsync($"/v1/libraries?{query}")).StatusCode);
    }

    [Fact]
    public async Task Persistence_outage_is_not_an_empty_success()
    {
        await using var factory = new ApiFactory();
        factory.Repository.Unavailable = true;
        using var client = factory.CreateClient();
        client.DefaultRequestHeaders.Authorization = new("Bearer", factory.Token("known"));
        Assert.Equal(HttpStatusCode.ServiceUnavailable, (await client.GetAsync("/v1/libraries")).StatusCode);
    }
}

internal sealed class ApiFactory : WebApplicationFactory<Program>
{
    public const string Issuer = "https://identity.example/realms/nephos";
    public const string InternalKey = "test-only-analysis-service-key-32-characters";
    private readonly RSA rsa = RSA.Create(2048);
    public FakeRepository Repository { get; } = new();
    public FakeAnalysisRepository Analysis { get; } = new();

    protected override void ConfigureWebHost(IWebHostBuilder builder)
    {
        builder.UseEnvironment("Testing");
        builder.ConfigureAppConfiguration((_, config) => config.AddInMemoryCollection(new Dictionary<string, string?>
        {
            ["Authentication:Authority"] = Issuer,
            ["Authentication:Audience"] = "nephos-api",
            ["ConnectionStrings:Library"] = "Host=localhost;Database=unused;Username=unused",
            ["Services:Key"] = InternalKey
        }));
        builder.ConfigureServices(services =>
        {
            services.RemoveAll<ILibraryRepository>();
            services.AddSingleton<ILibraryRepository>(Repository);
            services.RemoveAll<IAnalysisRepository>();
            services.AddSingleton<IAnalysisRepository>(Analysis);
            services.PostConfigure<JwtBearerOptions>(JwtBearerDefaults.AuthenticationScheme, options =>
            {
                options.Configuration = new OpenIdConnectConfiguration { Issuer = Issuer };
                options.Configuration.SigningKeys.Add(new RsaSecurityKey(rsa) { KeyId = "tests" });
                options.ConfigurationManager = new StaticConfigurationManager<OpenIdConnectConfiguration>(options.Configuration);
            });
        });
    }

    public string Token(string subject, string issuer = Issuer, string audience = "nephos-api", bool expired = false)
    {
        var now = DateTime.UtcNow;
        var token = new JwtSecurityToken(issuer, audience, [new Claim("sub", subject)],
            now.AddHours(-1), expired ? now.AddMinutes(-5) : now.AddMinutes(5),
            new SigningCredentials(new RsaSecurityKey(rsa) { KeyId = "tests" }, SecurityAlgorithms.RsaSha256));
        return new JwtSecurityTokenHandler().WriteToken(token);
    }

    public override async ValueTask DisposeAsync()
    {
        await base.DisposeAsync();
        rsa.Dispose();
    }
}

internal sealed class FakeRepository : ILibraryRepository
{
    public int Calls { get; private set; }
    public int RequestedLimit { get; private set; }
    public bool Unavailable { get; set; }

    public Task<bool> IsEnabledAsync(string subject, CancellationToken cancellationToken)
    {
        Calls++;
        if (Unavailable)
        {
            throw new NpgsqlException("Synthetic outage");
        }
        return Task.FromResult(subject == "known");
    }

    public Task<IReadOnlyList<LibrarySummary>> ListAsync(string subject, Guid? after, int limit, CancellationToken cancellationToken)
    {
        RequestedLimit = limit;
        return Task.FromResult<IReadOnlyList<LibrarySummary>>([
            new(Guid.Parse("00000000-0000-0000-0000-000000000001"), "First"),
            new(Guid.Parse("00000000-0000-0000-0000-000000000002"), "Second")
        ]);
    }
}
