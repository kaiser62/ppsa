# Utils.psm1 - PPSA Local Builder Common Utilities
# Milestone 3: Process execution, file verification, system info, build tags.

function Invoke-CommandCapture {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$FileName,
        [string[]]$Arguments,
        [string]$WorkingDirectory,
        [int]$TimeoutSeconds = 3600
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FileName
    if ($Arguments.Count -gt 0) { $psi.Arguments = $Arguments -join ' ' }
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.CreateNoWindow = $true
    if ($WorkingDirectory) { $psi.WorkingDirectory = $WorkingDirectory }

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $proc = [System.Diagnostics.Process]::Start($psi)

    $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
    $stderrTask = $proc.StandardError.ReadToEndAsync()

    if ($TimeoutSeconds -gt 0) {
        if (-not $proc.WaitForExit($TimeoutSeconds * 1000)) {
            $proc.Kill()
            $proc.WaitForExit()
            $sw.Stop()
            throw "Command timed out after ${TimeoutSeconds}s: $FileName $($Arguments -join ' ')"
        }
    } else {
        $proc.WaitForExit()
    }
    $sw.Stop()

    return [PSCustomObject]@{
        ExitCode = $proc.ExitCode
        Stdout   = $stdoutTask.Result.Trim()
        Stderr   = $stderrTask.Result.Trim()
        Duration = $sw.Elapsed
    }
}

function Get-FileHashVerified {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$Path,
        [string]$ExpectedHash,
        [string]$Algorithm = "SHA256"
    )
    if (-not (Test-Path $Path)) {
        return [PSCustomObject]@{ Valid = $false; Hash = $null; Error = "File not found: $Path" }
    }
    try {
        $actual = (Get-FileHash -Path $Path -Algorithm $Algorithm).Hash.ToLower()
        if ($ExpectedHash) {
            $valid = ($actual -eq $ExpectedHash.ToLower())
            return [PSCustomObject]@{ Valid = $valid; Hash = $actual; Error = if (-not $valid) { "Hash mismatch: expected $ExpectedHash, got $actual" } else { $null } }
        }
        return [PSCustomObject]@{ Valid = $true; Hash = $actual; Error = $null }
    } catch {
        return [PSCustomObject]@{ Valid = $false; Hash = $null; Error = $_.Message }
    }
}

function Copy-Verified {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$Source,
        [Parameter(Mandatory=$true)]
        [string]$Destination
    )
    if (-not (Test-Path $Source)) { throw "Source not found: $Source" }

    $destDir = Split-Path $Destination -Parent
    if ($destDir -and -not (Test-Path $destDir)) {
        New-Item -ItemType Directory -Path $destDir -Force | Out-Null
    }

    Copy-Item -Path $Source -Destination $Destination -Force
    if (-not (Test-Path $Destination)) { throw "Copy failed: destination not created" }

    $srcHash = (Get-FileHash -Path $Source -Algorithm SHA256).Hash
    $dstHash = (Get-FileHash -Path $Destination -Algorithm SHA256).Hash
    if ($srcHash -ne $dstHash) {
        Remove-Item $Destination -Force -ErrorAction SilentlyContinue
        throw "Copy verification failed: hash mismatch after copying $Source -> $Destination"
    }
    return $true
}

function Get-SystemInformation {
    [CmdletBinding()]
    param()
    $os = Get-CimInstance Win32_OperatingSystem
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    $disk = Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" | Where-Object { $_.DeviceID -eq "H:" } | Select-Object -First 1
    if (-not $disk) { $disk = Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" | Select-Object -First 1 }

    $wslVersion = $null
    try {
        $wslOut = Invoke-CommandCapture -FileName "wsl" -Arguments @("--version") -TimeoutSeconds 10
        if ($wslOut.ExitCode -eq 0) { $wslVersion = $wslOut.Stdout }
    } catch {}

    $kernelVersion = $null
    try {
        $kOut = Invoke-CommandCapture -FileName "wsl" -Arguments @("-d", "Ubuntu", "--", "uname", "-r") -TimeoutSeconds 10
        if ($kOut.ExitCode -eq 0) { $kernelVersion = $kOut.Stdout }
    } catch {}

    return [PSCustomObject]@{
        MachineName    = $env:COMPUTERNAME
        OS             = "$($os.Caption) $($os.Version)"
        CPU            = "$($cpu.Name) ($($cpu.NumberOfLogicalProcessors) cores)"
        MemoryGB       = [math]::Round($os.TotalVisibleMemorySize / 1MB, 1)
        DiskFreeGB     = if ($disk) { [math]::Round($disk.FreeSpace / 1GB, 1) } else { $null }
        DiskTotalGB    = if ($disk) { [math]::Round($disk.Size / 1GB, 1) } else { $null }
        PowerShellVer  = $PSVersionTable.PSVersion.ToString()
        WslVersion     = $wslVersion
        KernelVersion  = $kernelVersion
    }
}

function New-BuildTag {
    [CmdletBinding()]
    param([string]$Prefix = "local")
    return "$Prefix-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
}

function Test-CommandAvailable {
    [CmdletBinding()]
    param([string]$Command)
    $oldPreference = $ErrorActionPreference
    $ErrorActionPreference = "Stop"
    try {
        if ($IsWindows -or $PSVersionTable.PSEdition -eq "Desktop") {
            $null = Get-Command $Command -ErrorAction Stop
        } else {
            $null = Get-Command $Command -ErrorAction Stop
        }
        return $true
    } catch {
        return $false
    } finally {
        $ErrorActionPreference = $oldPreference
    }
}

Export-ModuleMember -Function Invoke-CommandCapture, Get-FileHashVerified, Copy-Verified, Get-SystemInformation, New-BuildTag, Test-CommandAvailable
