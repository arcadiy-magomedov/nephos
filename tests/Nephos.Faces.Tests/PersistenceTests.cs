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
    public async Task MergingNamedSourceIntoUnnamedDestinationPreservesNameAndSearchAcrossRestart()
    {
        await using var db = Open();
        var repository = new PostgresFaceRepository(db);
        var owner = "merge-label-" + Guid.NewGuid();
        var first = Source(owner);
        var second = Source(owner);
        await repository.EnqueueAsync(owner, first, default);
        await repository.CompleteAsync((await repository.ClaimAsync(default))!, Result(first.Sha256), default);
        await repository.EnqueueAsync(owner, second, default);
        await repository.CompleteAsync((await repository.ClaimAsync(default))!, Result(second.Sha256, 1), default);
        var faces = await repository.FacesAsync(owner, null, null, null, 100, default);
        var source = faces.Single(face => face.AssetId == first.Id).PersonId!.Value;
        var target = faces.Single(face => face.AssetId == second.Id).PersonId!.Value;
        Assert.True(await repository.NameAsync(owner, source, new("Preserved name", ["source alias"]), default));
        Assert.True(await repository.MergeAsync(owner, source, target, default));
        await using var restarted = Open();
        var reader = new PostgresFaceRepository(restarted);
        Assert.Equal("Preserved name", (await reader.PersonAsync(owner, target, default))!.Name);
        Assert.Equal(target, Assert.Single(await reader.PeopleAsync(owner, null, 100, "source alias", default)).Id);
        Assert.Single(await reader.PeopleAsync(owner, null, 100, null, default));
        Assert.Equal(2, (await reader.AssetsAsync(owner, target, null, 100, default)).Count);
        Assert.True(await reader.NameAsync(owner, target, new("Target label", []), default));
        Assert.True(await reader.NameAsync(owner, source, new("Source label", ["source alias"]), default));
        Assert.Equal("Target label", (await reader.PersonAsync(owner, target, default))!.Name);
        Assert.Equal(target, Assert.Single(await reader.PeopleAsync(owner, null, 100, "SOURCE LABEL", default)).Id);
        Assert.Equal(target, Assert.Single(await reader.PeopleAsync(owner, null, 100, "source alias", default)).Id);
        Assert.True(await reader.MergeAsync(owner, source, null, default));
        Assert.Equal("Source label", (await reader.PersonAsync(owner, source, default))!.Name);
        Assert.Equal("Target label", (await reader.PersonAsync(owner, target, default))!.Name);
        Assert.Equal(2, (await reader.PeopleAsync(owner, null, 100, null, default)).Count);
    }

    [DatabaseFact]
    public async Task LegacyMergedNamesBackfillOnlyUnambiguousLabelsAndNeverOverwriteUserNames()
    {
        await using var db = Open();
        var repository = new PostgresFaceRepository(db);
        var owner = "legacy-label-" + Guid.NewGuid();
        var target = Guid.NewGuid();
        var first = Guid.NewGuid();
        var second = Guid.NewGuid();
        await using (var insert = db.CreateCommand("""
            INSERT INTO people(id,owner,name) VALUES($1,$2,NULL),($3,$2,'First label'),($4,$2,'Second label');
            """))
        {
            insert.Parameters.AddWithValue(target);
            insert.Parameters.AddWithValue(owner);
            insert.Parameters.AddWithValue(first);
            insert.Parameters.AddWithValue(second);
            await insert.ExecuteNonQueryAsync();
        }
        await using (var merge = db.CreateCommand("UPDATE people SET redirect_id=$1 WHERE owner=$2 AND id IN ($3,$4)"))
        {
            merge.Parameters.AddWithValue(target);
            merge.Parameters.AddWithValue(owner);
            merge.Parameters.AddWithValue(first);
            merge.Parameters.AddWithValue(second);
            await merge.ExecuteNonQueryAsync();
        }
        var root = Environment.GetEnvironmentVariable("FACES_PROJECT_ROOT")!;
        var sql = await File.ReadAllTextAsync(Path.Combine(root, "src/Nephos.Migrations/Sql/faces/006_merged_names.sql"));
        await using var migrate = db.CreateCommand(sql);
        await migrate.ExecuteNonQueryAsync();
        Assert.Null((await repository.PersonAsync(owner, target, default))!.Name);
        Assert.Equal(target, Assert.Single(await repository.PeopleAsync(owner, null, 100, "First label", default)).Id);
        Assert.Equal(target, Assert.Single(await repository.PeopleAsync(owner, null, 100, "Second label", default)).Id);
        Assert.True(await repository.NameAsync(owner, second, new("First label", []), default));
        await migrate.ExecuteNonQueryAsync();
        Assert.Equal("First label", (await repository.PersonAsync(owner, target, default))!.Name);
        Assert.True(await repository.NameAsync(owner, target, new("User selected label", []), default));
        await migrate.ExecuteNonQueryAsync();
        Assert.Equal("User selected label", (await repository.PersonAsync(owner, target, default))!.Name);
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
    public async Task Asset_deletion_removes_face_data_and_preserves_other_assets()
    {
        await using var db = Open();
        var repository = new PostgresFaceRepository(db);
        var owner = "delete-asset-" + Guid.NewGuid();
        var removed = Source(owner);
        var retained = Source(owner);
        await repository.EnqueueAsync(owner, removed, default);
        await repository.CompleteAsync((await repository.ClaimAsync(default))!, Result(removed.Sha256), default);
        await repository.EnqueueAsync(owner, retained, default);
        await repository.CompleteAsync((await repository.ClaimAsync(default))!, Result(retained.Sha256), default);
        var removedFace = Assert.Single(await repository.FacesAsync(owner, removed.Id, null, null, 100, default));
        Assert.True(await repository.AssignAsync(owner, removedFace.Id, new(null, true), default));

        await repository.DeleteAssetAsync(owner, removed.Id, default);

        Assert.Empty(await repository.FacesAsync(owner, removed.Id, null, null, 100, default));
        Assert.Single(await repository.FacesAsync(owner, retained.Id, null, null, 100, default));
        Assert.DoesNotContain(await repository.JobsAsync(owner, null, 100, default), job => job.AssetId == removed.Id);
        Assert.DoesNotContain(
            await repository.CorrectionsAsync(owner, null, 100, default), correction => correction.SubjectId == removedFace.Id);
        await repository.DeleteAssetAsync(owner, removed.Id, default);
        await Assert.ThrowsAsync<FaceAssetDeletedException>(
            () => repository.EnqueueAsync(owner, removed, default));
    }

    [DatabaseFact]
    public async Task Authorized_republication_resumes_denied_jobs_without_replacing_completed_analysis()
    {
        await using var db = Open();
        var repository = new PostgresFaceRepository(db);
        var owner = "restore-analysis-" + Guid.NewGuid();
        var source = Source(owner);
        var original = await repository.EnqueueAsync(owner, source, default);
        var claim = (await repository.ClaimAsync(default))!;
        Assert.Equal(original.Id, claim.Id);
        await repository.FailAsync(claim, "access_denied", true, default);
        var resumed = await repository.EnqueueAsync(owner, source, default);
        Assert.Equal(original.Id, resumed.Id);
        Assert.Equal("queued", resumed.Status);
        Assert.Equal(0, resumed.Attempts);
        await repository.CompleteAsync((await repository.ClaimAsync(default))!, Result(source.Sha256), default);
        var face = Assert.Single(await repository.FacesAsync(owner, source.Id, null, null, 100, default));
        var complete = await repository.EnqueueAsync(owner, source, default);
        Assert.Equal(original.Id, complete.Id);
        Assert.Equal(face.Id, Assert.Single(await repository.FacesAsync(owner, source.Id, null, null, 100, default)).Id);
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
