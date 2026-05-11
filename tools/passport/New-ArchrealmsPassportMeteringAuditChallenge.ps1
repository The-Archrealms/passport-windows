param(
    [string]$WorkspaceRoot,
    [string]$IdentityId,
    [string]$DeviceId,
    [string]$DeviceKeyReferencePath,
    [string]$AdmissionPath,
    [string]$RegistrarId,
    [string]$ChallengeReason,
    [string]$DotnetPath
)

$ErrorActionPreference = "Stop"

if (-not $WorkspaceRoot) { throw "WorkspaceRoot is required." }
if (-not $IdentityId) { throw "IdentityId is required." }
if (-not $DeviceId) { throw "DeviceId is required." }
if (-not $DeviceKeyReferencePath) { throw "DeviceKeyReferencePath is required." }
if (-not $AdmissionPath) { throw "AdmissionPath is required." }

if (-not $RegistrarId) {
    $RegistrarId = $DeviceId
}

if (-not $ChallengeReason) {
    $ChallengeReason = "routine_sample"
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
$resolvedAdmissionPath = (Resolve-Path -LiteralPath $AdmissionPath).Path
$harnessRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("passport-metering-audit-challenge-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Force $harnessRoot | Out-Null

$projectPath = Join-Path $harnessRoot "PassportMeteringAuditChallenge.csproj"
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

namespace PassportMeteringAuditChallenge;

internal static class Program
{
    private static int Main(string[] args)
    {
        try
        {
            if (args.Length < 7)
            {
                throw new InvalidOperationException("Expected workspace root, identity id, device id, key reference, admission path, registrar id, and challenge reason.");
            }

            var service = new PassportRecordService();
            var result = service.CreateMeteringAuditChallenge(args[0], args[1], args[2], args[3], args[4], args[5], args[6]);
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

$output = & $dotnet run --project $projectPath -v q -p:RuntimeIdentifiers=win-x64 -- $resolvedWorkspaceRoot $IdentityId $DeviceId $DeviceKeyReferencePath $resolvedAdmissionPath $RegistrarId $ChallengeReason
if ($LASTEXITCODE -ne 0) {
    throw "Metering audit challenge harness failed: $output"
}

$output | Select-Object -Last 1
