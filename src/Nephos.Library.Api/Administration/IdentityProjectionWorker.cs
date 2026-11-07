using System.Net.Http.Json;
using Npgsql;

namespace Nephos.Library.Api.Administration;

public sealed class IdentityProjectionWorker(IAdministrationRepository repository, IHttpClientFactory clients,
    IConfiguration config, ILogger<IdentityProjectionWorker> logger) : BackgroundService
{
    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        while (!stoppingToken.IsCancellationRequested)
        {
            try { await SyncOnceAsync(stoppingToken); }
            catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested) { break; }
            catch (Exception e) when (e is HttpRequestException or NpgsqlException or TimeoutException
                or TaskCanceledException or System.Text.Json.JsonException or AdministrationConflictException)
            {
                logger.LogWarning("Identity projection unavailable ({ErrorType}); retaining last known state", e.GetType().Name);
            }
            await Task.Delay(TimeSpan.FromSeconds(30), stoppingToken);
        }
    }
    public async Task SyncOnceAsync(CancellationToken token)
    {
        using var client = clients.CreateClient("administration-identity");
        var baseUrl = config["Administration:IdentityUrl"] ?? throw new InvalidOperationException("Administration:IdentityUrl is required.");
        string? cursor = null;
        do
        {
            using var request = new HttpRequestMessage(HttpMethod.Get, baseUrl.TrimEnd('/') + "/users?limit=100" +
                (cursor is null ? "" : "&cursor=" + Uri.EscapeDataString(cursor)));
            request.Headers.Add("X-Nephos-Identity-Service-Key", config["Administration:IdentityKey"]);
            using var response = await client.SendAsync(request, token);
            response.EnsureSuccessStatusCode();
            var page = await response.Content.ReadFromJsonAsync<AdminPage<IdentityProjection>>(token)
                ?? throw new HttpRequestException("Identity page unavailable.");
            if (page.Items is null || page.Items.Count > 100 || page.Items.Any(i =>
                !Guid.TryParse(i.Subject, out _) || string.IsNullOrWhiteSpace(i.Login) || i.Login.Length > 200
                || i.DisplayName is { Length: > 200 } || i.Revision < 0))
                throw new HttpRequestException("Identity page invalid.");
            await repository.SyncAsync(new(page.Items), token);
            if (page.NextCursor is not null && (page.Items.Count == 0 || page.NextCursor == cursor))
                throw new HttpRequestException("Identity continuation did not advance.");
            cursor = page.NextCursor;
        } while (cursor is not null);
    }
}
