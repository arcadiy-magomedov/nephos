using System.Text.Json;
using Nephos.ServiceDefaults;

namespace Nephos.Tests;

public sealed class MessageTests
{
    [Fact]
    public void Well_formed_json_with_missing_fields_is_not_a_valid_publication()
    {
        Assert.False(JsonSerializer.Deserialize<AssetMessage>("{}")!.IsValid());
    }

    [Fact]
    public void Publication_fields_are_validated_before_persistence()
    {
        var message = new AssetMessage(Guid.NewGuid(), Guid.NewGuid(), "subject", "photo.png",
            "image/png", 42, new string('a', 64), true, DateTimeOffset.UtcNow, null);
        Assert.True(message.IsValid());
        Assert.False((message with { Size = 0 }).IsValid());
        Assert.False((message with { Sha256 = new string('z', 64) }).IsValid());
        Assert.False((message with { ResourceSetId = Guid.Empty }).IsValid());
        Assert.True((message with { ResourceSetId = Guid.NewGuid() }).IsValid());
    }
}
