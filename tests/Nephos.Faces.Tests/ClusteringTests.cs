using Nephos.Faces.Api;

namespace Nephos.Faces.Tests;

public sealed class ClusteringTests
{
    [Fact]
    public void CosineRequiresFinite128DimensionalVectors()
    {
        var a = new float[128]; a[0] = 1;
        var b = new float[128]; b[1] = 1;
        Assert.Equal(1, Clustering.Similarity(a, a), 8);
        Assert.Equal(0, Clustering.Similarity(a, b), 8);
        Assert.Equal(-1, Clustering.Similarity([], a));
        b[0] = float.NaN;
        Assert.Equal(-1, Clustering.Similarity(a, b));
    }

    [Fact]
    public void RejectsWrongVersionsHashesCoordinatesAndMalformedVectors()
    {
        var job = new FaceJob(Guid.NewGuid(), "owner", Guid.NewGuid(), new string('a', 64), Pipeline.Version, "running", 1, null, Guid.NewGuid());
        var vector = new float[128]; vector[0] = 1;
        var face = new Detection(0.1, 0.1, 0.4, 0.4, 0.99, "usable", vector);
        var result = new InferenceResult(Pipeline.Model, Pipeline.Preprocess, job.SourceSha256, 200, 300, "exif-normalized", [face]);
        Clustering.Validate(result, job);
        Assert.Throws<InvalidDataException>(() => Clustering.Validate(result with { ModelVersion = "other" }, job));
        Assert.Throws<InvalidDataException>(() => Clustering.Validate(result with { SourceSha256 = new string('b', 64) }, job));
        Assert.Throws<InvalidDataException>(() => Clustering.Validate(result with { Faces = [face with { X = 0.9 }] }, job));
        Assert.Throws<InvalidDataException>(() => Clustering.Validate(result with { Faces = [face with { Embedding = [1] }] }, job));
        Assert.Throws<InvalidDataException>(() => Clustering.Validate(result with { CoordinateSpace = "raw" }, job));
    }
}
