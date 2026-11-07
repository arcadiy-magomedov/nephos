using Nephos.ServiceDefaults;
using RabbitMQ.Client;

namespace Nephos.Storage.Api.Uploads;

public sealed class UploadWorker(
    IUploadRepository repository, IConfiguration configuration, ILogger<UploadWorker> logger) : BackgroundService
{
    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        while (!stoppingToken.IsCancellationRequested)
        {
            try
            {
                while (await repository.VerifyNextAsync(stoppingToken)) { }
                await repository.CleanupAsync(stoppingToken);
                await using var connection = await MediaProtocol.ConnectBrokerAsync(configuration, stoppingToken);
                await using var channel = await connection.CreateChannelAsync(
                    new CreateChannelOptions(publisherConfirmationsEnabled: true, publisherConfirmationTrackingEnabled: true),
                    stoppingToken);
                while (await repository.PublishNextAsync(async (body, token) =>
                {
                    var message = System.Text.Json.JsonSerializer.Deserialize<AssetMessage>(body)!;
                    System.Diagnostics.ActivityContext.TryParse(message.TraceParent, null, out var parent);
                    using var activity = MediaProtocol.Activities.StartActivity("publish verified asset", System.Diagnostics.ActivityKind.Producer, parent);
                    await channel.BasicPublishAsync("", "nephos.assets.ready", true,
                        new BasicProperties { Persistent = true, ContentType = "application/json" }, body, token);
                }, stoppingToken)) { }
            }
            catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested) { break; }
            catch (Exception exception) when (exception is Npgsql.NpgsqlException or IOException or
                RabbitMQ.Client.Exceptions.BrokerUnreachableException or RabbitMQ.Client.Exceptions.AlreadyClosedException or TimeoutException ||
                MediaProtocol.IsForcedBrokerShutdown(exception))
            {
                logger.LogError("Durable upload worker will retry after {ErrorType}", exception.GetType().Name);
            }
            await Task.Delay(TimeSpan.FromSeconds(2), stoppingToken);
        }
    }
}
