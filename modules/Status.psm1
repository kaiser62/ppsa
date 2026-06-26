# Status.psm1 - PPSA Build Status and History Engine
# Milestone 8: Generate status.json, history.json, and build summaries.

function New-BuildStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$Tag,
        [bool]$Success = $false,
        [string]$GitCommit = "",
        [string]$GitBranch = "",
        [double]$DurationSeconds = 0,
        [int]$ExitCode = 0,
        [object[]]$Artifacts,
        [object]$SystemInfo,
        [string]$TriggerId = "",
        [string]$TriggerUser = "",
        [string]$LogPath = ""
    )
    if (-not $GitCommit) { $GitCommit = & git rev-parse HEAD 2>$null; if (-not $?) { $GitCommit = "unknown" } }
    if (-not $GitBranch) { $GitBranch = & git rev-parse --abbrev-ref HEAD 2>$null; if (-not $?) { $GitBranch = "unknown" } }

    $artifactSizes = @{}
    $checksums = @{}
    if ($Artifacts) {
        foreach ($a in $Artifacts) {
            if ($a.SizeMB) { $artifactSizes[$a.FileName] = $a.SizeMB }
            if ($a.SHA256) { $checksums[$a.FileName] = $a.SHA256 }
        }
    }

    return [PSCustomObject]@{
        BuildId       = $Tag
        GitCommit     = $GitCommit.Trim()
        GitBranch     = $GitBranch.Trim()
        Duration      = [math]::Round($DurationSeconds, 1)
        DurationHuman = if ($DurationSeconds -ge 3600) { "{0:F1}h" -f ($DurationSeconds / 3600) } elseif ($DurationSeconds -ge 60) { "{0:F1}min" -f ($DurationSeconds / 60) } else { "{0:F1}s" -f $DurationSeconds }
        Success       = $Success
        ExitCode      = $ExitCode
        ArtifactSizes = $artifactSizes
        Checksums     = $checksums
        BuildTimestamp = (Get-Date).ToString("o")
        TriggerId     = $TriggerId
        TriggerUser   = $TriggerUser
        LogPath       = $LogPath
    }
}

function Add-SystemInfoToStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [object]$Status,
        [Parameter(Mandatory=$true)]
        [object]$SystemInfo
    )
    $Status | Add-Member -NotePropertyName "MachineName" -NotePropertyValue $SystemInfo.MachineName -Force
    $Status | Add-Member -NotePropertyName "OS" -NotePropertyValue $SystemInfo.OS -Force
    $Status | Add-Member -NotePropertyName "CPU" -NotePropertyValue $SystemInfo.CPU -Force
    $Status | Add-Member -NotePropertyName "MemoryGB" -NotePropertyValue $SystemInfo.MemoryGB -Force
    $Status | Add-Member -NotePropertyName "DiskFreeGB" -NotePropertyValue $SystemInfo.DiskFreeGB -Force
    $Status | Add-Member -NotePropertyName "PowerShellVer" -NotePropertyValue $SystemInfo.PowerShellVer -Force
    $Status | Add-Member -NotePropertyName "WslVersion" -NotePropertyValue $SystemInfo.WslVersion -Force
    $Status | Add-Member -NotePropertyName "KernelVersion" -NotePropertyValue $SystemInfo.KernelVersion -Force
    return $Status
}

function Save-BuildStatus {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [object]$Status,
        [Parameter(Mandatory=$true)]
        [string]$OutputDir
    )
    $path = Join-Path $OutputDir "status.json"
    $Status | ConvertTo-Json -Depth 10 | Set-Content -Path $path -Encoding UTF8
    Write-LogInfo -Module "Status" -Message "Status written to $path"
    return $path
}

function Save-BuildSummary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [object]$Status,
        [string]$OutputDir
    )
    $lines = @()
    $lines += "=" * 60
    $lines += "  PPSA Build Summary"
    $lines += "=" * 60
    $lines += ""
    $lines += "  Build ID:     $($Status.BuildId)"
    $lines += "  Status:       $(if ($Status.Success) { 'SUCCESS' } else { 'FAILED' })"
    $lines += "  Duration:     $($Status.DurationHuman) ($($Status.Duration)s)"
    $lines += "  Exit Code:    $($Status.ExitCode)"
    $lines += "  Timestamp:    $($Status.BuildTimestamp)"
    $lines += "  Git Commit:   $($Status.GitCommit)"
    $lines += "  Git Branch:   $($Status.GitBranch)"
    if ($Status.TriggerId) { $lines += "  Trigger:      $($Status.TriggerId) ($($Status.TriggerUser))" }
    if ($Status.LogPath) { $lines += "  Log:          $($Status.LogPath)" }
    $lines += ""
    if ($Status.ArtifactSizes -and @($Status.ArtifactSizes.PSObject.Properties).Count -gt 0) {
        $lines += "  Artifacts:"
        foreach ($prop in $Status.ArtifactSizes.PSObject.Properties) {
            $lines += "    $($prop.Name): $($prop.Value) MB"
        }
    }
    if ($Status.MachineName) {
        $lines += ""
        $lines += "  Machine:      $($Status.MachineName)"
        $lines += "  OS:           $($Status.OS)"
        $lines += "  CPU:          $($Status.CPU)"
        if ($Status.MemoryGB) { $lines += "  Memory:       $($Status.MemoryGB) GB" }
        if ($Status.DiskFreeGB) { $lines += "  Disk Free:    $($Status.DiskFreeGB) GB" }
    }
    $lines += ""
    $lines += "=" * 60

    $summary = $lines -join "`r`n"
    $path = Join-Path $OutputDir "summary.log"
    $summary | Set-Content -Path $path -Encoding UTF8
    Write-LogInfo -Module "Status" -Message "Summary written to $path"
    return $path
}

function Update-BuildHistory {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [object]$Status,
        [string]$OutputDir,
        [int]$MaxEntries = 100
    )
    $path = Join-Path $OutputDir "history.json"

    $history = @()
    if (Test-Path $path) {
        try {
            $history = Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json
            if (-not $history) { $history = @() }
            if ($history -isnot [array]) { $history = @($history) }
        } catch { $history = @() }
    }

    # Add new entry
    $entry = [PSCustomObject]@{
        BuildId       = $Status.BuildId
        Success       = $Status.Success
        Duration      = $Status.Duration
        DurationHuman = $Status.DurationHuman
        BuildTimestamp = $Status.BuildTimestamp
        GitCommit     = $Status.GitCommit
        GitBranch     = $Status.GitBranch
        ExitCode      = $Status.ExitCode
        MachineName   = $Status.MachineName
    }
    $history = @($history) + $entry

    # Trim to max entries
    if ($history.Count -gt $MaxEntries) {
        $history = $history | Select-Object -Last $MaxEntries
    }

    $history | ConvertTo-Json -Depth 5 | Set-Content -Path $path -Encoding UTF8
    Write-LogInfo -Module "Status" -Message "History updated ($(@($history).Count) entries)"
    return $path
}

function Get-BuildHistoryFromFile {
    [CmdletBinding()]
    param(
        [string]$HistoryPath,
        [int]$Last = 10
    )
    if (-not (Test-Path $HistoryPath)) { return @() }
    try {
        $history = Get-Content $HistoryPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not $history) { return @() }
        if ($history -isnot [array]) { $history = @($history) }
        $start = [Math]::Max(0, $history.Count - $Last)
        Write-Output -NoEnumerate $history[$start..($history.Count - 1)]
    } catch { return @() }
}

Export-ModuleMember -Function New-BuildStatus, Add-SystemInfoToStatus, Save-BuildStatus, Save-BuildSummary, Update-BuildHistory, Get-BuildHistoryFromFile
