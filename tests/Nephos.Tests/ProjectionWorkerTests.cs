using Microsoft.Extensions.Logging.Abstractions;
using Nephos.Library.Api.Assets;
using Npgsql;
using RabbitMQ.Client;
using RabbitMQ.Client.Events;
using RabbitMQ.Client.Exceptions;

namespace Nephos.Tests;

public sealed class ProjectionWorkerTests
{
    [Fact]
    public async Task Broker_forced_shutdown_retries_the_projection_worker()
    {
        await using var source = NpgsqlDataSource.Create("Host=localhost;Username=unused;Database=unused");
        var retried = new TaskCompletionSource(TaskCreationOptions.RunContinuationsAsynchronously);
        var attempts = 0;
        async Task<IConnection> Connect(CancellationToken token)
        {
            if (Interlocked.Increment(ref attempts) == 1)
                throw new OperationInterruptedException(new ShutdownEventArgs(ShutdownInitiator.Peer, 320, "shutdown"));
            retried.TrySetResult();
            await Task.Delay(Timeout.InfiniteTimeSpan, token);
            throw new InvalidOperationException("The connection attempt should have been cancelled.");
        }

        using var worker = new ProjectionWorker(new PostgresAssetRepository(source), NullLogger<ProjectionWorker>.Instance, Connect);
        await worker.StartAsync(CancellationToken.None);
        try
        {
            await retried.Task.WaitAsync(TimeSpan.FromSeconds(8));
            Assert.Equal(2, attempts);
            Assert.False(worker.ExecuteTask!.IsCompleted);
        }
        finally
        {
            await worker.StopAsync(CancellationToken.None);
        }
    }

    [Fact]
    public async Task Permanent_broker_channel_errors_are_not_retried()
    {
        await using var source = NpgsqlDataSource.Create("Host=localhost;Username=unused;Database=unused");
        Task<IConnection> Connect(CancellationToken _) => Task.FromException<IConnection>(
            new OperationInterruptedException(new ShutdownEventArgs(ShutdownInitiator.Peer, 403, "ACCESS_REFUSED")));
        using var worker = new ProjectionWorker(new PostgresAssetRepository(source), NullLogger<ProjectionWorker>.Instance, Connect);

        await Assert.ThrowsAsync<OperationInterruptedException>(async () =>
        {
            await worker.StartAsync(CancellationToken.None);
            await worker.ExecuteTask!;
        });
    }
}
