using Npgsql;
using NpgsqlTypes;

namespace Nephos.Library.Api.Libraries;

public sealed class PostgresLibraryRepository(NpgsqlDataSource dataSource) : ILibraryRepository
{
    public async Task<bool> IsEnabledAsync(string subject, CancellationToken cancellationToken)
    {
        await using var command = dataSource.CreateCommand(
            "SELECT EXISTS (SELECT 1 FROM principals WHERE subject = $1 AND enabled)");
        command.Parameters.AddWithValue(subject);
        return (bool)(await command.ExecuteScalarAsync(cancellationToken))!;
    }

    public async Task<IReadOnlyList<LibrarySummary>> ListAsync(
        string subject, Guid? after, int limit, CancellationToken cancellationToken)
    {
        await using var command = dataSource.CreateCommand("""
            SELECT l.id, l.name, NOT EXISTS(SELECT 1 FROM library_members m WHERE m.library_id=l.id AND m.subject=$1)
            FROM libraries l
            WHERE can_read_library($1,l.id)
              AND ($2::uuid IS NULL OR l.id > $2)
            ORDER BY l.id
            LIMIT $3
            """);
        command.Parameters.AddWithValue(subject);
        command.Parameters.Add(new NpgsqlParameter { NpgsqlDbType = NpgsqlDbType.Uuid, Value = (object?)after ?? DBNull.Value });
        command.Parameters.AddWithValue(limit);
        var libraries = new List<LibrarySummary>();
        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        while (await reader.ReadAsync(cancellationToken))
        {
            libraries.Add(new LibrarySummary(reader.GetGuid(0), reader.GetString(1), reader.GetBoolean(2)));
        }
        return libraries;
    }
}
