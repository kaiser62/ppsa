# Logger (M2)

Structured logging with timestamp, severity, module, colored console, and multi-file output.

## Format

```
[yyyy-MM-dd HH:mm:ss.fff] [LEVEL] [Module] Message | cmd: ... | exit: N | at: ... | action: ...
```

## Levels

TRACE → trace.log, DEBUG, INFO → build.log, WARN → build.log, ERROR → build.log + error.log, SUCCESS → build.log

## Usage

```powershell
Import-Module modules\Logger.psm1

Initialize-Logger -LogDirectory "H:\dev\palimage\logs" -Levels @("INFO","WARN","ERROR")

Write-LogInfo -Module "Builder" -Message "Building image..."
Write-LogError -Module "Builder" -Message "Failed" -Command "build" -ExitCode 1 -Location "build.ps1:42" -RecommendedAction "Check disk space"

$sw = Start-Timer
Start-Sleep -Seconds 1
Stop-Timer -Stopwatch $sw -Module "Builder" -Operation "sleep"

Measure-Phase -Module "Builder" -Name "build" -ScriptBlock { ./build.sh }
```

## Functions

| Function | Description |
|----------|-------------|
| Initialize-Logger | Create log dir, set levels, purge old logs |
| Write-Log | Core log writer (raw) |
| Write-LogTrace/Debug/Info/Warn/Error/Success | Level wrappers |
| Start-Timer | Returns Stopwatch |
| Stop-Timer | Stops and logs elapsed duration |
| Measure-Phase | Wraps a scriptblock with timing and error handling |
