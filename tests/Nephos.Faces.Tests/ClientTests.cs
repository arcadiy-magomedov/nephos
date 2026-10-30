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
}
