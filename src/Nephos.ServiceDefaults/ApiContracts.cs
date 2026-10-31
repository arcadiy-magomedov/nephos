using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Routing;

namespace Nephos.ServiceDefaults;

public static class ApiContracts
{
    // Legacy aliases remain pinned to v1 so older peers can finish a rolling upgrade.
    public static RouteGroupBuilder MapInternalV1(
        this IEndpointRouteBuilder endpoints, string pattern, string[] methods, Delegate handler)
    {
        var group = endpoints.MapGroup("");
        group.MapMethods("/internal/v1" + pattern, methods, handler);
        group.MapMethods("/internal" + pattern, methods, handler).AddEndpointFilter(async (context, next) =>
        {
            var path = context.HttpContext.Request.Path.Value!;
            context.HttpContext.Response.Headers.Append(
                "Link", $"</internal/v1{path["/internal".Length..]}>; rel=\"successor-version\"");
            return await next(context);
        });
        return group;
    }
}
