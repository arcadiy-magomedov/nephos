namespace Nephos.Library.Api.Administration;

public sealed record AdminPage<T>(IReadOnlyList<T> Items, string? NextCursor, long Total);
public sealed record AdminSummary(DateTimeOffset CheckedAt, long UserCount, long EnabledUserCount,
    long LibraryCount, long AssetCount, long SizeBytes, long OperationsPending, long OperationsFailed, long PublicationPending,
    DateTimeOffset? IdentitySyncedAt);
public sealed record AdminUser(string Subject, string? Login, string? DisplayName, bool Enabled,
    bool Discoverable, long Revision, Guid? PersonalLibraryId, string? ProvisioningStatus, long IdentityRevision);
public sealed record AdminLibrary(Guid Id, string Name, string? OwnerSubject, string? OwnerLogin,
    string? OwnerDisplayName, long Revision, long MemberCount, long AssetCount, long SizeBytes);
public sealed record AdminMember(string Subject, string? Login, string? DisplayName, bool Enabled,
    string Scope, bool CanUpload, bool CanShare, bool AllAssets, long? SharedAssetCount);
public sealed record AdminLibraryDetail(AdminLibrary Library, IReadOnlyList<AdminMember> Members);
public sealed record AdminUserDetail(AdminUser User, IReadOnlyList<AdminLibrary> Libraries,
    IReadOnlyList<AdminMembership> Memberships);
public sealed record AdminMembership(Guid LibraryId, string Name, string Scope, bool CanUpload,
    bool CanShare, bool AllAssets, long? SharedAssetCount);
public sealed record IdentityProjection(string Subject, string Login, string? DisplayName, bool Enabled, long Revision);
public sealed record IdentitySync(IReadOnlyList<IdentityProjection> Items);
public sealed record ProfileCommand(Guid CommandId, long ExpectedRevision, string DisplayName, bool Discoverable);
public sealed record AccessCommand(Guid CommandId, long ExpectedRevision, bool Enabled);
public sealed record LibraryRename(string Name, long ExpectedRevision);
public sealed record LibraryOwnerAssign(string Subject, long ExpectedRevision, bool Personal = false);
public sealed record ProvisionCommand(Guid Id, string Login, string DisplayName, bool Discoverable, string LibraryName);
public sealed record AdminOperation(Guid Id, string Kind, string RequestHash, string? Login, string Subject,
    Guid? LibraryId, string? DisplayName, bool Discoverable, string? LibraryName, bool DesiredEnabled,
    long? ExpectedRevision, long ProviderRevision, string Step, string Status, long Revision, int Attempts,
    string? ErrorCode, Guid? LeaseId, DateTimeOffset CreatedAt, DateTimeOffset UpdatedAt, string? OperatorSubject);
public sealed class AdministrationConflictException(string message) : Exception(message);
