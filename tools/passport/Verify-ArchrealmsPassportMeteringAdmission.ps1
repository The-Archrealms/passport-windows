param(
    [string]$AdmissionPath,
    [string]$WorkspaceRoot,
    [string]$OutputPath,
    [string]$DotnetPath
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

if (-not $AdmissionPath) {
    throw "AdmissionPath is required."
}

$resolvedAdmissionPath = (Resolve-Path -LiteralPath $AdmissionPath).Path
if (-not $WorkspaceRoot) {
    $WorkspaceRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $resolvedAdmissionPath)))))
}

$resolvedWorkspaceRoot = (Resolve-Path -LiteralPath $WorkspaceRoot).Path
$admission = Get-Content -LiteralPath $resolvedAdmissionPath -Raw | ConvertFrom-Json
$reasons = New-Object System.Collections.Generic.List[string]

if ($admission.record_type -ne "passport_metering_admission_record") {
    $reasons.Add("record_type_is_not_passport_metering_admission_record")
}

if ($admission.status -ne "admitted") {
    $reasons.Add("admission_status_is_not_admitted")
}

if ($admission.settlement_status -ne "not_settled") {
    $reasons.Add("settlement_status_is_not_not_settled")
}

if (-not $admission.package_verification.verified) {
    $reasons.Add("package_verification_not_verified")
}

if (-not $admission.package_verification.document_hashes_valid) {
    $reasons.Add("package_document_hashes_not_valid")
}

$payloadHashMatches = $false
$signatureVerified = $false
$payloadPath = ""
$signaturePath = ""
$publicKeyPath = ""

if (-not $admission.signature) {
    $reasons.Add("missing_signature")
}
else {
    $payloadPath = Resolve-WorkspacePath -WorkspaceRoot $resolvedWorkspaceRoot -Path ([string]$admission.signature.signed_payload_path)
    $signaturePath = Resolve-WorkspacePath -WorkspaceRoot $resolvedWorkspaceRoot -Path ([string]$admission.signature.signature_path)
    $publicKeyPath = Join-Path $resolvedWorkspaceRoot ("records\registry\public-keys\" + [string]$admission.device_id + ".spki.der")

    if (-not (Test-Path -LiteralPath $payloadPath)) {
        $reasons.Add("signed_payload_not_found")
    }

    if (-not (Test-Path -LiteralPath $signaturePath)) {
        $reasons.Add("signature_file_not_found")
    }

    if (-not (Test-Path -LiteralPath $publicKeyPath)) {
        $reasons.Add("public_key_not_found")
    }

    if ((Test-Path -LiteralPath $payloadPath) -and (Test-Path -LiteralPath $signaturePath) -and (Test-Path -LiteralPath $publicKeyPath)) {
        $actualPayloadSha256 = Get-Sha256 -Path $payloadPath
        $payloadHashMatches = $actualPayloadSha256.Equals([string]$admission.signature.signed_payload_sha256, [System.StringComparison]::OrdinalIgnoreCase)
        if (-not $payloadHashMatches) {
            $reasons.Add("signed_payload_hash_mismatch")
        }

        if ($payloadHashMatches) {
            $harnessRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("passport-admission-verify-" + [Guid]::NewGuid().ToString("N"))
            New-Item -ItemType Directory -Force $harnessRoot | Out-Null
            $projectPath = Join-Path $harnessRoot "AdmissionSignatureVerifier.csproj"
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
        if (args.Length < 3)
        {
            return 2;
        }

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
    admission_path = $resolvedAdmissionPath
    record_id = $admission.record_id
    package_id = $admission.package_id
    verified = $verified
    payload_hash_matches = $payloadHashMatches
    signature_verified = $signatureVerified
    settlement_status = $admission.settlement_status
    reasons = $reasons
}

if (-not $OutputPath) {
    $OutputPath = Join-Path (Split-Path -Parent $resolvedAdmissionPath) "metering-admission-verification-report.json"
}

$outputDirectory = Split-Path -Parent $OutputPath
if ($outputDirectory) {
    New-Item -ItemType Directory -Force $outputDirectory | Out-Null
}

$report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
Get-Content -LiteralPath $OutputPath
