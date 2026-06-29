# SmokeTest.psm1 - PPSA VM Smoke Testing
# Milestone 10: Boot a built VDI in VirtualBox, wait for login,
# detect kernel panic, optionally probe the WebUI, shut down,
# and persist a JSON report. Wraps VirtualBox.psm1.

function Get-VmConsoleLogPath {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)] [string]$VmName)
    return (Join-Path $HOME "VirtualBox VMs" $VmName "console.log")
}

function Get-VmConsoleLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)] [string]$VmName,
        [int]$TailLines = 200
    )
    $path = Get-VmConsoleLogPath -VmName $VmName
    if (-not (Test-Path $path)) { return $null }
    $lines = Get-Content $path -ErrorAction SilentlyContinue
    if (-not $lines) { return "" }
    if ($lines.Count -le $TailLines) { return ($lines -join "`n") }
    return (($lines | Select-Object -Last $TailLines) -join "`n")
}

function Test-VmBootHealthy {
    [CmdletBinding()]
    param([string]$ConsoleText)

    if (-not $ConsoleText) {
        return [PSCustomObject]@{ Healthy = $false; Reason = "Console log empty" }
    }

    $panicPatterns = @(
        "Kernel panic",
        "kernel panic - not syncing",
        "Oops",
        "Out of memory: Killed process",
        "VFS: Unable to mount root fs",
        "No working init found",
        "systemd\[1\]: Failed to start",
        "Failed to mount",
        "FATAL: kernel too old"
    )
    foreach ($p in $panicPatterns) {
        if ($ConsoleText -match [regex]::Escape($p)) {
            return [PSCustomObject]@{ Healthy = $false; Reason = "Matched: $p" }
        }
    }
    return [PSCustomObject]@{ Healthy = $true; Reason = $null }
}

function Wait-VmBootReady {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)] [string]$VmName,
        [int]$TimeoutSeconds = 600,
        [int]$PollSeconds = 5
    )
    $readyMarkers = @("login:", "Debian GNU/Linux", "Welcome to PPSA", "cloud-init", "Started Daily")
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $logPath = Get-VmConsoleLogPath -VmName $VmName
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        if (Test-Path $logPath) {
            $tail = Get-VmConsoleLog -VmName $VmName -TailLines 400
            foreach ($m in $readyMarkers) {
                if ($tail -and $tail -match [regex]::Escape($m)) {
                    $sw.Stop()
                    Write-LogInfo -Module "Smoke" -Message "VM '$VmName' boot ready (matched '$m' after $([math]::Round($sw.Elapsed.TotalSeconds,1))s)"
                    return [PSCustomObject]@{ Ready = $true; Marker = $m; Duration = $sw.Elapsed }
                }
            }
        }
        Start-Sleep -Seconds $PollSeconds
    }
    $sw.Stop()
    Write-LogWarn -Module "Smoke" -Message "VM '$VmName' boot timeout after $TimeoutSeconds s"
    return [PSCustomObject]@{ Ready = $false; Marker = $null; Duration = $sw.Elapsed }
}

function Test-VmWebUiReachable {
    [CmdletBinding()]
    param(
        [string]$Url = "http://127.0.0.1:8080",
        [string]$ProbePath = "/",
        [int]$TimeoutSeconds = 5
    )
    try {
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $resp = Invoke-WebRequest -Uri ($Url.TrimEnd('/') + $ProbePath) -TimeoutSec $TimeoutSeconds -UseBasicParsing -ErrorAction Stop
        $sw.Stop()
        return [PSCustomObject]@{
            Reachable = $true
            StatusCode = $resp.StatusCode
            Duration = $sw.Elapsed
            Error = $null
        }
    } catch {
        return [PSCustomObject]@{
            Reachable = $false
            StatusCode = $null
            Duration = $null
            Error = $_.Exception.Message
        }
    }
}

function Invoke-SmokeTest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)] [object]$Config,
        [Parameter(Mandatory=$true)] [string]$VdiPath
    )

    $vmName      = $Config.virtualbox.vm_name
    $memoryMB    = [int]$Config.virtualbox.memory_mb
    $cpus        = [int]$Config.virtualbox.cpus
    $bootTimeout = [int]$Config.smoke_test.boot_timeout_seconds
    $webuiTimeout = [int]$Config.smoke_test.webui_timeout_seconds
    $webuiUrl    = $Config.smoke_test.webui_url
    $probePath   = $Config.smoke_test.webui_probe_path
    $autoShutdown = [bool]$Config.smoke_test.auto_shutdown

    $phases = @()

    $r = Test-VBoxManageAvailable
    if (-not $r) {
        Write-LogError -Module "Smoke" -Message "VBoxManage not available" -Location "Invoke-SmokeTest" -RecommendedAction "Install VirtualBox"
        return [PSCustomObject]@{ Success = $false; Phases = @(); Reason = "VBoxManage missing" }
    }

    $sw = Start-Timer
    $null = New-TestVm -Name $vmName -MemoryMB $memoryMB -Cpus $cpus -VdiPath $VdiPath
    $sw.Stop()
    $phases += [PSCustomObject]@{ Name = "create-vm"; Success = $true; Duration = $sw.Elapsed }
    Write-LogInfo -Module "Smoke" -Message "Test VM prepared ($($sw.Elapsed.TotalSeconds.ToString('F1'))s)"

    $bootOk = $false
    $bootMarker = $null
    $bootDuration = $null
    try {
        $sw = Start-Timer
        $null = Start-TestVm -Name $vmName -Type "headless"
        $sw.Stop()
        $phases += [PSCustomObject]@{ Name = "start-vm"; Success = $true; Duration = $sw.Elapsed }

        $ready = Wait-VmBootReady -VmName $vmName -TimeoutSeconds $bootTimeout
        $bootOk = $ready.Ready
        $bootMarker = $ready.Marker
        $bootDuration = $ready.Duration
        $phases += [PSCustomObject]@{ Name = "wait-boot"; Success = $bootOk; Duration = $ready.Duration; Marker = $bootMarker }

        $console = Get-VmConsoleLog -VmName $vmName -TailLines 500
        $health = Test-VmBootHealthy -ConsoleText $console
        $phases += [PSCustomObject]@{ Name = "health-check"; Success = $health.Healthy; Reason = $health.Reason }
        if (-not $health.Healthy) {
            Write-LogError -Module "Smoke" -Message "Console indicates unhealthy boot: $($health.Reason)" -Location "Invoke-SmokeTest" -RecommendedAction "Inspect $((Get-VmConsoleLogPath -VmName $vmName))"
        }

        $probe = $null
        if ($webuiUrl) {
            $sw = Start-Timer
            $probe = Test-VmWebUiReachable -Url $webuiUrl -ProbePath $probePath -TimeoutSeconds 5
            $sw.Stop()
            $phases += [PSCustomObject]@{ Name = "webui-probe"; Success = $probe.Reachable; Duration = $sw.Elapsed; StatusCode = $probe.StatusCode; Error = $probe.Error }
        }

        $success = $bootOk -and $health.Healthy -and (($null -eq $probe) -or $probe.Reachable)
    } finally {
        if ($autoShutdown) {
            try {
                $sw = Start-Timer
                $null = Stop-TestVm -Name $vmName -Mode "acpipowerbutton"
                $null = Wait-VmStopped -Name $vmName -TimeoutSeconds 60
                $sw.Stop()
                $phases += [PSCustomObject]@{ Name = "shutdown"; Success = $true; Duration = $sw.Elapsed }
            } catch {
                $phases += [PSCustomObject]@{ Name = "shutdown"; Success = $false; Error = $_.Exception.Message }
            }
        }
    }

    return [PSCustomObject]@{
        Success        = $success
        VmName         = $vmName
        VdiPath        = $VdiPath
        BootReady      = $bootOk
        BootMarker     = $bootMarker
        BootDuration   = $bootDuration
        ConsoleExcerpt = (Get-VmConsoleLog -VmName $vmName -TailLines 80)
        Phases         = $phases
        Timestamp      = (Get-Date).ToString("o")
    }
}

function Save-SmokeTestResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)] [object]$Result,
        [Parameter(Mandatory=$true)] [string]$OutputDir
    )
    if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null }
    $path = Join-Path $OutputDir "smoke-test.json"
    $Result | ConvertTo-Json -Depth 10 | Set-Content -Path $path -Encoding UTF8
    Write-LogInfo -Module "Smoke" -Message "Smoke test result saved to $path"
    return $path
}

Export-ModuleMember -Function Get-VmConsoleLogPath, Get-VmConsoleLog, Test-VmBootHealthy, Wait-VmBootReady, Test-VmWebUiReachable, Invoke-SmokeTest, Save-SmokeTestResult
