using Nephos.Library.Api.Assets;
using Nephos.Library.Api.Analysis;
using Nephos.Library.Api.Sharing;
using Nephos.ServiceDefaults;
using Npgsql;

namespace Nephos.Tests;

public sealed class LibraryDatabaseFactAttribute : FactAttribute
{
    public LibraryDatabaseFactAttribute()
    {
        if (Environment.GetEnvironmentVariable("LIBRARY_TEST_CONNECTION") is null)
            Skip = "Set LIBRARY_TEST_CONNECTION to an isolated migrated Library database.";
    }
}

[CollectionDefinition("trash-database", DisableParallelization = true)]
public sealed class TrashDatabaseCollection;

[Collection("trash-database")]
public sealed class TrashPersistenceTests
{
    private static NpgsqlDataSource Open() => NpgsqlDataSource.Create(Environment.GetEnvironmentVariable("LIBRARY_TEST_CONNECTION")!);
    private static NpgsqlDataSource Runtime()
    {
        var configuration = new NpgsqlConnectionStringBuilder(Environment.GetEnvironmentVariable("LIBRARY_TEST_CONNECTION")!)
        { Options = "-c role=library_app" };
        return NpgsqlDataSource.Create(configuration.ConnectionString);
    }
    private static async Task Execute(NpgsqlDataSource db, string sql, params object[] values)
    {
        await using var query = db.CreateCommand(sql);
        foreach (var value in values) query.Parameters.AddWithValue(value);
        await query.ExecuteNonQueryAsync();
    }
    private static async Task<(string Owner, string Other, Guid Library)> Seed(NpgsqlDataSource db)
    {
        var owner = Guid.NewGuid().ToString();
        var other = Guid.NewGuid().ToString();
        var library = Guid.NewGuid();
        await Execute(db, "INSERT INTO principals(subject,enabled,discoverable,display_name) VALUES($1,true,true,'Owner'),($2,true,true,'Other')", owner, other);
        await Execute(db, "INSERT INTO libraries(id,name) VALUES($1,'Trash test')", library);
        await Execute(db, "INSERT INTO library_members(subject,library_id) VALUES($1,$2)", owner, library);
        return (owner, other, library);
    }
    private static AssetMessage Message(string owner, Guid library, Guid? set = null) =>
        new(Guid.NewGuid(), library, owner, "photo.jpg", "image/jpeg", 100, new string('a', 64), true, DateTimeOffset.UtcNow, null, set);

    [LibraryDatabaseFact]
    public async Task Delete_restore_preserve_identity_sharing_and_gallery_tombstones()
    {
        await using var db = Open();
        var (owner, other, library) = await Seed(db);
        var assets = new PostgresAssetRepository(db);
        var trash = new PostgresTrashRepository(db);
        var gallery = new PostgresGalleryRepository(db);
        var shares = new PostgresSharingRepository(db);
        var message = Message(owner, library);
        Assert.True(await assets.ProjectAsync(message, default));
        var before = await gallery.CreateAsync(owner, library, default);
        await shares.PutAsync(owner, Guid.NewGuid(), new(library, other, true, []), default);
        Assert.NotNull(await assets.FindAsync(other, message.Id, default));
        Assert.False(await assets.DeleteAsync(other, message.Id, default));
        Assert.True(await assets.DeleteAsync(owner, message.Id, default));
        var deleted = Assert.Single((await trash.ListAsync(owner, null, 50, default)).Items);
        Assert.Equal(TimeSpan.FromDays(30), deleted.PurgeAfter - deleted.DeletedAt);
        Assert.True(await assets.DeleteAsync(owner, message.Id, default));
        Assert.Equal(deleted.DeletedAt, Assert.Single((await trash.ListAsync(owner, null, 50, default)).Items).DeletedAt);
        Assert.Null(await assets.FindAsync(owner, message.Id, default));
        Assert.Null(await assets.FindAsync(other, message.Id, default));
        Assert.Null(await trash.FindAsync(other, message.Id, default));
        Assert.Empty((await trash.ListAsync(other, null, 50, default)).Items);
        Assert.Null(await new PostgresAnalysisRepository(db).FindSourceAsync(owner, message.Id, default));
        Assert.Empty((await gallery.PageAsync(owner, library, before.Id, null, 50, default)).Items);
        var removed = await gallery.CreateAsync(owner, library, default);
        var delta = await gallery.ChangesAsync(owner, library, before.Revision, removed.Revision, 10, default);
        Assert.Contains(delta.Changes.SelectMany(x => x.Items), x => x.Operation == "remove" && x.AssetId == message.Id);
        Assert.Equal(RestoreResult.NotFound, await trash.RestoreAsync(other, message.Id, default));
        Assert.Equal(RestoreResult.Restored, await trash.RestoreAsync(owner, message.Id, default));
        Assert.Equal(RestoreResult.Restored, await trash.RestoreAsync(owner, message.Id, default));
        Assert.Empty((await trash.ListAsync(owner, null, 50, default)).Items);
        Assert.NotNull(await assets.FindAsync(owner, message.Id, default));
        Assert.NotNull(await assets.FindAsync(other, message.Id, default));
        var restored = await gallery.CreateAsync(owner, library, default);
        var additions = await gallery.ChangesAsync(owner, library, removed.Revision, restored.Revision, 10, default);
        Assert.Contains(additions.Changes.SelectMany(x => x.Items), x => x.Operation == "upsert" && x.AssetId == message.Id);
        Assert.True(await assets.ProjectAsync(message, default));
        Assert.Single(await assets.ListAsync(owner, library, null, 50, default));
    }

    [LibraryDatabaseFact]
    public async Task Disabled_or_removed_owner_cannot_mutate_even_idempotently()
    {
        await using var db = Open();
        var (owner, _, library) = await Seed(db);
        var assets = new PostgresAssetRepository(db);
        var trash = new PostgresTrashRepository(db);
        var message = Message(owner, library);
        await assets.ProjectAsync(message, default);
        await assets.DeleteAsync(owner, message.Id, default);
        await Execute(db, "UPDATE principals SET enabled=false WHERE subject=$1", owner);
        Assert.False(await assets.DeleteAsync(owner, message.Id, default));
        Assert.Equal(RestoreResult.NotFound, await trash.RestoreAsync(owner, message.Id, default));
        Assert.Empty((await trash.ListAsync(owner, null, 50, default)).Items);
        await Execute(db, "UPDATE principals SET enabled=true WHERE subject=$1", owner);
        await Execute(db, "DELETE FROM library_members WHERE subject=$1 AND library_id=$2", owner, library);
        Assert.False(await assets.DeleteAsync(owner, message.Id, default));
        Assert.Equal(RestoreResult.NotFound, await trash.RestoreAsync(owner, message.Id, default));
    }

    [LibraryDatabaseFact]
    public async Task Compound_delete_restore_are_atomic_and_recommit_cannot_resurrect()
    {
        await using var db = Open();
        var (owner, _, library) = await Seed(db);
        var assets = new PostgresAssetRepository(db);
        var trash = new PostgresTrashRepository(db);
        var sets = new PostgresResourceSetRepository(db);
        var set = Guid.NewGuid();
        var first = Message(owner, library, set);
        var second = Message(owner, library, set);
        await assets.ProjectAsync(first, default);
        await assets.ProjectAsync(second, default);
        var input = new ResourceSetInput("live-photo", "revision-1", first.Id,
            [new(first.Id, "photo", first.Sha256, 100, "photo.jpg", "public.jpeg"),
             new(second.Id, "pairedVideo", second.Sha256, 100, "photo.jpg", "public.mpeg-4")]);
        await sets.CommitAsync(owner, library, set, input, default);
        await assets.DeleteAsync(owner, first.Id, default);
        Assert.Single((await trash.ListAsync(owner, null, 50, default)).Items);
        Assert.NotNull(await trash.FindAsync(owner, second.Id, default));
        Assert.Null(await sets.ForAssetAsync(owner, first.Id, default));
        await Assert.ThrowsAsync<ResourceConflictException>(() => sets.CommitAsync(owner, library, set, input, default));
        Assert.Equal(RestoreResult.Restored, await trash.RestoreAsync(owner, second.Id, default));
        Assert.Empty((await trash.ListAsync(owner, null, 50, default)).Items);
        Assert.NotNull(await sets.ForAssetAsync(owner, first.Id, default));
        Assert.Single(await assets.ListAsync(owner, library, null, 50, default));
        await assets.DeleteAsync(owner, first.Id, default);
        await Execute(db, "UPDATE assets SET deleted_at=now()-interval '31 days' WHERE id=ANY($1)", new[] { first.Id, second.Id });
        var claim = await trash.ClaimAsync(default);
        Assert.NotNull(claim);
        Assert.Equal(RestoreResult.Expired, await trash.RestoreAsync(owner, first.Id, default));
    }

    [LibraryDatabaseFact]
    public async Task Deadline_leases_and_projection_replay_fence_purge()
    {
        await using var db = Open();
        // Isolate candidates left by other tests without changing their original retention.
        await Execute(db, "UPDATE assets SET purge_lease_until=now()+interval '1 day' WHERE deleted_at<now()-interval '30 days'");
        var (owner, _, library) = await Seed(db);
        var assets = new PostgresAssetRepository(db);
        var trash = new PostgresTrashRepository(db);
        var message = Message(owner, library);
        await assets.ProjectAsync(message, default);
        await assets.DeleteAsync(owner, message.Id, default);
        await Execute(db, "UPDATE assets SET deleted_at=now()-interval '30 days'+interval '1 hour' WHERE id=$1", message.Id);
        Assert.Null(await trash.ClaimAsync(default));
        await Execute(db, "UPDATE assets SET deleted_at=now()-interval '30 days' WHERE id=$1", message.Id);
        var claim = Assert.IsType<PurgeClaim>(await trash.ClaimAsync(default));
        Assert.Equal(message.Id, claim.AssetId);
        Assert.Equal(RestoreResult.Expired, await trash.RestoreAsync(owner, message.Id, default));
        Assert.False(await trash.CompleteAsync(message.Id, Guid.NewGuid(), default));
        await Execute(db, "UPDATE assets SET purge_lease_until=now()-interval '1 second' WHERE id=$1", message.Id);
        Assert.False(await trash.CompleteAsync(message.Id, claim.LeaseId, default));
        var retry = Assert.IsType<PurgeClaim>(await trash.ClaimAsync(default));
        Assert.NotEqual(claim.LeaseId, retry.LeaseId);
        Assert.False(await trash.CompleteAsync(message.Id, claim.LeaseId, default));
        Assert.True(await trash.CompleteAsync(message.Id, retry.LeaseId, default));
        Assert.True(await trash.CompleteAsync(message.Id, retry.LeaseId, default));
        Assert.True(await assets.ProjectAsync(message, default));
        Assert.Null(await assets.FindAsync(owner, message.Id, default));
        Assert.Null(await trash.FindAsync(owner, message.Id, default));
        Assert.Equal(RestoreResult.Expired, await trash.RestoreAsync(owner, message.Id, default));
    }

    [LibraryDatabaseFact]
    public async Task Trash_pagination_is_stable_and_bounded()
    {
        await using var db = Open();
        var (owner, _, library) = await Seed(db);
        var assets = new PostgresAssetRepository(db);
        var trash = new PostgresTrashRepository(db);
        for (var i = 0; i < 3; i++)
        {
            var message = Message(owner, library);
            await assets.ProjectAsync(message, default);
            await assets.DeleteAsync(owner, message.Id, default);
        }
        var first = await trash.ListAsync(owner, null, 2, default);
        Assert.Equal(2, first.Items.Count);
        Assert.NotNull(first.NextCursor);
        var next = await trash.ListAsync(owner, first.NextCursor, 2, default);
        Assert.Single(next.Items);
        Assert.Null(next.NextCursor);
        Assert.DoesNotContain(next.Items[0].Asset.Id, first.Items.Select(x => x.Asset.Id));
    }

    [LibraryDatabaseFact]
    public async Task Late_pending_group_members_inherit_deletion_and_cannot_publish()
    {
        await using var db = Open();
        var (owner, _, library) = await Seed(db);
        var assets = new PostgresAssetRepository(db);
        var trash = new PostgresTrashRepository(db);
        var set = Guid.NewGuid();
        var first = Message(owner, library, set);
        await assets.ProjectAsync(first, default);
        await assets.DeleteAsync(owner, first.Id, default);
        var firstDeletion = Assert.Single((await trash.ListAsync(owner, null, 50, default)).Items).DeletedAt;
        var late = Message(owner, library, set);
        await assets.ProjectAsync(late, default);
        var pending = await trash.ListAsync(owner, null, 50, default);
        Assert.Equal(2, pending.Items.Count);
        Assert.All(pending.Items, x => Assert.Equal(firstDeletion, x.DeletedAt));
        Assert.Null(await assets.FindAsync(owner, late.Id, default));
        Assert.Equal(RestoreResult.Restored, await trash.RestoreAsync(owner, first.Id, default));
        Assert.Empty((await trash.ListAsync(owner, null, 50, default)).Items);
        Assert.NotNull(await assets.FindAsync(owner, late.Id, default));
    }

    [LibraryDatabaseFact]
    public async Task Restore_and_claim_race_never_claims_a_restored_asset()
    {
        await using var db = Open();
        await Execute(db, "UPDATE assets SET purge_lease_until=now()+interval '1 day' WHERE deleted_at<now()-interval '30 days'");
        var (owner, _, library) = await Seed(db);
        var assets = new PostgresAssetRepository(db);
        var trash = new PostgresTrashRepository(db);
        var message = Message(owner, library);
        await assets.ProjectAsync(message, default);
        await assets.DeleteAsync(owner, message.Id, default);
        // Restore must reject at the eligibility boundary, including under a cleanup race.
        await Execute(db, "UPDATE assets SET deleted_at=now()-interval '30 days' WHERE id=$1", message.Id);
        var restore = trash.RestoreAsync(owner, message.Id, default);
        var claim = trash.ClaimAsync(default);
        await Task.WhenAll(restore, claim);
        Assert.Equal(RestoreResult.Expired, restore.Result);
        Assert.Equal(message.Id, claim.Result!.AssetId);
        Assert.Null(await assets.FindAsync(owner, message.Id, default));
    }

    [LibraryDatabaseFact]
    public async Task Runtime_role_can_delete_restore_and_purge_without_membership_write_permissions()
    {
        await using var admin = Open();
        await Execute(admin, "UPDATE assets SET purge_lease_until=now()+interval '1 day' WHERE deleted_at<now()-interval '30 days'");
        var (owner, _, library) = await Seed(admin);
        await using var runtime = Runtime();
        var assets = new PostgresAssetRepository(runtime);
        var trash = new PostgresTrashRepository(runtime);
        var message = Message(owner, library);
        Assert.True(await assets.ProjectAsync(message, default));
        Assert.True(await assets.DeleteAsync(owner, message.Id, default));
        Assert.Single((await trash.ListAsync(owner, null, 50, default)).Items);
        Assert.Equal(RestoreResult.Restored, await trash.RestoreAsync(owner, message.Id, default));
        Assert.True(await assets.DeleteAsync(owner, message.Id, default));
        await Execute(admin, "UPDATE assets SET deleted_at=now()-interval '30 days' WHERE id=$1", message.Id);
        var claim = Assert.IsType<PurgeClaim>(await trash.ClaimAsync(default));
        Assert.Equal(message.Id, claim.AssetId);
        Assert.True(await trash.CompleteAsync(message.Id, claim.LeaseId, default));
    }
}
