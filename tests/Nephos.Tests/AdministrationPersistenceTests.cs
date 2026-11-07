using System.Net;
using System.Net.Http.Json;
using System.Text.Json;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Logging.Abstractions;
using Nephos.Library.Api.Administration;
using Npgsql;

namespace Nephos.Tests;

[Collection("trash-database")]
public sealed class AdministrationPersistenceTests
{
    private static IConfiguration Config(bool runtime = false)
    {
        var connection = new NpgsqlConnectionStringBuilder(Environment.GetEnvironmentVariable("LIBRARY_TEST_CONNECTION")!);
        if (runtime) connection.Options = "-c role=library_app";
        return new ConfigurationBuilder().AddInMemoryCollection(new Dictionary<string, string?>
        {
            ["ConnectionStrings:LibraryAdmin"] = connection.ConnectionString,
            ["Administration:IdentityUrl"] = "https://identity.test/realms/nephos/nephos-admin",
            ["Administration:IdentityKey"] = "test-only-private-identity-key"
        }).Build();
    }
    private static ProvisionCommand Input() => new(Guid.NewGuid(), "admin-test-" + Guid.NewGuid().ToString("N"), "Example", true, "Personal");
    private static async Task Execute(string sql, params object[] values)
    {
        await using var db = NpgsqlDataSource.Create(Environment.GetEnvironmentVariable("LIBRARY_TEST_CONNECTION")!);
        await using var query = db.CreateCommand(System.Text.RegularExpressions.Regex.Replace(sql, @"\$(\d+)", "@p$1"));
        for (var i = 0; i < values.Length; i++) query.Parameters.AddWithValue("p" + (i + 1), values[i]);
        await query.ExecuteNonQueryAsync();
    }
    private static async Task<AdminOperation> Claim(PostgresAdministrationRepository repository, Guid id)
    {
        // Other tests leave deliberately failed operations, but no runnable ones.
        var operation = await repository.ClaimAsync(default);
        Assert.NotNull(operation);
        Assert.Equal(id, operation.Id);
        return operation;
    }
    private static async Task<AdminUser> Complete(PostgresAdministrationRepository repository, ProvisionCommand input)
    {
        await repository.ProvisionAsync(input, default);
        await repository.AdvanceAsync(await Claim(repository, input.Id), "identity-created", 0, default);
        await repository.AdvanceAsync(await Claim(repository, input.Id), "library-created", 0, default);
        var pending = (await repository.OperationAsync(input.Id, default))!;
        var disabled = (await repository.UserAsync(pending.Subject, default))!;
        Assert.False(disabled.User.Enabled);
        Assert.Equal(pending.LibraryId, disabled.User.PersonalLibraryId);
        Assert.Single(disabled.Libraries);
        await repository.AdvanceAsync(await Claim(repository, input.Id), "completed", 1, default);
        var operation = (await repository.OperationAsync(input.Id, default))!;
        return (await repository.UserAsync(operation.Subject, default))!.User;
    }
    [LibraryDatabaseFact]
    public async Task Additive_migration_preserves_existing_users_libraries_memberships_and_unknown_ownership()
    {
        var root = new DirectoryInfo(AppContext.BaseDirectory);
        while (root is not null && !Directory.Exists(Path.Combine(root.FullName, "src", "Nephos.Migrations"))) root = root.Parent;
        Assert.NotNull(root);
        var migrationDirectory = Path.Combine(root.FullName, "src", "Nephos.Migrations", "Sql", "library");
        var schema = "administration_upgrade_" + Guid.NewGuid().ToString("N");
        await using var db = NpgsqlDataSource.Create(Environment.GetEnvironmentVariable("LIBRARY_TEST_CONNECTION")!);
        await using var connection = await db.OpenConnectionAsync();
        await using var setup = new NpgsqlCommand($"CREATE SCHEMA {schema}; SET search_path={schema}; GRANT USAGE ON SCHEMA {schema} TO library_app", connection);
        await setup.ExecuteNonQueryAsync();
        try
        {
            foreach (var path in Directory.GetFiles(migrationDirectory, "*.sql").Order(StringComparer.Ordinal).Where(p => string.CompareOrdinal(Path.GetFileName(p), "009_") < 0))
            {
                await using var migration = new NpgsqlCommand(await File.ReadAllTextAsync(path), connection);
                await migration.ExecuteNonQueryAsync();
            }
            var owner = Guid.NewGuid().ToString();
            var other = Guid.NewGuid().ToString();
            var personal = Guid.NewGuid();
            var shared = Guid.NewGuid();
            await using (var seed = new NpgsqlCommand($"""
                INSERT INTO principals(subject,enabled,display_name,discoverable) VALUES('{owner}',true,'Existing',true),('{other}',false,'Other',false);
                INSERT INTO libraries(id,name) VALUES('{personal}','Original personal'),('{shared}','Shared historical');
                INSERT INTO library_members(subject,library_id) VALUES('{owner}','{personal}'),('{owner}','{shared}'),('{other}','{shared}');
                """, connection))
                await seed.ExecuteNonQueryAsync();
            await using (var migration = new NpgsqlCommand(await File.ReadAllTextAsync(Path.Combine(migrationDirectory, "009_administration.sql")), connection))
                await migration.ExecuteNonQueryAsync();
            await using (var migration = new NpgsqlCommand(await File.ReadAllTextAsync(Path.Combine(migrationDirectory, "010_administration_attribution.sql")), connection))
                await migration.ExecuteNonQueryAsync();
            await using (var migration = new NpgsqlCommand(await File.ReadAllTextAsync(Path.Combine(migrationDirectory, "011_administration_recovery.sql")), connection))
                await migration.ExecuteNonQueryAsync();
            var config = new NpgsqlConnectionStringBuilder(Environment.GetEnvironmentVariable("LIBRARY_TEST_CONNECTION")!)
            { Options = $"-c role=library_app -c search_path={schema}" };
            var runtime = new ConfigurationBuilder().AddInMemoryCollection(new Dictionary<string, string?>
            { ["ConnectionStrings:LibraryAdmin"] = config.ConnectionString }).Build();
            await using var repository = new PostgresAdministrationRepository(runtime);
            var existing = (await repository.UserAsync(owner, default))!;
            Assert.True(existing.User.Enabled);
            Assert.True(existing.User.Discoverable);
            Assert.Null(existing.User.Login);
            Assert.Equal(personal, existing.User.PersonalLibraryId);
            Assert.Equal(2, existing.Libraries.Count);
            var historical = (await repository.LibraryAsync(shared, default))!;
            Assert.Null(historical.Library.OwnerSubject);
            Assert.Equal(2, historical.Members.Count);
            await Assert.ThrowsAsync<PostgresException>(() => repository.ProvisionAsync(Input(), default));
            var administration = new NpgsqlConnectionStringBuilder(Environment.GetEnvironmentVariable("LIBRARY_TEST_CONNECTION")!)
            { Options = $"-c search_path={schema}" };
            await using var admin = new PostgresAdministrationRepository(new ConfigurationBuilder().AddInMemoryCollection(
                new Dictionary<string, string?> { ["ConnectionStrings:LibraryAdmin"] = administration.ConnectionString }).Build());
            var newPrincipal = await admin.ProvisionAsync(Input(), default);
            Assert.Null(await repository.UserAsync(newPrincipal.Subject, default));
        }
        finally
        {
            await using var cleanup = new NpgsqlCommand($"SET search_path=public; DROP SCHEMA {schema} CASCADE", connection);
            await cleanup.ExecuteNonQueryAsync();
        }
    }
    [LibraryDatabaseFact]
    public async Task Abandoned_stale_profile_allows_corrected_new_command_without_replaying_old_intent()
    {
        await using var repository = new PostgresAdministrationRepository(Config());
        var user = await Complete(repository, Input());
        var stale = await repository.ProfileAsync(user.Subject, new(Guid.NewGuid(), user.Revision, "Stale edit", false), default);
        await repository.FailAsync(await Claim(repository, stale.Id), "identity_conflict", false, default);
        var actor = Guid.NewGuid().ToString();
        Assert.Equal("abandoned", (await repository.AbandonAsync(stale.Id, actor, default))!.Status);
        Assert.Equal("abandoned", (await repository.AbandonAsync(stale.Id, actor, default))!.Status);
        await Assert.ThrowsAsync<AdministrationConflictException>(() => repository.RetryAsync(stale.Id, default));
        var current = (await repository.UserAsync(user.Subject, default))!.User;
        Assert.Null(current.ProvisioningStatus);
        Assert.Equal(user.DisplayName, current.DisplayName);
        await Assert.ThrowsAsync<AdministrationConflictException>(() => repository.ProfileAsync(user.Subject, new(Guid.NewGuid(), user.Revision, "Old form", false), default));
        var corrected = await repository.ProfileAsync(user.Subject, new(Guid.NewGuid(), current.Revision, "Corrected edit", true), default);
        await repository.AdvanceAsync(await Claim(repository, corrected.Id), "completed", 3, default);
        var updated = (await repository.UserAsync(user.Subject, default))!.User;
        Assert.Equal("Corrected edit", updated.DisplayName);
        Assert.True(updated.Enabled);
        Assert.True(updated.Discoverable);
    }
    [LibraryDatabaseFact]
    public async Task Abandoned_disable_keeps_durable_denial_and_explicit_enable_revokes_before_enabling()
    {
        var config = Config();
        await using var repository = new PostgresAdministrationRepository(config);
        var user = await Complete(repository, Input());
        var disable = await repository.AccessAsync(user.Subject, new(Guid.NewGuid(), user.Revision, false), default);
        await repository.FailAsync(await Claim(repository, disable.Id), "identity_conflict", false, default);
        await repository.AbandonAsync(disable.Id, Guid.NewGuid().ToString(), default);
        await repository.SyncAsync(new([new(user.Subject, user.Login!, user.DisplayName, true, 10)]), default);
        var denied = (await repository.UserAsync(user.Subject, default))!.User;
        Assert.False(denied.Enabled);
        Assert.Null(denied.ProvisioningStatus);
        await Assert.ThrowsAsync<AdministrationConflictException>(() => repository.AccessAsync(user.Subject, new(Guid.NewGuid(), user.Revision, true), default));
        var enable = await repository.AccessAsync(user.Subject, new(Guid.NewGuid(), denied.Revision, true), default);
        using var provider = new FencedProvider(user.Subject, 10, true);
        var worker = new AdministrationWorker(repository, provider, config, NullLogger<AdministrationWorker>.Instance);
        Assert.True(await worker.RunOnceAsync(default));
        Assert.False((await repository.UserAsync(user.Subject, default))!.User.Enabled);
        Assert.Equal("identity-created", (await repository.OperationAsync(enable.Id, default))!.Step);
        Assert.True(await worker.RunOnceAsync(default));
        Assert.True((await repository.UserAsync(user.Subject, default))!.User.Enabled);
        Assert.Equal(new[] { false, true }, provider.AccessChanges);
        Assert.Equal(1, provider.Revocations);
        Assert.Equal(2, provider.Commands.Count);
        Assert.Equal("abandoned", (await repository.OperationAsync(disable.Id, default))!.Status);
    }
    private sealed class FencedProvider(string subject, long revision, bool enabled) : HttpMessageHandler, IHttpClientFactory
    {
        public List<bool> AccessChanges { get; } = [];
        public HashSet<Guid> Commands { get; } = [];
        public int Revocations { get; private set; }
        public HttpClient CreateClient(string name) => new(this, disposeHandler: false);
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            Assert.True(request.Headers.Contains("X-Nephos-Identity-Service-Key"));
            if (request.Method == HttpMethod.Put)
            {
                var input = await request.Content!.ReadFromJsonAsync<JsonElement>(cancellationToken);
                if (input.GetProperty("expectedRevision").GetInt64() != revision)
                    return new(HttpStatusCode.Conflict);
                Assert.True(Commands.Add(input.GetProperty("commandId").GetGuid()));
                enabled = input.GetProperty("enabled").GetBoolean();
                if (!enabled) Revocations++;
                AccessChanges.Add(enabled);
                revision++;
            }
            return new(HttpStatusCode.OK) { Content = JsonContent.Create(new { subject, revision, enabled }) };
        }
    }
    [LibraryDatabaseFact]
    public async Task Explicit_conflict_retry_rebases_provider_revision_durably_before_external_mutation()
    {
        var configuration = Config();
        await using var repository = new PostgresAdministrationRepository(configuration);
        var user = await Complete(repository, Input());
        var operation = await repository.AccessAsync(user.Subject, new(Guid.NewGuid(), user.Revision, false), default);
        await repository.FailAsync(await Claim(repository, operation.Id), "identity_conflict", false, default);
        Assert.True(await repository.RetryAsync(operation.Id, default));
        var retry = await Claim(repository, operation.Id);
        Assert.Equal(-1, retry.ProviderRevision);
        await repository.RebaseAsync(retry, 17, default);
        await repository.FailAsync(retry, "identity_unavailable", true, default);
        await Execute("UPDATE administration_operations SET next_attempt_at=now() WHERE id=$1", operation.Id);
        await using var restarted = new PostgresAdministrationRepository(configuration);
        var recovered = await Claim(restarted, operation.Id);
        Assert.Equal(17, recovered.ProviderRevision);
        await restarted.AdvanceAsync(recovered, "completed", 18, default);
        Assert.False((await restarted.UserAsync(user.Subject, default))!.User.Enabled);
        Assert.Equal(18, (await restarted.UserAsync(user.Subject, default))!.User.IdentityRevision);
    }
    [LibraryDatabaseFact]
    public async Task Runtime_role_cannot_mutate_identity_membership_or_operation_audit_and_actor_is_immutable()
    {
        var actor = Guid.NewGuid().ToString();
        var input = Input();
        await using var repository = new PostgresAdministrationRepository(Config());
        var accepted = await repository.ProvisionAsync(input, default, actor);
        Assert.Equal(actor, accepted.OperatorSubject);
        Assert.Equal(actor, (await repository.ProvisionAsync(input, default, actor)).OperatorSubject);
        await Assert.ThrowsAsync<AdministrationConflictException>(() => repository.ProvisionAsync(input, default, Guid.NewGuid().ToString()));
        await repository.AdvanceAsync(await Claim(repository, input.Id), "identity-created", 0, default);
        await repository.AdvanceAsync(await Claim(repository, input.Id), "library-created", 0, default);
        await repository.AdvanceAsync(await Claim(repository, input.Id), "completed", 1, default);
        await using var db = NpgsqlDataSource.Create(Environment.GetEnvironmentVariable("LIBRARY_TEST_CONNECTION")!);
        await using var permissions = db.CreateCommand("""
            SELECT has_table_privilege('library_app','principals','INSERT'),
              has_table_privilege('library_app','principals','UPDATE'),
              has_table_privilege('library_app','libraries','INSERT'),
              has_table_privilege('library_app','library_members','INSERT'),
              has_table_privilege('library_app','administration_operations','UPDATE'),
              has_table_privilege('library_app','administration_events','UPDATE'),
              has_column_privilege('library_app','principals','share_generation','UPDATE')
            """);
        await using (var r = await permissions.ExecuteReaderAsync())
        {
            Assert.True(await r.ReadAsync());
            for (var i = 0; i < 6; i++) Assert.False(r.GetBoolean(i));
            Assert.True(r.GetBoolean(6));
        }
        await using var audit = db.CreateCommand("SELECT count(*),count(*) FILTER(WHERE operator_subject=$2) FROM administration_events WHERE operation_id=$1");
        audit.Parameters.AddWithValue(input.Id);
        audit.Parameters.AddWithValue(actor);
        await using var events = await audit.ExecuteReaderAsync();
        Assert.True(await events.ReadAsync());
        Assert.Equal(4, events.GetInt64(0));
        Assert.Equal(1, events.GetInt64(1));
    }
    [LibraryDatabaseFact]
    public async Task Additive_owner_mapping_cleanup_never_deletes_library_or_other_members()
    {
        await using var repository = new PostgresAdministrationRepository(Config());
        var user = await Complete(repository, Input());
        var library = user.PersonalLibraryId!.Value;
        await Execute("DELETE FROM library_members WHERE subject=$1; DELETE FROM principals WHERE subject=$1", user.Subject);
        var preserved = (await repository.LibraryAsync(library, default))!;
        Assert.Null(preserved.Library.OwnerSubject);
        Assert.Empty(preserved.Members);
        Assert.Null(await repository.UserAsync(user.Subject, default));
    }
    [LibraryDatabaseFact]
    public async Task Initial_owner_assignment_only_maps_existing_members_and_never_transfers_or_replaces_personal_library()
    {
        await using var repository = new PostgresAdministrationRepository(Config());
        var owner = await Complete(repository, Input());
        var other = await Complete(repository, Input());
        var legacy = Guid.NewGuid();
        await Execute("""
            INSERT INTO libraries(id,name,creation_name) VALUES($1,'Legacy multi-member','Legacy multi-member');
            INSERT INTO library_members(subject,library_id) VALUES($2,$1),($3,$1)
            """, legacy, owner.Subject, other.Subject);
        Assert.True(await repository.AssignOwnerAsync(legacy, new(owner.Subject, 0), default));
        Assert.True(await repository.AssignOwnerAsync(legacy, new(owner.Subject, 0), default));
        await Assert.ThrowsAsync<AdministrationConflictException>(() => repository.AssignOwnerAsync(legacy, new(other.Subject, 1), default));
        await Assert.ThrowsAsync<AdministrationConflictException>(() => repository.AssignOwnerAsync(legacy, new(owner.Subject, 1, true), default));
        var detail = (await repository.LibraryAsync(legacy, default))!;
        Assert.Equal(owner.Subject, detail.Library.OwnerSubject);
        Assert.Equal(2, detail.Members.Count);
        Assert.Equal(owner.PersonalLibraryId, (await repository.UserAsync(owner.Subject, default))!.User.PersonalLibraryId);
        await Assert.ThrowsAsync<AdministrationConflictException>(() => repository.AssignOwnerAsync(legacy, new(Guid.NewGuid().ToString(), 1), default));
    }
    [LibraryDatabaseFact]
    public async Task Projection_worker_bootstraps_all_pages_without_service_account_or_session_mock_in_runtime()
    {
        var subject = Guid.NewGuid().ToString();
        var second = Guid.NewGuid().ToString();
        var prefix = "projection-" + Guid.NewGuid().ToString("N");
        var config = Config();
        await using var repository = new PostgresAdministrationRepository(config);
        using var provider = new PagedProvider(
            [new(subject, prefix, "Real legacy", true, 0)],
            [new(second, prefix + "-2", "Disabled legacy", false, 5)]);
        var worker = new IdentityProjectionWorker(repository, provider, config, NullLogger<IdentityProjectionWorker>.Instance);
        await worker.SyncOnceAsync(default);
        Assert.Equal(2, provider.Requests);
        Assert.Equal(2, (await repository.UsersAsync(prefix, null, null, 100, default)).Total);
        Assert.True((await repository.UserAsync(subject, default))!.User.Enabled);
        Assert.False((await repository.UserAsync(second, default))!.User.Enabled);
    }
    private sealed class PagedProvider(IReadOnlyList<IdentityProjection> first, IReadOnlyList<IdentityProjection> second)
        : HttpMessageHandler, IHttpClientFactory
    {
        public int Requests { get; private set; }
        public HttpClient CreateClient(string name) => new(this, disposeHandler: false);
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            Assert.True(request.Headers.Contains("X-Nephos-Identity-Service-Key"));
            Requests++;
            var next = request.RequestUri!.Query.Contains("cursor=", StringComparison.Ordinal);
            return Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK)
            { Content = JsonContent.Create(new AdminPage<IdentityProjection>(next ? second : first, next ? null : first[0].Subject, 2)) });
        }
    }
    [LibraryDatabaseFact]
    public async Task Provisioning_reserves_login_and_identity_once_across_concurrent_processes_and_restart()
    {
        var input = Input();
        await using var repository = new PostgresAdministrationRepository(Config());
        await using var second = new PostgresAdministrationRepository(Config());
        var results = await Task.WhenAll(repository.ProvisionAsync(input, default), second.ProvisionAsync(input, default));
        Assert.Equal(results[0].Subject, results[1].Subject);
        Assert.Equal(results[0].LibraryId, results[1].LibraryId);
        Assert.Null(await repository.UserAsync(results[0].Subject, default));
        await Assert.ThrowsAsync<AdministrationConflictException>(() => repository.ProvisionAsync(input with { LibraryName = "Different" }, default));
        await Assert.ThrowsAsync<AdministrationConflictException>(() => repository.ProvisionAsync(input with { Id = Guid.NewGuid(), Login = input.Login.ToUpperInvariant() }, default));
        var completed = await Complete(second, input);
        Assert.True(completed.Enabled);
        Assert.Equal(results[0].LibraryId, completed.PersonalLibraryId);
        Assert.Single((await second.UserAsync(completed.Subject, default))!.Libraries);
        Assert.Equal("completed", (await repository.OperationAsync(input.Id, default))!.Status);
    }
    [LibraryDatabaseFact]
    public async Task Expired_leases_recover_after_restart_and_stale_claims_cannot_advance()
    {
        var input = Input();
        await using var repository = new PostgresAdministrationRepository(Config());
        await repository.ProvisionAsync(input, default);
        var first = await Claim(repository, input.Id);
        Assert.Null(await repository.ClaimAsync(default));
        await Execute("UPDATE administration_operations SET lease_until=now()-interval '1 second' WHERE id=$1", input.Id);
        await using var restarted = new PostgresAdministrationRepository(Config());
        var recovered = await Claim(restarted, input.Id);
        Assert.NotEqual(first.LeaseId, recovered.LeaseId);
        await Assert.ThrowsAsync<AdministrationConflictException>(() => repository.AdvanceAsync(first, "identity-created", 0, default));
        await repository.AdvanceAsync(recovered, "identity-created", 0, default);
        await repository.AdvanceAsync(await Claim(repository, input.Id), "library-created", 0, default);
        await repository.AdvanceAsync(await Claim(repository, input.Id), "completed", 1, default);
    }
    [LibraryDatabaseFact]
    public async Task Personal_library_transaction_rolls_back_principal_when_reserved_library_id_conflicts()
    {
        var input = Input();
        await using var repository = new PostgresAdministrationRepository(Config());
        var reserved = await repository.ProvisionAsync(input, default);
        await repository.AdvanceAsync(await Claim(repository, input.Id), "identity-created", 0, default);
        await Execute("INSERT INTO libraries(id,name,creation_name) VALUES($1,'Occupied','Occupied')", reserved.LibraryId!.Value);
        var lease = await Claim(repository, input.Id);
        await Assert.ThrowsAsync<PostgresException>(() => repository.AdvanceAsync(lease, "library-created", 0, default));
        Assert.Equal("Occupied", (await repository.LibraryAsync(reserved.LibraryId.Value, default))!.Library.Name);
        Assert.Null(await repository.UserAsync(reserved.Subject, default));
        await repository.FailAsync(lease, "contains-sensitive-provider-response", false, default);
        var failed = (await repository.OperationAsync(input.Id, default))!;
        Assert.Equal("operation_failed", failed.ErrorCode);
        Assert.Equal("failed", failed.Status);
    }
    [LibraryDatabaseFact]
    public async Task Failed_login_reservation_does_not_mask_real_provider_identity_projection()
    {
        var input = Input();
        await using var repository = new PostgresAdministrationRepository(Config());
        var operation = await repository.ProvisionAsync(input, default);
        var canonicalSubject = Guid.NewGuid().ToString();
        await repository.SyncAsync(new([new(canonicalSubject, input.Login, "Existing provider account", true, 1)]), default);
        await repository.FailAsync(await Claim(repository, operation.Id), "identity_conflict", false, default);
        Assert.Null(await repository.UserAsync(operation.Subject, default));
        var projected = Assert.Single((await repository.UsersAsync(input.Login, null, null, 100, default)).Items);
        Assert.Equal(canonicalSubject, projected.Subject);
        Assert.Equal("Existing provider account", projected.DisplayName);
        Assert.Equal("failed", (await repository.OperationAsync(input.Id, default))!.Status);
    }
    [LibraryDatabaseFact]
    public async Task Library_commands_bind_owner_and_creation_name_even_after_rename()
    {
        await using var repository = new PostgresAdministrationRepository(Config());
        var first = await Complete(repository, Input());
        var second = await Complete(repository, Input());
        var input = new LibraryCreate(Guid.NewGuid(), "Additional", first.Subject);
        Assert.True(await repository.CreateLibraryAsync(input, default));
        Assert.False(await repository.CreateLibraryAsync(input with { Subject = second.Subject }, default));
        Assert.True(await repository.RenameAsync(input.Id, new("Renamed", 0), default));
        Assert.True(await repository.RenameAsync(input.Id, new("Renamed", 0), default));
        Assert.True(await repository.CreateLibraryAsync(input, default));
        Assert.False(await repository.CreateLibraryAsync(input with { Name = "Renamed" }, default));
        await Assert.ThrowsAsync<AdministrationConflictException>(() => repository.RenameAsync(input.Id, new("Stale", 0), default));
        var detail = (await repository.LibraryAsync(input.Id, default))!;
        Assert.Equal(first.Subject, detail.Library.OwnerSubject);
        Assert.Equal("Renamed", detail.Library.Name);
        Assert.Equal(first.Subject, Assert.Single(detail.Members).Subject);
    }
    [LibraryDatabaseFact]
    public async Task Identity_sync_is_real_immutable_revision_fenced_and_preserves_memberships_and_directory()
    {
        await using var repository = new PostgresAdministrationRepository(Config());
        var user = await Complete(repository, Input());
        var additional = new LibraryCreate(Guid.NewGuid(), "Existing extra", user.Subject);
        Assert.True(await repository.CreateLibraryAsync(additional, default));
        await repository.SyncAsync(new([new(user.Subject, user.Login!, "Identity update", true, 10)]), default);
        var detail = (await repository.UserAsync(user.Subject, default))!;
        Assert.Equal(2, detail.Libraries.Count);
        Assert.True(detail.User.Discoverable);
        Assert.Equal("Identity update", detail.User.DisplayName);
        await repository.SyncAsync(new([new(user.Subject, user.Login!, "Stale", false, 9)]), default);
        Assert.Equal("Identity update", (await repository.UserAsync(user.Subject, default))!.User.DisplayName);
        await Assert.ThrowsAsync<AdministrationConflictException>(() => repository.SyncAsync(new([new(user.Subject, "different-login", "Changed", true, 11)]), default));
        Assert.Equal(user.Login, (await repository.UserAsync(user.Subject, default))!.User.Login);
    }
    [LibraryDatabaseFact]
    public async Task Profile_and_access_have_distinct_state_fences_and_disable_fails_closed_before_provider()
    {
        await using var repository = new PostgresAdministrationRepository(Config());
        var user = await Complete(repository, Input());
        var profile = new ProfileCommand(Guid.NewGuid(), user.Revision, "Renamed profile", false);
        var change = await repository.ProfileAsync(user.Subject, profile, default);
        Assert.Equal(change.Id, (await repository.ProfileAsync(user.Subject, profile, default)).Id);
        await Assert.ThrowsAsync<AdministrationConflictException>(() => repository.AccessAsync(user.Subject, new(Guid.NewGuid(), user.Revision, false), default));
        await repository.AdvanceAsync(await Claim(repository, change.Id), "completed", 2, default);
        var updated = (await repository.UserAsync(user.Subject, default))!.User;
        Assert.True(updated.Enabled);
        Assert.False(updated.Discoverable);
        Assert.Equal(user.Login, updated.Login);
        Assert.Equal("Renamed profile", updated.DisplayName);
        var access = await repository.AccessAsync(user.Subject, new(Guid.NewGuid(), updated.Revision, false), default);
        Assert.False((await repository.UserAsync(user.Subject, default))!.User.Enabled);
        await repository.FailAsync(await Claim(repository, access.Id), "identity_unavailable", false, default);
        Assert.False((await repository.UserAsync(user.Subject, default))!.User.Enabled);
        Assert.True(await repository.RetryAsync(access.Id, default));
        await repository.AdvanceAsync(await Claim(repository, access.Id), "completed", 3, default);
        Assert.Equal(user.PersonalLibraryId, (await repository.UserAsync(user.Subject, default))!.User.PersonalLibraryId);
    }
    [LibraryDatabaseFact]
    public async Task Server_search_filters_totals_and_pagination_include_more_than_one_thousand_records()
    {
        var prefix = "pagination-" + Guid.NewGuid().ToString("N");
        await Execute("""
            INSERT INTO principals(subject,login,display_name,enabled)
            SELECT gen_random_uuid()::text,$1||'-'||i::text,'Pagination person',i%2=0 FROM generate_series(1,1005) i
            """, prefix);
        await using var repository = new PostgresAdministrationRepository(Config());
        string? cursor = null;
        var subjects = new HashSet<string>();
        do
        {
            var page = await repository.UsersAsync(prefix, null, cursor, 100, default);
            Assert.Equal(1005, page.Total);
            Assert.All(page.Items, i => Assert.True(subjects.Add(i.Subject)));
            cursor = page.NextCursor;
        } while (cursor is not null);
        Assert.Equal(1005, subjects.Count);
        Assert.Equal(502, (await repository.UsersAsync(prefix, true, null, 100, default)).Total);
        Assert.Equal(0, (await repository.UsersAsync(prefix + "%", null, null, 100, default)).Total);
        Assert.True((await repository.SummaryAsync(default)).UserCount >= 1005);
        Assert.NotNull(await repository.OperationsAsync(null, null, 100, default));
        var legacy = await repository.ReadAsync(default);
        Assert.Equal(1000, legacy.Principals.Count);
        Assert.True(legacy.PrincipalTotal >= 1005);
        Assert.True(legacy.Truncated);
    }
    [LibraryDatabaseFact]
    public async Task Details_show_membership_and_scoped_shares_without_changing_uploader_rights()
    {
        await using var repository = new PostgresAdministrationRepository(Config());
        var owner = await Complete(repository, Input());
        var recipient = await Complete(repository, Input());
        var library = owner.PersonalLibraryId!.Value;
        await Execute("INSERT INTO shares(id,library_id,owner_subject,recipient_subject,all_assets) VALUES($1,$2,$3,$4,false)",
            Guid.NewGuid(), library, owner.Subject, recipient.Subject);
        var detail = (await repository.LibraryAsync(library, default))!;
        Assert.Equal(2, detail.Members.Count);
        var member = Assert.Single(detail.Members, m => m.Scope == "member");
        Assert.True(member.CanUpload);
        Assert.True(member.CanShare);
        var shared = Assert.Single(detail.Members, m => m.Scope == "share");
        Assert.False(shared.CanUpload);
        Assert.False(shared.CanShare);
        Assert.False(shared.AllAssets);
        Assert.Equal(0, shared.SharedAssetCount);
        Assert.Equal(2, (await repository.UserAsync(recipient.Subject, default))!.Libraries.Count);
        Assert.Equal(2, (await repository.UserAsync(recipient.Subject, default))!.Memberships.Count);
        Assert.Contains((await repository.LibrariesAsync(owner.Login, null, 100, default)).Items, l => l.Id == library);
    }
    [LibraryDatabaseFact]
    public async Task Reconciler_retries_lost_provider_response_with_same_predetermined_identity_and_command()
    {
        var input = Input();
        var configuration = Config();
        await using var repository = new PostgresAdministrationRepository(configuration);
        var reserved = await repository.ProvisionAsync(input, default);
        var provider = new IdempotentProvider { LoseFirstResponse = true };
        var worker = new AdministrationWorker(repository, provider, configuration, NullLogger<AdministrationWorker>.Instance);
        Assert.True(await worker.RunOnceAsync(default));
        Assert.Equal("reserved", (await repository.OperationAsync(input.Id, default))!.Step);
        Assert.Null(await repository.UserAsync(reserved.Subject, default));
        await Execute("UPDATE administration_operations SET next_attempt_at=now() WHERE id=$1", input.Id);
        await using var restarted = new PostgresAdministrationRepository(configuration);
        var restartedWorker = new AdministrationWorker(restarted, provider, configuration, NullLogger<AdministrationWorker>.Instance);
        Assert.True(await restartedWorker.RunOnceAsync(default));
        Assert.True(await restartedWorker.RunOnceAsync(default));
        Assert.True(await restartedWorker.RunOnceAsync(default));
        Assert.Equal(1, provider.Created);
        Assert.Equal("completed", (await restarted.OperationAsync(input.Id, default))!.Status);
        Assert.True((await restarted.UserAsync(reserved.Subject, default))!.User.Enabled);
    }
    private sealed class IdempotentProvider : HttpMessageHandler, IHttpClientFactory
    {
        private readonly HashSet<string> commands = [];
        public bool LoseFirstResponse { get; init; }
        public int Created { get; private set; }
        public HttpClient CreateClient(string name) => new(this, disposeHandler: false);
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            Assert.True(request.Headers.Contains("X-Nephos-Identity-Service-Key"));
            var body = await request.Content!.ReadFromJsonAsync<JsonElement>(cancellationToken);
            var command = body.GetProperty("commandId").GetGuid().ToString();
            var path = request.RequestUri!.AbsolutePath;
            var subject = path.Split('/')[5];
            var provision = path.EndsWith("/provision", StringComparison.Ordinal);
            if (provision && commands.Add(command))
            {
                Created++;
                Assert.Equal(64, body.GetProperty("requestHash").GetString()!.Length);
                if (LoseFirstResponse) throw new HttpRequestException("Response lost after provider commit.");
            }
            return new(HttpStatusCode.OK)
            {
                Content = JsonContent.Create(new
                {
                    subject,
                    revision = provision ? 0 : 1,
                    enabled = !provision && (!body.TryGetProperty("enabled", out var desired) || desired.GetBoolean())
                })
            };
        }
    }
}
