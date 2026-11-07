using System.Security.Cryptography;
using System.Text.Json;
using Npgsql;

namespace Nephos.Library.Api.Administration;

public sealed partial class PostgresAdministrationRepository
{
    private const string OperationColumns = """
        id,kind,request_hash,login,subject,library_id,display_name,discoverable,library_name,desired_enabled,
        expected_revision,provider_revision,step,status,revision,attempts,error_code,lease_id,created_at,updated_at,operator_subject
        """;
    private static AdminOperation ReadOperation(NpgsqlDataReader r) => new(r.GetGuid(0), r.GetString(1),
        r.GetString(2), Text(r, 3), r.GetString(4), r.IsDBNull(5) ? null : r.GetGuid(5), Text(r, 6),
        r.GetBoolean(7), Text(r, 8), r.GetBoolean(9), r.IsDBNull(10) ? null : r.GetInt64(10),
        r.GetInt64(11), r.GetString(12), r.GetString(13), r.GetInt64(14), r.GetInt32(15), Text(r, 16),
        r.IsDBNull(17) ? null : r.GetGuid(17), r.GetFieldValue<DateTimeOffset>(18), r.GetFieldValue<DateTimeOffset>(19), Text(r, 20));
    private static string Hash(object request) => Convert.ToHexString(SHA256.HashData(JsonSerializer.SerializeToUtf8Bytes(request))).ToLowerInvariant();
    private static async Task<AdminOperation?> FindOperation(NpgsqlConnection connection, NpgsqlTransaction? tx, Guid id, CancellationToken token)
    {
        await using var query = Command(connection, tx, "SELECT " + OperationColumns + " FROM administration_operations WHERE id=$1", id);
        await using var r = await query.ExecuteReaderAsync(token);
        return await r.ReadAsync(token) ? ReadOperation(r) : null;
    }
    public async Task<AdminOperation?> OperationAsync(Guid id, CancellationToken token)
    {
        await using var connection = await OpenAsync(token);
        return await FindOperation(connection, null, id, token);
    }
    public async Task<AdminPage<AdminOperation>> OperationsAsync(string? status, string? cursor, int limit, CancellationToken token)
    {
        await using var connection = await OpenAsync(token);
        await using var tx = await connection.BeginTransactionAsync(System.Data.IsolationLevel.RepeatableRead, token);
        var rows = new List<AdminOperation>();
        await using (var query = Command(connection, tx, "SELECT " + OperationColumns + " " + """
            FROM administration_operations WHERE ($1::text IS NULL OR status=$1)
            AND ($2::text IS NULL OR id::text>$2) ORDER BY id::text LIMIT $3
            """, status, cursor, limit + 1))
        await using (var r = await query.ExecuteReaderAsync(token))
            while (await r.ReadAsync(token)) rows.Add(ReadOperation(r));
        await using var count = Command(connection, tx, "SELECT count(*) FROM administration_operations WHERE ($1::text IS NULL OR status=$1)", status);
        var total = (long)(await count.ExecuteScalarAsync(token))!;
        await tx.CommitAsync(token);
        return new(rows.Take(limit).ToArray(), rows.Count > limit ? rows[limit - 1].Id.ToString() : null, total);
    }
    public async Task<AdminOperation> ProvisionAsync(ProvisionCommand input, CancellationToken token, string? operatorSubject = null)
    {
        input = input with { Login = input.Login.Trim().ToLowerInvariant(), DisplayName = input.DisplayName.Trim(), LibraryName = input.LibraryName.Trim() };
        var hash = Hash(input);
        await using var connection = await OpenAsync(token);
        await using var tx = await connection.BeginTransactionAsync(token);
        // Command and login reservations serialize independent callers, including
        // a second process retrying a response lost after commit.
        await using (var mutex = Command(connection, tx, "SELECT pg_advisory_xact_lock(hashtextextended($1,0)); SELECT pg_advisory_xact_lock(hashtextextended($2,1))", input.Id.ToString(), input.Login))
            await mutex.ExecuteNonQueryAsync(token);
        var existing = await FindOperation(connection, tx, input.Id, token);
        if (existing is not null)
        {
            if (existing.RequestHash != hash || existing.OperatorSubject != operatorSubject) throw new AdministrationConflictException("Command ID is bound to a different request or operator.");
            return existing;
        }
        await using (var check = Command(connection, tx, """
            SELECT EXISTS(SELECT 1 FROM principals WHERE lower(login)=$1)
            OR EXISTS(SELECT 1 FROM administration_operations WHERE lower(login)=$1 AND kind='provision')
            """, input.Login))
            if (Equals(await check.ExecuteScalarAsync(token), true)) throw new AdministrationConflictException("Login is already reserved.");
        var subject = Guid.NewGuid().ToString();
        var libraryId = Guid.NewGuid();
        await using (var insert = Command(connection, tx, """
            INSERT INTO administration_operations(id,kind,request_hash,login,subject,library_id,display_name,discoverable,library_name)
            VALUES($1,'provision',$2,$3,$4,$5,$6,$7,$8)
            """, input.Id, hash, input.Login, subject, libraryId, input.DisplayName, input.Discoverable, input.LibraryName))
            await insert.ExecuteNonQueryAsync(token);
        var result = (await FindOperation(connection, tx, input.Id, token))!;
        await Attribute(connection, tx, input.Id, operatorSubject, "accepted", token);
        result = result with { OperatorSubject = operatorSubject };
        await tx.CommitAsync(token);
        return result;
    }
    public Task<AdminOperation> ProfileAsync(string subject, ProfileCommand input, CancellationToken token, string? operatorSubject = null) =>
        ReserveChange(subject, input.CommandId, "profile", Hash(input with { DisplayName = input.DisplayName.Trim() }),
            input.ExpectedRevision, input.DisplayName.Trim(), input.Discoverable, null, token, operatorSubject);
    public Task<AdminOperation> AccessAsync(string subject, AccessCommand input, CancellationToken token, string? operatorSubject = null) =>
        ReserveChange(subject, input.CommandId, "access", Hash(input), input.ExpectedRevision, null, null, input.Enabled, token, operatorSubject);
    private async Task<AdminOperation> ReserveChange(string subject, Guid id, string kind, string hash, long revision,
        string? displayName, bool? discoverable, bool? enabled, CancellationToken token, string? operatorSubject)
    {
        hash = Hash(new { subject, requestHash = hash });
        await using var connection = await OpenAsync(token);
        await using var tx = await connection.BeginTransactionAsync(token);
        await using (var mutex = Command(connection, tx, "SELECT pg_advisory_xact_lock(hashtextextended($1,0))", id.ToString()))
            await mutex.ExecuteNonQueryAsync(token);
        var existing = await FindOperation(connection, tx, id, token);
        if (existing is not null)
        {
            if (existing.RequestHash != hash || existing.OperatorSubject != operatorSubject) throw new AdministrationConflictException("Command ID is bound to a different request or operator.");
            return existing;
        }
        AdminUser user;
        await using (var query = Command(connection, tx, UserSelect + " WHERE p.subject=$1 FOR UPDATE OF p", subject))
        await using (var r = await query.ExecuteReaderAsync(token))
        {
            if (!await r.ReadAsync(token)) throw new AdministrationConflictException("Principal is not provisioned.");
            user = ReadUser(r);
        }
        if (user.Revision != revision || user.ProvisioningStatus is not null)
            throw new AdministrationConflictException("Principal revision changed or an operation is unfinished.");
        await using (var insert = Command(connection, tx, """
            INSERT INTO administration_operations(id,kind,request_hash,subject,display_name,discoverable,desired_enabled,expected_revision,provider_revision)
            VALUES($1,$2,$3,$4,$5,$6,$7,$8,$9)
            """, id, kind, hash, subject, displayName ?? user.DisplayName, discoverable ?? user.Discoverable,
                enabled ?? user.Enabled, revision, user.IdentityRevision))
            await insert.ExecuteNonQueryAsync(token);
        if (enabled is not null)
        {
            await using var disable = Command(connection, tx, """
                UPDATE principals SET enabled=false,administration_denied=true,access_generation=access_generation+1,admin_revision=admin_revision+1 WHERE subject=$1;
                UPDATE principals SET share_generation=share_generation+1 WHERE subject IN(SELECT recipient_subject FROM shares WHERE owner_subject=$1)
                """, subject);
            await disable.ExecuteNonQueryAsync(token);
        }
        var result = (await FindOperation(connection, tx, id, token))!;
        await Attribute(connection, tx, id, operatorSubject, "accepted", token);
        result = result with { OperatorSubject = operatorSubject };
        await tx.CommitAsync(token);
        return result;
    }
    public async Task<bool> RetryAsync(Guid id, CancellationToken token, string? operatorSubject = null)
    {
        await using var connection = await OpenAsync(token);
        await using var tx = await connection.BeginTransactionAsync(token);
        await using var query = Command(connection, tx, """
            UPDATE administration_operations SET status='pending',next_attempt_at=now(),
              step=CASE WHEN kind='access' AND desired_enabled THEN 'reserved' ELSE step END,
              provider_revision=CASE WHEN kind<>'provision' AND error_code IN ('identity_conflict','revision_conflict')
                THEN -1 ELSE provider_revision END,error_code=NULL,
              revision=revision+1,updated_at=now() WHERE id=$1 AND status='failed' AND lease_id IS NULL
            """, id);
        if (await query.ExecuteNonQueryAsync(token) > 0)
        {
            await using var audit = Command(connection, tx, "INSERT INTO administration_events(operation_id,operator_subject,action) VALUES($1,$2,'retry-requested')", id, operatorSubject);
            await audit.ExecuteNonQueryAsync(token);
            await tx.CommitAsync(token);
            return true;
        }
        await using var exists = Command(connection, tx, "SELECT status FROM administration_operations WHERE id=$1", id);
        var status = (string?)await exists.ExecuteScalarAsync(token);
        if (status == "abandoned") throw new AdministrationConflictException("Abandoned operation cannot be retried.");
        return status is not null;
    }
    public async Task<AdminOperation?> AbandonAsync(Guid id, string operatorSubject, CancellationToken token)
    {
        await using var connection = await OpenAsync(token);
        await using var tx = await connection.BeginTransactionAsync(token);
        await using (var query = Command(connection, tx, "SELECT id FROM administration_operations WHERE id=$1 FOR UPDATE", id))
            await query.ExecuteNonQueryAsync(token);
        var operation = await FindOperation(connection, tx, id, token);
        if (operation is null || operation.Status == "abandoned") return operation;
        if (operation.Kind == "provision" || operation.Status != "failed" || operation.LeaseId is not null)
            throw new AdministrationConflictException("Only failed profile/access operations can be abandoned.");
        await using (var abandon = Command(connection, tx, """
            UPDATE administration_operations SET status='abandoned',revision=revision+1,updated_at=now() WHERE id=$1;
            UPDATE principals SET admin_revision=admin_revision+1 WHERE subject=$2;
            INSERT INTO administration_events(operation_id,operator_subject,action) VALUES($1,$3,'abandoned')
            """, id, operation.Subject, operatorSubject))
            await abandon.ExecuteNonQueryAsync(token);
        var result = await FindOperation(connection, tx, id, token);
        await tx.CommitAsync(token);
        return result;
    }
    private static async Task Attribute(NpgsqlConnection connection, NpgsqlTransaction tx, Guid id, string? actor, string action, CancellationToken token)
    {
        await using var attribution = Command(connection, tx, """
            UPDATE administration_operations SET operator_subject=$2 WHERE id=$1;
            INSERT INTO administration_events(operation_id,operator_subject,action) VALUES($1,$2,$3)
            """, id, actor, action);
        await attribution.ExecuteNonQueryAsync(token);
    }
    public async Task<AdminOperation?> ClaimAsync(CancellationToken token)
    {
        await using var connection = await OpenAsync(token);
        await using var query = Command(connection, null, """
            UPDATE administration_operations SET lease_id=$1,lease_until=now()+interval '90 seconds',
              status='running',attempts=attempts+1,revision=revision+1,updated_at=now()
            WHERE id=(SELECT id FROM administration_operations WHERE status IN ('pending','running')
              AND next_attempt_at<=now() AND (lease_until IS NULL OR lease_until<now())
              ORDER BY created_at FOR UPDATE SKIP LOCKED LIMIT 1)
            RETURNING
            """ + " " + OperationColumns, Guid.NewGuid());
        await using var r = await query.ExecuteReaderAsync(token);
        return await r.ReadAsync(token) ? ReadOperation(r) : null;
    }
    public async Task AdvanceAsync(AdminOperation operation, string step, long providerRevision, CancellationToken token)
    {
        var valid = operation.Kind == "provision"
            ? (operation.Step, step) is ("reserved", "identity-created") or ("identity-created", "library-created") or ("library-created", "completed")
            : operation.Kind == "access" && operation.DesiredEnabled
                ? (operation.Step, step) is ("reserved", "identity-created") or ("identity-created", "completed")
                : operation.Step == "reserved" && step == "completed";
        if (!valid) throw new InvalidOperationException("Invalid administration transition.");
        await using var connection = await OpenAsync(token);
        await using var tx = await connection.BeginTransactionAsync(token);
        await using (var guard = Command(connection, tx, """
            SELECT EXISTS(SELECT 1 FROM administration_operations WHERE id=$1 AND lease_id=$2
              AND lease_until>now() AND step=$3 AND status='running' FOR UPDATE)
            """, operation.Id, operation.LeaseId, operation.Step))
            if (!Equals(await guard.ExecuteScalarAsync(token), true)) throw new AdministrationConflictException("Operation lease expired.");
        if (step == "library-created")
        {
            await using var insert = Command(connection, tx, """
                INSERT INTO principals(subject,login,display_name,enabled,discoverable) VALUES($3,$4,$5,false,$6);
                INSERT INTO libraries(id,name,creation_name,owner_subject) VALUES($1,$2,$2,$3);
                INSERT INTO library_members(subject,library_id) VALUES($3,$1);
                INSERT INTO personal_libraries(subject,library_id) VALUES($3,$1);
                """, operation.LibraryId, operation.LibraryName, operation.Subject, operation.Login, operation.DisplayName, operation.Discoverable);
            await insert.ExecuteNonQueryAsync(token);
        }
        if (step == "completed")
        {
            await using var complete = Command(connection, tx, """
                UPDATE principals SET display_name=CASE WHEN $7='access' THEN display_name ELSE $2 END,
                  discoverable=CASE WHEN $7='access' THEN discoverable ELSE $3 END,
                  enabled=CASE WHEN $7='profile' THEN enabled ELSE $4 END,identity_revision=$5,identity_synced_at=now(),
                  administration_denied=CASE WHEN $7='profile' THEN administration_denied ELSE NOT $4 END,
                  admin_revision=greatest(admin_revision,coalesce($6::bigint,admin_revision)+1),
                  access_generation=access_generation+CASE WHEN $7<>'profile' AND enabled<>$4 THEN 1 ELSE 0 END
                WHERE subject=$1;
                UPDATE principals SET share_generation=share_generation+1
                WHERE subject IN(SELECT recipient_subject FROM shares WHERE owner_subject=$1);
                """, operation.Subject, operation.DisplayName, operation.Discoverable, operation.DesiredEnabled,
                    providerRevision, operation.ExpectedRevision, operation.Kind);
            complete.Parameters[5].NpgsqlDbType = NpgsqlTypes.NpgsqlDbType.Bigint;
            complete.Parameters[5].Value = (object?)operation.ExpectedRevision ?? DBNull.Value;
            await complete.ExecuteNonQueryAsync(token);
        }
        await using (var update = Command(connection, tx, """
            UPDATE administration_operations SET step=$3,provider_revision=$4,
              status=CASE WHEN $3='completed' THEN 'completed' ELSE 'pending' END,
              lease_id=NULL,lease_until=NULL,error_code=NULL,next_attempt_at=now(),revision=revision+1,updated_at=now()
              WHERE id=$1 AND lease_id=$2
            """, operation.Id, operation.LeaseId, step, providerRevision))
            await update.ExecuteNonQueryAsync(token);
        await using (var audit = Command(connection, tx, "INSERT INTO administration_events(operation_id,action) VALUES($1,$2)", operation.Id, step))
            await audit.ExecuteNonQueryAsync(token);
        await tx.CommitAsync(token);
    }
    public async Task FailAsync(AdminOperation operation, string code, bool retryable, CancellationToken token)
    {
        var safeCode = code is "identity_unavailable" or "identity_conflict" or "identity_rejected" or "persistence_unavailable" or "revision_conflict"
            ? code : "operation_failed";
        await using var connection = await OpenAsync(token);
        await using var tx = await connection.BeginTransactionAsync(token);
        await using var query = Command(connection, tx, """
            UPDATE administration_operations SET status=$3,error_code=$4,lease_id=NULL,lease_until=NULL,
              next_attempt_at=now()+make_interval(secs=>least(300,power(2,least(attempts,8)))::integer),
              revision=revision+1,updated_at=now() WHERE id=$1 AND lease_id=$2
            """, operation.Id, operation.LeaseId, retryable ? "pending" : "failed", safeCode);
        if (await query.ExecuteNonQueryAsync(token) > 0)
        {
            await using var audit = Command(connection, tx, "INSERT INTO administration_events(operation_id,action,error_code) VALUES($1,'attempt-failed',$2)", operation.Id, safeCode);
            await audit.ExecuteNonQueryAsync(token);
        }
        await tx.CommitAsync(token);
    }
    public async Task RebaseAsync(AdminOperation operation, long providerRevision, CancellationToken token)
    {
        if (providerRevision < 0) throw new ArgumentOutOfRangeException(nameof(providerRevision));
        await using var connection = await OpenAsync(token);
        await using var query = Command(connection, null, """
            UPDATE administration_operations SET provider_revision=$3,revision=revision+1,updated_at=now()
            WHERE id=$1 AND lease_id=$2 AND lease_until>now() AND status='running' AND provider_revision=-1
            """, operation.Id, operation.LeaseId, providerRevision);
        if (await query.ExecuteNonQueryAsync(token) == 0) throw new AdministrationConflictException("Operation lease expired.");
    }
}
