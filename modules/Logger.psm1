# Logger.psm1 - PPSA Local Builder Structured Logger
# Milestone 2: Timestamped, leveled, colored, multi-sink logging with timing.

$script:LogDir = $null
$script:EnabledLevels = @("TRACE","DEBUG","INFO","WARN","ERROR","SUCCESS")

$LevelColors = @{
    TRACE   = "DarkGray"
    DEBUG   = "Gray"
    INFO    = "White"
    WARN    = "Yellow"
    ERROR   = "Red"
    SUCCESS = "Green"
}

$LevelOrder = @{ TRACE=0; DEBUG=1; INFO=2; WARN=3; ERROR=4; SUCCESS=5 }

function Initialize-Logger {
    [CmdletBinding()]
    param(
        [string]$LogDirectory,
        [string[]]$Levels = @("TRACE","DEBUG","INFO","WARN","ERROR","SUCCESS"),
        [int]$RetentionDays = 30
    )
    $script:LogDir = $LogDirectory
    $script:EnabledLevels = $Levels

    if (-not (Test-Path $LogDirectory)) {
        New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
    }

    # Clean old logs
    $cutoff = (Get-Date).AddDays(-$RetentionDays)
    Get-ChildItem $LogDirectory -Filter "*.log" | Where-Object { $_.LastWriteTime -lt $cutoff } | Remove-Item -Force
}

function Format-LogLine {
    param([string]$Level, [string]$Module, [string]$Message,
          [string]$Command, [int]$ExitCode, [string]$Location, [string]$RecommendedAction)
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
    $line = "[$ts] [$Level] [$Module] $Message"
    if ($Command)  { $line += " | cmd: $Command" }
    if ($ExitCode -ne 0) { $line += " | exit: $ExitCode" }
    if ($Location) { $line += " | at: $Location" }
    if ($RecommendedAction) { $line += " | action: $RecommendedAction" }
    return $line
}

function Write-Log {
    [CmdletBinding()]
    param(
        [ValidateSet("TRACE","DEBUG","INFO","WARN","ERROR","SUCCESS")]
        [string]$Level = "INFO",
        [string]$Module = "General",
        [string]$Message,
        [string]$Command,
        [int]$ExitCode = 0,
        [string]$Location,
        [string]$RecommendedAction
    )

    $line = Format-LogLine -Level $Level -Module $Module -Message $Message `
        -Command $Command -ExitCode $ExitCode -Location $Location -RecommendedAction $RecommendedAction

    # Console output (colored)
    $color = if ($LevelColors.ContainsKey($Level)) { $LevelColors[$Level] } else { "White" }
    Write-Host $line -ForegroundColor $color

    # File output
    if ($script:LogDir) {
        $logFile = Join-Path $script:LogDir "build.log"
        Add-Content -Path $logFile -Value $line

        # TRACE goes to trace.log
        if ($Level -eq "TRACE") {
            $traceFile = Join-Path $script:LogDir "trace.log"
            Add-Content -Path $traceFile -Value $line
        }

        # ERROR goes to error.log
        if ($Level -eq "ERROR") {
            $errFile = Join-Path $script:LogDir "error.log"
            Add-Content -Path $errFile -Value $line
        }
    }
}

# Convenience wrappers
function Write-LogTrace {
    [CmdletBinding()] param([string]$Module, [string]$Message, [string]$Command, [int]$ExitCode, [string]$Location, [string]$RecommendedAction)
    Write-Log -Level TRACE -Module $Module -Message $Message -Command $Command -ExitCode $ExitCode -Location $Location -RecommendedAction $RecommendedAction
}
function Write-LogDebug {
    [CmdletBinding()] param([string]$Module, [string]$Message, [string]$Command, [int]$ExitCode, [string]$Location, [string]$RecommendedAction)
    Write-Log -Level DEBUG -Module $Module -Message $Message -Command $Command -ExitCode $ExitCode -Location $Location -RecommendedAction $RecommendedAction
}
function Write-LogInfo {
    [CmdletBinding()] param([string]$Module, [string]$Message, [string]$Command, [int]$ExitCode, [string]$Location, [string]$RecommendedAction)
    Write-Log -Level INFO -Module $Module -Message $Message -Command $Command -ExitCode $ExitCode -Location $Location -RecommendedAction $RecommendedAction
}
function Write-LogWarn {
    [CmdletBinding()] param([string]$Module, [string]$Message, [string]$Command, [int]$ExitCode, [string]$Location, [string]$RecommendedAction)
    Write-Log -Level WARN -Module $Module -Message $Message -Command $Command -ExitCode $ExitCode -Location $Location -RecommendedAction $RecommendedAction
}
function Write-LogError {
    [CmdletBinding()] param([string]$Module, [string]$Message, [string]$Command, [int]$ExitCode, [string]$Location, [string]$RecommendedAction)
    Write-Log -Level ERROR -Module $Module -Message $Message -Command $Command -ExitCode $ExitCode -Location $Location -RecommendedAction $RecommendedAction
}
function Write-LogSuccess {
    [CmdletBinding()] param([string]$Module, [string]$Message, [string]$Command, [int]$ExitCode, [string]$Location, [string]$RecommendedAction)
    Write-Log -Level SUCCESS -Module $Module -Message $Message -Command $Command -ExitCode $ExitCode -Location $Location -RecommendedAction $RecommendedAction
}

# Timing
function Start-Timer {
    return [System.Diagnostics.Stopwatch]::StartNew()
}

function Stop-Timer {
    [CmdletBinding()]
    param(
        [System.Diagnostics.Stopwatch]$Stopwatch,
        [string]$Module = "General",
        [string]$Operation = "operation"
    )
    $Stopwatch.Stop()
    $secs = $Stopwatch.Elapsed.TotalSeconds.ToString("F3")
    Write-LogInfo -Module $Module -Message "$Operation completed in ${secs}s"
    return $Stopwatch.Elapsed
}

function Measure-Phase {
    [CmdletBinding()]
    param(
        [string]$Module = "General",
        [string]$Name = "phase",
        [scriptblock]$ScriptBlock
    )
    $sw = Start-Timer
    Write-LogInfo -Module $Module -Message "Starting: $Name"
    try {
        & $ScriptBlock
        $sw.Stop()
        $secs = $sw.Elapsed.TotalSeconds.ToString("F3")
        Write-LogInfo -Module $Module -Message "Completed: $Name (${secs}s)"
    } catch {
        $sw.Stop()
        $secs = $sw.Elapsed.TotalSeconds.ToString("F3")
        Write-LogError -Module $Module -Message "Failed: $Name after ${secs}s" `
            -Command $Name -Location $_.ScriptStackTrace -RecommendedAction "Check logs above for details"
        throw
    }
}

Export-ModuleMember -Function Initialize-Logger, Write-Log, Write-LogTrace, Write-LogDebug, Write-LogInfo, Write-LogWarn, Write-LogError, Write-LogSuccess, Start-Timer, Stop-Timer, Measure-Phase
