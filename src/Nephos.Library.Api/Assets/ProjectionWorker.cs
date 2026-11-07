using System.Diagnostics;
using System.Text.Json;
using Nephos.ServiceDefaults;
using RabbitMQ.Client;

namespace Nephos.Library.Api.Assets;

public sealed class ProjectionWorker : BackgroundService
{
    private readonly IAssetRepository repository;
    private readonly ILogger<ProjectionWorker> logger;
    private readonly Func<CancellationToken, Task<IConnection>> connectBroker;

    public ProjectionWorker(IAssetRepository repository, IConfiguration configuration, ILogger<ProjectionWorker> logger)
        : this(repository, logger, token => MediaProtocol.ConnectBrokerAsync(configuration, token)) { }

    internal ProjectionWorker(
        IAssetRepository repository, ILogger<ProjectionWorker> logger, Func<CancellationToken, Task<IConnection>> connectBroker)
    {
        this.repository = repository;
        this.logger = logger;
        this.connectBroker = connectBroker;
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        while (!stoppingToken.IsCancellationRequested)
        {
            try
            {
                await using var connection = await connectBroker(stoppingToken);
                await using var channel = await connection.CreateChannelAsync(cancellationToken: stoppingToken);
                while (!stoppingToken.IsCancellationRequested)
                {
                    var delivery = await channel.BasicGetAsync("nephos.assets.ready", false, stoppingToken);
                    if (delivery is null)
                    {
                        await Task.Delay(500, stoppingToken);
                        continue;
                    }
                    try
                    {
                        var message = JsonSerializer.Deserialize<AssetMessage>(delivery.Body.Span)
                            ?? throw new JsonException("Empty asset message.");
                        if (!message.IsValid())
                            throw new JsonException("Invalid asset publication fields.");
                        ActivityContext.TryParse(message.TraceParent, null, out var parent);
                        using var activity = MediaProtocol.Activities.StartActivity("project verified asset", ActivityKind.Consumer, parent);
                        if (!await repository.ProjectAsync(message, stoppingToken))
                        {
                            logger.LogError("Asset publication rejected because its destination membership no longer exists");
                            await channel.BasicNackAsync(delivery.DeliveryTag, false, false, stoppingToken);
                        }
                        else await channel.BasicAckAsync(delivery.DeliveryTag, false, stoppingToken);
                    }
                    catch (JsonException)
                    {
                        logger.LogError("Malformed asset publication moved to the dead-letter queue");
                        await channel.BasicNackAsync(delivery.DeliveryTag, false, false, stoppingToken);
                    }
                }
            }
            catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested) { break; }
            catch (Exception exception) when (exception is Npgsql.NpgsqlException or IOException or
                RabbitMQ.Client.Exceptions.BrokerUnreachableException or RabbitMQ.Client.Exceptions.AlreadyClosedException or TimeoutException ||
                MediaProtocol.IsForcedBrokerShutdown(exception))
            {
                logger.LogError("Projection worker will reconnect after {ErrorType}", exception.GetType().Name);
            }
            await Task.Delay(2000, stoppingToken);
        }
    }
}
