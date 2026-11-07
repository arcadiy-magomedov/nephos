using System.Net;
using System.Net.Http.Json;
using Npgsql;

namespace Nephos.Library.Api.Administration;

public sealed class AdministrationWorker(IAdministrationRepository repository, IHttpClientFactory clients,
    IConfiguration configuration, ILogger<AdministrationWorker> logger) : BackgroundService
{
    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        while (!stoppingToken.IsCancellationRequested)
        {
            try
            {
                if (!await RunOnceAsync(stoppingToken)) await Task.Delay(TimeSpan.FromSeconds(2), stoppingToken);
            }
            catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested) { break; }
            catch (Exception e) when (e is NpgsqlException or HttpRequestException or TimeoutException)
            {
                logger.LogWarning("Administration reconciliation unavailable ({ErrorType})", e.GetType().Name);
                await Task.Delay(TimeSpan.FromSeconds(5), stoppingToken);
            }
        }
    }

    public async Task<bool> RunOnceAsync(CancellationToken token)
    {
        var operation = await repository.ClaimAsync(token);
        if (operation is null) return false;
        try
        {
            if (operation.ProviderRevision == -1 && operation.Kind != "provision")
            {
                var current = await ReadIdentity(operation.Subject, token);
                await repository.RebaseAsync(operation, current.Revision, token);
                operation = operation with { ProviderRevision = current.Revision };
            }
            if (operation.Kind == "provision")
            {
                if (operation.Step == "reserved")
                {
                    var identity = await UpdateIdentity(operation.Subject, "provision",
                        new { commandId = operation.Id, operation.RequestHash, operation.Login, operation.DisplayName }, 0, token, false);
                    await repository.AdvanceAsync(operation, "identity-created", identity.Revision, token);
                }
                else if (operation.Step == "identity-created")
                    await repository.AdvanceAsync(operation, "library-created", operation.ProviderRevision, token);
                else if (operation.Step == "library-created")
                {
                    var identity = await UpdateIdentity(operation.Subject, "access",
                        new { commandId = StepCommand(operation, "access"), expectedRevision = operation.ProviderRevision, enabled = true },
                        operation.ProviderRevision, token, true);
                    await repository.AdvanceAsync(operation, "completed", identity.Revision, token);
                }
            }
            else
            {
                if (operation.Kind == "access" && operation.DesiredEnabled && operation.Step == "reserved")
                {
                    var disabled = await UpdateIdentity(operation.Subject, "access",
                        new { commandId = StepCommand(operation, "disable-before-enable"), expectedRevision = operation.ProviderRevision, enabled = false },
                        operation.ProviderRevision, token, false);
                    await repository.AdvanceAsync(operation, "identity-created", disabled.Revision, token);
                    return true;
                }
                object input = operation.Kind == "profile"
                    ? new { commandId = StepCommand(operation, "profile"), expectedRevision = operation.ProviderRevision, operation.DisplayName }
                    : new { commandId = StepCommand(operation, "access"), expectedRevision = operation.ProviderRevision, enabled = operation.DesiredEnabled };
                var identity = await UpdateIdentity(operation.Subject, operation.Kind, input, operation.ProviderRevision, token,
                    operation.Kind == "access" ? operation.DesiredEnabled : null);
                await repository.AdvanceAsync(operation, "completed", identity.Revision, token);
            }
        }
        catch (IdentityOperationException e)
        {
            await repository.FailAsync(operation, e.Code, e.Retryable, token);
        }
        catch (AdministrationConflictException)
        {
            // A lost lease belongs to another reconciler. It alone may advance.
        }
        catch (Exception e) when (e is HttpRequestException or TaskCanceledException or TimeoutException or System.Text.Json.JsonException)
        {
            if (token.IsCancellationRequested) throw;
            await repository.FailAsync(operation, "identity_unavailable", true, token);
        }
        catch (NpgsqlException)
        {
            await repository.FailAsync(operation, "persistence_unavailable", true, token);
        }
        return true;
    }

    private static Guid StepCommand(AdminOperation operation, string action) => new(System.Security.Cryptography.SHA256.HashData(
        System.Text.Encoding.UTF8.GetBytes($"{operation.Id}:{action}:{operation.ProviderRevision}")).AsSpan(0, 16));
    private async Task<IdentityReply> UpdateIdentity(string subject, string action, object input, long minimumRevision, CancellationToken token, bool? expectedEnabled = null)
    {
        using var client = clients.CreateClient("administration-identity");
        var baseUrl = configuration["Administration:IdentityUrl"] ?? throw new InvalidOperationException("Administration:IdentityUrl is required.");
        using var request = new HttpRequestMessage(HttpMethod.Put,
            baseUrl.TrimEnd('/') + "/users/" + Uri.EscapeDataString(subject) + "/" + action);
        request.Headers.Add("X-Nephos-Identity-Service-Key", configuration["Administration:IdentityKey"]
            ?? throw new InvalidOperationException("Administration:IdentityKey is required."));
        request.Content = JsonContent.Create(input);
        using var response = await client.SendAsync(request, token);
        if (!response.IsSuccessStatusCode)
            throw new IdentityOperationException(
                response.StatusCode == HttpStatusCode.Conflict ? "identity_conflict" :
                (int)response.StatusCode >= 500 || response.StatusCode == HttpStatusCode.TooManyRequests ? "identity_unavailable" : "identity_rejected",
                (int)response.StatusCode >= 500 || response.StatusCode == HttpStatusCode.TooManyRequests);
        var identity = await response.Content.ReadFromJsonAsync<IdentityReply>(token)
            ?? throw new IdentityOperationException("identity_unavailable", true);
        if (identity.Subject != subject || identity.Revision < minimumRevision)
            throw new IdentityOperationException("identity_rejected", false);
        if (expectedEnabled is not null && identity.Enabled != expectedEnabled)
            throw new IdentityOperationException("identity_conflict", false);
        return identity;
    }
    private async Task<IdentityReply> ReadIdentity(string subject, CancellationToken token)
    {
        using var client = clients.CreateClient("administration-identity");
        using var request = new HttpRequestMessage(HttpMethod.Get,
            configuration["Administration:IdentityUrl"]!.TrimEnd('/') + "/users/" + Uri.EscapeDataString(subject));
        request.Headers.Add("X-Nephos-Identity-Service-Key", configuration["Administration:IdentityKey"]);
        using var response = await client.SendAsync(request, token);
        if (!response.IsSuccessStatusCode)
            throw new IdentityOperationException((int)response.StatusCode >= 500 ? "identity_unavailable" : "identity_rejected", (int)response.StatusCode >= 500);
        var identity = await response.Content.ReadFromJsonAsync<IdentityReply>(token);
        if (identity is null || identity.Subject != subject || identity.Revision < 0)
            throw new IdentityOperationException("identity_rejected", false);
        return identity;
    }
    private sealed record IdentityReply(string Subject, long Revision, bool? Enabled);
    private sealed class IdentityOperationException(string code, bool retryable) : Exception
    {
        public string Code { get; } = code;
        public bool Retryable { get; } = retryable;
    }
}
