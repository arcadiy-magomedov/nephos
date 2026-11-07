using Microsoft.AspNetCore.Diagnostics;
using Npgsql;
using Nephos.Library.Api.Assets;

namespace Nephos.Library.Api;

public sealed class PersistenceExceptionHandler(ILogger<PersistenceExceptionHandler> logger) : IExceptionHandler
{
    public async ValueTask<bool> TryHandleAsync(
    HttpContext context, Exception exception, CancellationToken cancellationToken)
    {
        if (exception is GalleryExpiredException or GalleryAccessException or ResourceConflictException or Administration.AdministrationConflictException
            || exception is PostgresException { SqlState: PostgresErrorCodes.UniqueViolation })
        {
            var code = exception is GalleryExpiredException ? 410 : exception is GalleryAccessException ? 404 : 409;
            logger.LogWarning("Library operation rejected ({ErrorType})", exception.GetType().Name);
            await Results.Problem(statusCode: code, title: exception is PostgresException ? "Conflicting administration metadata." : exception.Message).ExecuteAsync(context);
            return true;
        }
        if (exception is not NpgsqlException and not TimeoutException and not HttpRequestException)
        {
            return false;
        }
        logger.LogError("Persistence operation failed ({ErrorType})", exception.GetType().Name);
        await Results.Problem(statusCode: 503, title: "Library persistence unavailable").ExecuteAsync(context);
        return true;
    }
}
