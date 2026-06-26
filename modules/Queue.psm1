# Queue.psm1 - PPSA Build Queue Manager
# Milestone 5: Job queue, dedup, concurrency guard, build history.

$script:JobQueue = [System.Collections.Queue]::new()
$script:QueueState = "idle"        # idle | building
$script:CurrentJob = $null
$script:CompletedIds = @{}          # triggerId -> $true (dedup)
$script:BuildHistory = [System.Collections.ArrayList]::new()

function New-BuildJob {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$TriggerId,
        [string]$TriggerUser = "unknown",
        [string]$TriggerBody = "",
        [string]$Tag = "",
        [string]$Repository = "",
        [int]$IssueNumber = 0
    )
    if (-not $Tag) { $Tag = "build-$(Get-Date -Format 'yyyyMMdd-HHmmss')" }
    return [PSCustomObject]@{
        TriggerId     = $TriggerId
        TriggerUser   = $TriggerUser
        TriggerBody   = $TriggerBody
        Tag           = $Tag
        Repository    = $Repository
        IssueNumber   = $IssueNumber
        AddedAt       = (Get-Date).ToString("o")
        StartedAt     = $null
        CompletedAt   = $null
        Success       = $null
        Duration      = $null
        LogPath       = $null
    }
}

function Add-BuildJob {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$TriggerId,
        [string]$TriggerUser = "unknown",
        [string]$TriggerBody = "",
        [string]$Tag = "",
        [string]$Repository = "",
        [int]$IssueNumber = 0
    )
    # Check completed history
    if ($script:CompletedIds.ContainsKey($TriggerId)) {
        return $null
    }
    # Check pending queue (not yet dequeued)
    $pendingDup = $false
    foreach ($pendingJob in $script:JobQueue) {
        if ($pendingJob.TriggerId -eq $TriggerId) { $pendingDup = $true; break }
    }
    if ($pendingDup) { return $null }
    # Check current build job
    if ($script:CurrentJob -and $script:CurrentJob.TriggerId -eq $TriggerId) {
        return $null
    }

    $job = New-BuildJob -TriggerId $TriggerId -TriggerUser $TriggerUser -TriggerBody $TriggerBody `
        -Tag $Tag -Repository $Repository -IssueNumber $IssueNumber
    $script:JobQueue.Enqueue($job)
    return $job
}

function Get-NextBuildJob {
    [CmdletBinding()]
    param()
    if ($script:JobQueue.Count -eq 0) { return $null }
    if ($script:QueueState -ne "idle") { return $null }

    $job = $script:JobQueue.Dequeue()
    $script:CurrentJob = $job
    $script:QueueState = "building"
    $job.StartedAt = (Get-Date).ToString("o")
    return $job
}

function Complete-BuildJob {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [object]$Job,
        [bool]$Success = $false,
        [string]$LogPath = ""
    )
    $Job.CompletedAt = (Get-Date).ToString("o")
    $Job.Success = $Success
    $Job.LogPath = $LogPath
    if ($Job.StartedAt) {
        $start = [datetime]::Parse($Job.StartedAt)
        $Job.Duration = ((Get-Date) - $start).TotalSeconds
    }

    $script:CompletedIds[$Job.TriggerId] = $true
    $null = $script:BuildHistory.Add($Job)
    $script:CurrentJob = $null
    $script:QueueState = "idle"
}

function Get-QueueStatus {
    [CmdletBinding()]
    param()
    return [PSCustomObject]@{
        State          = $script:QueueState
        CurrentJob     = $script:CurrentJob
        PendingCount   = $script:JobQueue.Count
        TotalCompleted = $script:BuildHistory.Count
        LastBuild      = if ($script:BuildHistory.Count -gt 0) { $script:BuildHistory[-1] } else { $null }
    }
}

function Get-BuildHistory {
    [CmdletBinding()]
    param([int]$Last = 10)
    $count = $script:BuildHistory.Count
    if ($count -eq 0) { return @() }
    $start = [Math]::Max(0, $count - $Last)
    Write-Output -NoEnumerate $script:BuildHistory.GetRange($start, $count - $start)
}

function Clear-BuildQueue {
    [CmdletBinding()]
    param()
    if ($script:QueueState -eq "building") { throw "Cannot clear queue while a build is in progress" }
    $script:JobQueue.Clear()
    $script:CompletedIds.Clear()
}

function Reset-BuildQueue {
    [CmdletBinding()]
    param()
    $script:JobQueue.Clear()
    $script:BuildHistory.Clear()
    $script:QueueState = "idle"
    $script:CurrentJob = $null
    $script:CompletedIds.Clear()
}

Export-ModuleMember -Function New-BuildJob, Add-BuildJob, Get-NextBuildJob, Complete-BuildJob, Get-QueueStatus, Get-BuildHistory, Clear-BuildQueue, Reset-BuildQueue
