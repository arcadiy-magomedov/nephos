using System.Net;
using System.Net.Http.Json;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging;

namespace Nephos.Cleanup;

public sealed record CleanupClaim(Guid AssetId, string Subject, Guid LeaseId);
public sealed record CollectionResult(int Collected);

public sealed class CleanupJob(HttpClient client, IConfiguration configuration, ILogger<CleanupJob> logger)
{
    private string Endpoint(string name, string path)
    {
        var root = configuration[$"Services:{name}"];
        if (!Uri.TryCreate(root, UriKind.Absolute, out var uri) || uri.Scheme is not ("http" or "https"))
            throw new InvalidOperationException($"Services:{name} must be an absolute HTTP(S) URL.");
        return root!.TrimEnd('/') + "/internal/v1/" + path;
    }

    private async Task<HttpResponseMessage> SendAsync(HttpMethod method, string endpoint, object? body, CancellationToken token)
    {
        var key = configuration["Services:Key"];
        if (key is not { Length: >= 32 }) throw new InvalidOperationException("Services:Key must contain at least 32 characters.");
        using var request = new HttpRequestMessage(method, endpoint);
        request.Headers.Add("X-Nephos-Service-Key", key);
        if (body is not null) request.Content = JsonContent.Create(body);
        return await client.SendAsync(request, token);
    }

    public async Task RunAsync(CancellationToken token)
    {
        var maxClaims = configuration.GetValue("Cleanup:MaxClaims", 10000);
        if (maxClaims is < 1 or > 100000) throw new InvalidOperationException("Cleanup:MaxClaims must be 1..100000.");
        var completed = 0;
        Exception? failure = null;
        try
        {
            for (var i = 0; i < maxClaims; i++)
            {
                using var response = await SendAsync(HttpMethod.Post, Endpoint("Library", "cleanup/claim"), null, token);
                if (response.StatusCode == HttpStatusCode.NoContent) break;
                response.EnsureSuccessStatusCode();
                var claim = await response.Content.ReadFromJsonAsync<CleanupClaim>(token)
                    ?? throw new InvalidDataException("Library returned an empty cleanup claim.");
                if (claim.AssetId == Guid.Empty || claim.LeaseId == Guid.Empty || string.IsNullOrWhiteSpace(claim.Subject))
                    throw new InvalidDataException("Library returned an invalid cleanup claim.");
                try
                {
                    using (var release = await SendAsync(HttpMethod.Delete, Endpoint("Storage", $"cleanup/{claim.AssetId}"),
                        new { claim.Subject }, token))
                        release.EnsureSuccessStatusCode();
                    // Never mark complete when a configured Faces service failed to remove its data.
                    if (!string.IsNullOrWhiteSpace(configuration["Services:Faces"]))
                    {
                        using var faces = await SendAsync(HttpMethod.Delete, Endpoint("Faces", $"faces/assets/{claim.AssetId}"),
                            new { claim.Subject }, token);
                        faces.EnsureSuccessStatusCode();
                    }
                    using (var complete = await SendAsync(HttpMethod.Post, Endpoint("Library", $"cleanup/{claim.AssetId}/complete"),
                        new { claim.LeaseId }, token))
                    {
                        if (complete.StatusCode == HttpStatusCode.Conflict)
                        {
                            logger.LogWarning("Cleanup lease expired for {AssetId}; completion will retry with a new lease", claim.AssetId);
                            continue;
                        }
                        complete.EnsureSuccessStatusCode();
                    }
                    completed++;
                }
                catch (Exception error) when (error is not OperationCanceledException || !token.IsCancellationRequested)
                {
                    failure ??= error;
                    logger.LogWarning("Cleanup failed for {AssetId} ({ErrorType}); its lease will retry", claim.AssetId, error.GetType().Name);
                }
            }
        }
        catch (Exception error) when (error is not OperationCanceledException || !token.IsCancellationRequested) { failure = error; }
        // Run independently of claim availability: released blobs can remain held for days.
        for (var batch = 0; batch < 1000; batch++)
        {
            using var response = await SendAsync(HttpMethod.Post, Endpoint("Storage", "cleanup/gc"), null, token);
            response.EnsureSuccessStatusCode();
            var result = await response.Content.ReadFromJsonAsync<CollectionResult>(token)
                ?? throw new InvalidDataException("Storage returned an empty GC result.");
            if (result.Collected is < 0 or > 100) throw new InvalidDataException("Storage returned an invalid GC result.");
            if (result.Collected < 100) break;
        }
        logger.LogInformation("Cleanup run completed {Completed} Library claims", completed);
        if (failure is not null) System.Runtime.ExceptionServices.ExceptionDispatchInfo.Capture(failure).Throw();
    }
}
