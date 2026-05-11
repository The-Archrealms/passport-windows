param(
    [string]$WorkspaceRoot,
    [string]$IdentityId,
    [string]$DeviceId,
    [string]$DeviceKeyReferencePath,
    [string]$PackageRoot,
    [string]$PackageVerificationReportPath,
    [string]$DotnetPath
)

$ErrorActionPreference = "Stop"

if (-not $WorkspaceRoot) {
    throw "WorkspaceRoot is required."
}

if (-not $IdentityId) {
    throw "IdentityId is required."
}

if (-not $DeviceId) {
    throw "DeviceId is required."
}

if (-not $DeviceKeyReferencePath) {
    throw "DeviceKeyReferencePath is required."
}

if (-not $PackageRoot) {
    throw "PackageRoot is required."
}

if (-not $DotnetPath -and $env:ARCHREALMS_DOTNET) {
    $DotnetPath = $env:ARCHREALMS_DOTNET
}

if ($DotnetPath) {
    $dotnet = (Resolve-Path -LiteralPath $DotnetPath).Path
}
else {
    $dotnet = (Get-Command dotnet -ErrorAction Stop).Source
}

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
$resolvedWorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
$resolvedPackageRoot = (Resolve-Path -LiteralPath $PackageRoot).Path

if (-not $PackageVerificationReportPath) {
    $PackageVerificationReportPath = Join-Path $resolvedPackageRoot "metering-package-verification-report.json"
}

$resolvedVerificationReportPath = [System.IO.Path]::GetFullPath($PackageVerificationReportPath)
$verifyPackageScript = Join-Path $PSScriptRoot "Verify-ArchrealmsPassportMeteringPackage.ps1"
powershell -ExecutionPolicy Bypass -File $verifyPackageScript -PackageRoot $resolvedPackageRoot -OutputPath $resolvedVerificationReportPath | Out-Null

$verification = Get-Content -LiteralPath $resolvedVerificationReportPath -Raw | ConvertFrom-Json
if (-not $verification.verified) {
    throw "Metering package verification did not pass; admission was not created."
}

$harnessRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("passport-metering-admission-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force $harnessRoot | Out-Null

$projectPath = Join-Path $harnessRoot "PassportMeteringAdmission.csproj"
$programPath = Join-Path $harnessRoot "Program.cs"
$appProjectPath = Join-Path $repoRoot "src\ArchrealmsPassport.Windows\ArchrealmsPassport.Windows.csproj"

$projectText = @"
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <OutputType>Exe</OutputType>
    <TargetFramework>net8.0-windows10.0.19041.0</TargetFramework>
  </PropertyGroup>
  <ItemGroup>
    <ProjectReference Include="$appProjectPath" />
  </ItemGroup>
</Project>
"@

$programText = @"
using System;
using System.Text.Json;
using ArchrealmsPassport.Windows.Services;

namespace PassportMeteringAdmission;

internal static class Program
{
    private static int Main(string[] args)
    {
        try
        {
            if (args.Length < 6)
            {
                throw new InvalidOperationException("Expected workspace root, identity id, device id, key reference, package root, and verification report path.");
            }

            var service = new PassportRecordService();
            var result = service.CreateMeteringPackageAdmission(args[0], args[1], args[2], args[3], args[4], args[5]);
            Console.WriteLine(JsonSerializer.Serialize(result));
            return result.Succeeded ? 0 : 1;
        }
        catch (Exception ex)
        {
            Console.Error.WriteLine(ex.ToString());
            return 1;
        }
    }
}
"@

Set-Content -LiteralPath $projectPath -Value $projectText -Encoding UTF8
Set-Content -LiteralPath $programPath -Value $programText -Encoding UTF8

$output = & $dotnet run --project $projectPath -v q -p:RuntimeIdentifiers=win-x64 -- $resolvedWorkspaceRoot $IdentityId $DeviceId $DeviceKeyReferencePath $resolvedPackageRoot $resolvedVerificationReportPath
if ($LASTEXITCODE -ne 0) {
    throw "Metering admission harness failed: $output"
}

$output | Select-Object -Last 1
