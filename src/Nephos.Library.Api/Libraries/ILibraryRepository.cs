namespace Nephos.Library.Api.Libraries;

public sealed record LibrarySummary(Guid Id, string Name, bool IsShared = false);
public sealed record LibraryPage(IReadOnlyList<LibrarySummary> Items, Guid? NextCursor);

public interface ILibraryRepository
{
    Task<bool> IsEnabledAsync(string subject, CancellationToken cancellationToken);
    Task<IReadOnlyList<LibrarySummary>> ListAsync(string subject, Guid? after, int limit, CancellationToken cancellationToken);
}
