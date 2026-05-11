param(
    [string]$RecordPath,
    [string]$WorkspaceRoot,
    [string]$ExpectedRecordType,
    [string]$OutputPath,
    [string]$DotnetPath
)

$ErrorActionPreference = "Stop"

function Get-Sha256 {
    param([string]$Path)

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $stream = [System.IO.File]::OpenRead($Path)
        try {
            $hash = $sha.ComputeHash($stream)
            return -join ($hash | ForEach-Object { $_.ToString("x2") })
        }
        finally {
            $stream.Dispose()
        }
    }
    finally {
        $sha.Dispose()
    }
}

function Resolve-WorkspacePath {
    param(
        [string]$WorkspaceRoot,
        [string]$Path
    )

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }

    return [System.IO.Path]::GetFullPath((Join-Path $WorkspaceRoot ($Path -replace '/', '\')))
}

if (-not $RecordPath) { throw "RecordPath is required." }

if (-not $DotnetPath -and $env:ARCHREALMS_DOTNET) {
    $DotnetPath = $env:ARCHREALMS_DOTNET
}

if ($DotnetPath) {
    $dotnet = (Resolve-Path -LiteralPath $DotnetPath).Path
}
else {
    $dotnet = (Get-Command dotnet -ErrorAction Stop).Source
}

$resolvedRecordPath = (Resolve-Path -LiteralPath $RecordPath).Path
if (-not $WorkspaceRoot) {
    $WorkspaceRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $resolvedRecordPath))))))
}

$resolvedWorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
$record = Get-Content -LiteralPath $resolvedRecordPath -Raw | ConvertFrom-Json
$reasons = New-Object System.Collections.Generic.List[string]

if ($ExpectedRecordType -and $record.record_type -ne $ExpectedRecordType) {
    $reasons.Add("record_type_mismatch")
}

if ($record.settlement_status -ne "not_settled") {
    $reasons.Add("settlement_status_is_not_not_settled")
}

$payloadHashMatches = $false
$signatureVerified = $false

if (-not $record.signature) {
    $reasons.Add("missing_signature")
}
else {
    $payloadPath = Resolve-WorkspacePath -WorkspaceRoot $resolvedWorkspaceRoot -Path ([string]$record.signature.signed_payload_path)
    $signaturePath = Resolve-WorkspacePath -WorkspaceRoot $resolvedWorkspaceRoot -Path ([string]$record.signature.signature_path)
    $publicKeyPath = Join-Path $resolvedWorkspaceRoot ("records\registry\public-keys\" + [string]$record.device_id + ".spki.der")

    if (-not (Test-Path -LiteralPath $payloadPath)) { $reasons.Add("signed_payload_not_found") }
    if (-not (Test-Path -LiteralPath $signaturePath)) { $reasons.Add("signature_file_not_found") }
    if (-not (Test-Path -LiteralPath $publicKeyPath)) { $reasons.Add("public_key_not_found") }

    if ((Test-Path -LiteralPath $payloadPath) -and (Test-Path -LiteralPath $signaturePath) -and (Test-Path -LiteralPath $publicKeyPath)) {
        $actualPayloadSha256 = Get-Sha256 -Path $payloadPath
        $payloadHashMatches = $actualPayloadSha256.Equals([string]$record.signature.signed_payload_sha256, [System.StringComparison]::OrdinalIgnoreCase)
        if (-not $payloadHashMatches) {
            $reasons.Add("signed_payload_hash_mismatch")
        }

        if ($payloadHashMatches) {
            $harnessRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("passport-review-record-verify-" + [Guid]::NewGuid().ToString("N"))
            New-Item -ItemType Directory -Force $harnessRoot | Out-Null
            $projectPath = Join-Path $harnessRoot "ReviewRecordSignatureVerifier.csproj"
            $programPath = Join-Path $harnessRoot "Program.cs"
            $projectText = @"
<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <OutputType>Exe</OutputType>
    <TargetFramework>net8.0</TargetFramework>
  </PropertyGroup>
</Project>
"@
            $programText = @"
using System;
using System.IO;
using System.Security.Cryptography;

internal static class Program
{
    private static int Main(string[] args)
    {
        if (args.Length < 3) return 2;
        var payloadBytes = File.ReadAllBytes(args[0]);
        var signatureBytes = File.ReadAllBytes(args[1]);
        var publicKeyBytes = File.ReadAllBytes(args[2]);
        using var rsa = RSA.Create();
        rsa.ImportSubjectPublicKeyInfo(publicKeyBytes, out _);
        var verified = rsa.VerifyData(payloadBytes, signatureBytes, HashAlgorithmName.SHA256, RSASignaturePadding.Pkcs1);
        Console.WriteLine(verified ? "true" : "false");
        return verified ? 0 : 1;
    }
}
"@
            Set-Content -LiteralPath $projectPath -Value $projectText -Encoding UTF8
            Set-Content -LiteralPath $programPath -Value $programText -Encoding UTF8
            $verifyOutput = & $dotnet run --project $projectPath -v q -- $payloadPath $signaturePath $publicKeyPath
            $signatureVerified = (($verifyOutput | Select-Object -Last 1) -eq "true")
            if (-not $signatureVerified) {
                $reasons.Add("signature_verification_failed")
            }
        }
    }
}

$verified = $reasons.Count -eq 0
$report = [pscustomobject]@{
    verified_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    record_path = $resolvedRecordPath
    record_type = $record.record_type
    record_id = $record.record_id
    verified = $verified
    payload_hash_matches = $payloadHashMatches
    signature_verified = $signatureVerified
    settlement_status = $record.settlement_status
    reasons = $reasons
}

if (-not $OutputPath) {
    $OutputPath = Join-Path (Split-Path -Parent $resolvedRecordPath) "signed-review-record-verification-report.json"
}

$outputDirectory = Split-Path -Parent $OutputPath
if ($outputDirectory) {
    New-Item -ItemType Directory -Force $outputDirectory | Out-Null
}

$report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
Get-Content -LiteralPath $OutputPath
