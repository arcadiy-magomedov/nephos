using Nephos.Library.Api.Assets;

namespace Nephos.Tests;

public sealed class ResourceSetTests
{
    private static MediaResource Resource(string role) => new(Guid.NewGuid(), role, new string('a', 64), 100, "file.bin", "public.data");

    [Fact]
    public void Live_photo_requires_both_roles_and_distinct_committed_resources()
    {
        var image = Resource("photo");
        var video = Resource("pairedVideo");
        Assert.True(new ResourceSetInput("live-photo", "revision", image.AssetId, [image, video]).IsValid());
        Assert.False(new ResourceSetInput("live-photo", "revision", image.AssetId, [image]).IsValid());
        Assert.False(new ResourceSetInput("live-photo", "revision", image.AssetId, [image, image]).IsValid());
    }

    [Fact]
    public void Manifests_reject_unsafe_names_missing_primary_and_unbounded_metadata()
    {
        var resource = Resource("photo");
        Assert.False(new ResourceSetInput("single", "revision", resource.AssetId, [resource with { FileName = "../escape" }]).IsValid());
        Assert.False(new ResourceSetInput("single", "revision", Guid.NewGuid(), [resource]).IsValid());
        Assert.False(new ResourceSetInput("single", new string('a', 1025), resource.AssetId, [resource]).IsValid());
        Assert.False(new ResourceSetInput("single", "revision", resource.AssetId, [resource with { UniformTypeIdentifier = "file:///etc/passwd" }]).IsValid());
    }
}
