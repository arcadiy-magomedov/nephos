using Nephos.Library.Api.Assets;

namespace Nephos.Tests;

public sealed class ResourceSetTests
{
    private static MediaResource Resource(string role) => new(Guid.NewGuid(), role, new string('a', 64), 100, "file.bin", "public.data");

    [Theory]
    [InlineData("unknown-16")]
    [InlineData("unknown-2147483647")]
    [InlineData("photoProxy")]
    public void Edited_photos_preserve_additional_PhotoKit_resources(string role)
    {
        var original = Resource("photo");
        var rendered = Resource("fullSizePhoto");
        var adjustment = Resource("adjustmentData");
        var additional = Resource(role) with { UniformTypeIdentifier = "com.apple.photos.apple-adjustment-envelope" };
        Assert.True(new ResourceSetInput("edited", "revision", rendered.AssetId,
            [original, adjustment, additional, rendered]).IsValid());
        Assert.False(new ResourceSetInput("live-photo", "revision", original.AssetId,
            [original, Resource("pairedVideo"), additional]).IsValid());
    }

    [Theory]
    [InlineData("unknown-")]
    [InlineData("unknown-0")]
    [InlineData("unknown--1")]
    [InlineData("unknown-016")]
    [InlineData("unknown-+16")]
    [InlineData("unknown-16 ")]
    [InlineData("unknown-2147483648")]
    [InlineData("unknown-16/../")]
    [InlineData("arbitrary")]
    public void Opaque_resource_roles_require_a_canonical_positive_type(string role)
    {
        var resource = Resource(role);
        Assert.False(new ResourceSetInput("archive", "revision", resource.AssetId, [resource]).IsValid());
    }

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
