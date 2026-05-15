param(
    [string]$OutputDirectory = "artifacts\release\production-provisioning-packet-working",

    [switch]$Force,

    [switch]$NoValidate
)

$ErrorActionPreference = "Stop"

$scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$repoRoot = [System.IO.Path]::GetFullPath((Join-Path $scriptRoot "..\.."))

function Resolve-RepoPath {
    param([string]$Path)

    if ([System.IO.Path]::IsPathRooted($Path)) {
        return [System.IO.Path]::GetFullPath($Path)
    }

    return [System.IO.Path]::GetFullPath((Join-Path $repoRoot $Path))
}

function Format-CommandArgument {
    param([string]$Argument)

    if ($null -eq $Argument) {
        return '""'
    }

    if ($Argument.Length -eq 0 -or $Argument -match '\s|["]') {
        return '"' + ($Argument -replace '"', '\"') + '"'
    }

    return $Argument
}

function Invoke-CommandCapture {
    param(
        [string]$FilePath,
        [string[]]$Arguments,
        [string]$WorkingDirectory
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = ($Arguments | ForEach-Object { Format-CommandArgument -Argument $_ }) -join " "
    $psi.WorkingDirectory = $WorkingDirectory
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false

    $process = [System.Diagnostics.Process]::Start($psi)
    $stdout = $process.StandardOutput.ReadToEnd()
    $stderr = $process.StandardError.ReadToEnd()
    $process.WaitForExit()

    return [pscustomobject][ordered]@{
        command = (($Arguments | ForEach-Object { Format-CommandArgument -Argument $_ }) -join " ")
        exit_code = [int]$process.ExitCode
        output_excerpt = (($stdout + $stderr) -replace "`r", "").Trim()
    }
}

function Get-SourceCommit {
    $git = Get-Command git -ErrorAction SilentlyContinue
    if ($null -eq $git) {
        return ""
    }

    $result = Invoke-CommandCapture -FilePath $git.Source -Arguments @("rev-parse", "--short", "HEAD") -WorkingDirectory $repoRoot
    if ($result.exit_code -ne 0) {
        return ""
    }

    return $result.output_excerpt.Trim()
}

function Clear-PacketSubfolder {
    param(
        [string]$PacketRoot,
        [string]$Subfolder
    )

    $target = [System.IO.Path]::GetFullPath((Join-Path $PacketRoot $Subfolder))
    $rootWithSeparator = $PacketRoot.TrimEnd([System.IO.Path]::DirectorySeparatorChar, [System.IO.Path]::AltDirectorySeparatorChar) + [System.IO.Path]::DirectorySeparatorChar
    if (-not $target.StartsWith($rootWithSeparator, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to clear a path outside the packet root: $target"
    }

    if (Test-Path -LiteralPath $target) {
        Remove-Item -LiteralPath $target -Recurse -Force
    }
}

$resolvedOutput = Resolve-RepoPath -Path $OutputDirectory
if ((Test-Path -LiteralPath $resolvedOutput) -and -not $Force) {
    throw "OutputDirectory already exists. Use -Force to update it: $resolvedOutput"
}

New-Item -ItemType Directory -Force -Path $resolvedOutput | Out-Null

$folders = @(
    "package-signing",
    "release-lane-endpoints",
    "managed-storage",
    "managed-signing-custody",
    "canary-readiness",
    "hosted-services",
    "managed-signing",
    "open-weight-ai-runtime",
    "production-ops",
    "production-monetary"
)

$copied = @()
foreach ($folder in $folders) {
    $source = Join-Path $repoRoot "deploy\$folder"
    if (-not (Test-Path -LiteralPath $source -PathType Container)) {
        throw "Missing source provisioning folder: $source"
    }

    if ($Force) {
        Clear-PacketSubfolder -PacketRoot $resolvedOutput -Subfolder $folder
    }

    $target = Join-Path $resolvedOutput $folder
    New-Item -ItemType Directory -Force -Path $target | Out-Null
    Copy-Item -Path (Join-Path $source "*") -Destination $target -Recurse -Force
    $copied += [pscustomobject][ordered]@{
        source = $source
        target = $target
    }
}

$validation = [pscustomobject][ordered]@{
    skipped = [bool]$NoValidate
    exit_code = $null
    report_path = ""
    output_excerpt = ""
}

if (-not $NoValidate) {
    $powershell = Get-Command powershell -ErrorAction Stop
    $validationReport = Join-Path $resolvedOutput "production-provisioning-packet-validation-report.json"
    $validationResult = Invoke-CommandCapture `
        -FilePath $powershell.Source `
        -Arguments @(
            "-NoProfile",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            (Join-Path $repoRoot "tools\release\Test-PassportProductionProvisioningPacket.ps1"),
            "-PacketRoot",
            $resolvedOutput,
            "-SkipPublish",
            "-OutputPath",
            $validationReport
        ) `
        -WorkingDirectory $repoRoot

    $excerpt = $validationResult.output_excerpt
    if ($excerpt.Length -gt 4000) {
        $excerpt = $excerpt.Substring($excerpt.Length - 4000)
    }

    $validation = [pscustomobject][ordered]@{
        skipped = $false
        exit_code = $validationResult.exit_code
        report_path = $validationReport
        output_excerpt = $excerpt
    }

    if ($validationResult.exit_code -ne 0) {
        throw "Generated production provisioning packet failed validation. See $validationReport"
    }
}

$manifest = [pscustomobject][ordered]@{
    schema = "archrealms.passport.production_provisioning_packet_scaffold.v1"
    created_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    repo_root = $repoRoot
    source_commit = Get-SourceCommit
    output_directory = $resolvedOutput
    copied_items = $copied
    validation = $validation
    next_steps = @(
        "Copy this folder into the controlled production document system if the generated folder is only a local working copy.",
        "Fill every bracketed placeholder in the copied provisioning documents.",
        "Complete canary-readiness evidence after the allowlisted CanaryMvp lane has run, validate the packet with Test-PassportCanaryMvpReadinessEvidencePacket.ps1, then validate readiness with Test-PassportCanaryMvpReadiness.ps1.",
        "Run Test-PassportProductionProvisioningPacket.ps1 -PacketRoot <packet-root> -RequireNoPlaceholders before loading values into the ProductionMvp readiness environment.",
        "Run live probes only after approved production endpoints and authority records exist."
    )
}

$manifestPath = Join-Path $resolvedOutput "production-provisioning-packet.manifest.json"
$manifestJson = $manifest | ConvertTo-Json -Depth 8
Set-Content -LiteralPath $manifestPath -Value $manifestJson -Encoding UTF8
$manifestJson
