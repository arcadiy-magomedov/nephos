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
        while (!stoppingToken.IsCancellationRequested)
        {
            try
            {
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
                        LibraryLog.FacePublicationIneligible(logger);
                    else if (response.StatusCode != HttpStatusCode.Accepted)
                        LibraryLog.FacePublicationRejected(logger, status);
                }
                catch (HttpRequestException)
                {
                    LibraryLog.FacePublicationUnavailable(logger);
                }
                catch (OperationCanceledException) when (!stoppingToken.IsCancellationRequested)
                {
                    LibraryLog.FacePublicationTimedOut(logger);
                }
                await repository.CompleteAsync(publication, status, stoppingToken);
            }
            catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
            {
                return;
            }
            catch (NpgsqlException exception)
            {
                LibraryLog.FacePublicationFailed(logger, exception);
                try { await Task.Delay(TimeSpan.FromSeconds(5), stoppingToken); }
                catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested) { return; }
            }
        }
    }
}
