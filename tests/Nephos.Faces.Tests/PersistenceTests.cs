using Nephos.Faces.Api;
using Npgsql;

namespace Nephos.Faces.Tests;

public sealed class DatabaseFactAttribute : FactAttribute
{
    public DatabaseFactAttribute()
    {
        if (Environment.GetEnvironmentVariable("FACES_TEST_CONNECTION") is null) Skip = "Set FACES_TEST_CONNECTION to a migrated face test database.";
    }
}

[CollectionDefinition("face-database", DisableParallelization = true)]
public sealed class DatabaseCollection;

[Collection("face-database")]
public sealed class PersistenceTests
{
    private static NpgsqlDataSource Open() => NpgsqlDataSource.Create(Environment.GetEnvironmentVariable("FACES_TEST_CONNECTION")!);
    internal static InferenceResult Result(string hash, int axis = 0)
    {
        var vector = new float[128]; vector[axis] = 1;
        return new(Pipeline.Model, Pipeline.Preprocess, hash, 300, 400, "exif-normalized",
            [new(0.1, 0.2, 0.4, 0.4, 0.99, "usable", vector)]);
    }
    internal static AnalysisSource Source(string owner) => new(Guid.NewGuid(), Guid.NewGuid(), owner, "image/jpeg", 200, new string('a', 64));

    [DatabaseFact]
    public async Task DurableClusteringNamesMergesUndoSplitsAndOwnerIsolation()
    {
        await using var db = Open();
        var r = new PostgresFaceRepository(db);
        var owner = "test-" + Guid.NewGuid();
        var source = Source(owner);
        var first = await r.EnqueueAsync(owner, source, default);
        Assert.Equal(first.Id, (await r.EnqueueAsync(owner, source, default)).Id);
        var claim = await r.ClaimAsync(default); Assert.NotNull(claim); Assert.Equal(first.Id, claim.Id);
        await r.CompleteAsync(claim, Result(source.Sha256), default);
        var second = Source(owner);
        await r.EnqueueAsync(owner, second, default);
        await r.CompleteAsync((await r.ClaimAsync(default))!, Result(second.Sha256), default);
        var third = Source(owner);
        await r.EnqueueAsync(owner, third, default);
        await r.CompleteAsync((await r.ClaimAsync(default))!, Result(third.Sha256, 1), default);
        var people = await r.PeopleAsync(owner, null, 100, null, default);
        Assert.Equal(2, people.Count);
        var faces = await r.FacesAsync(owner, null, null, null, 100, default);
        var same = faces.Single(f => f.AssetId == first.AssetId).PersonId!.Value;
        Assert.Equal(same, faces.Single(f => f.AssetId == second.Id).PersonId);
        var different = faces.Single(f => f.AssetId == third.Id).PersonId!.Value;
        Assert.NotEqual(same, different);
        Assert.True(await r.NameAsync(owner, same, new("Publisher label", ["alias"]), default));
        Assert.True(await r.MergeAsync(owner, different, same, default));
        await using var restarted = Open();
        var rr = new PostgresFaceRepository(restarted);
        Assert.Equal("Publisher label", (await rr.PersonAsync(owner, same, default))!.Name);
        Assert.Equal(same, (await rr.PersonAsync(owner, different, default))!.RedirectId);
        Assert.Equal(3, (await rr.AssetsAsync(owner, different, null, 100, default)).Count);
        Assert.True(await rr.MergeAsync(owner, different, null, default));
        Assert.Single(await rr.AssetsAsync(owner, different, null, 100, default));
        var splitFace = faces.Single(f => f.AssetId == second.Id);
        Assert.True(await rr.AssignAsync(owner, splitFace.Id, new(null, true), default));
        Assert.Equal(3, (await rr.PeopleAsync(owner, null, 100, null, default)).Count);
        Assert.True(await rr.NegativeAsync(owner, same, different, default));
        Assert.False(await rr.MergeAsync(owner, same, different, default));
        Assert.False(await rr.RemoveNegativeAsync("other-" + owner, same, different, default));
        Assert.True(await rr.RemoveNegativeAsync(owner, same, different, default));
        Assert.True(await rr.MergeAsync(owner, same, different, default));
        Assert.True(await rr.MergeAsync(owner, same, null, default));
        Assert.Null(await rr.PersonAsync("other-" + owner, same, default));
        Assert.False(await rr.NameAsync("other-" + owner, same, new("stolen", []), default));
        Assert.False(await rr.AssignAsync(owner, splitFace.Id, new(Guid.NewGuid()), default));
        Assert.Empty(await rr.FacesAsync("other-" + owner, null, null, null, 100, default));
        Assert.NotEmpty(await rr.CorrectionsAsync(owner, null, 100, default));
        Assert.Single(await rr.PeopleAsync(owner, null, 100, "alias", default));
    }

    [DatabaseFact]
    public async Task FencesStaleLeasesRetriesNoFacesAndModelChanges()
    {
        await using var db = Open();
        var r = new PostgresFaceRepository(db);
        var owner = "lease-" + Guid.NewGuid();
        var source = Source(owner);
        await r.EnqueueAsync(owner, source, default);
        var job = (await r.ClaimAsync(default))!;
        await r.CompleteAsync(job with { LeaseToken = Guid.NewGuid() }, Result(source.Sha256), default);
        Assert.Empty(await r.FacesAsync(owner, null, null, null, 100, default));
        await r.FailAsync(job, "dependency_unavailable", false, default);
        Assert.Equal("queued", (await r.JobsAsync(owner, null, 100, default)).Single().Status);
        await using (var command = db.CreateCommand("UPDATE jobs SET available_at=now() WHERE id=$1"))
        { command.Parameters.AddWithValue(job.Id); await command.ExecuteNonQueryAsync(); }
        var retry = (await r.ClaimAsync(default))!;
        Assert.Equal(2, retry.Attempts);
        await r.CompleteAsync(retry, Result(source.Sha256) with { Faces = [] }, default);
        Assert.Equal("no_faces", (await r.JobsAsync(owner, null, 100, default)).Single().Status);
        Assert.Empty(await r.PeopleAsync(owner, null, 100, null, default));
        Assert.Throws<InvalidDataException>(() => Clustering.Validate(Result(source.Sha256) with { ModelVersion = "new-model" }, retry));
    }

    [DatabaseFact]
    public async Task ReprocessingKeepsStableTracksManualUnknownNamesSplitsAndMergeProvenance()
    {
        await using var db = Open();
        var r = new PostgresFaceRepository(db);
        var owner = "reprocess-" + Guid.NewGuid();
        var source = Source(owner);
        var originalJob = await r.EnqueueAsync(owner, source, default);
        await r.CompleteAsync((await r.ClaimAsync(default))!, Result(source.Sha256), default);
        var original = Assert.Single(await r.FacesAsync(owner, source.Id, null, null, 100, default));
        Assert.True(await r.NameAsync(owner, original.PersonId!.Value, new("Kept", ["Kept alias"]), default));
        Assert.True(await r.AssignAsync(owner, original.Id, new(null, true), default));
        var split = Assert.Single(await r.FacesAsync(owner, source.Id, null, null, 100, default));
        Assert.NotEqual(original.PersonId, split.PersonId);
        Assert.True(await r.MergeAsync(owner, split.PersonId!.Value, original.PersonId, default));
        await using (var command = db.CreateCommand("UPDATE jobs SET pipeline_version='retired-test-version' WHERE id=$1"))
        { command.Parameters.AddWithValue(originalJob.Id); await command.ExecuteNonQueryAsync(); }
        Assert.Empty(await r.FacesAsync(owner, source.Id, null, null, 100, default));
        var reprocess = await r.EnqueueAsync(owner, source, default);
        Assert.NotEqual(originalJob.Id, reprocess.Id);
        await r.CompleteAsync((await r.ClaimAsync(default))!, Result(source.Sha256, 1), default);
        var after = Assert.Single(await r.FacesAsync(owner, source.Id, null, null, 100, default));
        Assert.Equal(original.Id, after.Id);
        Assert.Equal(original.PersonId, after.PersonId);
        Assert.Equal("Kept", (await r.PersonAsync(owner, original.PersonId.Value, default))!.Name);
        Assert.True(await r.MergeAsync(owner, split.PersonId.Value, null, default));
        Assert.Equal(split.PersonId, Assert.Single(await r.FacesAsync(owner, source.Id, null, null, 100, default)).PersonId);
        Assert.True(await r.AssignAsync(owner, after.Id, new(null), default));
        Assert.Null(Assert.Single(await r.FacesAsync(owner, source.Id, null, null, 100, default)).PersonId);
        await using var count = db.CreateCommand("SELECT count(*) FROM observations WHERE owner=$1");
        count.Parameters.AddWithValue(owner);
        Assert.Equal(2L, await count.ExecuteScalarAsync());
    }

    [DatabaseFact]
    public async Task ConcurrentClaimersNeverOwnSameLeaseAndExpiredAttemptsAreBounded()
    {
        await using var db = Open();
        var r = new PostgresFaceRepository(db);
        var owner = "concurrent-" + Guid.NewGuid();
        var source = Source(owner);
        var queued = await r.EnqueueAsync(owner, source, default);
        var claims = await Task.WhenAll(Enumerable.Range(0, 8).Select(_ => r.ClaimAsync(default)));
        var claimed = Assert.Single(claims, c => c is not null)!;
        Assert.Equal(queued.Id, claimed.Id);
        await using (var expire = db.CreateCommand("UPDATE jobs SET lease_until=now()-interval '1 second',attempts=5 WHERE id=$1"))
        { expire.Parameters.AddWithValue(queued.Id); await expire.ExecuteNonQueryAsync(); }
        Assert.Null(await r.ClaimAsync(default));
        Assert.Equal("retry_exhausted", (await r.JobAsync(owner, queued.Id, default))!.Error);
        Assert.True(await r.RetryAsync(owner, queued.Id, default));
        var retried = (await r.ClaimAsync(default))!;
        Assert.Equal(1, retried.Attempts);
        await r.FailAsync(retried, "access_denied", true, default);
        Assert.Equal("denied", (await r.JobAsync(owner, queued.Id, default))!.Status);
    }

    [DatabaseFact]
    public async Task UndoMergeAlsoRestoresProvenanceForFacesMatchedWhileMergeWasActive()
    {
        await using var db = Open();
        var r = new PostgresFaceRepository(db);
        var owner = "undo-lineage-" + Guid.NewGuid();
        var first = Source(owner);
        var second = Source(owner);
        await r.EnqueueAsync(owner, first, default);
        await r.CompleteAsync((await r.ClaimAsync(default))!, Result(first.Sha256), default);
        await r.EnqueueAsync(owner, second, default);
        await r.CompleteAsync((await r.ClaimAsync(default))!, Result(second.Sha256, 1), default);
        var a = Assert.Single(await r.FacesAsync(owner, first.Id, null, null, 100, default)).PersonId!.Value;
        var b = Assert.Single(await r.FacesAsync(owner, second.Id, null, null, 100, default)).PersonId!.Value;
        Assert.True(await r.MergeAsync(owner, b, a, default));
        var whileMerged = Source(owner);
        await r.EnqueueAsync(owner, whileMerged, default);
        await r.CompleteAsync((await r.ClaimAsync(default))!, Result(whileMerged.Sha256, 1), default);
        Assert.Equal(a, Assert.Single(await r.FacesAsync(owner, whileMerged.Id, null, null, 100, default)).PersonId);
        Assert.True(await r.MergeAsync(owner, b, null, default));
        Assert.Equal(b, Assert.Single(await r.FacesAsync(owner, whileMerged.Id, null, null, 100, default)).PersonId);
    }
}
