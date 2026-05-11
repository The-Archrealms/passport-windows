param(
    [string]$ManifestPath,
    [string]$PackagePath,
    [string]$ArtifactRoot,
    [string]$OutputPath,
    [switch]$KeepWorkspace,
    [switch]$SkipDaemon
)

$ErrorActionPreference = "Stop"

function Add-Failure {
    param(
        [System.Collections.Generic.List[string]]$Failures,
        [string]$Message
    )

    $Failures.Add($Message) | Out-Null
}

function Get-FreeTcpPort {
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    try {
        $listener.Start()
        return $listener.LocalEndpoint.Port
    }
    finally {
        $listener.Stop()
    }
}

function Expand-PackageToScratch {
    param(
        [string]$Path,
        [string]$ScratchRoot
    )

    $resolvedPath = (Resolve-Path -LiteralPath $Path).Path
    $extractRoot = Join-Path $ScratchRoot ([System.IO.Path]::GetFileNameWithoutExtension($resolvedPath))
    if (Test-Path -LiteralPath $extractRoot) {
        Remove-SafeDirectory -Path $extractRoot -AllowedRoot $ScratchRoot
    }

    New-Item -ItemType Directory -Force -Path $extractRoot | Out-Null
    $archiveForExpansion = $resolvedPath
    if ([System.IO.Path]::GetExtension($resolvedPath) -ieq ".msix") {
        $archiveForExpansion = Join-Path $ScratchRoot (([System.IO.Path]::GetFileNameWithoutExtension($resolvedPath)) + ".zip")
        Copy-Item -LiteralPath $resolvedPath -Destination $archiveForExpansion -Force
    }

    Expand-Archive -LiteralPath $archiveForExpansion -DestinationPath $extractRoot -Force
    return $extractRoot
}

function Remove-SafeDirectory {
    param(
        [string]$Path,
        [string]$AllowedRoot,
        [switch]$BestEffort
    )

    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) {
        return
    }

    $resolvedPath = [System.IO.Path]::GetFullPath($Path)
    $resolvedAllowedRoot = [System.IO.Path]::GetFullPath($AllowedRoot)
    if (-not $resolvedPath.StartsWith($resolvedAllowedRoot, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to delete outside allowed root. Path: $resolvedPath Root: $resolvedAllowedRoot"
    }

    for ($attempt = 1; $attempt -le 5; $attempt++) {
        try {
            Remove-Item -Recurse -Force -LiteralPath $resolvedPath
            return
        }
        catch {
            if ($attempt -eq 5) {
                if ($BestEffort) {
                    Write-Warning ("Could not remove temporary validation directory: " + $_.Exception.Message)
                    return
                }

                throw
            }

            Start-Sleep -Milliseconds (500 * $attempt)
        }
    }
}

function Resolve-PackagedArtifactRoot {
    param(
        [string]$ManifestPath,
        [string]$PackagePath,
        [string]$ArtifactRoot,
        [string]$ScratchRoot
    )

    if ($ArtifactRoot) {
        return [pscustomobject]@{
            root = (Resolve-Path -LiteralPath $ArtifactRoot).Path
            source_type = "artifact-root"
            manifest = $null
            manifest_path = ""
            package_path = ""
        }
    }

    if ($PackagePath) {
        return [pscustomobject]@{
            root = Expand-PackageToScratch -Path $PackagePath -ScratchRoot $ScratchRoot
            source_type = "package"
            manifest = $null
            manifest_path = ""
            package_path = (Resolve-Path -LiteralPath $PackagePath).Path
        }
    }

    if (-not $ManifestPath) {
        $candidates = @(
            "artifacts\release\passport-windows-win-x64\release-manifest.json",
            "artifacts\release-validation\passport-windows-win-x64\release-manifest.json",
            "artifacts\release\passport-windows-msix-sideload\x64\msix-package-manifest.json",
            "artifacts\release\passport-windows-msix-store\x64\msix-package-manifest.json",
            "artifacts\release\passport-windows-msix\x64\msix-package-manifest.json",
            "artifacts\release-validation-msix\x64\msix-package-manifest.json"
        )

        $ManifestPath = $candidates | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf } | Select-Object -First 1
    }

    if (-not $ManifestPath) {
        throw "No manifest, package path, or artifact root was supplied or found."
    }

    $resolvedManifestPath = (Resolve-Path -LiteralPath $ManifestPath).Path
    $manifestDirectory = Split-Path -Parent $resolvedManifestPath
    $manifest = Get-Content -LiteralPath $resolvedManifestPath -Raw | ConvertFrom-Json

    foreach ($propertyName in @("zip_path", "package_path")) {
        if (-not $manifest.PSObject.Properties[$propertyName]) {
            continue
        }

        $candidate = [string]$manifest.$propertyName
        if (-not $candidate) {
            continue
        }

        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf)) {
            $candidate = Join-Path $manifestDirectory (Split-Path -Leaf $candidate)
        }

        if (Test-Path -LiteralPath $candidate -PathType Leaf) {
            return [pscustomobject]@{
                root = Expand-PackageToScratch -Path $candidate -ScratchRoot $ScratchRoot
                source_type = $propertyName
                manifest = $manifest
                manifest_path = $resolvedManifestPath
                package_path = (Resolve-Path -LiteralPath $candidate).Path
            }
        }
    }

    foreach ($propertyName in @("layout_dir", "publish_dir")) {
        if ($manifest.PSObject.Properties[$propertyName]) {
            $candidate = [string]$manifest.$propertyName
            if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Container)) {
                return [pscustomobject]@{
                    root = (Resolve-Path -LiteralPath $candidate).Path
                    source_type = $propertyName
                    manifest = $manifest
                    manifest_path = $resolvedManifestPath
                    package_path = ""
                }
            }
        }
    }

    throw "Could not resolve artifact root from manifest $resolvedManifestPath."
}

function Test-RequiredFiles {
    param(
        [string]$Root,
        [System.Collections.Generic.List[string]]$Failures
    )

    $requiredFiles = @(
        "ArchrealmsPassport.Windows.exe",
        "tools\ipfs\ArchrealmsIpfs.psm1",
        "tools\ipfs\Initialize-ArchrealmsIpfsNode.ps1",
        "tools\ipfs\Export-ArchrealmsIpfsCar.ps1",
        "tools\ipfs\runtime\ipfs.exe",
        "tools\passport\Publish-ArchrealmsRegistrySubmissionToIpfs.ps1",
        "tools\passport\Read-ArchrealmsIpfsText.ps1",
        "tools\passport\Save-ArchrealmsIpfsFileReadOnly.ps1",
        "registry\templates\passport-identity-record.template.json"
    )

    foreach ($relativePath in $requiredFiles) {
        if (-not (Test-Path -LiteralPath (Join-Path $Root $relativePath) -PathType Leaf)) {
            Add-Failure -Failures $Failures -Message "Required installed artifact file is missing: $relativePath"
        }
    }

    return $requiredFiles.Count
}

function Invoke-JsonCommand {
    param(
        [string]$FilePath,
        [string[]]$Arguments,
        [string]$WorkingDirectory
    )

    Push-Location -LiteralPath $WorkingDirectory
    try {
        $output = @(& $FilePath @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    }
    finally {
        Pop-Location
    }

    $combinedOutput = ($output | ForEach-Object { [string]$_ }) -join [Environment]::NewLine
    if ($exitCode -ne 0) {
        throw "Command failed: $FilePath $($Arguments -join ' ')`n$combinedOutput"
    }

    return [pscustomobject]@{
        stdout = $combinedOutput
        stderr = ""
        exit_code = $exitCode
    }
}

function Start-IpfsDaemon {
    param(
        [string]$IpfsCliPath,
        [string]$IpfsRepoPath,
        [string]$WorkingDirectory
    )

    $processStartInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $processStartInfo.FileName = $IpfsCliPath
    $processStartInfo.WorkingDirectory = $WorkingDirectory
    $processStartInfo.UseShellExecute = $false
    $processStartInfo.CreateNoWindow = $true
    $processStartInfo.RedirectStandardOutput = $true
    $processStartInfo.RedirectStandardError = $true
    $processStartInfo.Arguments = "daemon --enable-gc"
    $processStartInfo.EnvironmentVariables["IPFS_PATH"] = $IpfsRepoPath
    $processStartInfo.EnvironmentVariables["IPFS_TELEMETRY"] = "off"

    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $processStartInfo
    [void]$process.Start()
    return $process
}

function Wait-ForIpfsApi {
    param(
        [string]$ApiEndpoint,
        [int]$TimeoutSeconds = 120
    )

    $headers = @{ "User-Agent" = "ArchrealmsPassportReleaseValidation/1.0" }
    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        try {
            return Invoke-RestMethod -Method Post -Uri ($ApiEndpoint + "/api/v0/version") -Headers $headers -TimeoutSec 2
        }
        catch {
            Start-Sleep -Milliseconds 500
        }
    } while ([DateTime]::UtcNow -lt $deadline)

    throw "IPFS API was not reachable before timeout: $ApiEndpoint"
}

function Stop-IpfsDaemon {
    param(
        [System.Diagnostics.Process]$Process,
        [string]$ApiEndpoint
    )

    if (-not $Process) {
        return $false
    }

    try {
        Invoke-RestMethod -Method Post -Uri ($ApiEndpoint + "/api/v0/shutdown") -Headers @{ "User-Agent" = "ArchrealmsPassportReleaseValidation/1.0" } -TimeoutSec 2 | Out-Null
    }
    catch {
    }

    if (-not $Process.WaitForExit(30000)) {
        try {
            $Process.Kill()
            $Process.WaitForExit(5000) | Out-Null
        }
        catch {
        }
    }

    return $Process.HasExited
}

$scratchRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("passport-installed-validation-" + [Guid]::NewGuid().ToString("N"))
$workspaceRoot = Join-Path $scratchRoot "workspace"
$ipfsRepoPath = Join-Path $scratchRoot "ipfs-repo"
$daemonProcess = $null
$oldArchrealmsIpfsCli = $env:ARCHREALMS_IPFS_CLI
$oldIpfsPath = $env:IPFS_PATH
$failures = [System.Collections.Generic.List[string]]::new()
$report = $null
$stage = "starting validation"
$artifactInfo = $null
$resolvedArtifactRoot = $ArtifactRoot

New-Item -ItemType Directory -Force -Path $scratchRoot | Out-Null

try {
    $stage = "resolving packaged artifact"
    $artifactInfo = Resolve-PackagedArtifactRoot `
        -ManifestPath $ManifestPath `
        -PackagePath $PackagePath `
        -ArtifactRoot $ArtifactRoot `
        -ScratchRoot $scratchRoot

    $resolvedArtifactRoot = $artifactInfo.root
    $stage = "checking installed artifact files"
    $requiredFileCount = Test-RequiredFiles -Root $resolvedArtifactRoot -Failures $failures
    $ipfsCliPath = Join-Path $resolvedArtifactRoot "tools\ipfs\runtime\ipfs.exe"
    $initializeScript = Join-Path $resolvedArtifactRoot "tools\ipfs\Initialize-ArchrealmsIpfsNode.ps1"
    $exportCarScript = Join-Path $resolvedArtifactRoot "tools\ipfs\Export-ArchrealmsIpfsCar.ps1"
    $powershell = (Get-Command powershell -ErrorAction Stop).Source

    $env:ARCHREALMS_IPFS_CLI = $ipfsCliPath

    $ipfsVersion = ""
    if (Test-Path -LiteralPath $ipfsCliPath -PathType Leaf) {
        $stage = "checking bundled ipfs version"
        $ipfsVersionOutput = @(& $ipfsCliPath --version 2>&1)
        if ($LASTEXITCODE -ne 0) {
            Add-Failure -Failures $failures -Message "Bundled ipfs.exe failed --version."
        }
        elseif ($ipfsVersionOutput.Count -eq 0) {
            Add-Failure -Failures $failures -Message "Bundled ipfs.exe --version produced no output."
        }
        else {
            $ipfsVersion = ($ipfsVersionOutput | Select-Object -First 1).ToString().Trim()
        }
    }

    $stage = "choosing isolated node ports"
    $apiPort = Get-FreeTcpPort
    $gatewayPort = Get-FreeTcpPort
    $swarmPort = Get-FreeTcpPort
    $apiMultiaddr = "/ip4/127.0.0.1/tcp/$apiPort"
    $gatewayMultiaddr = "/ip4/127.0.0.1/tcp/$gatewayPort"
    $apiEndpoint = "http://127.0.0.1:$apiPort"

    $stage = "initializing bundled IPFS repo"
    Invoke-JsonCommand `
        -FilePath $powershell `
        -WorkingDirectory $resolvedArtifactRoot `
        -Arguments @(
            "-NoProfile",
            "-ExecutionPolicy", "Bypass",
            "-File", $initializeScript,
            "-WorkspaceRoot", $workspaceRoot,
            "-IpfsRepoPath", $ipfsRepoPath,
            "-ApiMultiaddr", $apiMultiaddr,
            "-GatewayMultiaddr", $gatewayMultiaddr,
            "-SwarmPort", [string]$swarmPort,
            "-StorageMax", "5GB",
            "-StorageGCWatermark", "80",
            "-ProvideStrategy", "pinned",
            "-ParticipationMode", "Public archive contributor",
            "-CachePolicy", "Balanced pinned archive"
        ) | Out-Null

    $stage = "reading initialized node record"
    $nodeRecordPath = Join-Path $workspaceRoot "records\passport\ipfs-node.local.json"
    $nodeRecord = $null
    if (Test-Path -LiteralPath $nodeRecordPath -PathType Leaf) {
        $nodeRecord = Get-Content -LiteralPath $nodeRecordPath -Raw | ConvertFrom-Json
        if ($nodeRecord.storage_max -ne "5GB") {
            Add-Failure -Failures $failures -Message "Node record did not preserve StorageMax from installed artifact validation."
        }
        if ([int]$nodeRecord.storage_gc_watermark -ne 80) {
            Add-Failure -Failures $failures -Message "Node record did not preserve StorageGCWatermark from installed artifact validation."
        }
        if ($nodeRecord.provide_strategy -ne "pinned") {
            Add-Failure -Failures $failures -Message "Node record did not preserve ProvideStrategy from installed artifact validation."
        }
        if ($nodeRecord.participation_mode -ne "Public archive contributor") {
            Add-Failure -Failures $failures -Message "Node record did not preserve ParticipationMode from installed artifact validation."
        }
        if ($nodeRecord.cache_policy -ne "Balanced pinned archive") {
            Add-Failure -Failures $failures -Message "Node record did not preserve CachePolicy from installed artifact validation."
        }
    }
    else {
        Add-Failure -Failures $failures -Message "Node initialization did not write the node record."
    }

    $seedPath = Join-Path $scratchRoot "clean-install-validation.txt"
    Set-Content -LiteralPath $seedPath -Value ("Archrealms Passport installed artifact validation " + [DateTime]::UtcNow.ToString("O")) -Encoding UTF8
    $env:IPFS_PATH = $ipfsRepoPath
    $stage = "adding validation content to bundled IPFS repo"
    $cidOutput = @(& $ipfsCliPath add -Q --cid-version=1 --hash=sha2-256 $seedPath 2>&1)
    if ($LASTEXITCODE -ne 0) {
        throw "ipfs add failed during installed artifact validation.`n$cidOutput"
    }
    elseif ($cidOutput.Count -eq 0) {
        throw "ipfs add produced no CID during installed artifact validation."
    }

    $cid = ($cidOutput | Select-Object -Last 1).ToString().Trim()

    $stage = "exporting validation CID as CAR"
    Invoke-JsonCommand `
        -FilePath $powershell `
        -WorkingDirectory $resolvedArtifactRoot `
        -Arguments @(
            "-NoProfile",
            "-ExecutionPolicy", "Bypass",
            "-File", $exportCarScript,
            "-Cid", $cid,
            "-WorkspaceRoot", $workspaceRoot,
            "-IpfsRepoPath", $ipfsRepoPath
        ) | Out-Null

    $stage = "reading CAR export record"
    $carExportRecordPath = Get-ChildItem -LiteralPath (Join-Path $workspaceRoot "records\ipfs-car-exports") -Filter "*.json" |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1 -ExpandProperty FullName
    $carExportRecord = $null
    if ($carExportRecordPath) {
        $carExportRecord = Get-Content -LiteralPath $carExportRecordPath -Raw | ConvertFrom-Json
        if (-not (Test-Path -LiteralPath $carExportRecord.car_path -PathType Leaf)) {
            Add-Failure -Failures $failures -Message "CAR export record points to a missing CAR file."
        }
    }
    else {
        Add-Failure -Failures $failures -Message "CAR export did not write a record."
    }

    $daemonStarted = $false
    $daemonStopped = $false
    $daemonApiVersion = ""
    if (-not $SkipDaemon) {
        $stage = "starting bundled IPFS daemon"
        $daemonProcess = Start-IpfsDaemon -IpfsCliPath $ipfsCliPath -IpfsRepoPath $ipfsRepoPath -WorkingDirectory $resolvedArtifactRoot
        $daemonStarted = $true
        $stage = "probing bundled IPFS daemon API"
        $apiVersion = Wait-ForIpfsApi -ApiEndpoint $apiEndpoint
        if ($apiVersion -and $apiVersion.Version) {
            $daemonApiVersion = [string]$apiVersion.Version
        }

        $stage = "stopping bundled IPFS daemon"
        $daemonStopped = Stop-IpfsDaemon -Process $daemonProcess -ApiEndpoint $apiEndpoint
        if (-not $daemonStopped) {
            Add-Failure -Failures $failures -Message "IPFS daemon did not stop cleanly."
        }
    }

    $report = [pscustomobject]@{
        verified_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
        passed = ($failures.Count -eq 0)
        failures = @($failures)
        source_type = $artifactInfo.source_type
        manifest_path = $artifactInfo.manifest_path
        package_path = $artifactInfo.package_path
        artifact_root = $resolvedArtifactRoot
        required_file_count = $requiredFileCount
        bundled_ipfs_cli_path = $ipfsCliPath
        bundled_ipfs_cli_version = $ipfsVersion
        workspace_root = $workspaceRoot
        ipfs_repo_path = $ipfsRepoPath
        node_record_path = $nodeRecordPath
        node_peer_id = if ($nodeRecord -and $nodeRecord.peer_id) { $nodeRecord.peer_id } else { "" }
        node_api_multiaddr = $apiMultiaddr
        node_gateway_multiaddr = $gatewayMultiaddr
        node_storage_max = if ($nodeRecord -and $nodeRecord.storage_max) { $nodeRecord.storage_max } else { "" }
        node_storage_gc_watermark = if ($nodeRecord -and $nodeRecord.storage_gc_watermark) { $nodeRecord.storage_gc_watermark } else { "" }
        node_provide_strategy = if ($nodeRecord -and $nodeRecord.provide_strategy) { $nodeRecord.provide_strategy } else { "" }
        node_participation_mode = if ($nodeRecord -and $nodeRecord.participation_mode) { $nodeRecord.participation_mode } else { "" }
        node_cache_policy = if ($nodeRecord -and $nodeRecord.cache_policy) { $nodeRecord.cache_policy } else { "" }
        test_content_cid = $cid
        car_export_record_path = $carExportRecordPath
        car_path = if ($carExportRecord -and $carExportRecord.car_path) { $carExportRecord.car_path } else { "" }
        car_sha256 = if ($carExportRecord -and $carExportRecord.car_sha256) { $carExportRecord.car_sha256 } else { "" }
        car_size_bytes = if ($carExportRecord -and $carExportRecord.car_size_bytes) { $carExportRecord.car_size_bytes } else { 0 }
        daemon_validation_skipped = $SkipDaemon.IsPresent
        daemon_started = $daemonStarted
        daemon_api_endpoint = $apiEndpoint
        daemon_api_version = $daemonApiVersion
        daemon_stopped = $daemonStopped
    }
}
catch {
    Add-Failure -Failures $failures -Message ($stage + ": " + $_.Exception.Message)
    if (-not $report) {
        $report = [pscustomobject]@{
            verified_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
            passed = $false
            failures = @($failures)
            source_type = if ($artifactInfo) { $artifactInfo.source_type } else { "" }
            manifest_path = if ($artifactInfo) { $artifactInfo.manifest_path } else { $ManifestPath }
            package_path = if ($artifactInfo) { $artifactInfo.package_path } else { $PackagePath }
            artifact_root = $resolvedArtifactRoot
            required_file_count = 0
            bundled_ipfs_cli_path = ""
            bundled_ipfs_cli_version = ""
            workspace_root = $workspaceRoot
            ipfs_repo_path = $ipfsRepoPath
            daemon_validation_skipped = $SkipDaemon.IsPresent
            daemon_started = $false
            daemon_api_endpoint = ""
            daemon_api_version = ""
            daemon_stopped = $false
            failing_stage = $stage
            error_line = $_.InvocationInfo.ScriptLineNumber
            error_script_stack_trace = $_.ScriptStackTrace
        }
    }
    else {
        $report.passed = $false
        $report.failures = @($failures)
    }
}
finally {
    if ($daemonProcess -and -not $daemonProcess.HasExited) {
        try {
            $daemonProcess.Kill()
            $daemonProcess.WaitForExit(5000) | Out-Null
        }
        catch {
        }
    }

    $env:ARCHREALMS_IPFS_CLI = $oldArchrealmsIpfsCli
    $env:IPFS_PATH = $oldIpfsPath

    if ($OutputPath) {
        $outputDirectory = Split-Path -Parent ([System.IO.Path]::GetFullPath($OutputPath))
        if ($outputDirectory) {
            New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null
        }

        $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
    }

    if (-not $KeepWorkspace) {
        Remove-SafeDirectory -Path $scratchRoot -AllowedRoot ([System.IO.Path]::GetTempPath()) -BestEffort
    }
}

$report | ConvertTo-Json -Depth 8

if (-not $report.passed) {
    throw "Passport Windows installed artifact validation failed."
}
