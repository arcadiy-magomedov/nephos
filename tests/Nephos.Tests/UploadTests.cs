extern alias storage;

using System.Security.Cryptography;
using System.Net;
using System.Net.Http.Json;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging.Abstractions;
using Nephos.ServiceDefaults;
using Upload = storage::Nephos.Storage.Api.Uploads.Upload;
using UploadIntent = storage::Nephos.Storage.Api.Uploads.UploadIntent;
using UploadConflictException = storage::Nephos.Storage.Api.Uploads.UploadConflictException;
using VolumeStore = storage::Nephos.Storage.Api.Uploads.VolumeStore;
using UploadWorker = storage::Nephos.Storage.Api.Uploads.UploadWorker;
using PostgresUploadRepository = storage::Nephos.Storage.Api.Uploads.PostgresUploadRepository;

namespace Nephos.Tests;

public sealed class UploadTests : IDisposable
{
    private readonly string root = Path.Combine(Path.GetTempPath(), "nephos-volume-test-" + Guid.NewGuid().ToString("N"));
    private readonly VolumeStore volume;

    public UploadTests()
    {
        Directory.CreateDirectory(root);
        volume = new VolumeStore(new ConfigurationBuilder().AddInMemoryCollection(
            new Dictionary<string, string?> { ["Storage:Root"] = root }).Build(), NullLogger<VolumeStore>.Instance, new Clients());
    }
    private sealed class Clients(HttpClient? client = null) : IHttpClientFactory
    {
        public HttpClient CreateClient(string name) => client ?? new();
    }

    private static async Task<bool> RenderPreviewAsync(VolumeStore store, string hash, string mediaType, int size)
    {
        var prepared = await store.PreparePreviewsAsync(store.OriginalPath(hash), hash, mediaType, Guid.NewGuid(), default, size);
        if (prepared is null) return false;
        store.PublishPreparedPreviews(hash, prepared);
        return File.Exists(store.ResolvePreviewPath(hash, size));
    }

    [Theory]
    [InlineData(true)]
    [InlineData(false)]
    public async Task Derivatives_are_hash_bound_and_cache_each_fixed_size_without_modifying_original(bool matchingHash)
    {
        byte[] original = [1, 2, 3, 4];
        var hash = Convert.ToHexStringLower(SHA256.HashData(original));
        var path = volume.OriginalPath(hash);
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        await File.WriteAllBytesAsync(path, original);
        using var handler = new Renderer(matchingHash ? hash : new string('0', 64));
        using var http = new HttpClient(handler);
        var renderer = new VolumeStore(new ConfigurationBuilder().AddInMemoryCollection(new Dictionary<string, string?>
        {
            ["Storage:Root"] = root,
            ["Services:Derivatives"] = "http://renderer",
            ["Services:Key"] = "test-only-derivative-key"
        }).Build(), NullLogger<VolumeStore>.Instance, new Clients(http));
        Assert.Equal(matchingHash, await RenderPreviewAsync(renderer, hash, "image/heic", 2560));
        Assert.Equal(original, await File.ReadAllBytesAsync(path));
        foreach (var size in PreviewSizes.All)
            Assert.Equal(matchingHash, File.Exists(renderer.PreviewPath(hash, size)));
        if (matchingHash)
        {
            Assert.True(await RenderPreviewAsync(renderer, hash, "image/heic", 1280));
            Assert.Equal(1, handler.Calls);
        }
        Assert.Throws<ArgumentOutOfRangeException>(() => renderer.PreviewPath(hash, 9999));
    }

    private sealed class Renderer(string hash) : HttpMessageHandler
    {
        public int Calls { get; private set; }
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken token)
        {
            Calls++;
            Assert.Equal("http://renderer/v1/render", request.RequestUri!.AbsoluteUri);
            Assert.Equal(new byte[] { 1, 2, 3, 4 }, await request.Content!.ReadAsByteArrayAsync(token));
            return new(HttpStatusCode.OK)
            {
                Content = JsonContent.Create(new
                {
                    sourceSha256 = hash,
                    width = 6048,
                    height = 8064,
                    variants = PreviewSizes.All.ToDictionary(size => size.ToString(System.Globalization.CultureInfo.InvariantCulture), _ => new byte[] { 0xff, 0xd8, 0xff, 0xd9 })
                })
            };
        }
    }

    [Theory]
    [InlineData("../escape.jpg", 4, "image/jpeg", true)]
    [InlineData("valid.jpg", 0, "image/jpeg", true)]
    [InlineData("valid.jpg", 8589934593, "image/jpeg", true)]
    [InlineData("valid.html", 4, "text/html", true)]
    [InlineData("valid.jpg", 4, "image/jpeg", false)]
    public void Unsafe_or_invalid_intents_are_rejected(string fileName, long size, string mediaType, bool validHash)
    {
        var intent = new UploadIntent(Guid.NewGuid(), Guid.NewGuid(), fileName, mediaType, size,
            validHash ? new string('a', 64) : "invalid");
        Assert.False(intent.IsValid());
    }

    [Theory]
    [InlineData("photo.jpg", "image/jpeg")]
    [InlineData("book.pdf", "application/pdf")]
    [InlineData("book.epub", "application/epub+zip")]
    [InlineData("movie.mkv", "video/x-matroska")]
    [InlineData("album.flac", "audio/flac")]
    public void Valid_intent_is_accepted(string fileName, string mediaType)
    {
        Assert.True(new UploadIntent(Guid.NewGuid(), Guid.NewGuid(), fileName, mediaType, 4, new string('a', 64)).IsValid());
    }

    [Theory]
    [InlineData("vector.svg", "image/svg+xml")]
    [InlineData("script.js", "application/javascript")]
    public void Active_web_script_media_types_remain_rejected(string fileName, string mediaType)
    {
        Assert.False(new UploadIntent(Guid.NewGuid(), Guid.NewGuid(), fileName, mediaType, 4, new string('a', 64)).IsValid());
    }

    [Fact]
    public async Task Repeated_chunk_is_immutable_and_short_bodies_leave_no_acknowledgeable_part()
    {
        var id = Guid.NewGuid();
        var digest = await volume.SavePartAsync(id, 0, new MemoryStream([1, 2, 3]), 3, default);
        Assert.Equal(digest, await volume.SavePartAsync(id, 0, new MemoryStream([1, 2, 3]), 3, default));
        await Assert.ThrowsAsync<UploadConflictException>(() => volume.SavePartAsync(id, 0, new MemoryStream([1, 2, 4]), 3, default));
        await Assert.ThrowsAsync<UploadConflictException>(() => volume.SavePartAsync(id, 1, new MemoryStream([1]), 3, default));
        Assert.False(File.Exists(Path.Combine(root, "staging", id.ToString("N"), "1")));
        Assert.Empty(Directory.GetFiles(root, "*.tmp", SearchOption.AllDirectories));
    }

    [Fact]
    public async Task Out_of_order_parts_assemble_exactly_and_retries_share_one_blob()
    {
        var data = RandomNumberGenerator.GetBytes(MediaProtocol.ChunkSize + 3);
        var expected = Convert.ToHexStringLower(SHA256.HashData(data));
        var id = Guid.NewGuid();
        await volume.SavePartAsync(id, 1, new MemoryStream(data[MediaProtocol.ChunkSize..]), 3, default);
        await volume.SavePartAsync(id, 0, new MemoryStream(data[..MediaProtocol.ChunkSize]), MediaProtocol.ChunkSize, default);
        var upload = new Upload(id, "owner", Guid.NewGuid(), "original.bin", "application/octet-stream",
            data.Length, expected, "verifying", null, false, null, DateTimeOffset.UtcNow);
        for (var attempt = 0; attempt < 2; attempt++)
        {
            var staged = await volume.StageVerifiedAsync(upload, Guid.NewGuid(), default);
            Assert.Equal(expected, staged.Hash);
            volume.PublishStaged(staged, null);
        }
        Assert.Equal(data, await File.ReadAllBytesAsync(volume.OriginalPath(expected)));
        Assert.Single(Directory.GetFiles(Path.Combine(root, "blobs"), "*", SearchOption.AllDirectories));
    }

    [Fact]
    public async Task Wrong_hash_never_publishes_a_blob()
    {
        var id = Guid.NewGuid();
        await volume.SavePartAsync(id, 0, new MemoryStream([1, 2, 3]), 3, default);
        var upload = new Upload(id, "owner", Guid.NewGuid(), "original.bin", "application/octet-stream",
            3, new string('0', 64), "verifying", null, false, null, DateTimeOffset.UtcNow);
        await Assert.ThrowsAsync<UploadConflictException>(() => volume.StageVerifiedAsync(upload, Guid.NewGuid(), default));
        Assert.False(File.Exists(volume.OriginalPath(upload.ExpectedHash)));
    }

    [Fact]
    public void Missing_prepared_preview_is_not_silently_published()
    {
        var hash = new string('a', 64);
        Assert.Throws<FileNotFoundException>(() => volume.PublishPreparedPreviews(hash,
            new Dictionary<int, string> { [512] = Path.Combine(root, "missing.jpg") }));
        Assert.False(File.Exists(volume.PreviewPath(hash)));
    }

    [Fact]
    public async Task Non_ascii_volume_paths_preserve_durable_single_part_publication()
    {
        var unicodeRoot = Path.Combine(root, "photos-é-画像");
        Directory.CreateDirectory(unicodeRoot);
        var unicodeVolume = new VolumeStore(new ConfigurationBuilder().AddInMemoryCollection(
            new Dictionary<string, string?> { ["Storage:Root"] = unicodeRoot }).Build(),
            NullLogger<VolumeStore>.Instance, new Clients());
        byte[] bytes = [1, 2, 3];
        var hash = Convert.ToHexStringLower(SHA256.HashData(bytes));
        var id = Guid.NewGuid();
        await unicodeVolume.SavePartAsync(id, 0, new MemoryStream(bytes), bytes.Length, default);
        var upload = new Upload(id, "owner", Guid.NewGuid(), "original.bin", "application/octet-stream",
            bytes.Length, hash, "verifying", null, false, null, DateTimeOffset.UtcNow);
        var staged = await unicodeVolume.StageVerifiedAsync(upload, Guid.NewGuid(), default);
        unicodeVolume.PublishStaged(staged, null);
        Assert.Equal(bytes, await File.ReadAllBytesAsync(unicodeVolume.OriginalPath(hash)));
    }

    [Theory]
    [InlineData(0)]
    [InlineData(9)]
    public async Task Invalid_worker_concurrency_fails_instead_of_silently_clamping(int concurrency)
    {
        var configuration = new ConfigurationBuilder().AddInMemoryCollection(new Dictionary<string, string?>
        {
            ["Upload:VerifyConcurrency"] = concurrency.ToString(System.Globalization.CultureInfo.InvariantCulture)
        }).Build();
        await using var database = Npgsql.NpgsqlDataSource.Create("Host=localhost;Database=unused;Username=unused");
        var repository = new PostgresUploadRepository(database, volume, NullLogger<PostgresUploadRepository>.Instance);
        using var worker = new UploadWorker(repository, configuration, NullLogger<UploadWorker>.Instance);
        await worker.StartAsync(default);
        await Assert.ThrowsAsync<InvalidOperationException>(() => worker.ExecuteTask!);
    }

    [Fact]
    public async Task Sharded_previews_fallback_to_legacy_flat_paths_and_remove_both_safely()
    {
        byte[] original = [5, 6, 7, 8];
        var hash = Convert.ToHexStringLower(SHA256.HashData(original));
        var originalPath = volume.OriginalPath(hash);
        Directory.CreateDirectory(Path.GetDirectoryName(originalPath)!);
        await File.WriteAllBytesAsync(originalPath, original);
        var legacy = Path.Combine(root, "previews", hash + ".jpg");
        Directory.CreateDirectory(Path.GetDirectoryName(legacy)!);
        await File.WriteAllBytesAsync(legacy, [0xff, 0xd8, 0xff, 0xd9]);

        Assert.Equal(legacy, volume.ResolvePreviewPath(hash, 512));
        Assert.Contains(Path.Combine("previews", hash[..2], hash + ".jpg"), volume.PreviewPath(hash, 512));

        volume.RemoveBlob(hash);
        Assert.False(File.Exists(legacy));
        Assert.False(File.Exists(originalPath));
    }

    public void Dispose() => Directory.Delete(root, true);
}
