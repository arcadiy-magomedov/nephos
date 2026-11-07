using System.Data;
using Npgsql;
using NpgsqlTypes;

namespace Nephos.Library.Api.Administration;

public sealed partial class PostgresAdministrationRepository
{
    public async Task<AdminSummary> SummaryAsync(CancellationToken token)
    {
        await using var connection = await OpenAsync(token);
        await using var query = Command(connection, null, """
            SELECT now(),(SELECT count(*) FROM principals),(SELECT count(*) FROM principals WHERE enabled),
              (SELECT count(*) FROM libraries),(SELECT count(*) FROM assets WHERE purged_at IS NULL),
              (SELECT coalesce(sum(size),0)::bigint FROM assets WHERE purged_at IS NULL),
              (SELECT count(*) FROM administration_operations WHERE status IN ('pending','running')),
              (SELECT count(*) FROM administration_operations WHERE status='failed'),
              (SELECT count(*) FROM face_publications WHERE delivered_at IS NULL),
              (SELECT max(identity_synced_at) FROM principals)
            """);
        await using var r = await query.ExecuteReaderAsync(token);
        await r.ReadAsync(token);
        return new(r.GetFieldValue<DateTimeOffset>(0), r.GetInt64(1), r.GetInt64(2), r.GetInt64(3),
            r.GetInt64(4), r.GetInt64(5), r.GetInt64(6), r.GetInt64(7), r.GetInt64(8),
            r.IsDBNull(9) ? null : r.GetFieldValue<DateTimeOffset>(9));
    }
    private const string UserSelect = """
        SELECT p.subject,p.login,p.display_name,p.enabled,p.discoverable,p.admin_revision,
          pl.library_id,(SELECT status FROM administration_operations o WHERE o.subject=p.subject
          AND o.status NOT IN ('completed','abandoned') ORDER BY created_at DESC LIMIT 1),p.identity_revision
        FROM principals p LEFT JOIN personal_libraries pl ON pl.subject=p.subject
        """;
    private const string LibrarySelect = """
        SELECT l.id,l.name,l.owner_subject,p.login,p.display_name,l.admin_revision,
          (SELECT count(*) FROM library_members m WHERE m.library_id=l.id),
          (SELECT count(*) FROM assets a WHERE a.library_id=l.id AND a.purged_at IS NULL),
          (SELECT coalesce(sum(a.size),0)::bigint FROM assets a WHERE a.library_id=l.id AND a.purged_at IS NULL)
        FROM libraries l LEFT JOIN principals p ON p.subject=l.owner_subject
        """;
    private static AdminUser ReadUser(NpgsqlDataReader r) => new(r.GetString(0), Text(r, 1), Text(r, 2),
        r.GetBoolean(3), r.GetBoolean(4), r.GetInt64(5), r.IsDBNull(6) ? null : r.GetGuid(6), Text(r, 7), r.GetInt64(8));
    private static AdminLibrary ReadLibrary(NpgsqlDataReader r) => new(r.GetGuid(0), r.GetString(1), Text(r, 2),
        Text(r, 3), Text(r, 4), r.GetInt64(5), r.GetInt64(6), r.GetInt64(7), r.GetInt64(8));
    private static string? Text(NpgsqlDataReader r, int index) => r.IsDBNull(index) ? null : r.GetString(index);
    private static string Search(string? value) => "%" + (value ?? "").Replace("\\", "\\\\", StringComparison.Ordinal)
        .Replace("%", "\\%", StringComparison.Ordinal).Replace("_", "\\_", StringComparison.Ordinal) + "%";
    private static NpgsqlCommand Command(NpgsqlConnection connection, NpgsqlTransaction? transaction, string sql, params object?[] values)
    {
        var command = new NpgsqlCommand(System.Text.RegularExpressions.Regex.Replace(sql, @"\$(\d+)", "@p$1"), connection, transaction);
        for (var i = 0; i < values.Length; i++)
            command.Parameters.Add(values[i] is null
                ? new NpgsqlParameter("p" + (i + 1), NpgsqlDbType.Text) { Value = DBNull.Value }
                : new NpgsqlParameter("p" + (i + 1), values[i]!));
        return command;
    }
    public async Task<AdminPage<AdminUser>> UsersAsync(string? search, bool? enabled, string? cursor, int limit, CancellationToken token)
    {
        await using var connection = await OpenAsync(token);
        await using var tx = await connection.BeginTransactionAsync(IsolationLevel.RepeatableRead, token);
        const string filter = " WHERE (p.login ILIKE $1 OR p.display_name ILIKE $1 OR p.subject ILIKE $1) AND ($2::boolean IS NULL OR p.enabled=$2)";
        var items = new List<AdminUser>();
        await using (var query = Command(connection, tx, UserSelect + filter + " AND ($3::text IS NULL OR p.subject>$3) ORDER BY p.subject LIMIT $4", Search(search), enabled?.ToString(), cursor, limit + 1))
        {
            query.Parameters[1].NpgsqlDbType = NpgsqlDbType.Boolean;
            query.Parameters[1].Value = (object?)enabled ?? DBNull.Value;
            await using var r = await query.ExecuteReaderAsync(token);
            while (await r.ReadAsync(token)) items.Add(ReadUser(r));
        }
        await using var count = Command(connection, tx, "SELECT count(*) FROM principals p" + filter, Search(search), null);
        count.Parameters[1].NpgsqlDbType = NpgsqlDbType.Boolean;
        count.Parameters[1].Value = (object?)enabled ?? DBNull.Value;
        var total = (long)(await count.ExecuteScalarAsync(token))!;
        await tx.CommitAsync(token);
        return new(items.Take(limit).ToArray(), items.Count > limit ? items[limit - 1].Subject : null, total);
    }
    public async Task<AdminPage<AdminLibrary>> LibrariesAsync(string? search, string? cursor, int limit, CancellationToken token)
    {
        await using var connection = await OpenAsync(token);
        await using var tx = await connection.BeginTransactionAsync(IsolationLevel.RepeatableRead, token);
        const string filter = " WHERE (l.name ILIKE $1 OR p.login ILIKE $1 OR p.display_name ILIKE $1)";
        var items = new List<AdminLibrary>();
        await using (var query = Command(connection, tx, LibrarySelect + filter + " AND ($2::text IS NULL OR l.id::text>$2) ORDER BY l.id::text LIMIT $3", Search(search), cursor, limit + 1))
        await using (var r = await query.ExecuteReaderAsync(token))
            while (await r.ReadAsync(token)) items.Add(ReadLibrary(r));
        await using var count = Command(connection, tx, "SELECT count(*) FROM libraries l LEFT JOIN principals p ON p.subject=l.owner_subject" + filter, Search(search));
        var total = (long)(await count.ExecuteScalarAsync(token))!;
        await tx.CommitAsync(token);
        return new(items.Take(limit).ToArray(), items.Count > limit ? items[limit - 1].Id.ToString() : null, total);
    }
    public async Task<AdminUserDetail?> UserAsync(string subject, CancellationToken token)
    {
        await using var connection = await OpenAsync(token);
        await using var tx = await connection.BeginTransactionAsync(IsolationLevel.RepeatableRead, token);
        AdminUser user;
        await using (var query = Command(connection, tx, UserSelect + " WHERE p.subject=$1", subject))
        await using (var r = await query.ExecuteReaderAsync(token))
        {
            if (!await r.ReadAsync(token)) return null;
            user = ReadUser(r);
        }
        var libraries = new List<AdminLibrary>();
        await using (var query = Command(connection, tx, LibrarySelect + " " + """
            WHERE EXISTS(SELECT 1 FROM library_members m WHERE m.library_id=l.id AND m.subject=$1)
            OR EXISTS(SELECT 1 FROM shares s WHERE s.library_id=l.id AND s.recipient_subject=$1)
            ORDER BY l.name,l.id
            """, subject))
        await using (var r = await query.ExecuteReaderAsync(token))
            while (await r.ReadAsync(token)) libraries.Add(ReadLibrary(r));
        var memberships = new List<AdminMembership>();
        await using (var query = Command(connection, tx, """
            SELECT l.id,l.name,'member',true,true,true,NULL::bigint
            FROM library_members m JOIN libraries l ON l.id=m.library_id WHERE m.subject=$1
            UNION ALL
            SELECT l.id,l.name,'share',false,false,s.all_assets,
              (SELECT count(*) FROM share_items i WHERE i.share_id=s.id)
            FROM shares s JOIN libraries l ON l.id=s.library_id WHERE s.recipient_subject=$1
            ORDER BY 2,1,3
            """, subject))
        await using (var r = await query.ExecuteReaderAsync(token))
            while (await r.ReadAsync(token)) memberships.Add(new(r.GetGuid(0), r.GetString(1), r.GetString(2),
                r.GetBoolean(3), r.GetBoolean(4), r.GetBoolean(5), r.IsDBNull(6) ? null : r.GetInt64(6)));
        await tx.CommitAsync(token);
        return new(user, libraries, memberships);
    }
    public async Task<AdminLibraryDetail?> LibraryAsync(Guid id, CancellationToken token)
    {
        await using var connection = await OpenAsync(token);
        await using var tx = await connection.BeginTransactionAsync(IsolationLevel.RepeatableRead, token);
        AdminLibrary library;
        await using (var query = Command(connection, tx, LibrarySelect + " WHERE l.id=$1", id))
        await using (var r = await query.ExecuteReaderAsync(token))
        {
            if (!await r.ReadAsync(token)) return null;
            library = ReadLibrary(r);
        }
        var members = new List<AdminMember>();
        await using (var query = Command(connection, tx, """
            SELECT p.subject,p.login,p.display_name,p.enabled,'member',true,true,true,NULL::bigint
            FROM library_members m JOIN principals p ON p.subject=m.subject WHERE m.library_id=$1
            UNION ALL
            SELECT p.subject,p.login,p.display_name,p.enabled,'share',false,false,s.all_assets,
              (SELECT count(*) FROM share_items i WHERE i.share_id=s.id)
            FROM shares s JOIN principals p ON p.subject=s.recipient_subject WHERE s.library_id=$1
            ORDER BY 1,5
            """, id))
        await using (var r = await query.ExecuteReaderAsync(token))
            while (await r.ReadAsync(token)) members.Add(new(r.GetString(0), Text(r, 1), Text(r, 2),
                r.GetBoolean(3), r.GetString(4), r.GetBoolean(5), r.GetBoolean(6), r.GetBoolean(7), r.IsDBNull(8) ? null : r.GetInt64(8)));
        await tx.CommitAsync(token);
        return new(library, members);
    }
    public async Task SyncAsync(IdentitySync input, CancellationToken token)
    {
        await using var connection = await OpenAsync(token);
        await using var tx = await connection.BeginTransactionAsync(token);
        foreach (var identity in input.Items.OrderBy(i => i.Subject, StringComparer.Ordinal))
        {
            await using (var principalLock = Command(connection, tx, "SELECT subject FROM principals WHERE subject=$1 FOR UPDATE", identity.Subject))
                await principalLock.ExecuteNonQueryAsync(token);
            await using var query = Command(connection, tx, """
                INSERT INTO principals(subject,login,display_name,enabled,identity_revision,identity_synced_at)
                SELECT $1,$2,$3,$4,$5,now() WHERE NOT EXISTS(SELECT 1 FROM administration_operations WHERE subject=$1 AND status NOT IN ('completed','abandoned'))
                ON CONFLICT(subject) DO UPDATE SET
                  login=EXCLUDED.login,display_name=EXCLUDED.display_name,enabled=EXCLUDED.enabled AND NOT principals.administration_denied,
                  identity_revision=EXCLUDED.identity_revision,identity_synced_at=now(),
                  admin_revision=principals.admin_revision+CASE WHEN
                    (principals.display_name,principals.enabled,principals.login) IS DISTINCT FROM
                    (EXCLUDED.display_name,EXCLUDED.enabled AND NOT principals.administration_denied,EXCLUDED.login) THEN 1 ELSE 0 END,
                  access_generation=principals.access_generation+CASE WHEN principals.enabled<>(EXCLUDED.enabled AND NOT principals.administration_denied) THEN 1 ELSE 0 END
                WHERE (principals.login IS NULL OR principals.login=EXCLUDED.login)
                  AND principals.identity_revision<=EXCLUDED.identity_revision
                  AND NOT EXISTS(SELECT 1 FROM administration_operations WHERE subject=$1 AND status NOT IN ('completed','abandoned'))
                """, identity.Subject, identity.Login.ToLowerInvariant(), identity.DisplayName, identity.Enabled, identity.Revision);
            var changed = await query.ExecuteNonQueryAsync(token);
            if (changed > 0 && !identity.Enabled)
            {
                await using var invalidate = Command(connection, tx, """
                    UPDATE principals SET share_generation=share_generation+1
                    WHERE subject IN(SELECT recipient_subject FROM shares WHERE owner_subject=$1)
                    """, identity.Subject);
                await invalidate.ExecuteNonQueryAsync(token);
            }
            await using var verify = Command(connection, tx, "SELECT login IS NULL OR lower(login)=lower($2) FROM principals WHERE subject=$1", identity.Subject, identity.Login);
            if (Equals(await verify.ExecuteScalarAsync(token), false)) throw new AdministrationConflictException("Login is immutable.");
        }
        await tx.CommitAsync(token);
    }
    public async Task<bool> RenameAsync(Guid id, LibraryRename input, CancellationToken token)
    {
        await using var connection = await OpenAsync(token);
        await using var query = Command(connection, null, """
            UPDATE libraries SET name=$2,admin_revision=admin_revision+CASE WHEN name=$2 THEN 0 ELSE 1 END
            WHERE id=$1 AND (admin_revision=$3 OR (admin_revision=$3+1 AND name=$2))
            """, id, input.Name.Trim(), input.ExpectedRevision);
        if (await query.ExecuteNonQueryAsync(token) != 0) return true;
        await using var exists = Command(connection, null, "SELECT EXISTS(SELECT 1 FROM libraries WHERE id=$1)", id);
        if (Equals(await exists.ExecuteScalarAsync(token), true)) throw new AdministrationConflictException("Library revision changed.");
        return false;
    }
    public async Task<bool> AssignOwnerAsync(Guid id, LibraryOwnerAssign input, CancellationToken token)
    {
        await using var connection = await OpenAsync(token);
        await using var tx = await connection.BeginTransactionAsync(token);
        string? owner;
        long revision;
        await using (var lockLibrary = Command(connection, tx, "SELECT owner_subject,admin_revision FROM libraries WHERE id=$1 FOR UPDATE", id))
        await using (var r = await lockLibrary.ExecuteReaderAsync(token))
        {
            if (!await r.ReadAsync(token)) return false;
            owner = Text(r, 0);
            revision = r.GetInt64(1);
        }
        if (owner is not null && owner != input.Subject)
            throw new AdministrationConflictException("Ownership transfer is not permitted.");
        if (revision != input.ExpectedRevision && !(owner == input.Subject && revision == input.ExpectedRevision + 1))
            throw new AdministrationConflictException("Library revision changed.");
        await using (var member = Command(connection, tx, """
            SELECT EXISTS(SELECT 1 FROM library_members WHERE library_id=$1 AND subject=$2)
              AND NOT EXISTS(SELECT 1 FROM administration_operations WHERE subject=$2 AND status NOT IN ('completed','abandoned'))
            """, id, input.Subject))
            if (!Equals(await member.ExecuteScalarAsync(token), true))
                throw new AdministrationConflictException("Initial owner must be an existing provisioned library member.");
        if (input.Personal)
        {
            await using var mapping = Command(connection, tx, """
                INSERT INTO personal_libraries(subject,library_id) VALUES($1,$2)
                ON CONFLICT(subject) DO NOTHING;
                SELECT library_id=$2 FROM personal_libraries WHERE subject=$1
                """, input.Subject, id);
            if (!Equals(await mapping.ExecuteScalarAsync(token), true))
                throw new AdministrationConflictException("Principal already has a different personal library.");
        }
        await using (var assign = Command(connection, tx, """
            UPDATE libraries SET owner_subject=$2,admin_revision=admin_revision+CASE WHEN owner_subject IS NULL THEN 1 ELSE 0 END
            WHERE id=$1
            """, id, input.Subject))
            await assign.ExecuteNonQueryAsync(token);
        await tx.CommitAsync(token);
        return true;
    }
}
