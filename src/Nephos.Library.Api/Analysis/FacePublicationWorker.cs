using System.Net;
using Nephos.ServiceDefaults;
using Npgsql;

namespace Nephos.Library.Api.Analysis;

public sealed class FacePublicationWorker(
    IAnalysisRepository repository, IHttpClientFactory clients, IConfiguration configuration,
    ILogger<FacePublicationWorker> logger) : BackgroundService
{
    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        var destination = new Uri(new Uri(configuration["Services:Faces"]
            ?? throw new InvalidOperationException("Services:Faces is required.")), "/internal/v1/faces/jobs");
        var deletionDestination = new Uri(new Uri(configuration["Services:Faces"]
            ?? throw new InvalidOperationException("Services:Faces is required.")), "/internal/v1/faces/assets/");
        while (!stoppingToken.IsCancellationRequested)
        {
            try
            {
                var deletion = await repository.ClaimDeletionAsync(stoppingToken);
                if (deletion is not null)
                {
                    using var deletionActivity = MediaProtocol.Activities.StartActivity("faces.delete");
                    int? deletionStatus = null;
                    try
                    {
                        using var request = new HttpRequestMessage(
                            HttpMethod.Delete, new Uri(deletionDestination, deletion.AssetId.ToString()))
                        {
                            Content = JsonContent.Create(new { deletion.Subject })
                        };
                        request.Headers.Add("X-Nephos-Service-Key", configuration["Services:Key"]);
                        using var response = await clients.CreateClient("faces").SendAsync(
                            request, HttpCompletionOption.ResponseHeadersRead, stoppingToken);
                        deletionStatus = (int)response.StatusCode;
                        if (response.StatusCode is not (HttpStatusCode.NoContent or HttpStatusCode.NotFound))
                            logger.LogWarning("Face deletion will retry after HTTP {StatusCode}", deletionStatus);
                    }
                    catch (HttpRequestException)
                    {
                        logger.LogWarning("Face service unavailable; durable deletion will retry");
                    }
                    catch (OperationCanceledException) when (!stoppingToken.IsCancellationRequested)
                    {
                        logger.LogWarning("Face deletion timed out; durable deletion will retry");
                    }
                    await repository.CompleteDeletionAsync(deletion, deletionStatus, stoppingToken);
                    continue;
                }

                var publication = await repository.ClaimAsync(stoppingToken);
                if (publication is null)
                {
                    await Task.Delay(TimeSpan.FromSeconds(2), stoppingToken);
                    continue;
                }
                using var activity = MediaProtocol.Activities.StartActivity("faces.publish");
                int? status = null;
                try
                {
                    using var request = new HttpRequestMessage(HttpMethod.Post, destination)
                    {
                        Content = JsonContent.Create(new { publication.AssetId, publication.Subject })
                    };
                    request.Headers.Add("X-Nephos-Service-Key", configuration["Services:Key"]);
                    using var response = await clients.CreateClient("faces").SendAsync(
                        request, HttpCompletionOption.ResponseHeadersRead, stoppingToken);
                    status = (int)response.StatusCode;
                    if (response.StatusCode == HttpStatusCode.NotFound)
                        logger.LogInformation("Face publication is no longer eligible");
                    else if (response.StatusCode != HttpStatusCode.Accepted)
                        logger.LogWarning("Face publication will retry after HTTP {StatusCode}", status);
                }
                catch (HttpRequestException)
                {
                    logger.LogWarning("Face service unavailable; durable publication will retry");
                }
                catch (OperationCanceledException) when (!stoppingToken.IsCancellationRequested)
                {
                    logger.LogWarning("Face publication timed out; durable publication will retry");
                }
                await repository.CompleteAsync(publication, status, stoppingToken);
            }
            catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
            {
                return;
            }
            catch (NpgsqlException exception)
            {
                logger.LogError(exception, "Face publication persistence failed; unacknowledged leases will expire");
                try { await Task.Delay(TimeSpan.FromSeconds(5), stoppingToken); }
                catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested) { return; }
            }
        }
    }
}
