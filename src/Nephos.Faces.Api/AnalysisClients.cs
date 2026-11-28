using System.Net;
using System.Security.Cryptography;

namespace Nephos.Faces.Api;

public interface IAnalysisSourceClient
{
    Task<bool> IsEnabledAsync(HttpContext context, CancellationToken ct);
    Task<AnalysisSource?> SourceAsync(string owner, Guid assetId, CancellationToken ct);
    Task<IReadOnlySet<Guid>> AuthorizeSourcesAsync(string owner, IReadOnlyList<Guid> assetIds, CancellationToken ct);
    Task<byte[]> OriginalAsync(AnalysisSource source, CancellationToken ct);
}

public sealed class AnalysisSourceClient(IHttpClientFactory factory, IConfiguration configuration) : IAnalysisSourceClient
{
    private sealed record BatchAuthorizeResponse(Guid[] AuthorizedIds);

    private HttpRequestMessage Internal(HttpMethod method, string path)
    {
        var request = new HttpRequestMessage(method, path);
        request.Headers.Add("X-Nephos-Service-Key", configuration["Services:Key"]);
        return request;
    }

    public async Task<bool> IsEnabledAsync(HttpContext context, CancellationToken ct)
    {
        var subject = context.User.FindFirst("sub")?.Value;
        if (string.IsNullOrWhiteSpace(subject)) return false;
        using var request = Internal(HttpMethod.Get, $"/internal/v1/analysis/owners/{Uri.EscapeDataString(subject)}/access");
        using var response = await factory.CreateClient("library").SendAsync(request, ct);
        if (response.StatusCode is HttpStatusCode.Forbidden or HttpStatusCode.Unauthorized or HttpStatusCode.NotFound) return false;
        response.EnsureSuccessStatusCode();
        if (response.StatusCode != HttpStatusCode.NoContent)
            throw new HttpRequestException("Library returned an invalid owner access response.");
        return true;
    }

    public async Task<IReadOnlySet<Guid>> AuthorizeSourcesAsync(string owner, IReadOnlyList<Guid> assetIds, CancellationToken ct)
    {
        var allowed = new HashSet<Guid>();
        var distinct = assetIds.Where(id => id != Guid.Empty).Distinct().ToArray();
        if (distinct.Length == 0) return allowed;
        foreach (var batch in distinct.Chunk(100))
        {
            using var request = Internal(HttpMethod.Post, $"/internal/v1/analysis/owners/{Uri.EscapeDataString(owner)}/assets/authorize");
            request.Content = JsonContent.Create(new { assetIds = batch });
            using var response = await factory.CreateClient("library").SendAsync(request, ct);
            if (response.StatusCode is HttpStatusCode.NotFound or HttpStatusCode.Forbidden or HttpStatusCode.Unauthorized)
                return new HashSet<Guid>();
            response.EnsureSuccessStatusCode();
            var result = await response.Content.ReadFromJsonAsync<BatchAuthorizeResponse>(ct);
            if (result?.AuthorizedIds is null)
                throw new HttpRequestException("Library returned an invalid authorization response.");
            foreach (var id in result.AuthorizedIds)
                if (batch.Contains(id)) allowed.Add(id);
        }
        return allowed;
    }

    public async Task<AnalysisSource?> SourceAsync(string owner, Guid assetId, CancellationToken ct)
    {
        using var request = Internal(HttpMethod.Get, $"/internal/v1/analysis/owners/{Uri.EscapeDataString(owner)}/assets/{assetId}");
        using var response = await factory.CreateClient("library").SendAsync(request, ct);
        if (response.StatusCode is HttpStatusCode.NotFound or HttpStatusCode.Forbidden or HttpStatusCode.Unauthorized) return null;
        response.EnsureSuccessStatusCode();
        var source = await response.Content.ReadFromJsonAsync<AnalysisSource>(ct);
        if (source is null || source.Id != assetId || source.Subject != owner || source.Size is <= 0 or > Pipeline.MaxBytes ||
            !Pipeline.SupportsMediaType(source.MediaType) ||
            source.Sha256 is not { Length: 64 } || !source.Sha256.All(char.IsAsciiHexDigit))
            throw new HttpRequestException("Library returned an invalid analysis source.");
        return source with { Sha256 = source.Sha256.ToLowerInvariant() };
    }

    public async Task<byte[]> OriginalAsync(AnalysisSource source, CancellationToken ct)
    {
        using var request = Internal(HttpMethod.Get, $"/internal/v1/assets/{source.Id}/original");
        using var response = await factory.CreateClient("storage").SendAsync(request, HttpCompletionOption.ResponseHeadersRead, ct);
        response.EnsureSuccessStatusCode();
        if (response.Content.Headers.ContentLength is > Pipeline.MaxBytes) throw new InvalidDataException("payload_limit");
        await using var stream = await response.Content.ReadAsStreamAsync(ct);
        using var output = new MemoryStream((int)source.Size);
        var buffer = new byte[65536];
        int read;
        while ((read = await stream.ReadAsync(buffer, ct)) > 0)
        {
            if (output.Length + read > source.Size || output.Length + read > Pipeline.MaxBytes)
                throw new InvalidDataException("payload_limit");
            output.Write(buffer, 0, read);
        }
        var bytes = output.ToArray();
        if (bytes.LongLength != source.Size ||
            Convert.ToHexStringLower(SHA256.HashData(bytes)) != source.Sha256) throw new InvalidDataException("source_mismatch");
        return bytes;
    }
}

public interface IInferenceClient
{
    Task<InferenceResult> AnalyzeAsync(byte[] bytes, CancellationToken ct);
}

public sealed class InferenceClient(IHttpClientFactory factory, IConfiguration configuration) : IInferenceClient
{
    public async Task<InferenceResult> AnalyzeAsync(byte[] bytes, CancellationToken ct)
    {
        using var request = new HttpRequestMessage(HttpMethod.Post, "/v1/infer");
        request.Headers.Add("X-Nephos-Inference-Key", configuration["Inference:Key"]);
        request.Content = new ByteArrayContent(bytes);
        request.Content.Headers.ContentType = new("application/octet-stream");
        using var response = await factory.CreateClient("inference").SendAsync(request, ct);
        if (response.StatusCode is HttpStatusCode.UnprocessableEntity or HttpStatusCode.RequestEntityTooLarge)
            throw new InvalidDataException("inference_rejected");
        response.EnsureSuccessStatusCode();
        return await response.Content.ReadFromJsonAsync<InferenceResult>(ct) ?? throw new InvalidDataException("empty_inference");
    }
}
