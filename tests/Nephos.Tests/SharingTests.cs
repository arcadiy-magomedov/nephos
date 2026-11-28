using Nephos.Library.Api.Sharing;
using Nephos.Library.Api.Assets;
using Npgsql;

namespace Nephos.Tests;

[Collection("trash-database")]
public sealed class SharingTests
{
    [Fact]
    public void Sharing_requires_an_explicit_bounded_scope()
    {
        var input = new ShareInput(Guid.NewGuid(), Guid.NewGuid().ToString(), false, [Guid.NewGuid()]);
        Assert.True(input.IsValid());
        Assert.False((input with { AssetIds = [] }).IsValid());
        Assert.False((input with { AllAssets = true }).IsValid());
        Assert.True((input with { AllAssets = true, AssetIds = [] }).IsValid());
        Assert.False((input with { AssetIds = [input.AssetIds[0], input.AssetIds[0]] }).IsValid());
        Assert.False((input with { RecipientId = "unknown" }).IsValid());
    }

    [LibraryDatabaseFact]
    public async Task Concurrent_share_creation_cannot_rebind_another_owners_share_identity()
    {
        await using var database = NpgsqlDataSource.Create(Environment.GetEnvironmentVariable("LIBRARY_TEST_CONNECTION")!);
        var first = Guid.NewGuid().ToString();
        var second = Guid.NewGuid().ToString();
        var recipient = Guid.NewGuid().ToString();
        var firstLibrary = Guid.NewGuid();
        var secondLibrary = Guid.NewGuid();
        await using (var setup = database.CreateCommand("""
            INSERT INTO principals(subject,enabled,discoverable,display_name)
              VALUES(@first,true,true,'First'),(@second,true,true,'Second'),(@recipient,true,true,'Recipient');
            INSERT INTO libraries(id,name) VALUES(@firstLibrary,'First'),(@secondLibrary,'Second');
            INSERT INTO library_members(subject,library_id) VALUES(@first,@firstLibrary),(@second,@secondLibrary);
            """))
        {
            setup.Parameters.AddWithValue("first", first);
            setup.Parameters.AddWithValue("second", second);
            setup.Parameters.AddWithValue("recipient", recipient);
            setup.Parameters.AddWithValue("firstLibrary", firstLibrary);
            setup.Parameters.AddWithValue("secondLibrary", secondLibrary);
            await setup.ExecuteNonQueryAsync();
        }
        var repository = new PostgresSharingRepository(database);
        var id = Guid.NewGuid();
        using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(10));
        await using var blocker = await database.OpenConnectionAsync(timeout.Token);
        await using var transaction = await blocker.BeginTransactionAsync(timeout.Token);
        await using (var gate = new NpgsqlCommand("LOCK TABLE shares IN SHARE MODE", blocker, transaction))
            await gate.ExecuteNonQueryAsync(timeout.Token);

        async Task<bool> CreateAsync(string owner, Guid library)
        {
            try
            {
                await repository.PutAsync(owner, id, new(library, recipient, true, []), timeout.Token);
                return true;
            }
            catch (ResourceConflictException) { return false; }
        }
        var attempts = new[] { CreateAsync(first, firstLibrary), CreateAsync(second, secondLibrary) };
        try
        {
            // Both requests must pass the precheck before either INSERT is allowed to proceed.
            await using var waiting = database.CreateCommand("""
                SELECT count(*) FROM pg_stat_activity
                WHERE datname=current_database() AND wait_event_type='Lock' AND query LIKE '%INSERT INTO shares%'
                """);
            while ((long)(await waiting.ExecuteScalarAsync(timeout.Token))! < 2)
                await Task.Delay(10, timeout.Token);
        }
        finally
        {
            await transaction.CommitAsync(CancellationToken.None);
        }
        var results = await Task.WhenAll(attempts);
        Assert.Single(results, success => success);
        Assert.Single(results, success => !success);
        var share = Assert.Single(await repository.ListAsync(recipient, null, 10, default));
        Assert.Equal(results[0] ? first : second, share.OwnerId);
        Assert.Equal(results[0] ? firstLibrary : secondLibrary, share.LibraryId);
    }

    [LibraryDatabaseFact]
    public async Task Existing_share_can_be_updated_after_recipient_disables_discoverability()
    {
        await using var database = NpgsqlDataSource.Create(Environment.GetEnvironmentVariable("LIBRARY_TEST_CONNECTION")!);
        var owner = Guid.NewGuid().ToString();
        var recipient = Guid.NewGuid().ToString();
        var library = Guid.NewGuid();
        var asset = Guid.NewGuid();
        await using (var setup = database.CreateCommand("""
            INSERT INTO principals(subject,enabled,discoverable,display_name)
              VALUES(@owner,true,true,'Owner'),(@recipient,true,true,'Recipient');
            INSERT INTO libraries(id,name) VALUES(@library,'Shared');
            INSERT INTO library_members(subject,library_id) VALUES(@owner,@library);
            INSERT INTO assets(id,library_id,uploaded_by,file_name,media_type,size,sha256,has_preview,created_at,hidden)
              VALUES(@asset,@library,@owner,'a.jpg','image/jpeg',12,repeat('a',64),false,now(),false);
            """))
        {
            setup.Parameters.AddWithValue("owner", owner);
            setup.Parameters.AddWithValue("recipient", recipient);
            setup.Parameters.AddWithValue("library", library);
            setup.Parameters.AddWithValue("asset", asset);
            await setup.ExecuteNonQueryAsync();
        }
        var repository = new PostgresSharingRepository(database);
        var shareId = Guid.NewGuid();
        await repository.PutAsync(owner, shareId, new(library, recipient, true, []), default);
        await using (var hide = database.CreateCommand("UPDATE principals SET discoverable=false WHERE subject=@recipient"))
        {
            hide.Parameters.AddWithValue("recipient", recipient);
            await hide.ExecuteNonQueryAsync();
        }
        var narrowed = await repository.PutAsync(owner, shareId, new(library, recipient, false, [asset]), default);
        Assert.False(narrowed.AllAssets);
        Assert.Equal([asset], narrowed.AssetIds);
        await Assert.ThrowsAsync<GalleryAccessException>(
            () => repository.PutAsync(owner, Guid.NewGuid(), new(library, recipient, true, []), default));
    }
}
