Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-ArchrealmsUtf8Json {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        $InputObject
    )

    $directory = Split-Path -Parent $Path
    if ($directory) {
        New-Item -ItemType Directory -Force -Path $directory | Out-Null
    }

    $json = $InputObject | ConvertTo-Json -Depth 8
    [System.IO.File]::WriteAllText($Path, $json + [Environment]::NewLine, [System.Text.UTF8Encoding]::new($false))
}

function Get-ArchrealmsDefaultIpfsRepoPath {
    return Join-Path $HOME ".archrealms\ipfs\kubo"
}

function Get-ArchrealmsResolvedIpfsRepoPath {
    param(
        [string]$IpfsRepoPath
    )

    if ($IpfsRepoPath) {
        return [System.IO.Path]::GetFullPath($IpfsRepoPath)
    }

    if ($env:IPFS_PATH) {
        return [System.IO.Path]::GetFullPath($env:IPFS_PATH)
    }

    return [System.IO.Path]::GetFullPath((Get-ArchrealmsDefaultIpfsRepoPath))
}

function Resolve-ArchrealmsIpfsCli {
    $command = Get-Command ipfs -ErrorAction SilentlyContinue
    if (-not $command) {
        throw "The ipfs CLI is not installed or not on PATH."
    }

    return $command.Source
}

function Invoke-ArchrealmsIpfsTextCommand {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments,
        [string]$IpfsRepoPath
    )

    $cli = Resolve-ArchrealmsIpfsCli
    $resolvedRepoPath = Get-ArchrealmsResolvedIpfsRepoPath -IpfsRepoPath $IpfsRepoPath
    $previousRepoPath = $env:IPFS_PATH
    $env:IPFS_PATH = $resolvedRepoPath

    try {
        $output = & $cli @Arguments 2>&1
        if ($LASTEXITCODE -ne 0) {
            $message = ($output | ForEach-Object { $_.ToString() }) -join [Environment]::NewLine
            throw "ipfs $($Arguments -join ' ') failed.`n$message"
        }

        return @($output | ForEach-Object { $_.ToString() })
    }
    finally {
        if ($null -ne $previousRepoPath) {
            $env:IPFS_PATH = $previousRepoPath
        }
        else {
            Remove-Item Env:IPFS_PATH -ErrorAction SilentlyContinue
        }
    }
}

function Test-ArchrealmsIpfsRepo {
    param(
        [string]$IpfsRepoPath
    )

    $resolvedRepoPath = Get-ArchrealmsResolvedIpfsRepoPath -IpfsRepoPath $IpfsRepoPath
    return (Test-Path -LiteralPath (Join-Path $resolvedRepoPath "config"))
}

function Get-ArchrealmsPathStats {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TargetPath
    )

    $item = Get-Item -LiteralPath $TargetPath
    if ($item.PSIsContainer) {
        $files = Get-ChildItem -LiteralPath $TargetPath -Recurse -File
        $totalBytes = 0
        foreach ($file in $files) {
            $totalBytes += $file.Length
        }
        return [ordered]@{
            target_type = "directory"
            file_count = @($files).Count
            size_bytes = $totalBytes
        }
    }

    return [ordered]@{
        target_type = "file"
        file_count = 1
        size_bytes = $item.Length
    }
}

function Export-ArchrealmsIpfsCar {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Cid,
        [Parameter(Mandatory = $true)]
        [string]$CarPath,
        [string]$IpfsRepoPath
    )

    $cli = Resolve-ArchrealmsIpfsCli
    $resolvedRepoPath = Get-ArchrealmsResolvedIpfsRepoPath -IpfsRepoPath $IpfsRepoPath
    $resolvedCarPath = [System.IO.Path]::GetFullPath($CarPath)

    $directory = Split-Path -Parent $resolvedCarPath
    if ($directory) {
        New-Item -ItemType Directory -Force -Path $directory | Out-Null
    }

    $processStartInfo = New-Object System.Diagnostics.ProcessStartInfo
    $processStartInfo.FileName = $cli
    $processStartInfo.Arguments = "dag export $Cid"
    $processStartInfo.UseShellExecute = $false
    $processStartInfo.RedirectStandardOutput = $true
    $processStartInfo.RedirectStandardError = $true
    $processStartInfo.EnvironmentVariables["IPFS_PATH"] = $resolvedRepoPath

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $processStartInfo
    $null = $process.Start()

    $fileStream = [System.IO.File]::Open($resolvedCarPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)

    try {
        $process.StandardOutput.BaseStream.CopyTo($fileStream)
        $process.WaitForExit()
        $stderr = $process.StandardError.ReadToEnd()
        if ($process.ExitCode -ne 0) {
            throw "ipfs dag export $Cid failed.`n$stderr"
        }
    }
    finally {
        $fileStream.Dispose()
        $process.Dispose()
    }

    return $resolvedCarPath
}

function Get-ArchrealmsIpfsNodeIdentity {
    param(
        [string]$IpfsRepoPath
    )

    $output = Invoke-ArchrealmsIpfsTextCommand -Arguments @("id", "-f", "<id>") -IpfsRepoPath $IpfsRepoPath
    return ($output | Select-Object -Last 1).Trim()
}

function Initialize-ArchrealmsIpfsRepo {
    param(
        [string]$IpfsRepoPath,
        [string]$ApiMultiaddr = "/ip4/127.0.0.1/tcp/5001",
        [string]$GatewayMultiaddr = "/ip4/127.0.0.1/tcp/8080",
        [int]$SwarmPort = 4001,
        [string]$StorageMax = "10GB"
    )

    $resolvedRepoPath = Get-ArchrealmsResolvedIpfsRepoPath -IpfsRepoPath $IpfsRepoPath
    New-Item -ItemType Directory -Force -Path $resolvedRepoPath | Out-Null

    if (-not (Test-ArchrealmsIpfsRepo -IpfsRepoPath $resolvedRepoPath)) {
        Invoke-ArchrealmsIpfsTextCommand -Arguments @("init", "--profile=server") -IpfsRepoPath $resolvedRepoPath | Out-Null
    }

    $swarmAddresses = @(
        "/ip4/0.0.0.0/tcp/$SwarmPort",
        "/ip4/0.0.0.0/udp/$SwarmPort/quic-v1",
        "/ip6/::/tcp/$SwarmPort",
        "/ip6/::/udp/$SwarmPort/quic-v1"
    ) | ConvertTo-Json -Compress

    Invoke-ArchrealmsIpfsTextCommand -Arguments @("config", "Addresses.API", $ApiMultiaddr) -IpfsRepoPath $resolvedRepoPath | Out-Null
    Invoke-ArchrealmsIpfsTextCommand -Arguments @("config", "Addresses.Gateway", $GatewayMultiaddr) -IpfsRepoPath $resolvedRepoPath | Out-Null
    Invoke-ArchrealmsIpfsTextCommand -Arguments @("config", "--json", "Addresses.Swarm", $swarmAddresses) -IpfsRepoPath $resolvedRepoPath | Out-Null
    Invoke-ArchrealmsIpfsTextCommand -Arguments @("config", "Datastore.StorageMax", $StorageMax) -IpfsRepoPath $resolvedRepoPath | Out-Null
    Invoke-ArchrealmsIpfsTextCommand -Arguments @("config", "Datastore.StorageGCWatermark", "85") -IpfsRepoPath $resolvedRepoPath | Out-Null
    Invoke-ArchrealmsIpfsTextCommand -Arguments @("config", "Reprovider.Strategy", "pinned") -IpfsRepoPath $resolvedRepoPath | Out-Null

    $version = (Invoke-ArchrealmsIpfsTextCommand -Arguments @("version", "--number") -IpfsRepoPath $resolvedRepoPath | Select-Object -Last 1).Trim()
    $peerId = Get-ArchrealmsIpfsNodeIdentity -IpfsRepoPath $resolvedRepoPath

    return [ordered]@{
        initialized_utc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        repo_path = $resolvedRepoPath
        ipfs_version = $version
        peer_id = $peerId
        api_multiaddr = $ApiMultiaddr
        gateway_multiaddr = $GatewayMultiaddr
        swarm_port = $SwarmPort
        storage_max = $StorageMax
        reprovider_strategy = "pinned"
    }
}

function Publish-ArchrealmsPathToIpfs {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TargetName,
        [Parameter(Mandatory = $true)]
        [string]$TargetPath,
        [Parameter(Mandatory = $true)]
        [string]$OutputPath,
        [string]$CarPath,
        [string]$IpfsRepoPath,
        [switch]$ExportCar
    )

    $resolvedTargetPath = (Resolve-Path $TargetPath).Path
    $resolvedOutputPath = [System.IO.Path]::GetFullPath($OutputPath)
    $resolvedRepoPath = Get-ArchrealmsResolvedIpfsRepoPath -IpfsRepoPath $IpfsRepoPath

    $stats = Get-ArchrealmsPathStats -TargetPath $resolvedTargetPath
    $rootCid = (Invoke-ArchrealmsIpfsTextCommand -Arguments @("add", "-Qr", "--cid-version=1", "--hash=sha2-256", $resolvedTargetPath) -IpfsRepoPath $resolvedRepoPath | Select-Object -Last 1).Trim()
    if (-not $rootCid) {
        throw "Failed to derive an IPFS CID for $resolvedTargetPath."
    }

    $resolvedCarPath = $null
    if ($ExportCar) {
        if (-not $CarPath) {
            $sanitizedTargetName = ($TargetName -replace "[^A-Za-z0-9._-]", "-")
            $resolvedCarPath = Join-Path (Split-Path -Parent $resolvedOutputPath) ($sanitizedTargetName + ".car")
        }
        else {
            $resolvedCarPath = [System.IO.Path]::GetFullPath($CarPath)
        }

        Export-ArchrealmsIpfsCar -Cid $rootCid -CarPath $resolvedCarPath -IpfsRepoPath $resolvedRepoPath | Out-Null
    }

    $record = [ordered]@{
        target_name = $TargetName
        target_path = $resolvedTargetPath
        target_type = $stats.target_type
        file_count = $stats.file_count
        size_bytes = $stats.size_bytes
        published_utc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
        root_cid = $rootCid
        ipfs_repo_path = $resolvedRepoPath
        ipfs_peer_id = Get-ArchrealmsIpfsNodeIdentity -IpfsRepoPath $resolvedRepoPath
        ipfs_version = (Invoke-ArchrealmsIpfsTextCommand -Arguments @("version", "--number") -IpfsRepoPath $resolvedRepoPath | Select-Object -Last 1).Trim()
        add_command = "ipfs add -Qr --cid-version=1 --hash=sha2-256 <target>"
        pinned_locally = $true
        car_path = $resolvedCarPath
    }

    Write-ArchrealmsUtf8Json -Path $resolvedOutputPath -InputObject $record
    return $record
}

Export-ModuleMember -Function `
    Write-ArchrealmsUtf8Json, `
    Get-ArchrealmsDefaultIpfsRepoPath, `
    Get-ArchrealmsResolvedIpfsRepoPath, `
    Resolve-ArchrealmsIpfsCli, `
    Invoke-ArchrealmsIpfsTextCommand, `
    Test-ArchrealmsIpfsRepo, `
    Get-ArchrealmsPathStats, `
    Export-ArchrealmsIpfsCar, `
    Get-ArchrealmsIpfsNodeIdentity, `
    Initialize-ArchrealmsIpfsRepo, `
    Publish-ArchrealmsPathToIpfs
