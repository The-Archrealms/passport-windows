param(
    [string]$ExecutablePath,
    [string]$PackageFamilyName,
    [string]$AppId = "App",
    [string]$ProcessName = "ArchrealmsPassport.Windows",
    [int]$TimeoutSeconds = 30,
    [switch]$StopExisting,
    [switch]$ExerciseTrayMinimize,
    [switch]$ExerciseCloseToTaskbar,
    [switch]$KeepRunning,
    [string]$OutputPath
)

$ErrorActionPreference = "Stop"

function Add-Failure {
    param(
        [System.Collections.Generic.List[string]]$Failures,
        [string]$Message
    )

    $Failures.Add($Message) | Out-Null
}

function Stop-ExistingAppProcess {
    param([string]$Name)

    Get-Process -Name $Name -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            Stop-Process -Id $_.Id -Force
        }
        catch {
        }
    }
}

function Wait-ForMainWindowProcess {
    param(
        [System.Diagnostics.Process]$StartedProcess,
        [string]$Name,
        [DateTime]$StartedAfter,
        [int]$TimeoutSeconds
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    do {
        $candidates = @()
        if ($StartedProcess) {
            try {
                $StartedProcess.Refresh()
                $candidates += $StartedProcess
            }
            catch {
            }
        }
        else {
            $candidates += Get-Process -Name $Name -ErrorAction SilentlyContinue | Where-Object {
                try {
                    $_.StartTime.ToUniversalTime() -ge $StartedAfter.AddSeconds(-5)
                }
                catch {
                    $true
                }
            }
        }

        foreach ($candidate in $candidates) {
            try {
                if ($candidate.HasExited) {
                    continue
                }

                $candidate.Refresh()
                if ($candidate.MainWindowHandle -ne [IntPtr]::Zero) {
                    return $candidate
                }
            }
            catch {
            }
        }

        Start-Sleep -Milliseconds 300
    } while ([DateTime]::UtcNow -lt $deadline)

    return $null
}

function Find-AutomationElementById {
    param(
        [System.Windows.Automation.AutomationElement]$Root,
        [string]$AutomationId
    )

    $condition = [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::AutomationIdProperty,
        $AutomationId)
    return $Root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $condition)
}

function Select-TabItemByName {
    param(
        [System.Windows.Automation.AutomationElement]$Root,
        [string]$Name
    )

    $typeCondition = [System.Windows.Automation.PropertyCondition]::new(
        [System.Windows.Automation.AutomationElement]::ControlTypeProperty,
        [System.Windows.Automation.ControlType]::TabItem)
    $tabItem = $null
    $tabItems = $Root.FindAll([System.Windows.Automation.TreeScope]::Descendants, $typeCondition)
    foreach ($candidate in $tabItems) {
        if ($candidate.Current.Name -eq $Name) {
            $tabItem = $candidate
            break
        }
    }

    if (-not $tabItem) {
        return $false
    }

    $selectionPattern = $tabItem.GetCurrentPattern([System.Windows.Automation.SelectionItemPattern]::Pattern)
    $selectionPattern.Select()
    Start-Sleep -Milliseconds 500
    return $true
}

if (($ExecutablePath -and $PackageFamilyName) -or (-not $ExecutablePath -and -not $PackageFamilyName)) {
    throw "Provide exactly one of -ExecutablePath or -PackageFamilyName."
}

Add-Type -AssemblyName UIAutomationClient
Add-Type -AssemblyName UIAutomationTypes

$failures = [System.Collections.Generic.List[string]]::new()
$before = [DateTime]::UtcNow
$startedProcess = $null
$process = $null
$windowElement = $null
$verifiedAutomationIds = @()
$expectedHomeAutomationIds = @(
    "MainNavigationTabs",
    "HomePassportStatusText",
    "HomeStorageStatusText",
    "HomeNodeStatusText",
    "HomeRegistryStatusText",
    "DisplayNameTextBox"
)
$expectedStorageAutomationIds = @(
    "InitializeNodeButton",
    "StorageActionStatusText",
    "StorageAllocationSlider"
)
$expectedAutomationIds = @($expectedHomeAutomationIds + $expectedStorageAutomationIds)

try {
    if ($StopExisting) {
        Stop-ExistingAppProcess -Name $ProcessName
        Start-Sleep -Milliseconds 500
    }

    if ($ExecutablePath) {
        $resolvedExecutablePath = (Resolve-Path -LiteralPath $ExecutablePath).Path
        $startedProcess = Start-Process -FilePath $resolvedExecutablePath -PassThru
    }
    else {
        $appUserModelId = "$PackageFamilyName!$AppId"
        Start-Process -FilePath "explorer.exe" -ArgumentList "shell:AppsFolder\$appUserModelId"
    }

    $process = Wait-ForMainWindowProcess `
        -StartedProcess $startedProcess `
        -Name $ProcessName `
        -StartedAfter $before `
        -TimeoutSeconds $TimeoutSeconds

    if (-not $process) {
        Add-Failure -Failures $failures -Message "The Passport window did not appear before timeout."
    }
    else {
        $windowElement = [System.Windows.Automation.AutomationElement]::FromHandle($process.MainWindowHandle)
        if (-not $windowElement) {
            Add-Failure -Failures $failures -Message "The Passport main window could not be attached through UI Automation."
        }
        elseif ($windowElement.Current.Name -ne "Archrealms Passport") {
            Add-Failure -Failures $failures -Message ("Unexpected window title: " + $windowElement.Current.Name)
        }
        else {
            foreach ($automationId in $expectedHomeAutomationIds) {
                $element = Find-AutomationElementById -Root $windowElement -AutomationId $automationId
                if ($element) {
                    $verifiedAutomationIds += $automationId
                }
                else {
                    Add-Failure -Failures $failures -Message "Missing UI automation element: $automationId"
                }
            }

            if (Select-TabItemByName -Root $windowElement -Name "Storage") {
                foreach ($automationId in $expectedStorageAutomationIds) {
                    $element = Find-AutomationElementById -Root $windowElement -AutomationId $automationId
                    if ($element) {
                        $verifiedAutomationIds += $automationId
                    }
                    else {
                        Add-Failure -Failures $failures -Message "Missing Storage tab UI automation element: $automationId"
                    }
                }
            }
            else {
                Add-Failure -Failures $failures -Message "Storage tab could not be selected."
            }

            if ($ExerciseTrayMinimize) {
                try {
                    $windowPattern = $windowElement.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern)
                    $windowPattern.SetWindowVisualState([System.Windows.Automation.WindowVisualState]::Minimized)
                    Start-Sleep -Seconds 2
                    $process.Refresh()
                    if ($process.HasExited) {
                        Add-Failure -Failures $failures -Message "The Passport process exited after minimize-to-tray."
                    }
                }
                catch {
                    Add-Failure -Failures $failures -Message ("Minimize exercise failed: " + $_.Exception.Message)
                }
            }

            if ($ExerciseCloseToTaskbar) {
                try {
                    $windowPattern = $windowElement.GetCurrentPattern([System.Windows.Automation.WindowPattern]::Pattern)
                    $windowPattern.SetWindowVisualState([System.Windows.Automation.WindowVisualState]::Normal)
                    Start-Sleep -Milliseconds 500
                    $windowPattern.Close()
                    Start-Sleep -Seconds 2
                    $process.Refresh()
                    if ($process.HasExited) {
                        Add-Failure -Failures $failures -Message "The Passport process exited when the main window was closed."
                    }
                }
                catch {
                    Add-Failure -Failures $failures -Message ("Close-to-taskbar exercise failed: " + $_.Exception.Message)
                }
            }
        }
    }

    $eventFailures = @(
        Get-WinEvent -FilterHashtable @{ LogName = "Application"; StartTime = $before } -ErrorAction SilentlyContinue |
            Where-Object {
                $_.ProviderName -in @(".NET Runtime", "Application Error", "Windows Error Reporting") -and
                $_.Message -match "ArchrealmsPassport\.Windows"
            }
    )

    if ($eventFailures.Count -gt 0) {
        Add-Failure -Failures $failures -Message ("Application crash/error events were recorded: " + $eventFailures.Count)
    }
}
finally {
    if (-not $KeepRunning -and $process -and -not $process.HasExited) {
        try {
            Stop-Process -Id $process.Id -Force
        }
        catch {
        }
    }
}

$report = [pscustomobject]@{
    verified_utc = [DateTime]::UtcNow.ToString("yyyy-MM-ddTHH:mm:ssZ")
    passed = ($failures.Count -eq 0)
    failures = @($failures)
    executable_path = if ($ExecutablePath) { (Resolve-Path -LiteralPath $ExecutablePath).Path } else { "" }
    package_family_name = if ($PackageFamilyName) { $PackageFamilyName } else { "" }
    app_id = $AppId
    process_name = $ProcessName
    process_id = if ($process) { $process.Id } else { 0 }
    expected_automation_ids = $expectedAutomationIds
    verified_automation_ids = $verifiedAutomationIds
    exercised_tray_minimize = $ExerciseTrayMinimize.IsPresent
    exercised_close_to_taskbar = $ExerciseCloseToTaskbar.IsPresent
}

if ($OutputPath) {
    $outputDirectory = Split-Path -Parent ([System.IO.Path]::GetFullPath($OutputPath))
    if ($outputDirectory) {
        New-Item -ItemType Directory -Force -Path $outputDirectory | Out-Null
    }

    $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $OutputPath -Encoding UTF8
}

$report | ConvertTo-Json -Depth 8

if ($failures.Count -gt 0) {
    throw "Passport Windows UI smoke validation failed."
}
