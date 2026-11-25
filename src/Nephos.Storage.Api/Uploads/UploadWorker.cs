using Nephos.ServiceDefaults;
using RabbitMQ.Client;

namespace Nephos.Storage.Api.Uploads;

public sealed class UploadWorker(
    IUploadRepository repository, IConfiguration configuration, ILogger<UploadWorker> logger) : BackgroundService
{
    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        var concurrency = Math.Clamp(configuration.GetValue("Upload:VerifyConcurrency", 2), 1, 8);
        IConnection? connection = null;
        IChannel? channel = null;
        try
        {
            while (!stoppingToken.IsCancellationRequested)
            {
                try
                {
                    await VerifyBatchAsync(concurrency, stoppingToken);
                    await repository.CleanupAsync(stoppingToken);
                    if (connection is not { IsOpen: true } || channel is not { IsOpen: true })
                    {
                        await DisposeBrokerAsync(channel, connection);
                        connection = await MediaProtocol.ConnectBrokerAsync(configuration, stoppingToken);
                        channel = await connection.CreateChannelAsync(
                            new CreateChannelOptions(publisherConfirmationsEnabled: true, publisherConfirmationTrackingEnabled: true),
                            stoppingToken);
                    }
                    var publishChannel = channel;
                    while (await repository.PublishNextAsync(async (body, token) =>
                    {
                        var message = System.Text.Json.JsonSerializer.Deserialize<AssetMessage>(body)!;
                        System.Diagnostics.ActivityContext.TryParse(message.TraceParent, null, out var parent);
                        using var activity = MediaProtocol.Activities.StartActivity("publish verified asset", System.Diagnostics.ActivityKind.Producer, parent);
                        await publishChannel.BasicPublishAsync("", "nephos.assets.ready", true,
                            new BasicProperties { Persistent = true, ContentType = "application/json" }, body, token);
                    }, stoppingToken)) { }
                }
                catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested) { break; }
                catch (Exception exception) when (exception is Npgsql.NpgsqlException or IOException or
                    RabbitMQ.Client.Exceptions.BrokerUnreachableException or RabbitMQ.Client.Exceptions.AlreadyClosedException or TimeoutException ||
                    MediaProtocol.IsForcedBrokerShutdown(exception))
                {
                    await DisposeBrokerAsync(channel, connection);
                    channel = null;
                    connection = null;
                    logger.LogError("Durable upload worker will retry after {ErrorType}", exception.GetType().Name);
                }
                await Task.Delay(TimeSpan.FromSeconds(2), stoppingToken);
            }
        }
        finally
        {
            await DisposeBrokerAsync(channel, connection);
        }
    }

    private async Task VerifyBatchAsync(int concurrency, CancellationToken stoppingToken)
    {
        var workers = Enumerable.Range(0, concurrency).Select(_ => Task.Run(async () =>
        {
            while (await repository.VerifyNextAsync(stoppingToken)) { }
        }, stoppingToken));
        await Task.WhenAll(workers);
    }

    private static async Task DisposeBrokerAsync(IChannel? channel, IConnection? connection)
    {
        if (channel is not null)
        {
            try { await channel.DisposeAsync(); } catch (Exception) { }
        }
        if (connection is not null)
        {
            try { await connection.DisposeAsync(); } catch (Exception) { }
        }
    }
}
