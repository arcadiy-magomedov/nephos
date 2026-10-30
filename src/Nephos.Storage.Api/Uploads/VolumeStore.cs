using System.Diagnostics;
using System.Security.Cryptography;
using System.Runtime.InteropServices;
using System.ComponentModel;
using Nephos.ServiceDefaults;

namespace Nephos.Storage.Api.Uploads;

public interface IVolumeStore
{
    Task<string> SavePartAsync(Guid id, int part, Stream source, int size, CancellationToken token);
    Task<string> AssembleAsync(Upload upload, CancellationToken token);
    Task<bool> CreatePreviewAsync(string hash, CancellationToken token);
    string OriginalPath(string hash);
    string PreviewPath(string hash);
    void RemoveStaging(Guid id);
    bool HasSpace(long bytes);
}

public sealed class VolumeStore(IConfiguration configuration, ILogger<VolumeStore> logger) : IVolumeStore
{
    private readonly string root = Path.GetFullPath(configuration["Storage:Root"]
        ?? throw new InvalidOperationException("Storage:Root is required."));

    public string OriginalPath(string hash) => Path.Combine(root, "blobs", hash[..2], hash);
    public string PreviewPath(string hash) => Path.Combine(root, "previews", hash + ".jpg");
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

    public async Task<bool> CreatePreviewAsync(string hash, CancellationToken token)
    {
        var destination = PreviewPath(hash);
        if (File.Exists(destination)) return true;
        Directory.CreateDirectory(Path.GetDirectoryName(destination)!);
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
                "-threads", "1", "-i", OriginalPath(hash), "-frames:v", "1", "-vf", "scale=512:512:force_original_aspect_ratio=decrease",
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

    public void RemoveStaging(Guid id)
    {
        var path = Staging(id);
        if (Directory.Exists(path)) Directory.Delete(path, true);
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
