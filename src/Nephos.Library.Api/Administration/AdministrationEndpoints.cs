using Nephos.ServiceDefaults;

namespace Nephos.Library.Api.Administration;

public sealed record PrincipalUpdate(string Subject, bool Enabled, string? DisplayName = null, bool? Discoverable = null);
public sealed record LibraryCreate(Guid Id, string Name, string Subject);
public sealed record AdministrationState(IReadOnlyList<PrincipalUpdate> Principals, IReadOnlyList<Libraries.LibrarySummary> Libraries);

public static class AdministrationEndpoints
{
    public static void MapAdministration(this WebApplication app)
    {
        app.MapGet("/internal/admin/state", async (HttpContext context, IConfiguration config, IAdministrationRepository repository, CancellationToken token) =>
            MediaProtocol.IsInternal(context, config, "Administration:Key") ? Results.Ok(await repository.ReadAsync(token)) : Results.Unauthorized());
        app.MapPost("/internal/admin/principals", async (PrincipalUpdate update, HttpContext context, IConfiguration config, IAdministrationRepository repository, CancellationToken token) =>
        {
            if (!MediaProtocol.IsInternal(context, config, "Administration:Key")) return Results.Unauthorized();
            if (!Guid.TryParse(update.Subject, out _) || update.DisplayName is { Length: > 200 } ||
                update.DisplayName?.Any(char.IsControl) == true)
                return Results.Problem(statusCode: 400, title: "Invalid known-user identity or display name.");
            await repository.SetPrincipalAsync(update, token);
            return Results.NoContent();
        });
        app.MapPost("/internal/admin/libraries", async (LibraryCreate input, HttpContext context, IConfiguration config, IAdministrationRepository repository, CancellationToken token) =>
        {
            if (!MediaProtocol.IsInternal(context, config, "Administration:Key")) return Results.Unauthorized();
            if (input.Id == Guid.Empty || !Guid.TryParse(input.Subject, out _) || string.IsNullOrWhiteSpace(input.Name) || input.Name.Length > 200)
                return Results.BadRequest();
            return await repository.CreateLibraryAsync(input, token) ? Results.NoContent()
                : Results.Problem(statusCode: 409, title: "Principal is not provisioned or library ID has conflicting metadata.");
        });
    }
}
