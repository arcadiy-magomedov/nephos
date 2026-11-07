using Nephos.ServiceDefaults;

namespace Nephos.Library.Api.Administration;

public sealed record PrincipalUpdate(string Subject, bool Enabled, string? DisplayName = null, bool? Discoverable = null);
public sealed record LibraryCreate(Guid Id, string Name, string Subject);
public sealed record AdministrationState(IReadOnlyList<PrincipalUpdate> Principals, IReadOnlyList<Libraries.LibrarySummary> Libraries,
    long PrincipalTotal, long LibraryTotal, bool Truncated);

public static class AdministrationEndpoints
{
    public static void MapAdministration(this WebApplication app)
    {
        app.MapInternalV1("/admin/summary", ["GET"], async (HttpContext context, IConfiguration config, IAdministrationRepository repository, CancellationToken token) =>
            Authorized(context, config) ? Results.Ok(await repository.SummaryAsync(token)) : Results.Unauthorized());
        app.MapInternalV1("/admin/users", ["GET"], async (HttpContext context, IConfiguration config, IAdministrationRepository repository,
            string? search, bool? enabled, string? cursor, int? limit, CancellationToken token) =>
        {
            if (!Authorized(context, config)) return Results.Unauthorized();
            if (!ValidPage(search, cursor, limit)) return Results.BadRequest();
            return Results.Ok(await repository.UsersAsync(search, enabled, cursor, limit ?? 50, token));
        });
        app.MapInternalV1("/admin/users/{subject}", ["GET"], async (string subject, HttpContext context, IConfiguration config, IAdministrationRepository repository, CancellationToken token) =>
        {
            if (!Authorized(context, config)) return Results.Unauthorized();
            var user = await repository.UserAsync(subject, token);
            return user is null ? Results.NotFound() : Results.Ok(user);
        });
        app.MapInternalV1("/admin/identities", ["POST"], async (IdentitySync input, HttpContext context, IConfiguration config, IAdministrationRepository repository, CancellationToken token) =>
        {
            if (!Authorized(context, config)) return Results.Unauthorized();
            if (input.Items is null || input.Items.Count > 500 || input.Items.Any(i => !Guid.TryParse(i.Subject, out _) ||
                !ValidLogin(i.Login) || i.DisplayName is { Length: > 200 } || i.DisplayName?.Any(char.IsControl) == true || i.Revision < 0))
                return Results.BadRequest();
            await repository.SyncAsync(input, token);
            return Results.NoContent();
        });
        app.MapInternalV1("/admin/users/{subject}/profile", ["POST"], async (string subject, ProfileCommand input, HttpContext context, IConfiguration config, IAdministrationRepository repository, CancellationToken token) =>
        {
            if (!Authorized(context, config)) return Results.Unauthorized();
            if (!Guid.TryParse(subject, out _) || input.CommandId == Guid.Empty || input.ExpectedRevision < 0 || !ValidName(input.DisplayName) || Operator(context) is null) return Results.BadRequest();
            if (!WorkerConfigured(config)) return Results.Problem(statusCode: 503, title: "Identity reconciliation is not configured.");
            return Results.Accepted(value: await repository.ProfileAsync(subject, input, token, Operator(context)));
        });
        app.MapInternalV1("/admin/users/{subject}/access", ["POST"], async (string subject, AccessCommand input, HttpContext context, IConfiguration config, IAdministrationRepository repository, CancellationToken token) =>
        {
            if (!Authorized(context, config)) return Results.Unauthorized();
            if (!Guid.TryParse(subject, out _) || input.CommandId == Guid.Empty || input.ExpectedRevision < 0 || Operator(context) is null) return Results.BadRequest();
            if (!WorkerConfigured(config)) return Results.Problem(statusCode: 503, title: "Identity reconciliation is not configured.");
            return Results.Accepted(value: await repository.AccessAsync(subject, input, token, Operator(context)));
        });
        app.MapInternalV1("/admin/libraries", ["GET"], async (HttpContext context, IConfiguration config, IAdministrationRepository repository,
            string? search, string? cursor, int? limit, CancellationToken token) =>
        {
            if (!Authorized(context, config)) return Results.Unauthorized();
            if (!ValidPage(search, cursor, limit)) return Results.BadRequest();
            return Results.Ok(await repository.LibrariesAsync(search, cursor, limit ?? 50, token));
        });
        app.MapInternalV1("/admin/libraries/{id:guid}", ["GET"], async (Guid id, HttpContext context, IConfiguration config, IAdministrationRepository repository, CancellationToken token) =>
        {
            if (!Authorized(context, config)) return Results.Unauthorized();
            var library = await repository.LibraryAsync(id, token);
            return library is null ? Results.NotFound() : Results.Ok(library);
        });
        app.MapInternalV1("/admin/libraries/{id:guid}/rename", ["POST"], async (Guid id, LibraryRename input, HttpContext context, IConfiguration config, IAdministrationRepository repository, CancellationToken token) =>
        {
            if (!Authorized(context, config)) return Results.Unauthorized();
            if (!ValidName(input.Name) || input.ExpectedRevision < 0) return Results.BadRequest();
            return await repository.RenameAsync(id, input, token) ? Results.NoContent() : Results.NotFound();
        });
        app.MapInternalV1("/admin/libraries/{id:guid}/owner", ["POST"], async (Guid id, LibraryOwnerAssign input, HttpContext context, IConfiguration config, IAdministrationRepository repository, CancellationToken token) =>
        {
            if (!Authorized(context, config)) return Results.Unauthorized();
            if (!Guid.TryParse(input.Subject, out _) || input.ExpectedRevision < 0) return Results.BadRequest();
            return await repository.AssignOwnerAsync(id, input, token) ? Results.NoContent() : Results.NotFound();
        });
        app.MapInternalV1("/admin/operations", ["POST"], async (ProvisionCommand input, HttpContext context, IConfiguration config, IAdministrationRepository repository, CancellationToken token) =>
        {
            if (!Authorized(context, config)) return Results.Unauthorized();
            if (input.Id == Guid.Empty || !ValidProvisionLogin(input.Login) || !ValidName(input.DisplayName) || !ValidName(input.LibraryName) || Operator(context) is null) return Results.BadRequest();
            if (!WorkerConfigured(config)) return Results.Problem(statusCode: 503, title: "Identity reconciliation is not configured.");
            var operation = await repository.ProvisionAsync(input, token, Operator(context));
            return Results.Accepted("/internal/v1/admin/operations/" + operation.Id, operation);
        });
        app.MapInternalV1("/admin/operations", ["GET"], async (HttpContext context, IConfiguration config, IAdministrationRepository repository,
            string? status, string? cursor, int? limit, CancellationToken token) =>
        {
            if (!Authorized(context, config)) return Results.Unauthorized();
            if (!ValidPage(null, cursor, limit) || status is not (null or "pending" or "running" or "failed" or "completed" or "abandoned")) return Results.BadRequest();
            return Results.Ok(await repository.OperationsAsync(status, cursor, limit ?? 50, token));
        });
        app.MapInternalV1("/admin/operations/{id:guid}", ["GET"], async (Guid id, HttpContext context, IConfiguration config, IAdministrationRepository repository, CancellationToken token) =>
        {
            if (!Authorized(context, config)) return Results.Unauthorized();
            var operation = await repository.OperationAsync(id, token);
            return operation is null ? Results.NotFound() : Results.Ok(operation);
        });
        app.MapInternalV1("/admin/operations/{id:guid}/retry", ["POST"], async (Guid id, HttpContext context, IConfiguration config, IAdministrationRepository repository, CancellationToken token) =>
        {
            if (!Authorized(context, config)) return Results.Unauthorized();
            if (!WorkerConfigured(config)) return Results.Problem(statusCode: 503, title: "Identity reconciliation is not configured.");
            if (Operator(context) is null) return Results.BadRequest();
            return await repository.RetryAsync(id, token, Operator(context)) ? Results.Accepted() : Results.NotFound();
        });
        app.MapInternalV1("/admin/operations/{id:guid}/abandon", ["POST"], async (Guid id, HttpContext context, IConfiguration config, IAdministrationRepository repository, CancellationToken token) =>
        {
            if (!Authorized(context, config)) return Results.Unauthorized();
            if (Operator(context) is null) return Results.BadRequest();
            var operation = await repository.AbandonAsync(id, Operator(context)!, token);
            return operation is null ? Results.NotFound() : Results.Ok(operation);
        });
        app.MapInternalV1("/admin/state", ["GET"], async (HttpContext context, IConfiguration config, IAdministrationRepository repository, CancellationToken token) =>
            MediaProtocol.IsInternal(context, config, "Administration:Key") ? Results.Ok(await repository.ReadAsync(token)) : Results.Unauthorized());
        app.MapInternalV1("/admin/principals", ["POST"], async (PrincipalUpdate update, HttpContext context, IConfiguration config, IAdministrationRepository repository, CancellationToken token) =>
        {
            if (!MediaProtocol.IsInternal(context, config, "Administration:Key")) return Results.Unauthorized();
            if (!Guid.TryParse(update.Subject, out _) || update.DisplayName is { Length: > 200 } ||
                update.DisplayName?.Any(char.IsControl) == true)
                return Results.Problem(statusCode: 400, title: "Invalid known-user identity or display name.");
            await repository.SetPrincipalAsync(update, token);
            return Results.NoContent();
        });
        app.MapInternalV1("/admin/libraries", ["POST"], async (LibraryCreate input, HttpContext context, IConfiguration config, IAdministrationRepository repository, CancellationToken token) =>
        {
            if (!MediaProtocol.IsInternal(context, config, "Administration:Key")) return Results.Unauthorized();
            if (input.Id == Guid.Empty || !Guid.TryParse(input.Subject, out _) || !ValidName(input.Name))
                return Results.BadRequest();
            return await repository.CreateLibraryAsync(input with { Name = input.Name.Trim() }, token) ? Results.NoContent()
                : Results.Problem(statusCode: 409, title: "Principal is not provisioned or library ID has conflicting metadata.");
        });
    }
    private static bool Authorized(HttpContext context, IConfiguration config) => MediaProtocol.IsInternal(context, config, "Administration:Key");
    private static string? Operator(HttpContext context) => Guid.TryParse(context.Request.Headers["X-Nephos-Operator-Subject"].ToString(), out var subject) && subject != Guid.Empty
        ? subject.ToString() : null;
    private static bool WorkerConfigured(IConfiguration config) => !string.IsNullOrWhiteSpace(config["Administration:IdentityUrl"])
        && !string.IsNullOrWhiteSpace(config["Administration:IdentityKey"]);
    private static bool ValidName(string? value) => !string.IsNullOrWhiteSpace(value) && value.Length <= 200 && !value.Any(char.IsControl);
    private static bool ValidLogin(string? value) => !string.IsNullOrWhiteSpace(value) && value.Length <= 200
        && value == value.Trim() && !value.Any(c => char.IsControl(c) || char.IsWhiteSpace(c));
    private static bool ValidProvisionLogin(string? value) => value is not null &&
        System.Text.RegularExpressions.Regex.IsMatch(value.ToLowerInvariant(), @"\A[a-z0-9][a-z0-9._-]{0,63}\z");
    private static bool ValidPage(string? search, string? cursor, int? limit) => (limit ?? 50) is >= 1 and <= 100
        && (search?.Length ?? 0) <= 200 && (cursor?.Length ?? 0) <= 200;
}
