FROM mcr.microsoft.com/dotnet/sdk:10.0.300 AS build
WORKDIR /src
COPY . .
ARG PROJECT=Nephos.Library.Api
RUN dotnet restore src/${PROJECT}/${PROJECT}.csproj --locked-mode \
    && dotnet publish src/${PROJECT}/${PROJECT}.csproj -c Release -o /out --no-restore /p:UseAppHost=false

FROM mcr.microsoft.com/dotnet/aspnet:10.0.8 AS runtime
RUN apt-get update -qq && apt-get install -y --no-install-recommends ffmpeg libgssapi-krb5-2
WORKDIR /app
COPY --from=build /out .
USER $APP_UID
ENV ASPNETCORE_HTTP_PORTS=8080
EXPOSE 8080
ENTRYPOINT ["dotnet"]
