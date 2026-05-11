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

function Set-ArchrealmsJsonProperty {
    param(
        [Parameter(Mandatory = $true)]
        $InputObject,
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $true)]
        $Value
    )

    $property = $InputObject.PSObject.Properties[$Name]
    if ($property) {
        $property.Value = $Value
        return
    }

    Add-Member -InputObject $InputObject -MemberType NoteProperty -Name $Name -Value $Value
}

function Remove-ArchrealmsJsonProperty {
    param(
        [Parameter(Mandatory = $true)]
        $InputObject,
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    if ($InputObject.PSObject.Properties[$Name]) {
        $InputObject.PSObject.Properties.Remove($Name)
    }
}

function Get-ArchrealmsJsonObjectProperty {
    param(
        [Parameter(Mandatory = $true)]
        $InputObject,
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $property = $InputObject.PSObject.Properties[$Name]
    if ($property -and $property.Value) {
        return $property.Value
    }

    $value = [pscustomobject]@{}
    Set-ArchrealmsJsonProperty -InputObject $InputObject -Name $Name -Value $value
    return $value
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
    if (-not [string]::IsNullOrWhiteSpace($env:ARCHREALMS_IPFS_CLI)) {
        $preferredPath = [System.IO.Path]::GetFullPath($env:ARCHREALMS_IPFS_CLI)
        if (Test-Path -LiteralPath $preferredPath) {
            return $preferredPath
        }
    }

    $bundledRuntimeRoot = Join-Path $PSScriptRoot "runtime"
    if (Test-Path -LiteralPath $bundledRuntimeRoot) {
        $bundledRootCandidate = Join-Path $bundledRuntimeRoot "ipfs.exe"
        if (Test-Path -LiteralPath $bundledRootCandidate) {
            return (Resolve-Path -LiteralPath $bundledRootCandidate).Path
        }

        $bundledNestedCandidate = Get-ChildItem -LiteralPath $bundledRuntimeRoot -Recurse -File -Filter "ipfs.exe" -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($bundledNestedCandidate) {
            return $bundledNestedCandidate.FullName
        }
    }

    $command = Get-Command ipfs -ErrorAction SilentlyContinue
    if ($command) {
        return $command.Source
    }

    $candidates = @(
        (Join-Path $env:LOCALAPPDATA "Programs\IPFS Desktop\resources\app.asar.unpacked\node_modules\kubo\kubo\ipfs.exe"),
        (Join-Path $env:ProgramFiles "IPFS Desktop\resources\app.asar.unpacked\node_modules\kubo\kubo\ipfs.exe"),
        (Join-Path ${env:ProgramFiles(x86)} "IPFS Desktop\resources\app.asar.unpacked\node_modules\kubo\kubo\ipfs.exe")
    ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    throw "The ipfs CLI is not installed, not on PATH, and no IPFS Desktop Kubo binary was found."
}

function ConvertTo-ArchrealmsCliArgumentString {
    param(
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    return ($Arguments | ForEach-Object {
            if ($_ -match '[\s"]') {
                '"' + ($_ -replace '"', '\"') + '"'
            }
            else {
                $_
            }
        }) -join " "
}

function Get-ArchrealmsIpfsPathSpec {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Cid,
        [string]$RelativePath
    )

    $trimmedCid = $Cid.Trim()
    if ([string]::IsNullOrWhiteSpace($trimmedCid)) {
        throw "A non-empty CID is required."
    }

    $pathSpec = "/ipfs/$trimmedCid"
    if (-not [string]::IsNullOrWhiteSpace($RelativePath)) {
        $normalizedRelativePath = $RelativePath.Replace("\", "/").TrimStart("/")
        if (-not [string]::IsNullOrWhiteSpace($normalizedRelativePath)) {
            $pathSpec += "/" + $normalizedRelativePath
        }
    }

    return $pathSpec
}

function Get-ArchrealmsIpfsCidForPath {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TargetPath,
        [string]$IpfsRepoPath,
        [switch]$OnlyHash
    )

    $resolvedTargetPath = (Resolve-Path -LiteralPath $TargetPath).Path
    $arguments = @("add", "-Q", "--cid-version=1", "--hash=sha2-256")
    if ($OnlyHash) {
        $arguments += "--only-hash"
    }

    if ((Get-Item -LiteralPath $resolvedTargetPath).PSIsContainer) {
        $arguments += "-r"
    }

    $arguments += $resolvedTargetPath
    return (Invoke-ArchrealmsIpfsTextCommand -Arguments $arguments -IpfsRepoPath $IpfsRepoPath | Select-Object -Last 1).Trim()
}

function Read-ArchrealmsIpfsBytes {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Cid,
        [string]$RelativePath,
        [string]$IpfsRepoPath
    )

    $cli = Resolve-ArchrealmsIpfsCli
    $resolvedRepoPath = Get-ArchrealmsResolvedIpfsRepoPath -IpfsRepoPath $IpfsRepoPath
    $pathSpec = Get-ArchrealmsIpfsPathSpec -Cid $Cid -RelativePath $RelativePath

    $processStartInfo = New-Object System.Diagnostics.ProcessStartInfo
    $processStartInfo.FileName = $cli
    $processStartInfo.Arguments = ConvertTo-ArchrealmsCliArgumentString -Arguments @("cat", $pathSpec)
    $processStartInfo.UseShellExecute = $false
    $processStartInfo.RedirectStandardOutput = $true
    $processStartInfo.RedirectStandardError = $true
    $processStartInfo.EnvironmentVariables["IPFS_PATH"] = $resolvedRepoPath

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $processStartInfo
    $null = $process.Start()

    $memoryStream = New-Object System.IO.MemoryStream
    try {
        $process.StandardOutput.BaseStream.CopyTo($memoryStream)
        $process.WaitForExit()
        $stderr = $process.StandardError.ReadToEnd()
        if ($process.ExitCode -ne 0) {
            throw "ipfs cat $pathSpec failed.`n$stderr"
        }
    }
    finally {
        $process.Dispose()
    }

    return $memoryStream.ToArray()
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
        [string]$StorageMax = "10GB",
        [int]$StorageGCWatermark = 85,
        [string]$ProvideStrategy = "pinned",
        [string]$ParticipationMode = "Public archive contributor",
        [string]$CachePolicy = "Balanced pinned archive"
    )

    $resolvedRepoPath = Get-ArchrealmsResolvedIpfsRepoPath -IpfsRepoPath $IpfsRepoPath
    if ($StorageGCWatermark -lt 1) {
        $StorageGCWatermark = 1
    }
    elseif ($StorageGCWatermark -gt 99) {
        $StorageGCWatermark = 99
    }

    if (-not $ProvideStrategy) {
        $ProvideStrategy = "pinned"
    }
    if (-not $ParticipationMode) {
        $ParticipationMode = "Public archive contributor"
    }
    if (-not $CachePolicy) {
        $CachePolicy = "Balanced pinned archive"
    }

    New-Item -ItemType Directory -Force -Path $resolvedRepoPath | Out-Null

    if (-not (Test-ArchrealmsIpfsRepo -IpfsRepoPath $resolvedRepoPath)) {
        Invoke-ArchrealmsIpfsTextCommand -Arguments @("init", "--profile=server") -IpfsRepoPath $resolvedRepoPath | Out-Null
    }

    $swarmAddresses = @(
        "/ip4/0.0.0.0/tcp/$SwarmPort",
        "/ip4/0.0.0.0/udp/$SwarmPort/quic-v1",
        "/ip6/::/tcp/$SwarmPort",
        "/ip6/::/udp/$SwarmPort/quic-v1"
    )

    $configPath = Join-Path $resolvedRepoPath "config"
    $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    $addresses = Get-ArchrealmsJsonObjectProperty -InputObject $config -Name "Addresses"
    $datastore = Get-ArchrealmsJsonObjectProperty -InputObject $config -Name "Datastore"
    $provide = Get-ArchrealmsJsonObjectProperty -InputObject $config -Name "Provide"
    $plugins = Get-ArchrealmsJsonObjectProperty -InputObject $config -Name "Plugins"
    $pluginMap = Get-ArchrealmsJsonObjectProperty -InputObject $plugins -Name "Plugins"
    $telemetryPlugin = Get-ArchrealmsJsonObjectProperty -InputObject $pluginMap -Name "telemetry"
    $telemetryConfig = Get-ArchrealmsJsonObjectProperty -InputObject $telemetryPlugin -Name "Config"
    Remove-ArchrealmsJsonProperty -InputObject $config -Name "Reprovider"

    Set-ArchrealmsJsonProperty -InputObject $addresses -Name "API" -Value $ApiMultiaddr
    Set-ArchrealmsJsonProperty -InputObject $addresses -Name "Gateway" -Value $GatewayMultiaddr
    Set-ArchrealmsJsonProperty -InputObject $addresses -Name "Swarm" -Value $swarmAddresses
    Set-ArchrealmsJsonProperty -InputObject $datastore -Name "StorageMax" -Value $StorageMax
    Set-ArchrealmsJsonProperty -InputObject $datastore -Name "StorageGCWatermark" -Value $StorageGCWatermark
    Set-ArchrealmsJsonProperty -InputObject $provide -Name "Strategy" -Value $ProvideStrategy
    Set-ArchrealmsJsonProperty -InputObject $telemetryConfig -Name "Mode" -Value "off"
    Write-ArchrealmsUtf8Json -Path $configPath -InputObject $config

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
        storage_gc_watermark = $StorageGCWatermark
        provide_strategy = $ProvideStrategy
        participation_mode = $ParticipationMode
        cache_policy = $CachePolicy
        telemetry_mode = "off"
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
    Get-ArchrealmsIpfsPathSpec, `
    Get-ArchrealmsIpfsCidForPath, `
    Read-ArchrealmsIpfsBytes, `
    Invoke-ArchrealmsIpfsTextCommand, `
    Test-ArchrealmsIpfsRepo, `
    Get-ArchrealmsPathStats, `
    Export-ArchrealmsIpfsCar, `
    Get-ArchrealmsIpfsNodeIdentity, `
    Initialize-ArchrealmsIpfsRepo, `
    Publish-ArchrealmsPathToIpfs
