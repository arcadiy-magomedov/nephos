using System.Diagnostics;
using System.Security.Cryptography;
using System.Text;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.Configuration;
using RabbitMQ.Client;

namespace Nephos.ServiceDefaults;

public sealed record AssetMessage(
    Guid Id, Guid LibraryId, string Subject, string FileName, string MediaType,
    long Size, string Sha256, bool HasPreview, DateTimeOffset CreatedAt, string? TraceParent, Guid? ResourceSetId = null)
{
    public bool IsValid() =>
        Id != Guid.Empty && LibraryId != Guid.Empty && ResourceSetId != Guid.Empty && !string.IsNullOrWhiteSpace(Subject) &&
        !string.IsNullOrWhiteSpace(FileName) && !string.IsNullOrWhiteSpace(MediaType) &&
        Size is > 0 and <= MediaProtocol.MaxUploadBytes && Sha256 is { Length: 64 } &&
        Sha256.All(c => c is >= '0' and <= '9' or >= 'a' and <= 'f');
}

public static class MediaProtocol
{
    public const int ChunkSize = 4 * 1024 * 1024;
    public const long MaxUploadBytes = 8L * 1024 * 1024 * 1024;
    public static readonly ActivitySource Activities = new("Nephos.Media");

    public static bool IsInternal(HttpContext context, IConfiguration configuration, string keyName = "Services:Key")
    {
        var expected = configuration[keyName]
            ?? throw new InvalidOperationException($"{keyName} is required.");
        var provided = context.Request.Headers["X-Nephos-Service-Key"].ToString();
        return expected.Length >= 32 && CryptographicOperations.FixedTimeEquals(
            SHA256.HashData(Encoding.UTF8.GetBytes(expected)), SHA256.HashData(Encoding.UTF8.GetBytes(provided)));
    }

    public static async Task<IConnection> ConnectBrokerAsync(IConfiguration configuration, CancellationToken token)
    {
        var factory = new ConnectionFactory
        {
            HostName = configuration["Broker:Host"] ?? "rabbitmq",
            UserName = configuration["Broker:Username"] ?? "nephos",
            Password = configuration["Broker:Password"] ?? throw new InvalidOperationException("Broker:Password is required."),
            AutomaticRecoveryEnabled = true
        };
        return await factory.CreateConnectionAsync(token);
    }

}
