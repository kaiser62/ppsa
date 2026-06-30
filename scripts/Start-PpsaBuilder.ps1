# Start-PpsaBuilder.ps1 - PPSA Local Builder Orchestrator
# Milestone 11: Wires all 9 modules into a single entry point.
# Usage:
#   pwsh ./scripts/Start-PpsaBuilder.ps1                       # single-shot, uses github.issue_number from builder.json
#   pwsh ./scripts/Start-PpsaBuilder.ps1 -IssueNumber 42       # single-shot, override issue
#   pwsh ./scripts/Start-PpsaBuilder.ps1 -Watch                # poll loop
#   pwsh ./scripts/Start-PpsaBuilder.ps1 -SkipSmokeTest        # skip the M10 boot/verify phase
#   pwsh ./scripts/Start-PpsaBuilder.ps1 -Repo owner/name      # override repo
[CmdletBinding()]
param(
    [int]$IssueNumber = 0,
    [string]$Repository = "",
    [switch]$Watch,
    [switch]$SkipSmokeTest,
    [int]$PollSeconds = 0,
    [string]$ConfigPath = ""
)

$ErrorActionPreference = "Stop"
$script:RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
$ModulesDir = Join-Path $script:RepoRoot "modules"

# ponytail: hardcoded module order matches build dependency chain (Utils/Logger first, last depends on all)
$modules = @("Utils", "Logger", "Configuration", "GitHub", "Queue", "Builder", "Artifacts", "VirtualBox", "Status", "SmokeTest")
foreach ($m in $modules) {
    Remove-Module $m -ErrorAction SilentlyContinue
    Import-Module (Join-Path $ModulesDir "$m.psm1") -Force
}

function Get-TriggerComment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)] [string]$Repo,
        [Parameter(Mandatory=$true)] [int]$Issue
    )
    $comments = Get-GitHubComments -Repository $Repo -IssueNumber $Issue -Count 20
    foreach ($c in $comments) {
        if (Test-GitHubCommentIsOwn -CommentUser $c.user) { continue }
        if (Test-BuildTrigger -CommentBody $c.body) {
            return $c
        }
    }
    return $null
}

function Get-LocalWireguardEnv {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)] [string]$RepoRoot
    )
    $localJson = Join-Path $RepoRoot "wireguard.local.json"
    if (-not (Test-Path $localJson)) {
        return @{}
    }
    try {
        $cfg = Get-Content $localJson -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    } catch {
        Write-LogWarn -Module "Orchestrator" -Message "wireguard.local.json present but unparseable: $($_.Exception.Message)"
        return @{}
    }
    if (-not $cfg.enabled) {
        Write-LogInfo -Module "Orchestrator" -Message "wireguard.local.json has enabled=false, skipping"
        return @{}
    }
    # Map JSON fields to build env vars. PowerShell-process env vars win (allow CI override).
    $map = @{
        "PPSA_WG_API_URL"       = "api_url"
        "PPSA_WG_API_USER"      = "api_user"
        "PPSA_WG_API_PASS"      = "api_password"
        "PPSA_WG_PEER_NAME"     = "peer_name"
        "PPSA_WG_PREFERRED_IP"  = "preferred_ip"
    }
    $out = @{}
    foreach ($envName in $map.Keys) {
        $jsonField = $map[$envName]
        $val = $cfg.$jsonField
        if ($null -eq $val) { $val = "" }
        # Process env override: if already set (non-empty), keep that value.
        $existing = [Environment]::GetEnvironmentVariable($envName, "Process")
        if ([string]::IsNullOrEmpty($existing)) {
            $out[$envName] = [string]$val
        } else {
            $out[$envName] = $existing
        }
    }
    # Drop empty optional fields so the bash build keeps its defaults.
    if ([string]::IsNullOrEmpty($out["PPSA_WG_PREFERRED_IP"])) {
        $out.Remove("PPSA_WG_PREFERRED_IP")
    }
    if ($out.Count -gt 0) {
        Write-LogInfo -Module "Orchestrator" -Message "wireguard.local.json: loaded $($out.Keys -join ', ')"
    }
    return $out
}

function Invoke-PpsaBuildOnce {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)] [object]$Config
    )

    $repo = if ($Repository) { $Repository } else { $Config.github.repository }
    $issue = if ($IssueNumber -gt 0) { $IssueNumber } else { [int]$Config.github.issue_number }

    # Read local wg-easy creds (gitignored) so first-boot auto-registration
    # works without the user touching the build script. CI never has this file.
    $wgEnv = Get-LocalWireguardEnv -RepoRoot $script:RepoRoot

    # Phase 1: Watch GitHub for a build trigger
    $trigger = $null
    Measure-Phase -Module "Orchestrator" -Name "watch-github (issue #$issue)" -ScriptBlock {
        $trigger = Get-TriggerComment -Repo $repo -Issue $issue
        if (-not $trigger) {
            Write-LogInfo -Module "Orchestrator" -Message "No new build trigger on $repo#$issue"
            return
        }
        Write-LogInfo -Module "Orchestrator" -Message "Trigger: id=$($trigger.id) user=$($trigger.user)"
    }
    if (-not $trigger) { return $false }

    # Phase 2: Queue
    $job = $null
    Measure-Phase -Module "Orchestrator" -Name "queue-build" -ScriptBlock {
        $job = Add-BuildJob -TriggerId ([string]$trigger.id) -TriggerUser $trigger.user `
            -TriggerBody $trigger.body -Repository $repo -IssueNumber $issue
        if (-not $job) {
            Write-LogInfo -Module "Orchestrator" -Message "Duplicate trigger $(([string]$trigger.id).Substring(0,[Math]::Min(12,([string]$trigger.id).Length)))... already handled"
        } else {
            Write-LogInfo -Module "Orchestrator" -Message "Queued job: tag=$($job.Tag)"
        }
    }
    if (-not $job) { return $false }

    $next = Get-NextBuildJob
    if (-not $next) {
        Write-LogInfo -Module "Orchestrator" -Message "Queue busy; will retry next tick"
        return $false
    }
    Write-LogInfo -Module "Orchestrator" -Message "Dequeued: tag=$($next.Tag)"

    # Phase 3: Build (WSL)
    $build = $null
    try {
        $build = Invoke-Build -Config $Config -Tag $next.Tag -ExtraEnv $wgEnv
    } catch {
        Write-LogError -Module "Orchestrator" -Message "Invoke-Build threw" -Location $_.ScriptStackTrace -RecommendedAction "See Builder logs above"
        Complete-BuildJob -Job $next -Success $false
        return $true
    }

    if (-not $build.Success) {
        Write-LogError -Module "Orchestrator" -Message "Build failed (phase: $($build.FailedPhase))" -RecommendedAction "Inspect WSL build log"
        Complete-BuildJob -Job $next -Success $false
        return $true
    }

    # Phase 4: Process artifacts
    $outDir  = $Config.output.directory
    $vdiPath = Join-Path $outDir "ppsa-vbox-$($next.Tag).vdi"
    $imgZst  = Join-Path $outDir "ppsa-vbox-$($next.Tag).img.zst"
    $shaPath = Join-Path $outDir "ppsa-vbox-$($next.Tag).vdi.sha256"
    $expectedHash = $null
    if (Test-Path $shaPath) { $expectedHash = (Get-Content $shaPath).Split(' ')[0].Trim() }

    $artifact = $null
    Measure-Phase -Module "Orchestrator" -Name "verify-vdi" -ScriptBlock {
        $artifact = Test-Artifact -Path $vdiPath -ExpectedHash $expectedHash -MinSizeMB 100
        if (-not $artifact.Valid) {
            throw "Artifact invalid: $($artifact.Issues -join '; ')"
        }
    }
    if (-not $artifact) { Complete-BuildJob -Job $next -Success $false; return $true }

    Measure-Phase -Module "Orchestrator" -Name "vdi-integrity" -ScriptBlock {
        $integ = Test-VdiIntegrity -VdiPath $vdiPath
        if (-not $integ.Valid) { throw "VDI integrity check failed: $($integ.Error)" }
    }

    Measure-Phase -Module "Orchestrator" -Name "write-manifest" -ScriptBlock {
        $manifest = New-ArtifactManifest -Tag $next.Tag `
            -FilePaths @($vdiPath, $imgZst, $shaPath) `
            -OutputPath (Join-Path $outDir "manifest-$($next.Tag).json")
        Update-LatestSymlink -SourceVdi $vdiPath -OutputDir $outDir | Out-Null
    }

    # Phase 5: Status
    $status = $null
    Measure-Phase -Module "Orchestrator" -Name "save-status" -ScriptBlock {
        $sysInfo = Get-SystemInformation
        $status = New-BuildStatus -Tag $next.Tag -Success $true `
            -DurationSeconds ($build.TotalDuration.TotalSeconds) -ExitCode 0 `
            -Artifacts @([PSCustomObject]@{ FileName = (Split-Path $vdiPath -Leaf); SizeMB = $artifact.SizeMB; SHA256 = $artifact.Hash }) `
            -TriggerId ([string]$trigger.id) -TriggerUser $trigger.user `
            -LogPath (Join-Path $Config.logging.directory "build.log")
        $null = Add-SystemInfoToStatus -Status $status -SystemInfo $sysInfo
        $null = Save-BuildStatus -Status $status -OutputDir $outDir
        $null = Save-BuildSummary -Status $status -OutputDir $outDir
        $null = Update-BuildHistory -Status $status -OutputDir $outDir
    }

    # Phase 6: Optional smoke test
    if (-not $SkipSmokeTest) {
        $smoke = $null
        try {
            $smoke = Invoke-SmokeTest -Config $Config -VdiPath $vdiPath
        } catch {
            Write-LogError -Module "Orchestrator" -Message "Smoke test threw" -Location $_.ScriptStackTrace -RecommendedAction "Inspect VBox console log"
        }
        if ($smoke) {
            Measure-Phase -Module "Orchestrator" -Name "save-smoke" -ScriptBlock {
                $null = Save-SmokeTestResult -Result $smoke -OutputDir $outDir
            }
            if (-not $smoke.Success) {
                Write-LogWarn -Module "Orchestrator" -Message "Smoke test reported unhealthy; build still marked SUCCESS (build artifact OK)"
            }
        }
    } else {
        Write-LogInfo -Module "Orchestrator" -Message "Smoke test skipped (SkipSmokeTest)"
    }

    Complete-BuildJob -Job $next -Success $true
    return $true
}

# --- Main ---
$configPath = if ($ConfigPath) { $ConfigPath } else { Join-Path $script:RepoRoot "builder.json" }
try {
    $config = Get-Configuration -Path $configPath
} catch {
    Write-Host "FATAL: $($_.Exception.Message)" -ForegroundColor Red
    exit 2
}

Initialize-Logger -LogDirectory $config.logging.directory `
    -Levels $config.logging.levels `
    -RetentionDays ([int]$config.logging.retention_days)

$repoDisp = if ($Repository) { $Repository } else { $config.github.repository }
$issueDisp = if ($IssueNumber -gt 0) { $IssueNumber } else { $config.github.issue_number }
Write-LogInfo -Module "Orchestrator" -Message "PPSA Local Builder starting (repo=$repoDisp, issue=$issueDisp, watch=$Watch)"

if ($Watch) {
    $interval = if ($PollSeconds -gt 0) { $PollSeconds } else { [int]$config.github.poll_interval_seconds }
    Write-LogInfo -Module "Orchestrator" -Message "Watch mode: polling every ${interval}s. Ctrl+C to stop."
    while ($true) {
        try {
            $null = Invoke-PpsaBuildOnce -Config $config
        } catch {
            Write-LogError -Module "Orchestrator" -Message "Loop tick failed" -Location $_.ScriptStackTrace -RecommendedAction "See error.log"
        }
        Start-Sleep -Seconds $interval
    }
} else {
    try {
        $null = Invoke-PpsaBuildOnce -Config $config
    } catch {
        Write-LogError -Module "Orchestrator" -Message "Build run failed" -Location $_.ScriptStackTrace -RecommendedAction "See error.log"
        exit 1
    }
}

Write-LogInfo -Module "Orchestrator" -Message "PPSA Local Builder exiting"
