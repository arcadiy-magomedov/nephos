using Nephos.Library.Api.Sharing;

namespace Nephos.Tests;

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
}
