using System.Diagnostics;
using System.Diagnostics.Metrics;

namespace Nephos.Faces.Api;

public sealed class FaceWorker(IFaceRepository repository, IAnalysisSourceClient sourceClient,
    IInferenceClient inference, ILogger<FaceWorker> logger) : BackgroundService
{
    private static readonly ActivitySource Traces = new("Nephos.Faces");
    private static readonly Meter Meter = new("Nephos.Faces");
    private static readonly Counter<long> Outcomes = Meter.CreateCounter<long>("nephos.faces.jobs");

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        while (!stoppingToken.IsCancellationRequested)
        {
            try
            {
                var job = await repository.ClaimAsync(stoppingToken);
                if (job is null) { await Task.Delay(TimeSpan.FromSeconds(2), stoppingToken); continue; }
                await ProcessAsync(job, stoppingToken);
            }
            catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested) { break; }
            catch (Exception exception)
            {
                logger.LogWarning("Face worker unavailable ({ErrorType}); retrying", exception.GetType().Name);
                await Task.Delay(TimeSpan.FromSeconds(5), stoppingToken);
            }
        }
    }

    public async Task ProcessAsync(FaceJob job, CancellationToken stoppingToken)
    {
        using var activity = Traces.StartActivity("face-analysis");
        using var timeout = CancellationTokenSource.CreateLinkedTokenSource(stoppingToken);
        timeout.CancelAfter(TimeSpan.FromSeconds(90));
        var ct = timeout.Token;
        try
        {
            var source = await sourceClient.SourceAsync(job.Owner, job.AssetId, ct);
            if (source is null) { await repository.FailAsync(job, "access_denied", true, ct); return; }
            if (source.Sha256 != job.SourceSha256) throw new InvalidDataException("source_changed");
            var bytes = await sourceClient.OriginalAsync(source, ct);
            var result = await inference.AnalyzeAsync(bytes, ct);
            var current = await sourceClient.SourceAsync(job.Owner, job.AssetId, ct);
            if (current is null) { await repository.FailAsync(job, "access_denied", true, ct); return; }
            if (current.Sha256 != source.Sha256) throw new InvalidDataException("source_changed");
            await repository.CompleteAsync(job, result, ct);
            Outcomes.Add(1, new KeyValuePair<string, object?>("outcome", result.Faces.Length == 0 ? "no_faces" : "complete"));
        }
        catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested) { throw; }
        catch (Exception exception)
        {
            var permanent = exception is InvalidDataException;
            var error = permanent ? "invalid_media_or_provenance" : exception is OperationCanceledException ? "timeout" : "dependency_unavailable";
            await repository.FailAsync(job, error, permanent, stoppingToken);
            Outcomes.Add(1, new KeyValuePair<string, object?>("outcome", error));
            logger.LogWarning("Face analysis unsuccessful ({ErrorCode}); attempt {Attempt}", error, job.Attempts);
        }
    }
}
