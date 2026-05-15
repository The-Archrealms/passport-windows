# syntax=docker/dockerfile:1

FROM mcr.microsoft.com/dotnet/sdk:8.0 AS build
WORKDIR /src

COPY global.json ./
COPY src/ArchrealmsPassport.Core/ArchrealmsPassport.Core.csproj src/ArchrealmsPassport.Core/
COPY src/ArchrealmsPassport.HostedServices/ArchrealmsPassport.HostedServices.csproj src/ArchrealmsPassport.HostedServices/
RUN dotnet restore src/ArchrealmsPassport.HostedServices/ArchrealmsPassport.HostedServices.csproj

COPY src/ src/
RUN dotnet publish src/ArchrealmsPassport.HostedServices/ArchrealmsPassport.HostedServices.csproj \
    -c Release \
    -o /app/publish \
    --no-restore \
    /p:UseAppHost=false

FROM mcr.microsoft.com/dotnet/aspnet:8.0 AS runtime
WORKDIR /app

ENV ASPNETCORE_URLS=http://+:8080 \
    DOTNET_EnableDiagnostics=0 \
    ARCHREALMS_PASSPORT_HOSTED_DATA_ROOT=/var/lib/archrealms/passport-hosted

RUN useradd --create-home --home-dir /home/archrealms --shell /usr/sbin/nologin archrealms \
    && mkdir -p /var/lib/archrealms/passport-hosted \
    && chown -R archrealms:archrealms /var/lib/archrealms /app

COPY --from=build --chown=archrealms:archrealms /app/publish .

USER archrealms
EXPOSE 8080
VOLUME ["/var/lib/archrealms/passport-hosted"]

ENTRYPOINT ["dotnet", "ArchrealmsPassport.HostedServices.dll"]
