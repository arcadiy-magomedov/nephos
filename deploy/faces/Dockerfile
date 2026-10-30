FROM mcr.microsoft.com/dotnet/sdk:10.0.300 AS build
WORKDIR /src
COPY Directory.Build.props global.json ./
COPY src/Nephos.ServiceDefaults/ src/Nephos.ServiceDefaults/
COPY src/Nephos.Faces.Api/ src/Nephos.Faces.Api/
COPY src/Nephos.Migrations/ src/Nephos.Migrations/
ARG PROJECT=Nephos.Faces.Api
RUN dotnet restore src/${PROJECT}/${PROJECT}.csproj --locked-mode \
    && dotnet publish src/${PROJECT}/${PROJECT}.csproj -c Release -o /out --no-restore /p:UseAppHost=false
FROM mcr.microsoft.com/dotnet/aspnet:10.0.8
RUN apt-get update -qq && apt-get install -y --no-install-recommends libgssapi-krb5-2
WORKDIR /app
COPY --from=build /out .
USER $APP_UID
ENV ASPNETCORE_HTTP_PORTS=8080
ENTRYPOINT ["dotnet"]
