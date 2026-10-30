using System.Net;
using System.Security.Cryptography;
using System.Text;

namespace Nephos.Faces.Api;

public interface IAnalysisSourceClient
{
    Task<bool> IsEnabledAsync(HttpContext context, CancellationToken ct);
    Task<AnalysisSource?> SourceAsync(string owner, Guid assetId, CancellationToken ct);
    Task<byte[]> OriginalAsync(AnalysisSource source, CancellationToken ct);
}

public sealed class AnalysisSourceClient(IHttpClientFactory factory, IConfiguration configuration) : IAnalysisSourceClient
{
    private HttpRequestMessage Internal(HttpMethod method, string path)
    {
        var request = new HttpRequestMessage(method, path);
        request.Headers.Add("X-Nephos-Service-Key", configuration["Services:Key"]);
        return request;
    }

    public async Task<bool> IsEnabledAsync(HttpContext context, CancellationToken ct)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, "/v1/analysis/access");
        request.Headers.TryAddWithoutValidation("Authorization", context.Request.Headers.Authorization.ToString());
        using var response = await factory.CreateClient("library").SendAsync(request, ct);
        if (response.StatusCode is HttpStatusCode.Forbidden or HttpStatusCode.Unauthorized or HttpStatusCode.NotFound) return false;
        response.EnsureSuccessStatusCode();
        return response.StatusCode == HttpStatusCode.NoContent;
    }

    public async Task<AnalysisSource?> SourceAsync(string owner, Guid assetId, CancellationToken ct)
    {
        using var request = Internal(HttpMethod.Get, $"/internal/analysis/owners/{Uri.EscapeDataString(owner)}/assets/{assetId}");
        using var response = await factory.CreateClient("library").SendAsync(request, ct);
        if (response.StatusCode is HttpStatusCode.NotFound or HttpStatusCode.Forbidden or HttpStatusCode.Unauthorized) return null;
        response.EnsureSuccessStatusCode();
        var source = await response.Content.ReadFromJsonAsync<AnalysisSource>(ct);
        if (source is null || source.Id != assetId || source.Subject != owner || source.Size is <= 0 or > Pipeline.MaxBytes ||
            source.MediaType is not ("image/jpeg" or "image/png" or "image/webp") ||
            source.Sha256.Length != 64 || !source.Sha256.All(char.IsAsciiHexDigit))
            return null;
        return source with { Sha256 = source.Sha256.ToLowerInvariant() };
    }

    public async Task<byte[]> OriginalAsync(AnalysisSource source, CancellationToken ct)
    {
        using var request = Internal(HttpMethod.Get, $"/internal/assets/{source.Id}/original");
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
        using var request = new HttpRequestMessage(HttpMethod.Post, "/infer");
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

public static class ServiceAuthentication
{
    public static bool Valid(HttpContext context, IConfiguration configuration)
    {
        var expected = configuration["Services:Key"] ?? "";
        var supplied = context.Request.Headers["X-Nephos-Service-Key"].ToString();
        return expected.Length >= 32 && supplied.Length <= 512 &&
            CryptographicOperations.FixedTimeEquals(SHA256.HashData(Encoding.UTF8.GetBytes(expected)),
                SHA256.HashData(Encoding.UTF8.GetBytes(supplied)));
    }
}
