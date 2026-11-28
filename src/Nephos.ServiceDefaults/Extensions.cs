using System.Collections.Concurrent;
using System.Diagnostics;
using System.Net.Http.Headers;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Diagnostics.HealthChecks;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Diagnostics.HealthChecks;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Microsoft.IdentityModel.Tokens;
using OpenTelemetry;
using OpenTelemetry.Logs;
using OpenTelemetry.Metrics;
using OpenTelemetry.Resources;
using OpenTelemetry.Trace;

namespace Nephos.ServiceDefaults;

public static class Extensions
{
    private const string IntrospectionUnavailable = "Nephos.KeycloakIntrospectionUnavailable";

    public static WebApplicationBuilder AddServiceDefaults(this WebApplicationBuilder builder, string serviceName)
    {
        if (builder.Configuration.GetValue<bool>("Worker:Enabled")) serviceName += "-worker";
        else if (builder.Configuration.GetValue<bool>("Administration:Enabled")) serviceName += "-admin";
        builder.Services.AddSingleton<IHostedService>(new ServiceHeartbeat(serviceName));
        builder.Services.AddAuthentication(JwtBearerDefaults.AuthenticationScheme).AddJwtBearer(options =>
        {
            var authority = builder.Configuration["Authentication:Authority"]
                ?? throw new InvalidOperationException("Authentication:Authority is required.");
            var audience = builder.Configuration["Authentication:Audience"]
                ?? throw new InvalidOperationException("Authentication:Audience is required.");
            if (!Uri.TryCreate(authority, UriKind.Absolute, out var issuer) ||
                (issuer.Scheme != "https" && !(builder.Environment.IsDevelopment() && issuer.Scheme == "http")))
            {
                throw new InvalidOperationException("The authority must be HTTPS outside Development.");
            }
            if (string.IsNullOrWhiteSpace(audience))
            {
                throw new InvalidOperationException("A nonempty audience is required.");
            }
            options.Authority = authority;
            options.Audience = audience;
            options.RequireHttpsMetadata = !builder.Environment.IsDevelopment();
            options.MapInboundClaims = false;
            if (builder.Configuration["Authentication:MetadataAddress"] is { } metadata)
            {
                options.MetadataAddress = metadata;
            }
            options.TokenValidationParameters = new TokenValidationParameters
            {
                ValidIssuer = authority,
                ValidAudience = audience,
                ValidateIssuer = true,
                ValidateAudience = true,
                ValidateLifetime = true,
                ValidateIssuerSigningKey = true,
                RequireSignedTokens = true,
                ClockSkew = TimeSpan.FromSeconds(30),
                ValidAlgorithms = [SecurityAlgorithms.RsaSha256]
            };
            var introspectionEndpoint = builder.Configuration["Authentication:IntrospectionEndpoint"];
            var introspectionClientId = builder.Configuration["Authentication:IntrospectionClientId"];
            var introspectionClientSecret = builder.Configuration["Authentication:IntrospectionClientSecret"];
            if (string.IsNullOrWhiteSpace(introspectionEndpoint) ||
                string.IsNullOrWhiteSpace(introspectionClientId) ||
                string.IsNullOrWhiteSpace(introspectionClientSecret))
            {
                throw new InvalidOperationException("Keycloak token introspection settings are required.");
            }
            if (!Uri.TryCreate(introspectionEndpoint, UriKind.Absolute, out var introspectionUri) ||
                (introspectionUri.Scheme != Uri.UriSchemeHttps && introspectionUri.Scheme != Uri.UriSchemeHttp))
            {
                throw new InvalidOperationException("Authentication:IntrospectionEndpoint must be an absolute HTTP(S) URL.");
            }
            options.Events = new JwtBearerEvents
            {
                OnTokenValidated = async context =>
                {
                    try
                    {
                        var authorization = context.Request.Headers.Authorization.ToString();
                        if (!authorization.StartsWith("Bearer ", StringComparison.OrdinalIgnoreCase))
                        {
                            context.Fail("Bearer token is missing.");
                            return;
                        }
                        var token = authorization["Bearer ".Length..].Trim();
                        var coalescer = context.HttpContext.RequestServices.GetRequiredService<IntrospectionCoalescer>();
                        var clientFactory = context.HttpContext.RequestServices.GetRequiredService<IHttpClientFactory>();
                        var outcome = await coalescer.InspectAsync(
                            token,
                            async ct =>
                            {
                                try
                                {
                                    var client = clientFactory.CreateClient("keycloak-introspection");
                                    using var request = new HttpRequestMessage(HttpMethod.Post, introspectionUri);
                                    var credentials = Convert.ToBase64String(Encoding.UTF8.GetBytes(
                                        $"{introspectionClientId}:{introspectionClientSecret}"));
                                    request.Headers.Authorization = new AuthenticationHeaderValue("Basic", credentials);
                                    request.Content = new FormUrlEncodedContent(
                                        [new KeyValuePair<string, string>("token", token)]);
                                    using var response = await client.SendAsync(request, ct);
                                    if (!response.IsSuccessStatusCode) return IntrospectionOutcome.Unavailable;
                                    using var body = await JsonDocument.ParseAsync(
                                        await response.Content.ReadAsStreamAsync(ct),
                                        cancellationToken: ct);
                                    if (body.RootElement.ValueKind != JsonValueKind.Object ||
                                        !body.RootElement.TryGetProperty("active", out var active) ||
                                        active.ValueKind is not (JsonValueKind.True or JsonValueKind.False))
                                        return IntrospectionOutcome.Unavailable;
                                    return active.ValueKind == JsonValueKind.True
                                        ? IntrospectionOutcome.Active : IntrospectionOutcome.Inactive;
                                }
                                catch (OperationCanceledException) { return IntrospectionOutcome.Unavailable; }
                                catch (HttpRequestException) { return IntrospectionOutcome.Unavailable; }
                                catch (JsonException) { return IntrospectionOutcome.Unavailable; }
                            },
                            context.HttpContext.RequestAborted);
                        if (outcome == IntrospectionOutcome.Unavailable)
                        {
                            context.HttpContext.Items[IntrospectionUnavailable] = true;
                            context.Fail("Token session status is unavailable.");
                        }
                        else if (outcome == IntrospectionOutcome.Inactive)
                        {
                            context.Fail("The identity provider has revoked this token session.");
                        }
                    }
                    catch (OperationCanceledException) when (context.HttpContext.RequestAborted.IsCancellationRequested)
                    {
                        context.Fail("Request was cancelled before token validation completed.");
                    }
                }
            };
        });
        builder.Services.AddSingleton<IntrospectionCoalescer>();
        builder.Services.AddHttpClient("keycloak-introspection", client =>
            client.Timeout = TimeSpan.FromSeconds(5));
        builder.Services.AddOptions<JwtBearerOptions>(JwtBearerDefaults.AuthenticationScheme).ValidateOnStart();
        builder.Services.AddAuthorization();
        builder.Services.AddProblemDetails();
        builder.Services.AddHealthChecks();
        builder.Logging.AddFilter("System.Net.Http.HttpClient", LogLevel.Warning);

        var resource = ResourceBuilder.CreateDefault().AddService(serviceName);
        var sampleRatio = builder.Configuration.GetValue<double?>("Telemetry:TraceSampleRatio") ?? 0.1;
        if (!double.IsFinite(sampleRatio) || sampleRatio is < 0 or > 1)
        {
            throw new InvalidOperationException("Telemetry:TraceSampleRatio must be between 0 and 1.");
        }
        builder.Logging.AddOpenTelemetry(options =>
        {
            options.SetResourceBuilder(resource);
            options.IncludeFormattedMessage = true;
            options.IncludeScopes = false;
            options.AddOtlpExporter();
        });
        builder.Services.AddOpenTelemetry()
            .ConfigureResource(r => r.AddService(serviceName))
            .WithTracing(tracing => tracing
                .SetSampler(new TraceIdRatioBasedSampler(sampleRatio))
                .AddAspNetCoreInstrumentation()
                .AddHttpClientInstrumentation()
                .AddSource("Nephos.*")
                .AddSource("Npgsql")
                .AddProcessor(new SafeTraceProcessor())
                .AddOtlpExporter())
            .WithMetrics(metrics => metrics
                .AddAspNetCoreInstrumentation()
                .AddHttpClientInstrumentation()
                .AddRuntimeInstrumentation()
                .AddMeter("Nephos.*")
                .AddOtlpExporter());
        return builder;
    }

    public static void UseActiveTokenStatus(this WebApplication app)
    {
        app.Use(async (context, next) =>
        {
            if (context.Items.ContainsKey(IntrospectionUnavailable))
            {
                context.Response.StatusCode = StatusCodes.Status503ServiceUnavailable;
                context.Response.Headers.RetryAfter = "5";
                context.Response.Headers.CacheControl = "no-store";
                await context.Response.WriteAsJsonAsync(new
                {
                    title = "Authentication service temporarily unavailable.",
                    status = StatusCodes.Status503ServiceUnavailable
                });
                return;
            }
            await next();
        });
    }

    public static void MapServiceHealth(this WebApplication app)
    {
        app.MapHealthChecks("/health/live", new HealthCheckOptions { Predicate = _ => false });
        app.MapHealthChecks("/health/ready", new HealthCheckOptions
        {
            ResultStatusCodes =
            {
                [HealthStatus.Healthy] = 200,
                [HealthStatus.Degraded] = 503,
                [HealthStatus.Unhealthy] = 503
            }
        });
    }

    private enum IntrospectionOutcome { Active, Inactive, Unavailable }

    // Coalesces concurrent in-flight introspections for the same token without post-completion caching.
    private sealed class IntrospectionCoalescer
    {
        private readonly ConcurrentDictionary<string, Lazy<Task<IntrospectionOutcome>>> inflight = new();

        public async Task<IntrospectionOutcome> InspectAsync(
            string token, Func<CancellationToken, Task<IntrospectionOutcome>> probe, CancellationToken callerToken)
        {
            var key = Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(token)));
            Lazy<Task<IntrospectionOutcome>>? created = null;
            created = new Lazy<Task<IntrospectionOutcome>>(() => RunAsync(key, created!, probe));
            var entry = inflight.GetOrAdd(key, created);
            return await entry.Value.WaitAsync(callerToken);
        }

        private async Task<IntrospectionOutcome> RunAsync(
            string key, Lazy<Task<IntrospectionOutcome>> self, Func<CancellationToken, Task<IntrospectionOutcome>> probe)
        {
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(5));
            try
            {
                return await probe(timeout.Token);
            }
            finally
            {
                inflight.TryRemove(KeyValuePair.Create(key, self));
            }
        }
    }

    private sealed class SafeTraceProcessor : BaseProcessor<Activity>
    {
        public override void OnEnd(Activity activity)
        {
            foreach (var key in new[]
            {
                "url.full", "url.query", "url.path", "http.url", "http.target",
                "db.query.text", "db.statement"
            })
            {
                activity.SetTag(key, null);
            }
        }
    }
}
