using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging.Abstractions;
using Nephos.Cleanup;

namespace Nephos.Tests;

public sealed class CleanupJobTests
{
    [Fact]
    public async Task Cleanup_http_timeout_without_shutdown_still_runs_deferred_GC()
    {
        using var handler = new Handler(new(Guid.NewGuid(), "owner", Guid.NewGuid()), timedOut: true);
        using var client = new HttpClient(handler);
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => Job(client).RunAsync(default));
        Assert.Contains("POST storage/internal/v1/cleanup/gc", handler.Calls);
    }

    [Fact]
    public async Task Cleanup_releases_exact_claim_then_faces_then_completes_and_collects()
    {
        var claim = new CleanupClaim(Guid.NewGuid(), "owner", Guid.NewGuid());
        using var handler = new Handler(claim);
        using var client = new HttpClient(handler);
        await Job(client).RunAsync(default);
        Assert.Equal(new[]
        {
            "POST library/internal/v1/cleanup/claim",
            $"DELETE storage/internal/v1/cleanup/{claim.AssetId}",
            $"DELETE faces/internal/v1/faces/assets/{claim.AssetId}",
            $"POST library/internal/v1/cleanup/{claim.AssetId}/complete",
            "POST library/internal/v1/cleanup/claim",
            "POST storage/internal/v1/cleanup/gc"
        }, handler.Calls);
    }

    [Theory]
    [InlineData("storage")]
    [InlineData("faces")]
    [InlineData("library")]
    public async Task Cleanup_failure_never_completes_failed_claim_and_GC_still_runs(string failedService)
    {
        using var handler = new Handler(new(Guid.NewGuid(), "owner", Guid.NewGuid()), failedService);
        using var client = new HttpClient(handler);
        await Assert.ThrowsAsync<HttpRequestException>(() => Job(client).RunAsync(default));
        Assert.DoesNotContain(handler.Calls, c => c.EndsWith("/complete", StringComparison.Ordinal));
        Assert.Contains("POST storage/internal/v1/cleanup/gc", handler.Calls);
    }

    [Fact]
    public async Task Cleanup_stale_lease_is_not_counted_and_released_claim_can_retry_idempotently()
    {
        using var handler = new Handler(new(Guid.NewGuid(), "owner", Guid.NewGuid()), staleLease: true);
        using var client = new HttpClient(handler);
        await Job(client).RunAsync(default);
        Assert.Single(handler.Calls, c => c.EndsWith("/complete", StringComparison.Ordinal));
        Assert.Contains("POST storage/internal/v1/cleanup/gc", handler.Calls);
    }

    private static CleanupJob Job(HttpClient client) => new(client,
        new ConfigurationBuilder().AddInMemoryCollection(new Dictionary<string, string?>
        {
            ["Services:Library"] = "http://library",
            ["Services:Storage"] = "http://storage",
            ["Services:Faces"] = "http://faces",
            ["Services:Key"] = new string('k', 32)
        }).Build(), NullLogger<CleanupJob>.Instance);

    private sealed class Handler(CleanupClaim claim, string? failedService = null, bool staleLease = false, bool timedOut = false) : HttpMessageHandler
    {
        public List<string> Calls { get; } = [];
        private bool claimed;
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token)
        {
            var uri = request.RequestUri!;
            Calls.Add($"{request.Method} {uri.Host}{uri.AbsolutePath}");
            Assert.Equal(new string('k', 32), Assert.Single(request.Headers.GetValues("X-Nephos-Service-Key")));
            if (uri.AbsolutePath.EndsWith("/gc", StringComparison.Ordinal))
                return new(HttpStatusCode.OK) { Content = JsonContent.Create(new { collected = 0 }) };
            if (timedOut) throw new TaskCanceledException("Simulated HTTP timeout");
            if (uri.Host == failedService) return new(HttpStatusCode.ServiceUnavailable);
            if (uri.AbsolutePath.EndsWith("/claim", StringComparison.Ordinal))
            {
                if (claimed) return new(HttpStatusCode.NoContent);
                claimed = true;
                return new(HttpStatusCode.OK) { Content = JsonContent.Create(claim) };
            }
            var body = await request.Content!.ReadFromJsonAsync<JsonElement>(token);
            if (request.Method == HttpMethod.Delete) Assert.Equal(claim.Subject, body.GetProperty("subject").GetString());
            else Assert.Equal(claim.LeaseId, body.GetProperty("leaseId").GetGuid());
            return new(staleLease && request.Method == HttpMethod.Post ? HttpStatusCode.Conflict : HttpStatusCode.NoContent);
        }
    }
}
