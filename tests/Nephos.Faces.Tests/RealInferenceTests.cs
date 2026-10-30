using System.Diagnostics;
using System.Net;
using System.Net.Http.Json;
using System.Security.Cryptography;
using System.Text.Json;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging.Abstractions;
using Nephos.Faces.Api;

namespace Nephos.Faces.Tests;

public sealed class RealPhotoFactAttribute : FactAttribute
{
    public RealPhotoFactAttribute()
    {
        var root = Environment.GetEnvironmentVariable("FACES_PROJECT_ROOT");
        if (Environment.GetEnvironmentVariable("FACES_TEST_CONNECTION") is null || root is null ||
            !File.Exists(Path.Combine(root, "face-inference/fixtures/provenance.json")))
            Skip = "Download licensed fixtures and set FACES_PROJECT_ROOT + FACES_TEST_CONNECTION.";
    }
}

public sealed class ActualLocalInference(string root) : IInferenceClient
{
    public async Task<InferenceResult> AnalyzeAsync(byte[] bytes, CancellationToken ct)
    {
        var start = new ProcessStartInfo(Path.Combine(root, "face-inference/.venv/bin/python"))
        {
            RedirectStandardInput = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            WorkingDirectory = root
        };
        start.ArgumentList.Add("face-inference/infer.py");
        using var process = Process.Start(start)!;
        try
        {
            var output = process.StandardOutput.ReadToEndAsync(ct);
            var error = process.StandardError.ReadToEndAsync(ct);
            await process.StandardInput.BaseStream.WriteAsync(bytes, ct);
            process.StandardInput.Close();
            await process.WaitForExitAsync(ct);
            if (process.ExitCode != 0) throw new InvalidDataException("Actual inference failed: " + await error);
            return JsonSerializer.Deserialize<InferenceResult>(await output, new JsonSerializerOptions(JsonSerializerDefaults.Web))!;
        }
        finally { if (!process.HasExited) process.Kill(true); }
    }
}

[Collection("face-database")]
public sealed class RealInferenceTests
{
    [RealPhotoFact]
    public async Task SixRealPortraitJobsClusterThenPersistNamesMergesAndCorrectiveSplitsAcrossRestart()
    {
        var root = Environment.GetEnvironmentVariable("FACES_PROJECT_ROOT")!;
        var sources = JsonDocument.Parse(await File.ReadAllTextAsync(Path.Combine(root, "face-inference/fixtures/provenance.json")));
        var owner = "real-photos-" + Guid.NewGuid();
        var assets = new Dictionary<string, List<Guid>>();
        var personIds = new Dictionary<string, Guid>();
        var report = new Dictionary<string, object>();
        await using (var app = new FacesApplication())
        {
            using var client = app.Authenticated(owner);
            var r = app.Services.GetRequiredService<IFaceRepository>();
            var worker = new FaceWorker(r, app.Source, new ActualLocalInference(root), NullLogger<FaceWorker>.Instance);
            foreach (var fixture in sources.RootElement.EnumerateArray())
            {
                var id = fixture.GetProperty("id").GetString()!;
                var label = fixture.GetProperty("label").GetString()!;
                var bytes = await File.ReadAllBytesAsync(Path.Combine(root, "face-inference/fixtures/photos", id + ".jpg"));
                var hash = Convert.ToHexStringLower(SHA256.HashData(bytes));
                Assert.Equal(fixture.GetProperty("sha256").GetString(), hash);
                var source = new AnalysisSource(Guid.NewGuid(), Guid.NewGuid(), owner, "image/jpeg", bytes.Length, hash);
                app.Source.Sources[source.Id] = (source, bytes);
                if (!assets.TryGetValue(label, out var list)) assets[label] = list = [];
                list.Add(source.Id);
                Assert.Equal(HttpStatusCode.Accepted, (await client.PostAsync($"/v1/faces/jobs/{source.Id}", null)).StatusCode);
                var job = (await r.ClaimAsync(default))!;
                Assert.Equal(source.Id, job.AssetId);
                using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(90));
                await worker.ProcessAsync(job, deadline.Token);
                var face = Assert.Single(await r.FacesAsync(owner, source.Id, null, null, 100, default));
                Assert.NotNull(face.PersonId);
                if (personIds.TryGetValue(label, out var known)) Assert.Equal(known, face.PersonId);
                else personIds[label] = face.PersonId.Value;
                report[id] = new { source.Id, Person = face.PersonId, face.Quality, face.SourceSha256, Status = "complete" };
            }
            Assert.Equal(3, personIds.Values.Distinct().Count());
            Assert.Equal(3, (await r.PeopleAsync(owner, null, 100, null, default)).Count);
            foreach (var (label, person) in personIds)
            {
                Assert.Equal(HttpStatusCode.NoContent, (await client.PutAsJsonAsync($"/v1/faces/people/{person}/name", new NameRequest(label, []))).StatusCode);
                var page = await client.GetFromJsonAsync<Page<Guid>>($"/v1/faces/people/{person}/assets");
                Assert.Equal(2, page!.Items.Count);
            }
            var ids = personIds.Values.ToArray();
            Assert.Equal(HttpStatusCode.NoContent, (await client.PostAsJsonAsync($"/v1/faces/people/{ids[1]}/merge", new MergeRequest(ids[0]))).StatusCode);
        }
        // A new ASP.NET host and new Npgsql pool prove corrections are not process-local.
        await using (var restarted = new FacesApplication())
        {
            using var client = restarted.Authenticated(owner);
            var r = restarted.Services.GetRequiredService<IFaceRepository>();
            foreach (var (label, person) in personIds)
                Assert.Equal(label, (await client.GetFromJsonAsync<Person>($"/v1/faces/people/{person}"))!.Name);
            var ids = personIds.Values.ToArray();
            Assert.Equal(ids[0], (await r.PersonAsync(owner, ids[1], default))!.RedirectId);
            Assert.Equal(4, (await r.AssetsAsync(owner, ids[0], null, 100, default)).Count);
            Assert.Equal(HttpStatusCode.NoContent, (await client.DeleteAsync($"/v1/faces/people/{ids[1]}/merge")).StatusCode);
            var face = (await r.FacesAsync(owner, assets.Values.First()[1], null, null, 100, default)).Single();
            Assert.Equal(HttpStatusCode.NoContent, (await client.PutAsJsonAsync($"/v1/faces/observations/{face.Id}/person", new AssignmentRequest(null, true))).StatusCode);
            var split = (await r.FacesAsync(owner, face.AssetId, null, null, 100, default)).Single().PersonId;
            Assert.NotEqual(face.PersonId, split);
            Assert.True(await r.MergeAsync(owner, split!.Value, ids[0], default));
            Assert.Equal(2, (await r.AssetsAsync(owner, ids[0], null, 100, default)).Count);
            report["corrections"] = new { NamesSurviveRestart = true, MergeSurvivesRestart = true, UndoMerge = true, Split = true, Rejoin = true };
        }
        Directory.CreateDirectory(Path.Combine(root, "face-inference/results"));
        await File.WriteAllTextAsync(Path.Combine(root, "face-inference/results/pipeline-verification.json"),
            JsonSerializer.Serialize(report, new JsonSerializerOptions { WriteIndented = true }));
    }
}
