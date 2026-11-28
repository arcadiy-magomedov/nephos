namespace Nephos.Storage.Api;

internal static partial class StorageLog
{
    [LoggerMessage(Level = LogLevel.Warning, Message = "Upload request failed with {Status} ({ErrorType})")]
    internal static partial void RequestFailed(ILogger logger, int status, string errorType);

    [LoggerMessage(Level = LogLevel.Error, Message = "Upload persistence failed with SQLSTATE {SqlState}")]
    internal static partial void PersistenceFailed(ILogger logger, string sqlState);

    [LoggerMessage(Level = LogLevel.Error, Message = "Storage operational metrics could not be refreshed ({ErrorType})")]
    internal static partial void MetricsFailed(ILogger logger, string errorType);

    [LoggerMessage(Level = LogLevel.Error, Message = "Durable upload worker will retry after {ErrorType}")]
    internal static partial void WorkerFailed(ILogger logger, string errorType);

    [LoggerMessage(Level = LogLevel.Warning, Message = "Upload verification lease release failed ({ErrorType}); the lease will expire")]
    internal static partial void LeaseReleaseFailed(ILogger logger, string errorType);

    [LoggerMessage(Level = LogLevel.Warning, Message = "Upload broker {Resource} disposal failed ({ErrorType})")]
    internal static partial void BrokerDisposalFailed(ILogger logger, string resource, string errorType);

    [LoggerMessage(Level = LogLevel.Debug, Message = "An immutable preview variant was already published concurrently")]
    internal static partial void PreviewPublishedConcurrently(ILogger logger);

    [LoggerMessage(Level = LogLevel.Warning, Message = "Video preview tool is unavailable; original remains stored without a preview")]
    internal static partial void PreviewToolUnavailable(ILogger logger);

    [LoggerMessage(Level = LogLevel.Warning, Message = "Preview generation exceeded its time budget")]
    internal static partial void PreviewTimedOut(ILogger logger);

    [LoggerMessage(Level = LogLevel.Warning, Message = "Preview unavailable for an unsupported or undecodable resource")]
    internal static partial void PreviewUnsupported(ILogger logger);

    [LoggerMessage(Level = LogLevel.Warning, Message = "Image derivative service is not configured; original remains available")]
    internal static partial void DerivativesUnconfigured(ILogger logger);

    [LoggerMessage(Level = LogLevel.Warning, Message = "Image exceeds the derivative input budget; original remains available")]
    internal static partial void DerivativeInputTooLarge(ILogger logger);

    [LoggerMessage(Level = LogLevel.Warning, Message = "Image derivative rejected an unsupported, corrupt or oversized image")]
    internal static partial void DerivativeRejected(ILogger logger);

    [LoggerMessage(Level = LogLevel.Warning, Message = "Image derivatives unavailable ({ErrorType}); original is retained and preview requests may retry")]
    internal static partial void DerivativesUnavailable(ILogger logger, string errorType);
}
