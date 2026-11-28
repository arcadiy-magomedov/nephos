namespace Nephos.Faces.Api;

internal static partial class FaceLog
{
    [LoggerMessage(Level = LogLevel.Warning, Message = "Face worker unavailable ({ErrorType}); retrying")]
    internal static partial void WorkerUnavailable(ILogger logger, string errorType);

    [LoggerMessage(Level = LogLevel.Warning, Message = "Face analysis unsuccessful ({ErrorCode}); attempt {Attempt}")]
    internal static partial void AnalysisFailed(ILogger logger, string errorCode, int attempt);
}
