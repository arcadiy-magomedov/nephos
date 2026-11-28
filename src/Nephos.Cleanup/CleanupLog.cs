using Microsoft.Extensions.Logging;

namespace Nephos.Cleanup;

internal static partial class CleanupLog
{
    [LoggerMessage(Level = LogLevel.Warning, Message = "Cleanup lease expired for {AssetId}; completion will retry with a new lease")]
    internal static partial void LeaseExpired(ILogger logger, Guid assetId);

    [LoggerMessage(Level = LogLevel.Warning, Message = "Cleanup failed for {AssetId} ({ErrorType}); its lease will retry")]
    internal static partial void ClaimFailed(ILogger logger, Guid assetId, string errorType);

    [LoggerMessage(Level = LogLevel.Information, Message = "Cleanup run completed {Completed} Library claims")]
    internal static partial void Completed(ILogger logger, int completed);

    [LoggerMessage(Level = LogLevel.Error, Message = "Cleanup run failed; durable claims and GC fences will retry on the next schedule")]
    internal static partial void RunFailed(ILogger logger, Exception exception);
}
