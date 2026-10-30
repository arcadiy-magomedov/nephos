using System.Net;
using System.Net.Http.Json;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging.Abstractions;
using Nephos.Library.Api.Analysis;

namespace Nephos.Tests;

public sealed class AnalysisTests
{
    [Theory]
    [InlineData(null, HttpStatusCode.Unauthorized)]
    [InlineData("unknown", HttpStatusCode.Forbidden)]
    [InlineData("known", HttpStatusCode.NoContent)]
    public async Task Live_analysis_access_is_enabled_subject_only(string? subject, HttpStatusCode expected)
    {
        await using var factory = new ApiFactory();
        using var client = factory.CreateClient();
        if (subject is not null) client.DefaultRequestHeaders.Authorization = new("Bearer", factory.Token(subject));
        using var response = await client.GetAsync("/v1/analysis/access");
        Assert.Equal(expected, response.StatusCode);
    }

    [Fact]
    public async Task Source_requires_peer_key_and_exact_authorized_subject()
    {
        await using var factory = new ApiFactory();
        using var client = factory.CreateClient();
        client.DefaultRequestHeaders.Authorization = new("Bearer", factory.Token("known"));
        var path = $"/internal/analysis/owners/known/assets/{factory.Analysis.AssetId}";
        Assert.Equal(HttpStatusCode.Unauthorized, (await client.GetAsync(path)).StatusCode);
        Assert.Equal(0, factory.Analysis.Reads);
        client.DefaultRequestHeaders.Add("X-Nephos-Service-Key", ApiFactory.InternalKey);
        var source = await client.GetFromJsonAsync<AnalysisSource>(path);
        Assert.NotNull(source);
        Assert.Equal("known", source.Subject);
        Assert.Equal(HttpStatusCode.NotFound, (await client.GetAsync(
            $"/internal/analysis/owners/other/assets/{factory.Analysis.AssetId}")).StatusCode);
    }

    [Theory]
    [InlineData(202)]
    [InlineData(404)]
    [InlineData(503)]
    [InlineData(null)]
    public async Task Publisher_preserves_response_and_lease_for_durable_retry(int? status)
    {
        var repository = new FakeAnalysisRepository { Pending = true };
        using var handler = new PublicationHandler(status);
        using var http = new HttpClient(handler);
        using var worker = new FacePublicationWorker(repository, new ClientFactory(http),
            new ConfigurationBuilder().AddInMemoryCollection(new Dictionary<string, string?>
            {
                ["Services:Faces"] = "http://faces-api:8080",
                ["Services:Key"] = ApiFactory.InternalKey
            }).Build(), NullLogger<FacePublicationWorker>.Instance);
        await worker.StartAsync(CancellationToken.None);
        var completion = await repository.Completed.Task.WaitAsync(TimeSpan.FromSeconds(5));
        await worker.StopAsync(CancellationToken.None);
        Assert.Equal(status, completion.Status);
        Assert.Equal(repository.LeaseId, completion.Publication.LeaseId);
        Assert.Equal(repository.AssetId, completion.Publication.AssetId);
        Assert.Equal("known", handler.Body?.Subject);
        Assert.Equal(repository.AssetId, handler.Body?.AssetId);
    }

    private sealed class ClientFactory(HttpClient client) : IHttpClientFactory
    {
        public HttpClient CreateClient(string name) => client;
    }

    private sealed record Payload(Guid AssetId, string Subject);
    private sealed class PublicationHandler(int? status) : HttpMessageHandler
    {
        public Payload? Body { get; private set; }
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token)
        {
            Assert.Equal("http://faces-api:8080/internal/faces/jobs", request.RequestUri?.ToString());
            Assert.Equal(ApiFactory.InternalKey, Assert.Single(request.Headers.GetValues("X-Nephos-Service-Key")));
            Body = await request.Content!.ReadFromJsonAsync<Payload>(token);
            if (status is null) throw new HttpRequestException("Synthetic unavailable peer");
            return new HttpResponseMessage((HttpStatusCode)status);
        }
    }
}

internal sealed class FakeAnalysisRepository : IAnalysisRepository
{
    public Guid AssetId { get; } = Guid.NewGuid();
    public Guid LeaseId { get; } = Guid.NewGuid();
    public int Reads { get; private set; }
    public bool Pending { get; set; }
    public TaskCompletionSource<(FacePublication Publication, int? Status)> Completed { get; } = new(TaskCreationOptions.RunContinuationsAsynchronously);

    public Task<AnalysisSource?> FindSourceAsync(string subject, Guid assetId, CancellationToken token)
    {
        Reads++;
        return Task.FromResult(subject == "known" && assetId == AssetId
            ? new AnalysisSource(AssetId, Guid.NewGuid(), subject, "image/jpeg", 123, new string('a', 64))
            : null);
    }

    public Task<FacePublication?> ClaimAsync(CancellationToken token)
    {
        var result = Pending ? new FacePublication(AssetId, "known", LeaseId, 1) : null;
        Pending = false;
        return Task.FromResult(result);
    }

    public Task CompleteAsync(FacePublication publication, int? status, CancellationToken token)
    {
        Completed.TrySetResult((publication, status));
        return Task.CompletedTask;
    }
}
