using Nephos.ServiceDefaults;

namespace Nephos.Storage.Api.Uploads;

public sealed record UploadIntent(Guid Id, Guid LibraryId, string FileName, string MediaType, long Size, string Sha256,
    DateTimeOffset? CapturedAt = null, Guid? ResourceSetId = null)
{
    public bool IsValid() =>
        Id != Guid.Empty && LibraryId != Guid.Empty && ResourceSetId != Guid.Empty && Size is > 0 and <= MediaProtocol.MaxUploadBytes &&
        !string.IsNullOrWhiteSpace(FileName) && FileName.Length <= 200 &&
        !FileName.Any(c => char.IsControl(c) || c is '/' or '\\') &&
        MediaType is "image/jpeg" or "image/png" or "image/heic" or "image/heif" or "image/webp" or "image/gif" or
            "video/mp4" or "video/quicktime" or "application/octet-stream" &&
        Sha256 is { Length: 64 } && Sha256.All(c => c is >= '0' and <= '9' or >= 'a' and <= 'f') &&
        (CapturedAt is null || CapturedAt >= new DateTimeOffset(1800, 1, 1, 0, 0, 0, TimeSpan.Zero) && CapturedAt <= DateTimeOffset.UtcNow.AddDays(1));
}

public sealed record Upload(
    Guid Id, string Subject, Guid LibraryId, string FileName, string MediaType,
    long Size, string ExpectedHash, string State, string? Sha256, bool HasPreview,
    string? Error, DateTimeOffset CreatedAt, string? TraceParent = null, Guid? ResourceSetId = null);

public sealed record UploadStatus(Guid Id, string State, int ChunkSize, int[] ReceivedParts, Guid? AssetId, string? Error);
public sealed class UploadConflictException(string message) : Exception(message);
public sealed class UploadQuotaException(string message) : Exception(message);
