using Nephos.Library.Api.Libraries;
using Npgsql;

namespace Nephos.Library.Api.Administration;

public interface IAdministrationRepository
{
    Task<AdministrationState> ReadAsync(CancellationToken token);
    Task<AdminSummary> SummaryAsync(CancellationToken token);
    Task SetPrincipalAsync(PrincipalUpdate update, CancellationToken token);
    Task<bool> CreateLibraryAsync(LibraryCreate input, CancellationToken token);
    Task<AdminPage<AdminUser>> UsersAsync(string? search, bool? enabled, string? cursor, int limit, CancellationToken token);
    Task<AdminUserDetail?> UserAsync(string subject, CancellationToken token);
    Task<AdminPage<AdminLibrary>> LibrariesAsync(string? search, string? cursor, int limit, CancellationToken token);
    Task<AdminLibraryDetail?> LibraryAsync(Guid id, CancellationToken token);
    Task SyncAsync(IdentitySync input, CancellationToken token);
    Task<bool> RenameAsync(Guid id, LibraryRename input, CancellationToken token);
    Task<bool> AssignOwnerAsync(Guid id, LibraryOwnerAssign input, CancellationToken token);
    Task<AdminOperation> ProvisionAsync(ProvisionCommand input, CancellationToken token, string? operatorSubject = null);
    Task<AdminOperation> ProfileAsync(string subject, ProfileCommand input, CancellationToken token, string? operatorSubject = null);
    Task<AdminOperation> AccessAsync(string subject, AccessCommand input, CancellationToken token, string? operatorSubject = null);
    Task<AdminOperation?> OperationAsync(Guid id, CancellationToken token);
    Task<AdminPage<AdminOperation>> OperationsAsync(string? status, string? cursor, int limit, CancellationToken token);
    Task<bool> RetryAsync(Guid id, CancellationToken token, string? operatorSubject = null);
    Task<AdminOperation?> AbandonAsync(Guid id, string operatorSubject, CancellationToken token);
    Task<AdminOperation?> ClaimAsync(CancellationToken token);
    Task AdvanceAsync(AdminOperation operation, string step, long providerRevision, CancellationToken token);
    Task FailAsync(AdminOperation operation, string code, bool retryable, CancellationToken token);
    Task RebaseAsync(AdminOperation operation, long providerRevision, CancellationToken token);
}

public sealed partial class PostgresAdministrationRepository(IConfiguration configuration) : IAdministrationRepository, IAsyncDisposable
{
    private readonly NpgsqlDataSource source = NpgsqlDataSource.Create(configuration.GetConnectionString("LibraryAdmin")
        ?? throw new InvalidOperationException("ConnectionStrings:LibraryAdmin is required."));
    private async Task<NpgsqlConnection> OpenAsync(CancellationToken token) => await source.OpenConnectionAsync(token);
    public ValueTask DisposeAsync() => source.DisposeAsync();

    public async Task<AdministrationState> ReadAsync(CancellationToken token)
    {
        await using var connection = await OpenAsync(token);
        await using var transaction = await connection.BeginTransactionAsync(System.Data.IsolationLevel.RepeatableRead, token);
        var principals = new List<PrincipalUpdate>();
        var libraries = new List<LibrarySummary>();
        await using (var query = new NpgsqlCommand("SELECT subject,enabled,display_name,discoverable FROM principals ORDER BY subject LIMIT 1000", connection, transaction))
        await using (var reader = await query.ExecuteReaderAsync(token))
            while (await reader.ReadAsync(token)) principals.Add(new(reader.GetString(0), reader.GetBoolean(1),
                reader.IsDBNull(2) ? null : reader.GetString(2), reader.GetBoolean(3)));
        await using (var query = new NpgsqlCommand("SELECT id,name FROM libraries ORDER BY name,id LIMIT 1000", connection, transaction))
        await using (var reader = await query.ExecuteReaderAsync(token))
            while (await reader.ReadAsync(token)) libraries.Add(new(reader.GetGuid(0), reader.GetString(1)));
        await using var count = new NpgsqlCommand("SELECT (SELECT count(*) FROM principals),(SELECT count(*) FROM libraries)", connection, transaction);
        long principalTotal;
        long libraryTotal;
        await using (var reader = await count.ExecuteReaderAsync(token))
        {
            await reader.ReadAsync(token);
            principalTotal = reader.GetInt64(0);
            libraryTotal = reader.GetInt64(1);
        }
        await transaction.CommitAsync(token);
        return new(principals, libraries, principalTotal, libraryTotal, principalTotal > principals.Count || libraryTotal > libraries.Count);
    }

    public async Task SetPrincipalAsync(PrincipalUpdate update, CancellationToken token)
    {
        await using var connection = await OpenAsync(token);
        await using var transaction = await connection.BeginTransactionAsync(token);
        await using (var principalLock = new NpgsqlCommand("SELECT subject FROM principals WHERE subject=$1 FOR UPDATE", connection, transaction))
        {
            principalLock.Parameters.AddWithValue(update.Subject);
            await principalLock.ExecuteNonQueryAsync(token);
        }
        await using (var guard = new NpgsqlCommand("SELECT EXISTS(SELECT 1 FROM administration_operations WHERE subject=$1 AND status NOT IN ('completed','abandoned'))", connection, transaction))
        {
            guard.Parameters.AddWithValue(update.Subject);
            if (Equals(await guard.ExecuteScalarAsync(token), true)) throw new AdministrationConflictException("Principal has an unfinished operation.");
        }
        await using var command = new NpgsqlCommand("""
            INSERT INTO principals(subject,enabled,display_name,discoverable,administration_denied) VALUES($1,$2,$3,coalesce($4,false),NOT $2)
            ON CONFLICT(subject) DO UPDATE SET enabled=EXCLUDED.enabled,access_generation=principals.access_generation+1,
              administration_denied=EXCLUDED.administration_denied,
              admin_revision=principals.admin_revision+1,
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
        await using (var principalLock = new NpgsqlCommand("SELECT subject FROM principals WHERE subject=$1 FOR UPDATE", connection, transaction))
        {
            principalLock.Parameters.AddWithValue(input.Subject);
            await principalLock.ExecuteNonQueryAsync(token);
        }
        await using (var check = new NpgsqlCommand("""
            SELECT EXISTS(SELECT 1 FROM principals WHERE subject=$1) AND
            NOT EXISTS(SELECT 1 FROM administration_operations WHERE subject=$1 AND status NOT IN ('completed','abandoned')) AND
            NOT EXISTS(SELECT 1 FROM libraries WHERE id=$2 AND
              (creation_name IS DISTINCT FROM $3 OR owner_subject IS DISTINCT FROM $1))
            """, connection, transaction))
        {
            check.Parameters.AddWithValue(input.Subject);
            check.Parameters.AddWithValue(input.Id);
            check.Parameters.AddWithValue(input.Name);
            if (!(bool)(await check.ExecuteScalarAsync(token))!) return false;
        }
        await using (var command = new NpgsqlCommand("INSERT INTO libraries(id,name,creation_name,owner_subject) VALUES($1,$2,$2,$3) ON CONFLICT DO NOTHING", connection, transaction))
        {
            command.Parameters.AddWithValue(input.Id);
            command.Parameters.AddWithValue(input.Name);
            command.Parameters.AddWithValue(input.Subject);
            if (await command.ExecuteNonQueryAsync(token) == 0)
            {
                await using var verify = new NpgsqlCommand("SELECT creation_name=$2 AND owner_subject=$3 FROM libraries WHERE id=$1", connection, transaction);
                verify.Parameters.AddWithValue(input.Id);
                verify.Parameters.AddWithValue(input.Name);
                verify.Parameters.AddWithValue(input.Subject);
                if (!Equals(await verify.ExecuteScalarAsync(token), true)) return false;
            }
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
