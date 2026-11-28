using System.Net;
using System.Net.Http.Json;
using System.Security.Cryptography;
using Microsoft.Extensions.Configuration;
using Nephos.Faces.Api;

namespace Nephos.Faces.Tests;

public sealed class ClientTests
{
    private sealed class Handler(Func<HttpRequestMessage, HttpResponseMessage> respond) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) =>
            Task.FromResult(respond(request));
    }

    private sealed class Factory(Func<HttpRequestMessage, HttpResponseMessage> respond) : IHttpClientFactory
    {
        public HttpClient CreateClient(string name) => new(new Handler(respond)) { BaseAddress = new Uri("http://fixed-service.invalid") };
    }

    private static IConfiguration Config => new ConfigurationBuilder().AddInMemoryCollection(
        new Dictionary<string, string?> { ["Services:Key"] = new string('s', 64) }).Build();

    [Fact]
    public async Task InternalSourceIsBoundToRequestedOwnerAndAsset()
    {
        var owner = "owner";
        var source = PersistenceTests.Source(owner);
        var client = new AnalysisSourceClient(new Factory(request =>
        {
            Assert.Equal($"/internal/v1/analysis/owners/{owner}/assets/{source.Id}", request.RequestUri!.AbsolutePath);
            Assert.Equal(new string('s', 64), request.Headers.GetValues("X-Nephos-Service-Key").Single());
            return new(HttpStatusCode.OK) { Content = JsonContent.Create(source with { Subject = "other" }) };
        }), Config);
        await Assert.ThrowsAsync<HttpRequestException>(() => client.SourceAsync(owner, source.Id, default));
    }

    [Fact]
    public async Task ExactOriginalLengthAndHashAreVerifiedBeforeInference()
    {
        byte[] bytes = [1, 2, 3, 4];
        var source = PersistenceTests.Source("owner") with { Size = bytes.Length, Sha256 = Convert.ToHexStringLower(SHA256.HashData(bytes)) };
        var client = new AnalysisSourceClient(new Factory(request =>
        {
            Assert.Equal($"/internal/v1/assets/{source.Id}/original", request.RequestUri!.AbsolutePath);
            return new(HttpStatusCode.OK) { Content = new ByteArrayContent(bytes) };
        }), Config);
        Assert.Equal(bytes, await client.OriginalAsync(source, default));
        await Assert.ThrowsAsync<InvalidDataException>(() => client.OriginalAsync(source with { Sha256 = new string('f', 64) }, default));
        await Assert.ThrowsAsync<InvalidDataException>(() => client.OriginalAsync(source with { Size = 3 }, default));
    }

    [Theory]
    [InlineData("image/jpeg", true)]
    [InlineData("image/png", true)]
    [InlineData("image/webp", true)]
    [InlineData("image/heic", true)]
    [InlineData("image/heif", true)]
    [InlineData("image/heic-sequence", false)]
    [InlineData("image/heif-sequence", false)]
    [InlineData("image/gif", false)]
    [InlineData("video/quicktime", false)]
    [InlineData("application/octet-stream", false)]
    public async Task AuthorizedSourceAcceptsSupportedStillImagesOnly(string mediaType, bool supported)
    {
        var source = PersistenceTests.Source("owner") with { MediaType = mediaType };
        var client = new AnalysisSourceClient(new Factory(_ =>
            new(HttpStatusCode.OK) { Content = JsonContent.Create(source) }), Config);
        if (supported)
            Assert.NotNull(await client.SourceAsync(source.Subject, source.Id, default));
        else
            await Assert.ThrowsAsync<HttpRequestException>(() => client.SourceAsync(source.Subject, source.Id, default));
    }

    [Fact]
    public async Task HeicDoesNotBypassSourceSizeLimitOrExactHash()
    {
        byte[] bytes = [1, 2, 3, 4];
        var source = PersistenceTests.Source("owner") with
        {
            MediaType = "image/heic",
            Size = Pipeline.MaxBytes + 1L
        };
        var metadata = new AnalysisSourceClient(new Factory(_ =>
            new(HttpStatusCode.OK) { Content = JsonContent.Create(source) }), Config);
        await Assert.ThrowsAsync<HttpRequestException>(() => metadata.SourceAsync(source.Subject, source.Id, default));
        var original = new AnalysisSourceClient(new Factory(_ =>
            new(HttpStatusCode.OK) { Content = new ByteArrayContent(bytes) }), Config);
        await Assert.ThrowsAsync<InvalidDataException>(() =>
            original.OriginalAsync(source with { Size = bytes.Length, Sha256 = new string('f', 64) }, default));
    }

    [Fact]
    public async Task BatchAssetAuthorizationIssuesOneInternalRequestPerBatchAndFiltersForeignIds()
    {
        var first = Guid.NewGuid();
        var second = Guid.NewGuid();
        var forged = Guid.NewGuid();
        var calls = 0;
        var client = new AnalysisSourceClient(new Factory(request =>
        {
            calls++;
            Assert.Equal(HttpMethod.Post, request.Method);
            Assert.Equal("/internal/v1/analysis/owners/owner/assets/authorize", request.RequestUri!.AbsolutePath);
            Assert.Equal(new string('s', 64), request.Headers.GetValues("X-Nephos-Service-Key").Single());
            return new(HttpStatusCode.OK) { Content = JsonContent.Create(new { authorizedIds = new[] { first, forged } }) };
        }), Config);

        var allowed = await client.AuthorizeSourcesAsync("owner", [first, second, first], default);

        Assert.Equal(1, calls);
        Assert.Equal([first], allowed.ToArray());
    }

    [Theory]
    [InlineData("{}")]
    [InlineData("{\"authorizedIds\":null}")]
    public async Task MalformedAuthorizationDoesNotBecomeAnEmptySuccess(string body)
    {
        var client = new AnalysisSourceClient(new Factory(_ => new(HttpStatusCode.OK)
        {
            Content = new StringContent(body, System.Text.Encoding.UTF8, "application/json")
        }), Config);
        await Assert.ThrowsAsync<HttpRequestException>(() => client.AuthorizeSourcesAsync("owner", [Guid.NewGuid()], default));
    }

    [Fact]
    public async Task SourceWithNullHashIsRetryableWithoutNullDereference()
    {
        var source = PersistenceTests.Source("owner") with { Sha256 = null! };
        var client = new AnalysisSourceClient(new Factory(_ => new(HttpStatusCode.OK)
        {
            Content = JsonContent.Create(source)
        }), Config);
        await Assert.ThrowsAsync<HttpRequestException>(() => client.SourceAsync("owner", source.Id, default));
    }

    [Fact]
    public async Task UnexpectedOwnerAccessSuccessIsNotMisclassifiedAsDisabled()
    {
        var context = new Microsoft.AspNetCore.Http.DefaultHttpContext
        {
            User = new System.Security.Claims.ClaimsPrincipal(new System.Security.Claims.ClaimsIdentity(
                [new System.Security.Claims.Claim("sub", "owner")]))
        };
        var client = new AnalysisSourceClient(new Factory(_ => new(HttpStatusCode.OK)), Config);
        await Assert.ThrowsAsync<HttpRequestException>(() => client.IsEnabledAsync(context, default));
    }
}
