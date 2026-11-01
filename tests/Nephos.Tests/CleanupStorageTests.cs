extern alias storage;

using System.Security.Cryptography;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.TestHost;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging.Abstractions;
using Nephos.ServiceDefaults;
using Npgsql;
using BlobCleanupRepository = storage::Nephos.Storage.Api.Uploads.BlobCleanupRepository;
using BlobCleanupEndpoints = storage::Nephos.Storage.Api.Uploads.BlobCleanupEndpoints;
using PostgresUploadRepository = storage::Nephos.Storage.Api.Uploads.PostgresUploadRepository;
using UploadIntent = storage::Nephos.Storage.Api.Uploads.UploadIntent;
using UploadConflictException = storage::Nephos.Storage.Api.Uploads.UploadConflictException;
using VolumeStore = storage::Nephos.Storage.Api.Uploads.VolumeStore;

namespace Nephos.Tests;

public sealed class CleanupStorageFactAttribute : FactAttribute
{
    public CleanupStorageFactAttribute()
    {
        if (Environment.GetEnvironmentVariable("STORAGE_CLEANUP_TEST_CONNECTION") is null)
            Skip = "Set STORAGE_CLEANUP_TEST_CONNECTION to an isolated migrated storage database.";
    }
}

public sealed class CleanupStorageTests : IAsyncLifetime
{
    private readonly string root = Path.Combine(Directory.GetCurrentDirectory(), "artifacts", "cleanup-" + Guid.NewGuid().ToString("N"));
    private readonly string subject = "cleanup-" + Guid.NewGuid().ToString("N");
    private readonly string hash = Convert.ToHexStringLower(SHA256.HashData(RandomNumberGenerator.GetBytes(32)));
    private readonly NpgsqlDataSource? source = Environment.GetEnvironmentVariable("STORAGE_CLEANUP_TEST_CONNECTION") is { } connection
        ? NpgsqlDataSource.Create(connection) : null;
    private VolumeStore volume = null!;
    private BlobCleanupRepository cleanup = null!;
    private PostgresUploadRepository uploads = null!;

    public Task InitializeAsync()
    {
        Directory.CreateDirectory(root);
        volume = new(new ConfigurationBuilder().AddInMemoryCollection(new Dictionary<string, string?> { ["Storage:Root"] = root }).Build(),
            NullLogger<VolumeStore>.Instance, new Clients());
        if (source is not null)
        {
            cleanup = new(source, volume);
            uploads = new(source, volume);
        }
        return Task.CompletedTask;
    }

    private sealed class Clients : IHttpClientFactory
    {
        public HttpClient CreateClient(string name) => new();
    }

    private async Task<Guid> StoredAsync(bool sent = true, string? state = null)
    {
        var id = Guid.NewGuid();
        await SqlAsync("""
            INSERT INTO uploads(id,subject,library_id,file_name,media_type,size,expected_hash,state,sha256)
            VALUES($1,$2,$3,'photo.jpg','image/jpeg',4,$4,$5,$4)
            """, id, subject, Guid.NewGuid(), hash, state ?? "stored");
        await SqlAsync("INSERT INTO blobs(sha256,size) VALUES($1,4) ON CONFLICT DO NOTHING", hash);
        await SqlAsync("INSERT INTO blob_references(asset_id,sha256) VALUES($1,$2)", id, hash);
        await SqlAsync("INSERT INTO outbox(id,payload,sent_at) VALUES($1,'{}',CASE WHEN $2 THEN now() ELSE NULL END)", id, sent);
        var path = volume.OriginalPath(hash);
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        await File.WriteAllBytesAsync(path, [1, 2, 3, 4]);
        foreach (var size in PreviewSizes.All)
        {
            Directory.CreateDirectory(Path.GetDirectoryName(volume.PreviewPath(hash, size))!);
            await File.WriteAllBytesAsync(volume.PreviewPath(hash, size), [1]);
        }
        return id;
    }

    private async Task SqlAsync(string sql, params object[] parameters)
    {
        await using var command = source!.CreateCommand(sql);
        foreach (var parameter in parameters) command.Parameters.AddWithValue(parameter);
        await command.ExecuteNonQueryAsync();
    }

    [CleanupStorageFact]
    public async Task Cleanup_unknown_asset_release_binds_owner_and_prevents_late_upload_creation()
    {
        var id = Guid.NewGuid();
        await cleanup.ReleaseAsync(id, subject, default);
        await cleanup.ReleaseAsync(id, subject, default);
        await Assert.ThrowsAsync<UploadConflictException>(() => cleanup.ReleaseAsync(id, "other-owner", default));
        await Assert.ThrowsAsync<UploadConflictException>(() => uploads.CreateAsync(
            new(id, Guid.NewGuid(), "late.jpg", "image/jpeg", 4, hash), subject, default));
    }

    [CleanupStorageFact]
    public async Task Cleanup_dedup_creation_keeps_shared_bytes_until_each_actual_reference_is_released()
    {
        var first = await StoredAsync();
        var original = (await uploads.FindAsync(first, default))!;
        var second = await uploads.CreateAsync(new(Guid.NewGuid(), original.LibraryId, "second.jpg",
            "image/jpeg", 4, hash, ResourceSetId: Guid.NewGuid()), subject, default);
        Assert.NotEqual(first, second.Id);
        Assert.Equal("stored", second.State);
        await cleanup.ReleaseAsync(first, subject, default);
        Assert.False(await cleanup.CollectNextAsync(default));
        await Assert.ThrowsAsync<UploadConflictException>(() => uploads.RetainAsync(first, default));
        await SqlAsync("UPDATE outbox SET sent_at=now() WHERE id=$1", second.Id);
        await cleanup.ReleaseAsync(second.Id, subject, default);
        Assert.True(await cleanup.CollectNextAsync(default));
    }

    [CleanupStorageFact]
    public async Task Cleanup_shared_original_survives_until_last_reference_then_removes_all_previews()
    {
        var first = await StoredAsync();
        var second = await StoredAsync();
        await cleanup.ReleaseAsync(first, subject, default);
        await cleanup.ReleaseAsync(first, subject, default);
        Assert.Null(await uploads.FindAsync(first, default));
        Assert.NotNull(await uploads.FindAsync(second, default));
        Assert.False(await cleanup.CollectNextAsync(default));
        Assert.True(File.Exists(volume.OriginalPath(hash)));
        await cleanup.ReleaseAsync(second, subject, default);
        Assert.True(await cleanup.CollectNextAsync(default));
        Assert.False(await cleanup.CollectNextAsync(default));
        Assert.False(File.Exists(volume.OriginalPath(hash)));
        foreach (var size in PreviewSizes.All) Assert.False(File.Exists(volume.PreviewPath(hash, size)));
        await Assert.ThrowsAsync<UploadConflictException>(() => uploads.CreateAsync(
            new(first, Guid.NewGuid(), "photo.jpg", "image/jpeg", 4, hash), subject, default));
    }

    [CleanupStorageFact]
    public async Task Cleanup_holds_survive_release_and_deferred_GC_runs_after_expiration()
    {
        var id = await StoredAsync();
        await SqlAsync("INSERT INTO retention_holds(asset_id,hold_id,retained_until) VALUES($1,$2,now()+interval '1 day')",
            id, Guid.NewGuid());
        await cleanup.ReleaseAsync(id, subject, default);
        Assert.False(await cleanup.CollectNextAsync(default));
        Assert.True(File.Exists(volume.OriginalPath(hash)));
        await SqlAsync("UPDATE retention_holds SET retained_until=now()-interval '1 second' WHERE asset_id=$1", id);
        Assert.True(await cleanup.CollectNextAsync(default));
    }

    [CleanupStorageFact]
    public async Task Cleanup_rejects_wrong_owner_pending_publication_and_active_upload()
    {
        var id = await StoredAsync(sent: false);
        await Assert.ThrowsAsync<UploadConflictException>(() => cleanup.ReleaseAsync(id, "wrong-owner", default));
        await Assert.ThrowsAsync<UploadConflictException>(() => cleanup.ReleaseAsync(id, subject, default));
        await SqlAsync("UPDATE outbox SET sent_at=now() WHERE id=$1", id);
        await cleanup.ReleaseAsync(id, subject, default);
        var intent = new UploadIntent(Guid.NewGuid(), Guid.NewGuid(), "new.jpg", "image/jpeg", 4, hash);
        await uploads.CreateAsync(intent, subject, default);
        Assert.False(await cleanup.CollectNextAsync(default));
        await uploads.CancelAsync(intent.Id, default);
        Assert.True(await cleanup.CollectNextAsync(default));
    }

    [CleanupStorageFact]
    public async Task Cleanup_committed_deletion_fence_rejects_writers_and_recovers_partial_unlink()
    {
        var id = await StoredAsync();
        await cleanup.ReleaseAsync(id, subject, default);
        await SqlAsync("UPDATE blobs SET deleting=true WHERE sha256=$1", hash);
        File.Delete(volume.OriginalPath(hash)); // Simulate a crash after only the original unlink.
        var intent = new UploadIntent(Guid.NewGuid(), Guid.NewGuid(), "new.jpg", "image/jpeg", 4, hash);
        await Assert.ThrowsAsync<UploadConflictException>(() => uploads.CreateAsync(intent, subject, default));
        Assert.True(await cleanup.CollectNextAsync(default));
        Assert.Equal("uploading", (await uploads.CreateAsync(intent, subject, default)).State);
        foreach (var size in PreviewSizes.All) Assert.False(File.Exists(volume.PreviewPath(hash, size)));
    }

    [CleanupStorageFact]
    public async Task Cleanup_advisory_gate_serializes_reference_creation_before_unlink()
    {
        var id = await StoredAsync();
        await cleanup.ReleaseAsync(id, subject, default);
        await using var connection = await source!.OpenConnectionAsync();
        await using var transaction = await connection.BeginTransactionAsync();
        await using (var gate = new NpgsqlCommand($"SELECT pg_advisory_xact_lock({BlobCleanupRepository.Gate})", connection, transaction))
            await gate.ExecuteNonQueryAsync();
        var collection = cleanup.CollectNextAsync(default);
        await Task.Delay(100);
        Assert.False(collection.IsCompleted);
        var active = Guid.NewGuid();
        await using (var insert = new NpgsqlCommand("""
            INSERT INTO uploads(id,subject,library_id,file_name,media_type,size,expected_hash,state)
            VALUES($1,$2,$3,'new.jpg','image/jpeg',4,$4,'uploading')
            """, connection, transaction))
        {
            insert.Parameters.AddWithValue(active);
            insert.Parameters.AddWithValue(subject);
            insert.Parameters.AddWithValue(Guid.NewGuid());
            insert.Parameters.AddWithValue(hash);
            await insert.ExecuteNonQueryAsync();
        }
        await transaction.CommitAsync();
        Assert.False(await collection);
        Assert.True(File.Exists(volume.OriginalPath(hash)));
    }

    [Fact]
    public async Task Cleanup_routes_reject_missing_or_wrong_service_key_without_database_access()
    {
        var builder = WebApplication.CreateBuilder();
        builder.WebHost.UseTestServer();
        builder.Configuration.AddInMemoryCollection(new Dictionary<string, string?> { ["Services:Key"] = new string('k', 32) });
        using var data = NpgsqlDataSource.Create("Host=127.0.0.1;Port=1;Database=unused;Username=unused");
        builder.Services.AddSingleton(new BlobCleanupRepository(data, volume));
        await using var app = builder.Build();
        BlobCleanupEndpoints.MapBlobCleanup(app);
        await app.StartAsync();
        using var client = app.GetTestClient();
        foreach (var key in new[] { "", "wrong-key" })
        {
            using var request = new HttpRequestMessage(HttpMethod.Delete, $"/internal/v1/cleanup/{Guid.NewGuid()}")
            {
                Content = System.Net.Http.Json.JsonContent.Create(new { subject = "owner" })
            };
            if (key != "") request.Headers.Add("X-Nephos-Service-Key", key);
            using var response = await client.SendAsync(request);
            Assert.Equal(System.Net.HttpStatusCode.Unauthorized, response.StatusCode);
        }
        Assert.Equal(System.Net.HttpStatusCode.Unauthorized,
            (await client.PostAsync("/internal/v1/cleanup/gc", null)).StatusCode);
    }

    public async Task DisposeAsync()
    {
        if (source is not null)
        {
            await using var fixtureSource = NpgsqlDataSource.Create(
                Environment.GetEnvironmentVariable("STORAGE_CLEANUP_TEST_ADMIN_CONNECTION") ?? source.ConnectionString);
            foreach (var sql in new[]
            {
                "DELETE FROM retention_holds WHERE asset_id IN (SELECT id FROM uploads WHERE subject=$1)",
                "DELETE FROM blob_references WHERE asset_id IN (SELECT id FROM uploads WHERE subject=$1)",
                "DELETE FROM outbox WHERE id IN (SELECT id FROM uploads WHERE subject=$1)",
                "DELETE FROM upload_parts WHERE upload_id IN (SELECT id FROM uploads WHERE subject=$1)",
                "DELETE FROM uploads WHERE subject=$1"
            })
            {
                await using var command = fixtureSource.CreateCommand(sql);
                command.Parameters.AddWithValue(subject);
                await command.ExecuteNonQueryAsync();
            }
            await using (var command = fixtureSource.CreateCommand("DELETE FROM blobs WHERE sha256=$1"))
            {
                command.Parameters.AddWithValue(hash);
                await command.ExecuteNonQueryAsync();
            }
            await source.DisposeAsync();
        }
        Directory.Delete(root, true);
    }
}
