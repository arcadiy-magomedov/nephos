namespace Nephos.Library.Api;

internal static partial class LibraryLog
{
    [LoggerMessage(Level = LogLevel.Information, Message = "Library page served with {ItemCount} items")]
    internal static partial void PageServed(ILogger logger, int itemCount);

    [LoggerMessage(Level = LogLevel.Warning, Message = "Library operation rejected ({ErrorType})")]
    internal static partial void OperationRejected(ILogger logger, string errorType);

    [LoggerMessage(Level = LogLevel.Error, Message = "Persistence operation failed ({ErrorType})")]
    internal static partial void PersistenceFailed(ILogger logger, string errorType);

    [LoggerMessage(Level = LogLevel.Information, Message = "Face publication is no longer eligible")]
    internal static partial void FacePublicationIneligible(ILogger logger);

    [LoggerMessage(Level = LogLevel.Warning, Message = "Face publication will retry after HTTP {StatusCode}")]
    internal static partial void FacePublicationRejected(ILogger logger, int? statusCode);

    [LoggerMessage(Level = LogLevel.Warning, Message = "Face service unavailable; durable publication will retry")]
    internal static partial void FacePublicationUnavailable(ILogger logger);

    [LoggerMessage(Level = LogLevel.Warning, Message = "Face publication timed out; durable publication will retry")]
    internal static partial void FacePublicationTimedOut(ILogger logger);

    [LoggerMessage(Level = LogLevel.Error, Message = "Face publication persistence failed; unacknowledged leases will expire")]
    internal static partial void FacePublicationFailed(ILogger logger, Exception exception);

    [LoggerMessage(Level = LogLevel.Warning, Message = "Identity projection unavailable ({ErrorType}); retaining last known state")]
    internal static partial void IdentityProjectionFailed(ILogger logger, string errorType);

    [LoggerMessage(Level = LogLevel.Warning, Message = "Administration reconciliation unavailable ({ErrorType})")]
    internal static partial void AdministrationFailed(ILogger logger, string errorType);

    [LoggerMessage(Level = LogLevel.Error, Message = "Asset publication rejected because its destination membership no longer exists")]
    internal static partial void AssetMembershipMissing(ILogger logger);

    [LoggerMessage(Level = LogLevel.Error, Message = "Malformed asset publication moved to the dead-letter queue")]
    internal static partial void AssetPublicationMalformed(ILogger logger);

    [LoggerMessage(Level = LogLevel.Error, Message = "Projection worker consumer closed; reconnecting")]
    internal static partial void ProjectionConsumerClosed(ILogger logger);

    [LoggerMessage(Level = LogLevel.Error, Message = "Projection worker will reconnect after {ErrorType}")]
    internal static partial void ProjectionFailed(ILogger logger, string errorType);
}
