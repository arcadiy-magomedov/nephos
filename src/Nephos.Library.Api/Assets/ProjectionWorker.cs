using System.Diagnostics;
using System.Text.Json;
using System.Threading.Channels;
using Nephos.ServiceDefaults;
using RabbitMQ.Client;
using RabbitMQ.Client.Events;

namespace Nephos.Library.Api.Assets;

public sealed class ProjectionWorker : BackgroundService
{
    private readonly IAssetRepository repository;
    private readonly ILogger<ProjectionWorker> logger;
    private readonly Func<CancellationToken, Task<IConnection>> connectBroker;

    public ProjectionWorker(IAssetRepository repository, IConfiguration configuration, ILogger<ProjectionWorker> logger)
        : this(repository, logger, token => MediaProtocol.ConnectBrokerAsync(configuration, token, automaticRecovery: false)) { }

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
                await channel.BasicQosAsync(0, 16, false, stoppingToken);

                using var sessionCts = CancellationTokenSource.CreateLinkedTokenSource(stoppingToken);
                var deliveries = Channel.CreateBounded<(ulong DeliveryTag, byte[] Body)>(
                    new BoundedChannelOptions(16) { SingleReader = true, SingleWriter = false });
                void EndSession()
                {
                    sessionCts.Cancel();
                    deliveries.Writer.TryComplete();
                }

                var consumer = new AsyncEventingBasicConsumer(channel);
                consumer.ReceivedAsync += async (_, args) =>
                {
                    if (sessionCts.IsCancellationRequested) return;
                    try
                    {
                        // Copy bytes immediately because RabbitMQ may recycle delivery buffers after the callback returns.
                        await deliveries.Writer.WriteAsync((args.DeliveryTag, args.Body.ToArray()), sessionCts.Token);
                    }
                    catch (OperationCanceledException) { }
                    catch (ChannelClosedException) { }
                };
                consumer.UnregisteredAsync += (_, _) => { EndSession(); return Task.CompletedTask; };
                consumer.ShutdownAsync += (_, _) => { EndSession(); return Task.CompletedTask; };
                channel.ChannelShutdownAsync += (_, _) => { EndSession(); return Task.CompletedTask; };
                connection.ConnectionShutdownAsync += (_, _) => { EndSession(); return Task.CompletedTask; };

                await channel.BasicConsumeAsync("nephos.assets.ready", autoAck: false, consumer, sessionCts.Token);

                // Single reader owns all BasicAck/BasicNack operations and stops immediately on channel/consumer shutdown.
                try
                {
                    await foreach (var (deliveryTag, body) in deliveries.Reader.ReadAllAsync(sessionCts.Token))
                    {
                        if (sessionCts.IsCancellationRequested || !channel.IsOpen) break;
                        try
                        {
                            var message = JsonSerializer.Deserialize<AssetMessage>(body)
                                ?? throw new JsonException("Empty asset message.");
                            if (!message.IsValid())
                                throw new JsonException("Invalid asset publication fields.");
                            ActivityContext.TryParse(message.TraceParent, null, out var parent);
                            using var activity = MediaProtocol.Activities.StartActivity("project verified asset", ActivityKind.Consumer, parent);
                            if (!await repository.ProjectAsync(message, sessionCts.Token))
                            {
                                LibraryLog.AssetMembershipMissing(logger);
                                if (!sessionCts.IsCancellationRequested && channel.IsOpen)
                                    await channel.BasicNackAsync(deliveryTag, false, false, sessionCts.Token);
                            }
                            else if (!sessionCts.IsCancellationRequested && channel.IsOpen)
                                await channel.BasicAckAsync(deliveryTag, false, sessionCts.Token);
                        }
                        catch (JsonException)
                        {
                            LibraryLog.AssetPublicationMalformed(logger);
                            if (!sessionCts.IsCancellationRequested && channel.IsOpen)
                                await channel.BasicNackAsync(deliveryTag, false, false, sessionCts.Token);
                        }
                    }
                }
                catch (OperationCanceledException) when (!stoppingToken.IsCancellationRequested)
                {
                    LibraryLog.ProjectionConsumerClosed(logger);
                }
            }
            catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested) { break; }
            catch (Exception exception) when (exception is Npgsql.NpgsqlException or IOException or
                RabbitMQ.Client.Exceptions.BrokerUnreachableException or RabbitMQ.Client.Exceptions.AlreadyClosedException or TimeoutException ||
                MediaProtocol.IsForcedBrokerShutdown(exception))
            {
                LibraryLog.ProjectionFailed(logger, exception.GetType().Name);
            }
            await Task.Delay(2000, stoppingToken);
        }
    }
}
