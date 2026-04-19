param(
    [string]$DotnetPath,
    [string]$OutputPath
)

$ErrorActionPreference = "Stop"

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
$smokeRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("passport-smoke-" + [Guid]::NewGuid().ToString("N"))
$harnessRoot = Join-Path $smokeRoot "harness"
$workspacesRoot = Join-Path $smokeRoot "workspaces"
New-Item -ItemType Directory -Force $harnessRoot | Out-Null
New-Item -ItemType Directory -Force $workspacesRoot | Out-Null

$projectPath = Join-Path $harnessRoot "PassportSmoke.csproj"
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
using System.IO;
using System.Text.Json;
using ArchrealmsPassport.Windows.Services;

namespace PassportSmoke;

internal static class Program
{
    private static int Main(string[] args)
    {
        try
        {
            if (args.Length < 1)
            {
                throw new InvalidOperationException("Missing workspaces root.");
            }

            var workspacesRoot = args[0];
            var authorityWorkspace = Path.Combine(workspacesRoot, "authority");
            var candidateWorkspace = Path.Combine(workspacesRoot, "candidate");
            Directory.CreateDirectory(authorityWorkspace);
            Directory.CreateDirectory(candidateWorkspace);

            var recordService = new PassportRecordService();
            var cryptoService = new PassportCryptoService();

            var authority = recordService.CreateNewIdentity(authorityWorkspace, "Authority Persona", "pseudonymous", "Authority Device", false);
            if (!authority.Succeeded) throw new InvalidOperationException(authority.Message);

            var joinRequest = recordService.CreateJoinRequest(candidateWorkspace, authority.IdentityId, "Candidate Device", false);
            if (!joinRequest.Succeeded) throw new InvalidOperationException(joinRequest.Message);

            var approval = cryptoService.ApproveJoinRequest(authorityWorkspace, authority.IdentityId, authority.DeviceId, authority.PrivateKeyPath, joinRequest.JoinRequestPath);
            if (!approval.Succeeded) throw new InvalidOperationException(approval.Message);

            var activation = cryptoService.ImportJoinApproval(candidateWorkspace, approval.ApprovalPackagePath, joinRequest.DeviceId, joinRequest.PrivateKeyPath);
            if (!activation.Succeeded) throw new InvalidOperationException(activation.Message);

            var submission = cryptoService.CreateRegistrySubmission(candidateWorkspace, activation.IdentityId, activation.DeviceId, joinRequest.PrivateKeyPath);
            if (!submission.Succeeded) throw new InvalidOperationException(submission.Message);

            var payload = new
            {
                AuthorityDeviceId = authority.DeviceId,
                AuthorityKeyReference = authority.PrivateKeyPath,
                CandidateDeviceId = joinRequest.DeviceId,
                CandidateKeyReference = joinRequest.PrivateKeyPath,
                SubmissionPath = submission.SubmissionPath,
                AuthorityWorkspace = authorityWorkspace
            };

            Console.WriteLine(JsonSerializer.Serialize(payload));
            return 0;
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

$harnessOutput = & $dotnet run --project $projectPath -v q -- $workspacesRoot
if ($LASTEXITCODE -ne 0) {
    throw "Passport smoke harness failed."
}

$harnessJson = $harnessOutput | Select-Object -Last 1
$harness = $harnessJson | ConvertFrom-Json

$verifyScript = Join-Path $repoRoot "tools\passport\Verify-ArchrealmsRegistrySubmission.ps1"
$submissionRoot = Split-Path -Parent $harness.SubmissionPath
$unanchoredReport = Join-Path $submissionRoot "verification-report.unanchored.json"
$anchoredReport = Join-Path $submissionRoot "verification-report.anchored.json"

powershell -ExecutionPolicy Bypass -File $verifyScript -SubmissionPath $harness.SubmissionPath -OutputPath $unanchoredReport -DotnetPath $dotnet | Out-Null
powershell -ExecutionPolicy Bypass -File $verifyScript -SubmissionPath $harness.SubmissionPath -OutputPath $anchoredReport -TrustedWorkspaceRoot $harness.AuthorityWorkspace -DotnetPath $dotnet | Out-Null

$unanchored = Get-Content -LiteralPath $unanchoredReport -Raw | ConvertFrom-Json
$anchored = Get-Content -LiteralPath $anchoredReport -Raw | ConvertFrom-Json
$authorityKeyRef = Get-Content -LiteralPath $harness.AuthorityKeyReference -Raw | ConvertFrom-Json
$candidateKeyRef = Get-Content -LiteralPath $harness.CandidateKeyReference -Raw | ConvertFrom-Json

$result = [pscustomobject]@{
    verified_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    dotnet = $dotnet
    authority_key_backend = $authorityKeyRef.StorageBackend
    authority_key_provider = $authorityKeyRef.Provider
    candidate_key_backend = $candidateKeyRef.StorageBackend
    candidate_key_provider = $candidateKeyRef.Provider
    unanchored_verified = $unanchored.verified
    unanchored_authorization_summary = $unanchored.authorization_summary
    anchored_verified = $anchored.verified
    anchored_authorization_summary = $anchored.authorization_summary
    authority_workspace = $harness.AuthorityWorkspace
    submission_path = $harness.SubmissionPath
}

if (-not $OutputPath) {
    $OutputPath = Join-Path $smokeRoot "passport-smoke-report.json"
}

$outputDirectory = Split-Path -Parent $OutputPath
if ($outputDirectory) {
    New-Item -ItemType Directory -Force $outputDirectory | Out-Null
}

$result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
Get-Content -LiteralPath $OutputPath
