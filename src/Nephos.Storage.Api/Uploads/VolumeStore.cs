using System.Diagnostics;
using System.Security.Cryptography;
using System.Runtime.InteropServices;
using System.ComponentModel;
using System.Net;
using System.Text.Json;
using Nephos.ServiceDefaults;

namespace Nephos.Storage.Api.Uploads;

public sealed record StagedOriginal(string Path, string Hash, long Size, bool IsSinglePart);

public interface IVolumeStore
{
    Task<string> SavePartAsync(Guid id, int part, Stream source, int size, CancellationToken token);
    Task<string> AssembleAsync(Upload upload, CancellationToken token);
    Task<StagedOriginal> StageVerifiedAsync(Upload upload, Guid leaseId, CancellationToken token);
    Task<Dictionary<int, string>?> PreparePreviewsAsync(string sourcePath, string hash, string mediaType, Guid leaseId, CancellationToken token, int? singleSize = null);
    void PublishStaged(StagedOriginal staged, Dictionary<int, string>? preparedPreviews);
    void PublishPreparedPreviews(string hash, Dictionary<int, string> preparedPreviews);
    void CleanupPreparedPreviews(Dictionary<int, string>? preparedPreviews);
    Task<bool> CreatePreviewAsync(string hash, string mediaType, CancellationToken token, int size = 512);
    string OriginalPath(string hash);
    string PreviewPath(string hash, int size = 512);
    string ResolvePreviewPath(string hash, int size = 512);
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
        return Path.Combine(root, "previews", hash[..2], hash + (size == 512 ? "" : "." + size) + ".jpg");
    }
    private string LegacyPreviewPath(string hash, int size = 512)
    {
        if (!PreviewSizes.Supports(size)) throw new ArgumentOutOfRangeException(nameof(size));
        return Path.Combine(root, "previews", hash + (size == 512 ? "" : "." + size) + ".jpg");
    }
    public string ResolvePreviewPath(string hash, int size = 512)
    {
        var sharded = PreviewPath(hash, size);
        if (File.Exists(sharded)) return sharded;
        var legacy = LegacyPreviewPath(hash, size);
        return File.Exists(legacy) ? legacy : sharded;
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

    public async Task<StagedOriginal> StageVerifiedAsync(Upload upload, Guid leaseId, CancellationToken token)
    {
        var partCount = (upload.Size + MediaProtocol.ChunkSize - 1) / MediaProtocol.ChunkSize;
        if (partCount == 1)
        {
            var singlePart = Path.Combine(Staging(upload.Id), "0");
            using var singleHash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
            long length;
            await using (var input = File.OpenRead(singlePart))
            {
                var buffer = new byte[65536];
                int read;
                while ((read = await input.ReadAsync(buffer, token)) > 0)
                    singleHash.AppendData(buffer, 0, read);
                length = input.Length;
            }
            if (length != upload.Size) throw new UploadConflictException("Assembled size does not match the intent.");
            var singleDigest = Convert.ToHexStringLower(singleHash.GetHashAndReset());
            if (singleDigest != upload.ExpectedHash)
                throw new UploadConflictException("SHA-256 verification failed. Create a new upload for corrected bytes.");
            return new(singlePart, singleDigest, upload.Size, true);
        }

        var temporary = Path.Combine(Staging(upload.Id), $"assembled.{leaseId:N}");
        using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        try
        {
            await using (var output = new FileStream(temporary, FileMode.Create, FileAccess.Write, FileShare.None, 65536, true))
            {
                var buffer = new byte[65536];
                for (var part = 0; part < partCount; part++)
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
            return new(temporary, digest, upload.Size, false);
        }
        catch
        {
            if (File.Exists(temporary)) File.Delete(temporary);
            throw;
        }
    }

    public void PublishStaged(StagedOriginal staged, Dictionary<int, string>? preparedPreviews)
    {
        var destination = OriginalPath(staged.Hash);
        Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
        if (File.Exists(destination))
        {
            using var existing = File.OpenRead(destination);
            if (existing.Length != staged.Size || Convert.ToHexStringLower(SHA256.HashData(existing)) != staged.Hash)
                throw new IOException("Existing content-addressed blob failed integrity verification.");
            if (!staged.IsSinglePart && File.Exists(staged.Path)) File.Delete(staged.Path);
        }
        else if (staged.IsSinglePart)
        {
            // Hard link preserves part 0 for crash retry without copying bytes; falls back to atomic copy if cross-device.
            if (NativeLink(staged.Path, destination) != 0)
            {
                var copyTemp = destination + "." + Guid.NewGuid().ToString("N") + ".tmp";
                try
                {
                    File.Copy(staged.Path, copyTemp);
                    File.Move(copyTemp, destination);
                }
                finally { if (File.Exists(copyTemp)) File.Delete(copyTemp); }
            }
        }
        else
        {
            File.Move(staged.Path, destination);
        }
        SyncDirectory(Path.GetDirectoryName(destination)!);
        SyncDirectory(Path.Combine(root, "blobs"));
        SyncDirectory(root);
        if (preparedPreviews is { Count: > 0 }) PublishPreparedPreviews(staged.Hash, preparedPreviews);
    }

    public void PublishPreparedPreviews(string hash, Dictionary<int, string> preparedPreviews)
    {
        string? syncedShard = null;
        foreach (var (side, temporary) in preparedPreviews)
        {
            if (!File.Exists(temporary)) continue;
            var destination = PreviewPath(hash, side);
            var shard = Path.GetDirectoryName(destination)!;
            Directory.CreateDirectory(shard);
            syncedShard = shard;
            if (File.Exists(destination))
            {
                File.Delete(temporary);
                continue;
            }
            try { File.Move(temporary, destination); }
            catch (IOException) when (File.Exists(destination))
            {
                if (File.Exists(temporary)) File.Delete(temporary);
                logger.LogDebug("An immutable preview variant was already published concurrently");
            }
        }
        if (syncedShard is not null)
        {
            SyncDirectory(syncedShard);
            SyncDirectory(Path.Combine(root, "previews"));
        }
    }

    public void CleanupPreparedPreviews(Dictionary<int, string>? preparedPreviews)
    {
        if (preparedPreviews is null) return;
        foreach (var path in preparedPreviews.Values)
            if (File.Exists(path)) File.Delete(path);
    }

    public async Task<string> AssembleAsync(Upload upload, CancellationToken token)
    {
        var staged = await StageVerifiedAsync(upload, Guid.NewGuid(), token);
        PublishStaged(staged, null);
        return staged.Hash;
    }

    public async Task<Dictionary<int, string>?> PreparePreviewsAsync(
        string sourcePath, string hash, string mediaType, Guid leaseId, CancellationToken token, int? singleSize = null)
    {
        var targetSize = singleSize ?? 512;
        if (File.Exists(ResolvePreviewPath(hash, targetSize))) return new();
        var workDirectory = Path.Combine(root, "previews", ".work");
        Directory.CreateDirectory(workDirectory);
        if (mediaType is "image/jpeg" or "image/png" or "image/webp" or "image/heic" or "image/heif")
            return await RenderImagesToTempAsync(sourcePath, hash, leaseId, workDirectory, token);
        var temporary = Path.Combine(workDirectory, $"{hash}.{leaseId:N}.{targetSize}.jpg");
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
                "-threads", "1", "-i", sourcePath, "-frames:v", "1", "-vf", $"scale={targetSize}:{targetSize}:force_original_aspect_ratio=decrease",
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
                if (File.Exists(temporary)) File.Delete(temporary);
                token.ThrowIfCancellationRequested();
                logger.LogWarning("Preview generation exceeded its time budget");
                return null;
            }
            await Task.WhenAll(errorDrain, outputDrain);
            if (process.ExitCode != 0 || !File.Exists(temporary))
            {
                if (File.Exists(temporary)) File.Delete(temporary);
                logger.LogWarning("Preview unavailable for an unsupported or undecodable resource");
                return null;
            }
            return new Dictionary<int, string> { [targetSize] = temporary };
        }
        catch
        {
            if (File.Exists(temporary)) File.Delete(temporary);
            throw;
        }
    }

    public async Task<bool> CreatePreviewAsync(string hash, string mediaType, CancellationToken token, int size = 512)
    {
        if (File.Exists(ResolvePreviewPath(hash, size))) return true;
        var prepared = await PreparePreviewsAsync(OriginalPath(hash), hash, mediaType, Guid.NewGuid(), token, size);
        if (prepared is null) return false;
        PublishPreparedPreviews(hash, prepared);
        return true;
    }

    private sealed record Derivatives(string SourceSha256, int Width, int Height, Dictionary<string, byte[]> Variants);

    private async Task<Dictionary<int, string>?> RenderImagesToTempAsync(
        string sourcePath, string hash, Guid leaseId, string workDirectory, CancellationToken token)
    {
        const int maximumResponse = 12 * 1024 * 1024;
        var endpoint = configuration["Services:Derivatives"];
        if (string.IsNullOrEmpty(endpoint))
        {
            logger.LogWarning("Image derivative service is not configured; original remains available");
            return null;
        }
        var written = new Dictionary<int, string>();
        try
        {
            await using var original = File.OpenRead(sourcePath);
            if (original.Length > 20 * 1024 * 1024)
            {
                logger.LogWarning("Image exceeds the derivative input budget; original remains available");
                return null;
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
                return null;
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
                if (File.Exists(PreviewPath(hash, side))) continue;
                var temporary = Path.Combine(workDirectory, $"{hash}.{leaseId:N}.{side}.tmp");
                await File.WriteAllBytesAsync(temporary, result.Variants[side.ToString()], token);
                written[side] = temporary;
            }
            return written;
        }
        catch (Exception error) when (error is HttpRequestException or IOException or JsonException ||
            error is OperationCanceledException && !token.IsCancellationRequested)
        {
            CleanupPreparedPreviews(written);
            logger.LogWarning("Image derivatives unavailable ({ErrorType}); original is retained and preview requests may retry",
                error.GetType().Name);
            return null;
        }
        catch
        {
            CleanupPreparedPreviews(written);
            throw;
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
        foreach (var size in PreviewSizes.All)
        {
            var sharded = PreviewPath(hash, size);
            if (File.Exists(sharded)) File.Delete(sharded);
            var legacy = LegacyPreviewPath(hash, size);
            if (File.Exists(legacy)) File.Delete(legacy);
        }
        var original = OriginalPath(hash);
        if (File.Exists(original)) File.Delete(original);
        var originalDirectory = Path.GetDirectoryName(original)!;
        if (Directory.Exists(originalDirectory)) SyncDirectory(originalDirectory);
        var previewShard = Path.GetDirectoryName(PreviewPath(hash, 512))!;
        if (Directory.Exists(previewShard)) SyncDirectory(previewShard);
        var legacyPreviewDir = Path.GetDirectoryName(LegacyPreviewPath(hash, 512))!;
        if (Directory.Exists(legacyPreviewDir)) SyncDirectory(legacyPreviewDir);
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
    [DllImport("libc", EntryPoint = "link", SetLastError = true)]
    private static extern int NativeLink(string existingPath, string newPath);
}
