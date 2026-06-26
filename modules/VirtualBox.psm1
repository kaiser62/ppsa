function Test-VBoxManageAvailable {
    param()
    try { $null = Get-Command VBoxManage -ErrorAction Stop; return $true } catch { return $false }
}

function Invoke-VBoxManage {
    param([string[]]$Arguments = @(), [int]$TimeoutSeconds = 120)
    $r = Invoke-CommandCapture -FileName "VBoxManage" -Arguments $Arguments -TimeoutSeconds $TimeoutSeconds
    return $r
}

function New-TestVm {
    param(
        [Parameter(Mandatory=$true)] [string]$Name,
        [int]$MemoryMB = 2048,
        [int]$Cpus = 2,
        [string]$VdiPath
    )
    $list = Invoke-VBoxManage -Arguments @("list", "vms")
    $quoted = '"' + $Name + '"'
    if ($list.ExitCode -ne 0 -or $list.Stdout -match $quoted) {
        Write-LogInfo -Module "VBox" -Message "VM '$Name' already exists"
        return [PSCustomObject]@{ Created = $false; Name = $Name; VdiAttached = $null }
    }
    $null = Invoke-VBoxManage -Arguments @("createvm", "--name", $Name, "--ostype", "Debian_64", "--register")
    $null = Invoke-VBoxManage -Arguments @("modifyvm", $Name, "--memory", [string]$MemoryMB)
    $null = Invoke-VBoxManage -Arguments @("modifyvm", $Name, "--cpus", [string]$Cpus)
    $null = Invoke-VBoxManage -Arguments @("modifyvm", $Name, "--boot1", "disk")
    $null = Invoke-VBoxManage -Arguments @("modifyvm", $Name, "--nic1", "nat")
    $null = Invoke-VBoxManage -Arguments @("modifyvm", $Name, "--uart1", "0x3F8", "4")
    $serialDir = Join-Path $HOME "VirtualBox VMs" $Name
    $serialPath = Join-Path $serialDir "console.log"
    $null = Invoke-VBoxManage -Arguments @("modifyvm", $Name, "--uartmode1", "file", $serialPath)
    Write-LogInfo -Module "VBox" -Message "VM '$Name' created (${MemoryMB}MB, ${Cpus} CPU)"
    if ($VdiPath) {
        $null = Set-TestVmDisk -Name $Name -VdiPath $VdiPath
    }
    return [PSCustomObject]@{ Created = $true; Name = $Name; VdiAttached = $null }
}

function Set-TestVmDisk {
    param(
        [Parameter(Mandatory=$true)] [string]$Name,
        [Parameter(Mandatory=$true)] [string]$VdiPath
    )
    if (-not (Test-Path $VdiPath)) { throw "VDI not found: $VdiPath" }
    $info = Invoke-VBoxManage -Arguments @("showvminfo", $Name, "--machinereadable")
    $sataPattern = 'SATA-0-0="(.+)"'
    if ($info.Stdout -match $sataPattern) {
        $null = Invoke-VBoxManage -Arguments @("storageattach", $Name, "--storagectl", "SATA", "--port", "0", "--device", "0", "--type", "hdd", "--medium", "none")
    }
    $ctrlPat = 'storagecontrollername.*SATA'
    if ($info.Stdout -notmatch $ctrlPat) {
        $null = Invoke-VBoxManage -Arguments @("storagectl", $Name, "--name", "SATA", "--add", "sata", "--controller", "IntelAhci")
    }
    $resolved = (Resolve-Path $VdiPath).Path
    $r = Invoke-VBoxManage -Arguments @("storageattach", $Name, "--storagectl", "SATA", "--port", "0", "--device", "0", "--type", "hdd", "--medium", $resolved)
    if ($r.ExitCode -ne 0) { throw "Failed to attach VDI: $($r.Stderr)" }
    Write-LogInfo -Module "VBox" -Message "VDI attached: $VdiPath"
    return $VdiPath
}

function Start-TestVm {
    param(
        [Parameter(Mandatory=$true)] [string]$Name,
        [string]$Type = "headless"
    )
    $r = Invoke-VBoxManage -Arguments @("startvm", $Name, "--type", $Type) -TimeoutSeconds 60
    if ($r.ExitCode -ne 0) { throw "Failed to start VM: $($r.Stderr)" }
    Write-LogInfo -Module "VBox" -Message "VM '$Name' started ($Type)"
    return $true
}

function Stop-TestVm {
    param(
        [Parameter(Mandatory=$true)] [string]$Name,
        [string]$Mode = "acpipowerbutton"
    )
    $r = Invoke-VBoxManage -Arguments @("controlvm", $Name, $Mode)
    if ($r.ExitCode -ne 0) {
        Write-LogWarn -Module "VBox" -Message "Stop via $Mode failed, poweroff"
        $r = Invoke-VBoxManage -Arguments @("controlvm", $Name, "poweroff")
    }
    Write-LogInfo -Module "VBox" -Message "VM '$Name' stopped"
    return ($r.ExitCode -eq 0)
}

function Wait-VmStopped {
    param(
        [Parameter(Mandatory=$true)] [string]$Name,
        [int]$TimeoutSeconds = 60
    )
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        $state = Get-VmPowerState -Name $Name
        if ($state -eq "poweroff" -or $state -eq "aborted") { return $true }
        Start-Sleep -Seconds 2
    }
    Write-LogWarn -Module "VBox" -Message "Timeout waiting for VM '$Name'"
    return $false
}

function Get-VmPowerState {
    param([Parameter(Mandatory=$true)] [string]$Name)
    try {
        $r = Invoke-VBoxManage -Arguments @("showvminfo", $Name, "--machinereadable")
        if ($r.ExitCode -eq 0 -and $r.Stdout -match 'VMState="(\w+)"') { return $matches[1] }
    } catch {}
    return "unknown"
}

function Remove-TestVm {
    param(
        [Parameter(Mandatory=$true)] [string]$Name,
        [switch]$Force
    )
    $state = Get-VmPowerState -Name $Name
    if ($state -ne "poweroff" -and $state -ne "aborted") {
        if ($Force) {
            $null = Invoke-VBoxManage -Arguments @("controlvm", $Name, "poweroff")
            Start-Sleep -Seconds 2
        } else { throw "VM '$Name' is running. Use -Force." }
    }
    $r = Invoke-VBoxManage -Arguments @("unregistervm", $Name, "--delete")
    if ($r.ExitCode -ne 0) { throw "Failed to delete VM: $($r.Stderr)" }
    Write-LogInfo -Module "VBox" -Message "VM '$Name' deleted"
    return $true
}

function Get-VmSerialLog {
    param([Parameter(Mandatory=$true)] [string]$Name)
    $logPath = Join-Path $HOME "VirtualBox VMs" $Name "console.log"
    if (Test-Path $logPath) { return Get-Content $logPath -Raw }
    return $null
}

Export-ModuleMember -Function Test-VBoxManageAvailable, Invoke-VBoxManage, New-TestVm, Set-TestVmDisk, Start-TestVm, Stop-TestVm, Wait-VmStopped, Get-VmPowerState, Remove-TestVm, Get-VmSerialLog
