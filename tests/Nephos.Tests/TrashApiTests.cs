using System.Net;
using System.Net.Http.Json;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;
using Nephos.Library.Api.Assets;

namespace Nephos.Tests;

public sealed class TrashApiTests
{
    [Fact]
    public async Task Trash_is_authenticated_paginated_and_owner_scoped()
    {
        await using var baseFactory = new ApiFactory();
        var trash = new FakeTrash();
        await using var factory = WithTrash(baseFactory, trash);
        using var client = factory.CreateClient();
        Assert.Equal(HttpStatusCode.Unauthorized, (await client.GetAsync("/v1/trash")).StatusCode);
        Assert.Equal(HttpStatusCode.Unauthorized, (await client.PostAsync($"/v1/assets/{trash.Id}/restore", null)).StatusCode);
        Assert.Equal(HttpStatusCode.Unauthorized, (await client.GetAsync($"/v1/trash/{trash.Id}/preview")).StatusCode);
        client.DefaultRequestHeaders.Authorization = new("Bearer", baseFactory.Token("known"));
        Assert.Equal(HttpStatusCode.BadRequest, (await client.GetAsync("/v1/trash?limit=101")).StatusCode);
        Assert.Equal(HttpStatusCode.BadRequest, (await client.GetAsync("/v1/trash?beforeId=" + trash.Id)).StatusCode);
        var response = await client.GetAsync("/v1/trash");
        Assert.True(response.Headers.CacheControl?.NoStore);
        var page = await response.Content.ReadFromJsonAsync<TrashPage>();
        Assert.Single(page!.Items);
        Assert.Equal("known", trash.Subject);
        client.DefaultRequestHeaders.Authorization = new("Bearer", baseFactory.Token("other"));
        Assert.Empty((await client.GetFromJsonAsync<TrashPage>("/v1/trash"))!.Items);
        Assert.Equal(HttpStatusCode.NotFound, (await client.PostAsync($"/v1/assets/{trash.Id}/restore", null)).StatusCode);
        Assert.Equal(HttpStatusCode.NotFound, (await client.GetAsync($"/v1/trash/{trash.Id}/preview")).StatusCode);
        client.DefaultRequestHeaders.Authorization = new("Bearer", baseFactory.Token("known"));
        Assert.Equal(HttpStatusCode.NoContent, (await client.PostAsync($"/v1/assets/{trash.Id}/restore", null)).StatusCode);
        trash.Expired = true;
        Assert.Equal(HttpStatusCode.Conflict, (await client.PostAsync($"/v1/assets/{trash.Id}/restore", null)).StatusCode);
    }

    [Fact]
    public async Task Cleanup_requires_service_key_and_current_lease()
    {
        await using var baseFactory = new ApiFactory();
        var trash = new FakeTrash();
        await using var factory = WithTrash(baseFactory, trash);
        using var client = factory.CreateClient();
        Assert.Equal(HttpStatusCode.Unauthorized, (await client.PostAsync("/internal/v1/cleanup/claim", null)).StatusCode);
        client.DefaultRequestHeaders.Add("X-Nephos-Service-Key", ApiFactory.InternalKey);
        var claim = await (await client.PostAsync("/internal/v1/cleanup/claim", null)).Content.ReadFromJsonAsync<PurgeClaim>();
        Assert.NotNull(claim);
        Assert.Equal(HttpStatusCode.Conflict, (await client.PostAsJsonAsync($"/internal/v1/cleanup/{claim.AssetId}/complete", new CompletePurgeRequest(Guid.NewGuid()))).StatusCode);
        Assert.Equal(HttpStatusCode.NoContent, (await client.PostAsJsonAsync($"/internal/v1/cleanup/{claim.AssetId}/complete", new CompletePurgeRequest(claim.LeaseId))).StatusCode);
        Assert.Equal(HttpStatusCode.NoContent, (await client.PostAsync("/internal/v1/cleanup/claim", null)).StatusCode);
    }

    private static WebApplicationFactory<Program> WithTrash(ApiFactory factory, FakeTrash trash) =>
        factory.WithWebHostBuilder(builder => builder.ConfigureServices(services =>
        {
            services.RemoveAll<ITrashRepository>();
            services.AddSingleton<ITrashRepository>(trash);
        }));

    private sealed class FakeTrash : ITrashRepository
    {
        public Guid Id { get; } = Guid.NewGuid();
        private readonly Guid lease = Guid.NewGuid();
        public string? Subject { get; private set; }
        public bool Expired { get; set; }
        private bool completed;
        public Task<TrashPage> ListAsync(string subject, TrashCursor? before, int limit, CancellationToken token)
        {
            Subject = subject;
            var now = DateTimeOffset.UtcNow;
            return Task.FromResult(new TrashPage(subject == "known"
                ? [new(new(Id, Guid.NewGuid(), "photo.jpg", "image/jpeg", 100, new string('a', 64), true, now), now, now.AddDays(30))]
                : [], null));
        }
        public Task<Asset?> FindAsync(string subject, Guid id, CancellationToken token) => Task.FromResult<Asset?>(null);
        public Task<RestoreResult> RestoreAsync(string subject, Guid id, CancellationToken token) =>
            Task.FromResult(subject != "known" || id != Id ? RestoreResult.NotFound : Expired ? RestoreResult.Expired : RestoreResult.Restored);
        public Task<PurgeClaim?> ClaimAsync(CancellationToken token) =>
            Task.FromResult(completed ? null : new PurgeClaim(Id, "known", lease));
        public Task<bool> CompleteAsync(Guid assetId, Guid leaseId, CancellationToken token)
        {
            var valid = assetId == Id && leaseId == lease;
            if (valid) completed = true;
            return Task.FromResult(valid);
        }
    }
}
