using System.Diagnostics;
using System.Security.Cryptography;
using System.Runtime.InteropServices;
using System.ComponentModel;
using System.Net;
using System.Text.Json;
using Nephos.ServiceDefaults;

namespace Nephos.Storage.Api.Uploads;

public interface IVolumeStore
{
    Task<string> SavePartAsync(Guid id, int part, Stream source, int size, CancellationToken token);
    Task<string> AssembleAsync(Upload upload, CancellationToken token);
    Task<bool> CreatePreviewAsync(string hash, string mediaType, CancellationToken token, int size = 512);
    string OriginalPath(string hash);
    string PreviewPath(string hash, int size = 512);
    void RemoveStaging(Guid id);
    void RemoveBlob(string hash);
    bool HasSpace(long bytes);
}

public sealed class VolumeStore(IConfiguration configuration, ILogger<VolumeStore> logger, IHttpClientFactory clients) : IVolumeStore
{
    private readonly string root = Path.GetFullPath(configuration["Storage:Root"]
        ?? throw new InvalidOperationException("Storage:Root is required."));

    public string OriginalPath(string hash) => Path.Combine(root, "blobs", hash[..2], hash);
    public string PreviewPath(string hash, int size = 512)
    {
        if (!PreviewSizes.Supports(size)) throw new ArgumentOutOfRangeException(nameof(size));
        return Path.Combine(root, "previews", hash + (size == 512 ? "" : "." + size) + ".jpg");
    }
    private string Staging(Guid id) => Path.Combine(root, "staging", id.ToString("N"));
    public bool HasSpace(long bytes) => new DriveInfo(root).AvailableFreeSpace > bytes + 1024L * 1024 * 1024;

    public async Task<string> SavePartAsync(Guid id, int part, Stream source, int size, CancellationToken token)
    {
        Directory.CreateDirectory(Staging(id));
        var path = Path.Combine(Staging(id), part.ToString(System.Globalization.CultureInfo.InvariantCulture));
        var temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try
        {
            using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
            await using (var output = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None, 65536, true))
            {
                var buffer = new byte[65536];
                var remaining = size;
                while (remaining > 0)
                {
                    var read = await source.ReadAsync(buffer.AsMemory(0, Math.Min(buffer.Length, remaining)), token);
                    if (read == 0) throw new UploadConflictException("Chunk body is shorter than declared.");
                    hash.AppendData(buffer, 0, read);
                    await output.WriteAsync(buffer.AsMemory(0, read), token);
                    remaining -= read;
                }
                await output.FlushAsync(token);
                output.Flush(true);
            }
            var digest = Convert.ToHexStringLower(hash.GetHashAndReset());
            if (File.Exists(path))
            {
                await using var existing = File.OpenRead(path);
                var existingHash = Convert.ToHexStringLower(await SHA256.HashDataAsync(existing, token));
                if (existingHash != digest) throw new UploadConflictException("An immutable chunk already contains different bytes.");
            }
            else
            {
                File.Move(temporary, path);
            }
            SyncDirectory(Staging(id));
            SyncDirectory(Path.Combine(root, "staging"));
            SyncDirectory(root);
            return digest;
        }
        finally
        {
            if (File.Exists(temporary)) File.Delete(temporary);
        }
    }

    public async Task<string> AssembleAsync(Upload upload, CancellationToken token)
    {
        var temporary = Path.Combine(Staging(upload.Id), "assembled");
        using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        await using (var output = new FileStream(temporary, FileMode.Create, FileAccess.Write, FileShare.None, 65536, true))
        {
            var buffer = new byte[65536];
            for (var part = 0; part < (upload.Size + MediaProtocol.ChunkSize - 1) / MediaProtocol.ChunkSize; part++)
            {
                await using var input = File.OpenRead(Path.Combine(Staging(upload.Id), part.ToString(System.Globalization.CultureInfo.InvariantCulture)));
                int read;
                while ((read = await input.ReadAsync(buffer, token)) > 0)
                {
                    hash.AppendData(buffer, 0, read);
                    await output.WriteAsync(buffer.AsMemory(0, read), token);
                }
            }
            if (output.Length != upload.Size) throw new UploadConflictException("Assembled size does not match the intent.");
            await output.FlushAsync(token);
            output.Flush(true);
        }
        var digest = Convert.ToHexStringLower(hash.GetHashAndReset());
        if (digest != upload.ExpectedHash) throw new UploadConflictException("SHA-256 verification failed. Create a new upload for corrected bytes.");
        var destination = OriginalPath(digest);
        Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
        if (File.Exists(destination))
        {
            await using var existing = File.OpenRead(destination);
            if (existing.Length != upload.Size || Convert.ToHexStringLower(await SHA256.HashDataAsync(existing, token)) != digest)
                throw new IOException("Existing content-addressed blob failed integrity verification.");
        }
        else
        {
            File.Move(temporary, destination);
        }
        SyncDirectory(Path.GetDirectoryName(destination)!);
        SyncDirectory(Path.Combine(root, "blobs"));
        SyncDirectory(root);
        return digest;
    }

    public async Task<bool> CreatePreviewAsync(string hash, string mediaType, CancellationToken token, int size = 512)
    {
        var destination = PreviewPath(hash, size);
        if (File.Exists(destination)) return true;
        Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
        if (mediaType is "image/jpeg" or "image/png" or "image/webp" or "image/heic" or "image/heif")
            return await RenderImagesAsync(hash, token);
        var temporary = destination + "." + Guid.NewGuid().ToString("N") + ".jpg";
        try
        {
            using var process = new Process
            {
                StartInfo = new ProcessStartInfo("ffmpeg")
                {
                    UseShellExecute = false,
                    RedirectStandardError = true,
                    RedirectStandardOutput = true
                }
            };
            foreach (var argument in new[] { "-nostdin", "-v", "error", "-protocol_whitelist", "file,pipe",
                "-format_whitelist", "mov,png_pipe,jpeg_pipe,webp_pipe,gif",
                "-threads", "1", "-i", OriginalPath(hash), "-frames:v", "1", "-vf", $"scale={size}:{size}:force_original_aspect_ratio=decrease",
                "-threads", "1", "-y", temporary })
                process.StartInfo.ArgumentList.Add(argument);
            process.Start();
            var errorDrain = process.StandardError.BaseStream.CopyToAsync(Stream.Null, token);
            var outputDrain = process.StandardOutput.BaseStream.CopyToAsync(Stream.Null, token);
            using var timeout = CancellationTokenSource.CreateLinkedTokenSource(token);
            timeout.CancelAfter(TimeSpan.FromSeconds(30));
            try { await process.WaitForExitAsync(timeout.Token); }
            catch (OperationCanceledException)
            {
                process.Kill(true);
                await process.WaitForExitAsync(CancellationToken.None);
                token.ThrowIfCancellationRequested();
                logger.LogWarning("Preview generation exceeded its time budget");
                return false;
            }
            await Task.WhenAll(errorDrain, outputDrain);
            if (process.ExitCode != 0 || !File.Exists(temporary))
            {
                logger.LogWarning("Preview unavailable for an unsupported or undecodable resource");
                return false;
            }
            File.Move(temporary, destination, true);
            return true;
        }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }

    private sealed record Derivatives(string SourceSha256, int Width, int Height, Dictionary<string, byte[]> Variants);

    private async Task<bool> RenderImagesAsync(string hash, CancellationToken token)
    {
        const int maximumResponse = 12 * 1024 * 1024;
        var endpoint = configuration["Services:Derivatives"];
        if (string.IsNullOrEmpty(endpoint))
        {
            logger.LogWarning("Image derivative service is not configured; original remains available");
            return false;
        }
        try
        {
            await using var original = File.OpenRead(OriginalPath(hash));
            if (original.Length > 20 * 1024 * 1024)
            {
                logger.LogWarning("Image exceeds the derivative input budget; original remains available");
                return false;
            }
            using var request = new HttpRequestMessage(HttpMethod.Post, endpoint + "/v1/render");
            request.Headers.Add("X-Nephos-Service-Key", configuration["Services:Key"]);
            request.Content = new StreamContent(original);
            request.Content.Headers.ContentLength = original.Length;
            request.Content.Headers.ContentType = new("application/octet-stream");
            using var response = await clients.CreateClient("derivatives").SendAsync(request, HttpCompletionOption.ResponseHeadersRead, token);
            if (response.StatusCode is HttpStatusCode.UnprocessableEntity or HttpStatusCode.RequestEntityTooLarge)
            {
                logger.LogWarning("Image derivative rejected an unsupported, corrupt or oversized image");
                return false;
            }
            response.EnsureSuccessStatusCode();
            if (response.Content.Headers.ContentLength > maximumResponse) throw new IOException("Derivative response exceeds budget.");
            await using var input = await response.Content.ReadAsStreamAsync(token);
            using var output = new MemoryStream();
            var buffer = new byte[65536];
            int read;
            while ((read = await input.ReadAsync(buffer, token)) > 0)
            {
                if (output.Length + read > maximumResponse) throw new IOException("Derivative response exceeds budget.");
                output.Write(buffer, 0, read);
            }
            var result = JsonSerializer.Deserialize<Derivatives>(output.ToArray(), new JsonSerializerOptions(JsonSerializerDefaults.Web));
            if (result is null || result.SourceSha256 != hash || result.Width <= 0 || result.Height <= 0 ||
                (long)result.Width * result.Height > 64_000_000 || result.Variants is null ||
                result.Variants.Count != PreviewSizes.All.Length ||
                PreviewSizes.All.Any(side => !result.Variants.TryGetValue(side.ToString(), out var bytes) ||
                    bytes is not { Length: >= 4 and <= 8 * 1024 * 1024 } || bytes[0] != 0xff || bytes[1] != 0xd8))
                throw new IOException("Invalid derivative provenance or variant response.");
            foreach (var side in PreviewSizes.All)
            {
                var path = PreviewPath(hash, side);
                if (File.Exists(path)) continue;
                var temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
                try
                {
                    await File.WriteAllBytesAsync(temporary, result.Variants[side.ToString()], token);
                    try { File.Move(temporary, path); }
                    catch (IOException) when (File.Exists(path))
                    {
                        logger.LogDebug("An immutable preview variant was already published concurrently");
                    }
                }
                finally { if (File.Exists(temporary)) File.Delete(temporary); }
            }
            return true;
        }
        catch (Exception error) when (error is HttpRequestException or IOException or JsonException ||
            error is OperationCanceledException && !token.IsCancellationRequested)
        {
            logger.LogWarning("Image derivatives unavailable ({ErrorType}); original is retained and preview requests may retry",
                error.GetType().Name);
            return false;
        }
    }

    public void RemoveStaging(Guid id)
    {
        var path = Staging(id);
        if (Directory.Exists(path)) Directory.Delete(path, true);
    }

    public void RemoveBlob(string hash)
    {
        if (hash.Length != 64 || hash.Any(c => c is not (>= '0' and <= '9' or >= 'a' and <= 'f')))
            throw new ArgumentException("Invalid blob hash.", nameof(hash));
        foreach (var size in PreviewSizes.All) File.Delete(PreviewPath(hash, size));
        File.Delete(OriginalPath(hash));
        var originalDirectory = Path.GetDirectoryName(OriginalPath(hash))!;
        if (Directory.Exists(originalDirectory)) SyncDirectory(originalDirectory);
        var previewDirectory = Path.GetDirectoryName(PreviewPath(hash))!;
        if (Directory.Exists(previewDirectory)) SyncDirectory(previewDirectory);
    }

    private static void SyncDirectory(string path)
    {
        if (!OperatingSystem.IsLinux() && !OperatingSystem.IsMacOS())
            throw new PlatformNotSupportedException("The volume durability adapter requires a Unix filesystem.");
        var descriptor = NativeOpen(path, 0);
        if (descriptor < 0) throw new IOException("Cannot open directory for durability flush.", new Win32Exception(Marshal.GetLastPInvokeError()));
        try
        {
            if (NativeFsync(descriptor) != 0)
                throw new IOException("Directory durability flush failed.", new Win32Exception(Marshal.GetLastPInvokeError()));
        }
        finally { NativeClose(descriptor); }
    }

    [DllImport("libc", EntryPoint = "open", SetLastError = true)]
    private static extern int NativeOpen(string path, int flags);
    [DllImport("libc", EntryPoint = "fsync", SetLastError = true)]
    private static extern int NativeFsync(int descriptor);
    [DllImport("libc", EntryPoint = "close")]
    private static extern int NativeClose(int descriptor);
}
