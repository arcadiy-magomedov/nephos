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
            Assert.Equal($"/internal/analysis/owners/{owner}/assets/{source.Id}", request.RequestUri!.AbsolutePath);
            Assert.Equal(new string('s', 64), request.Headers.GetValues("X-Nephos-Service-Key").Single());
            return new(HttpStatusCode.OK) { Content = JsonContent.Create(source with { Subject = "other" }) };
        }), Config);
        Assert.Null(await client.SourceAsync(owner, source.Id, default));
    }

    [Fact]
    public async Task ExactOriginalLengthAndHashAreVerifiedBeforeInference()
    {
        byte[] bytes = [1, 2, 3, 4];
        var source = PersistenceTests.Source("owner") with { Size = bytes.Length, Sha256 = Convert.ToHexStringLower(SHA256.HashData(bytes)) };
        var client = new AnalysisSourceClient(new Factory(request =>
        {
            Assert.Equal($"/internal/assets/{source.Id}/original", request.RequestUri!.AbsolutePath);
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
        Assert.Equal(supported, await client.SourceAsync(source.Subject, source.Id, default) is not null);
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
        Assert.Null(await metadata.SourceAsync(source.Subject, source.Id, default));
        var original = new AnalysisSourceClient(new Factory(_ =>
            new(HttpStatusCode.OK) { Content = new ByteArrayContent(bytes) }), Config);
        await Assert.ThrowsAsync<InvalidDataException>(() =>
            original.OriginalAsync(source with { Size = bytes.Length, Sha256 = new string('f', 64) }, default));
    }
}
