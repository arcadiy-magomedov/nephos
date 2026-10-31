using System.Net;
using Microsoft.AspNetCore.Diagnostics;
using Nephos.ServiceDefaults;

namespace Nephos.Storage.Api.Uploads;

public sealed class LibraryAccess(HttpClient client, IConfiguration configuration)
{
    public async Task<bool> CanAccessAsync(HttpContext context, Guid library, CancellationToken token)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, $"{configuration["Services:Library"]}/v1/libraries/{library}?upload=true");
        request.Headers.TryAddWithoutValidation("Authorization", context.Request.Headers.Authorization.ToString());
        using var response = await client.SendAsync(request, token);
        if (response.StatusCode is HttpStatusCode.NotFound or HttpStatusCode.Forbidden or HttpStatusCode.Unauthorized) return false;
        response.EnsureSuccessStatusCode();
        return true;
    }

    public async Task<bool> IsPublishedAsync(HttpContext context, Guid id, CancellationToken token)
    {
        using var request = new HttpRequestMessage(HttpMethod.Get, $"{configuration["Services:Library"]}/v1/assets/{id}/backup");
        request.Headers.TryAddWithoutValidation("Authorization", context.Request.Headers.Authorization.ToString());
        using var response = await client.SendAsync(request, token);
        if (response.StatusCode == HttpStatusCode.NotFound) return false;
        response.EnsureSuccessStatusCode();
        return true;
    }
}

public static class UploadEndpoints
{
    public static void MapUploads(this WebApplication app)
    {
        var group = app.MapGroup("/v1/uploads").RequireAuthorization();
        group.MapPost("", async (UploadIntent intent, HttpContext context, IUploadRepository repository,
            LibraryAccess access, CancellationToken token) =>
        {
            if (!intent.IsValid()) return Results.Problem(statusCode: 400, title: "Invalid upload intent or unsupported media type.");
            var subject = context.User.FindFirst("sub")?.Value;
            if (string.IsNullOrWhiteSpace(subject) || !await access.CanAccessAsync(context, intent.LibraryId, token))
                return Results.Forbid();
            var upload = await repository.CreateAsync(intent, subject, token);
            return Results.Ok(await Status(upload, context, repository, access, token));
        });
        group.MapGet("/{id:guid}", async (Guid id, HttpContext context, IUploadRepository repository,
            LibraryAccess access, CancellationToken token) =>
        {
            var upload = await Authorized(id, context, repository, access, token);
            return upload is null ? Results.NotFound() : Results.Ok(await Status(upload, context, repository, access, token));
        });
        group.MapPut("/{id:guid}/parts/{part:int}", async (Guid id, int part, HttpContext context, IUploadRepository repository,
            LibraryAccess access, CancellationToken token) =>
        {
            if (await Authorized(id, context, repository, access, token) is null) return Results.NotFound();
            await repository.PutAsync(id, part, context.Request.Body, context.Request.ContentLength, token);
            return Results.NoContent();
        });
        group.MapPost("/{id:guid}/complete", async (Guid id, HttpContext context, IUploadRepository repository,
            LibraryAccess access, CancellationToken token) =>
        {
            if (await Authorized(id, context, repository, access, token) is null) return Results.NotFound();
            await repository.SealAsync(id, token);
            return Results.Json(await Status((await repository.FindAsync(id, token))!, context, repository, access, token), statusCode: 202);
        });
        group.MapDelete("/{id:guid}", async (Guid id, HttpContext context, IUploadRepository repository,
            LibraryAccess access, CancellationToken token) =>
        {
            if (await Authorized(id, context, repository, access, token) is null) return Results.NotFound();
            await repository.CancelAsync(id, token);
            return Results.NoContent();
        });
        app.MapGet("/internal/assets/{id:guid}/backup", async (Guid id, HttpContext context, IConfiguration config,
            IUploadRepository repository, IVolumeStore volume, CancellationToken token) =>
        {
            if (!MediaProtocol.IsInternal(context, config)) return Results.Unauthorized();
            var upload = await repository.FindAsync(id, token);
            if (upload is not { State: "stored", Sha256: not null }) return Results.NotFound();
            var file = new FileInfo(volume.OriginalPath(upload.Sha256));
            if (!file.Exists || file.Length != upload.Size) return Results.Problem(statusCode: 503, title: "Original storage is unavailable.");
            return Results.Ok(new { id, upload.Sha256, upload.Size, available = true, upload.CreatedAt });
        });
        app.MapPost("/internal/assets/{id:guid}/retention", async (Guid id, HttpContext context, IConfiguration config,
            IUploadRepository repository, CancellationToken token) =>
        {
            if (!MediaProtocol.IsInternal(context, config)) return Results.Unauthorized();
            var upload = await repository.FindAsync(id, token);
            if (upload is not { State: "stored", Sha256: not null }) return Results.NotFound();
            var hold = await repository.RetainAsync(id, token);
            return Results.Ok(new
            {
                id,
                upload.Sha256,
                upload.Size,
                available = true,
                hold.HoldId,
                hold.RetainedUntil,
                assurance = "single-volume-no-independent-backup"
            });
        });
        app.MapMethods("/internal/assets/{id:guid}/{kind}", ["GET", "HEAD"], async (Guid id, string kind, int? size,
            HttpContext context, IConfiguration config, IUploadRepository repository, IVolumeStore volume, CancellationToken token) =>
        {
            if (!MediaProtocol.IsInternal(context, config)) return Results.Unauthorized();
            if (kind is not ("original" or "preview")) return Results.NotFound();
            var side = size ?? 512;
            if (kind == "preview" && !PreviewSizes.Supports(side))
                return Results.Problem(statusCode: 400, title: "Preview size must be 512, 1280 or 2560.");
            var upload = await repository.FindAsync(id, token);
            if (upload is not { State: "stored", Sha256: not null })
                return Results.NotFound();
            var path = kind == "preview" ? volume.PreviewPath(upload.Sha256, side) : volume.OriginalPath(upload.Sha256);
            if (kind == "preview" && !File.Exists(path) &&
                !await volume.CreatePreviewAsync(upload.Sha256, upload.MediaType, token, side))
                return Results.Problem(statusCode: 503, title: "Preview is unavailable. The original has not been modified.");
            if (!File.Exists(path)) return Results.Problem(statusCode: 503, title: "Original storage is unavailable.");
            context.Response.Headers.CacheControl = "private, no-store";
            return Results.File(path, kind == "preview" ? "image/jpeg" : upload.MediaType,
                kind == "preview" ? null : upload.FileName, enableRangeProcessing: true,
                entityTag: new Microsoft.Net.Http.Headers.EntityTagHeaderValue($"\"{upload.Sha256}-{kind}{(kind == "preview" ? "-" + side : "")}\""));
        });
    }

    private static async Task<Upload?> Authorized(Guid id, HttpContext context, IUploadRepository repository,
        LibraryAccess access, CancellationToken token)
    {
        var upload = await repository.FindAsync(id, token);
        if (upload is null || upload.Subject != context.User.FindFirst("sub")?.Value ||
            !await access.CanAccessAsync(context, upload.LibraryId, token)) return null;
        return upload;
    }

    private static async Task<UploadStatus> Status(Upload upload, HttpContext context, IUploadRepository repository,
        LibraryAccess access, CancellationToken token)
    {
        var state = upload.State == "stored"
            ? await access.IsPublishedAsync(context, upload.Id, token) ? "ready" : "verifying"
            : upload.State;
        return new(upload.Id, state, MediaProtocol.ChunkSize, await repository.PartsAsync(upload.Id, token),
            state == "ready" ? upload.Id : null, upload.Error);
    }
}

public sealed class UploadExceptionHandler(ILogger<UploadExceptionHandler> logger) : IExceptionHandler
{
    public async ValueTask<bool> TryHandleAsync(HttpContext context, Exception exception, CancellationToken cancellationToken)
    {
        var status = exception switch
        {
            UploadConflictException => 409,
            UploadQuotaException => 507,
            Npgsql.NpgsqlException or IOException or HttpRequestException or TimeoutException => 503,
            _ => 0
        };
        if (status == 0) return false;
        logger.LogWarning("Upload request failed with {Status} ({ErrorType})", status, exception.GetType().Name);
        if (exception is Npgsql.PostgresException databaseError)
            logger.LogError("Upload persistence failed with SQLSTATE {SqlState}", databaseError.SqlState);
        await Results.Problem(statusCode: status, title: status == 503 ? "A required storage service is unavailable." : exception.Message)
            .ExecuteAsync(context);
        return true;
    }
}
