using System.Diagnostics;
using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Diagnostics.HealthChecks;
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
        });
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
