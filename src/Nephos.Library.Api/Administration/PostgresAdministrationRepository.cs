using Nephos.Library.Api.Libraries;
using Npgsql;

namespace Nephos.Library.Api.Administration;

public interface IAdministrationRepository
{
    Task<AdministrationState> ReadAsync(CancellationToken token);
    Task SetPrincipalAsync(PrincipalUpdate update, CancellationToken token);
    Task<bool> CreateLibraryAsync(LibraryCreate input, CancellationToken token);
}

public sealed class PostgresAdministrationRepository(IConfiguration configuration) : IAdministrationRepository, IAsyncDisposable
{
    private readonly NpgsqlDataSource source = NpgsqlDataSource.Create(configuration.GetConnectionString("LibraryAdmin")
        ?? throw new InvalidOperationException("ConnectionStrings:LibraryAdmin is required."));
    private async Task<NpgsqlConnection> OpenAsync(CancellationToken token) => await source.OpenConnectionAsync(token);
    public ValueTask DisposeAsync() => source.DisposeAsync();

    public async Task<AdministrationState> ReadAsync(CancellationToken token)
    {
        await using var connection = await OpenAsync(token);
        var principals = new List<PrincipalUpdate>();
        var libraries = new List<LibrarySummary>();
        await using (var query = new NpgsqlCommand("SELECT subject,enabled,display_name,discoverable FROM principals ORDER BY subject LIMIT 1000", connection))
        await using (var reader = await query.ExecuteReaderAsync(token))
            while (await reader.ReadAsync(token)) principals.Add(new(reader.GetString(0), reader.GetBoolean(1),
                reader.IsDBNull(2) ? null : reader.GetString(2), reader.GetBoolean(3)));
        await using (var query = new NpgsqlCommand("SELECT id,name FROM libraries ORDER BY name LIMIT 1000", connection))
        await using (var reader = await query.ExecuteReaderAsync(token))
            while (await reader.ReadAsync(token)) libraries.Add(new(reader.GetGuid(0), reader.GetString(1)));
        return new(principals, libraries);
    }

    public async Task SetPrincipalAsync(PrincipalUpdate update, CancellationToken token)
    {
        await using var connection = await OpenAsync(token);
        await using var transaction = await connection.BeginTransactionAsync(token);
        await using var command = new NpgsqlCommand("""
            INSERT INTO principals(subject,enabled,display_name,discoverable) VALUES($1,$2,$3,coalesce($4,false))
            ON CONFLICT(subject) DO UPDATE SET enabled=EXCLUDED.enabled,access_generation=principals.access_generation+1,
              display_name=coalesce($3,principals.display_name),discoverable=coalesce($4,principals.discoverable)
            """, connection, transaction);
        command.Parameters.AddWithValue(update.Subject);
        command.Parameters.AddWithValue(update.Enabled);
        command.Parameters.Add(new NpgsqlParameter
        {
            NpgsqlDbType = NpgsqlTypes.NpgsqlDbType.Text,
            Value = string.IsNullOrWhiteSpace(update.DisplayName) ? DBNull.Value : update.DisplayName.Trim()
        });
        command.Parameters.Add(new NpgsqlParameter
        {
            NpgsqlDbType = NpgsqlTypes.NpgsqlDbType.Boolean,
            Value = (object?)update.Discoverable ?? DBNull.Value
        });
        await command.ExecuteNonQueryAsync(token);
        await using (var invalidate = new NpgsqlCommand("""
            UPDATE principals SET share_generation=share_generation+1
            WHERE subject IN(SELECT recipient_subject FROM shares WHERE owner_subject=$1)
            """, connection, transaction))
        {
            invalidate.Parameters.AddWithValue(update.Subject);
            await invalidate.ExecuteNonQueryAsync(token);
        }
        await transaction.CommitAsync(token);
    }

    public async Task<bool> CreateLibraryAsync(LibraryCreate input, CancellationToken token)
    {
        await using var connection = await OpenAsync(token);
        await using var transaction = await connection.BeginTransactionAsync(token);
        await using (var check = new NpgsqlCommand("""
            SELECT EXISTS(SELECT 1 FROM principals WHERE subject=$1) AND
            NOT EXISTS(SELECT 1 FROM libraries WHERE id=$2 AND name<>$3)
            """, connection, transaction))
        {
            check.Parameters.AddWithValue(input.Subject);
            check.Parameters.AddWithValue(input.Id);
            check.Parameters.AddWithValue(input.Name);
            if (!(bool)(await check.ExecuteScalarAsync(token))!) return false;
        }
        await using (var command = new NpgsqlCommand("INSERT INTO libraries(id,name) VALUES($1,$2) ON CONFLICT DO NOTHING", connection, transaction))
        {
            command.Parameters.AddWithValue(input.Id);
            command.Parameters.AddWithValue(input.Name);
            await command.ExecuteNonQueryAsync(token);
        }
        await using (var command = new NpgsqlCommand("INSERT INTO library_members(subject,library_id) VALUES($1,$2) ON CONFLICT DO NOTHING", connection, transaction))
        {
            command.Parameters.AddWithValue(input.Subject);
            command.Parameters.AddWithValue(input.Id);
            await command.ExecuteNonQueryAsync(token);
        }
        await transaction.CommitAsync(token);
        return true;
    }
}
