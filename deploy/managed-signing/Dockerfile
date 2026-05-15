FROM mcr.microsoft.com/dotnet/sdk:8.0 AS build
WORKDIR /src

COPY src/ArchrealmsPassport.ManagedSigning/ArchrealmsPassport.ManagedSigning.csproj src/ArchrealmsPassport.ManagedSigning/
RUN dotnet restore src/ArchrealmsPassport.ManagedSigning/ArchrealmsPassport.ManagedSigning.csproj

COPY . .
RUN dotnet publish src/ArchrealmsPassport.ManagedSigning/ArchrealmsPassport.ManagedSigning.csproj \
    -c Release \
    -o /app/publish \
    /p:UseAppHost=false

FROM mcr.microsoft.com/dotnet/aspnet:8.0 AS runtime
WORKDIR /app

RUN useradd --create-home --shell /usr/sbin/nologin archrealms
RUN mkdir -p /var/lib/archrealms/managed-signing && chown -R archrealms:archrealms /var/lib/archrealms

COPY --from=build /app/publish .

ENV ASPNETCORE_URLS=http://+:8080
ENV ARCHREALMS_MANAGED_SIGNING_LOCAL_PKCS8_PATH=/var/lib/archrealms/managed-signing/local-validation.pkcs8

USER archrealms
EXPOSE 8080

ENTRYPOINT ["dotnet", "ArchrealmsPassport.ManagedSigning.dll"]
