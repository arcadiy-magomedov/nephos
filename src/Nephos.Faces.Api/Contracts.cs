namespace Nephos.Faces.Api;

public static class Pipeline
{
    public const string Model = "yunet-2023mar-sface-2021dec-8f2383e4-0ba9fbfa";
    public const string Preprocess = "exif-rgb-max1280-align5-v1";
    public const string Version = Model + ":" + Preprocess + ":cosine045-v1";
    public const double Threshold = 0.45;
    public const int MaxBytes = 20 * 1024 * 1024;
}

public sealed record AnalysisSource(Guid Id, Guid LibraryId, string Subject, string MediaType, long Size, string Sha256);
public sealed record EnqueueRequest(Guid AssetId, string Subject);
public sealed record NameRequest(string? Name, string[]? Aliases);
public sealed record MergeRequest(Guid TargetId);
public sealed record AssignmentRequest(Guid? PersonId, bool NewPerson = false);
public sealed record NegativeRequest(Guid OtherId);
public sealed record Person(Guid Id, string? Name, string[] Aliases, Guid? RedirectId);
public sealed record Face(Guid Id, Guid AssetId, Guid? PersonId, double X, double Y, double Width, double Height,
    string Quality, string SourceSha256, string ModelVersion, string PreprocessVersion, int ImageWidth, int ImageHeight);
public sealed record FaceJob(Guid Id, string Owner, Guid AssetId, string SourceSha256, string PipelineVersion,
    string Status, int Attempts, string? Error, Guid? LeaseToken);
public sealed record Detection(double X, double Y, double Width, double Height, double Confidence, string Quality, float[]? Embedding);
public sealed record InferenceResult(string ModelVersion, string PreprocessVersion, string SourceSha256,
    int Width, int Height, string CoordinateSpace, Detection[] Faces);
public sealed record Page<T>(IReadOnlyList<T> Items, Guid? Next);
public sealed record Correction(Guid Id, string Kind, Guid SubjectId, Guid? TargetId, DateTimeOffset CreatedAt);

public interface IFaceRepository
{
    Task<FaceJob> EnqueueAsync(string owner, AnalysisSource source, CancellationToken ct);
    Task<FaceJob?> ClaimAsync(CancellationToken ct);
    Task CompleteAsync(FaceJob job, InferenceResult result, CancellationToken ct);
    Task FailAsync(FaceJob job, string error, bool permanent, CancellationToken ct);
    Task<IReadOnlyList<FaceJob>> JobsAsync(string owner, Guid? after, int limit, CancellationToken ct);
    Task<FaceJob?> JobAsync(string owner, Guid id, CancellationToken ct);
    Task<bool> RetryAsync(string owner, Guid id, CancellationToken ct);
    Task<IReadOnlyList<Person>> PeopleAsync(string owner, Guid? after, int limit, string? name, CancellationToken ct);
    Task<Person?> PersonAsync(string owner, Guid id, CancellationToken ct);
    Task<bool> NameAsync(string owner, Guid id, NameRequest request, CancellationToken ct);
    Task<bool> MergeAsync(string owner, Guid source, Guid? target, CancellationToken ct);
    Task<bool> AssignAsync(string owner, Guid faceId, AssignmentRequest request, CancellationToken ct);
    Task<bool> NegativeAsync(string owner, Guid personId, Guid otherId, CancellationToken ct);
    Task<bool> RemoveNegativeAsync(string owner, Guid personId, Guid otherId, CancellationToken ct);
    Task<IReadOnlyList<Face>> FacesAsync(string owner, Guid? assetId, Guid? personId, Guid? after, int limit, CancellationToken ct);
    Task<IReadOnlyList<Guid>> AssetsAsync(string owner, Guid personId, Guid? after, int limit, CancellationToken ct);
    Task<IReadOnlyList<Correction>> CorrectionsAsync(string owner, Guid? after, int limit, CancellationToken ct);
}
