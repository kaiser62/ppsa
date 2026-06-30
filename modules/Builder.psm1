# Builder.psm1 - PPSA WSL Build Execution
# Milestone 6: Run build-live-usb.sh in WSL with per-step logging and timing.

function Invoke-WslCommand {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$Command,
        [string]$WslUser = "artho",
        [int]$TimeoutSeconds = 7200
    )
    $result = Invoke-CommandCapture -FileName "wsl" `
        -Arguments @("--user", $WslUser, "--exec", "bash", "-c", $Command) `
        -TimeoutSeconds $TimeoutSeconds
    return $result
}

function Test-WslAvailable {
    [CmdletBinding()]
    param([string]$WslUser = "artho")
    try {
        $r = Invoke-WslCommand -Command "echo WSL_OK" -WslUser $WslUser -TimeoutSeconds 10
        return ($r.ExitCode -eq 0 -and $r.Stdout -match "WSL_OK")
    } catch { return $false }
}

function Invoke-Build {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [object]$Config,
        [Parameter(Mandatory=$true)]
        [string]$Tag,
        [string]$LogDirectory,
        # ponytail: hashtable of extra env vars to inline-prefix the bash command
        # (WSL doesn't reliably inherit PowerShell process env). Used to pass
        # wireguard creds read from wireguard.local.json by the orchestrator.
        [hashtable]$ExtraEnv = @{}
    )

    $wslUser    = $Config.wsl.user
    $project    = $Config.wsl.project_path
    $wslOutDir  = $Config.build.wsl_home_build_dir
    $winOutDir  = $Config.output.directory
    $imgSize    = $Config.output.artifact_size_mb
    $compressLvl = $Config.output.compression_level
    $sudoPass   = "arthoroy"  # ponytail: hardcoded, configurable in future

    $imgFile     = "ppsa-vbox-$Tag.img"
    $vdiFile     = "ppsa-vbox-$Tag.vdi"
    $imgZstFile  = "ppsa-vbox-$Tag.img.zst"
    $shaFile     = "ppsa-vbox-$Tag.vdi.sha256"

    $imgPath     = "$wslOutDir/$imgFile"
    $vdiPath     = "$wslOutDir/$vdiFile"
    $imgZstPath  = "$wslOutDir/$imgZstFile"
    $shaPath     = "$wslOutDir/$shaFile"

    # Build inline env prefix (KEY='value' KEY2='value2' ...) for the bash command.
    # ponytail: the standard shell-quote-of-single-quote trick is end-quote,
    # backslash, single-quote, restart-quote ('\''). PS single-quoted strings
    # can't easily contain a literal '\'', so build it via [char].
    $singleQuoteEscape = [char]39 + [char]92 + [char]39 + [char]39  # 4 chars: ' \ ' '
    $envPrefix = ""
    if ($ExtraEnv -and $ExtraEnv.Count -gt 0) {
        $pairs = @()
        foreach ($k in $ExtraEnv.Keys) {
            $v = [string]$ExtraEnv[$k]
            $ev = $v -replace "'", $singleQuoteEscape
            $pairs += "$k='$ev'"
        }
        $envPrefix = ($pairs -join " ") + " "
    }

    $phases = @()

    # Phase 1: Prepare WSL build directory
    Write-LogInfo -Module "Builder" -Message "Creating WSL build directory: $wslOutDir"
    $sw = Start-Timer
    $r = Invoke-WslCommand -Command "mkdir -p $wslOutDir" -WslUser $wslUser
    $sw.Stop()
    $phases += [PSCustomObject]@{ Name = "prepare-dir"; Success = ($r.ExitCode -eq 0); ExitCode = $r.ExitCode; Duration = $sw.Elapsed; Stdout = $r.Stdout; Stderr = $r.Stderr }
    if ($r.ExitCode -ne 0) {
        Write-LogError -Module "Builder" -Message "Failed to create WSL build directory" -Command "mkdir -p $wslOutDir" -ExitCode $r.ExitCode -Location "Invoke-Build" -RecommendedAction "Check WSL disk space and permissions"
        return BuildResult -Tag $Tag -Success $false -Phases $phases
    }
    Write-LogInfo -Module "Builder" -Message "WSL directory ready ($($sw.Elapsed.TotalSeconds.ToString('F1'))s)"

    # Phase 2: Run build-live-usb.sh
    Write-LogInfo -Module "Builder" -Message "Starting build-live-usb.sh → $imgPath (${imgSize}MB)..."
    $sw = Start-Timer
    # ponytail: env vars must be set INSIDE the sudo command (sudo with env_reset
    # would strip them from the parent shell). Inline before the bash invocation.
    $buildCmd = "cd $project && echo '$sudoPass' | sudo -S ${envPrefix}bash scripts/build-live-usb.sh --output '$imgPath' --size $imgSize 2>&1"
    $r = Invoke-WslCommand -Command $buildCmd -WslUser $wslUser -TimeoutSeconds 7200
    $sw.Stop()
    $phases += [PSCustomObject]@{ Name = "build-image"; Success = ($r.ExitCode -eq 0); ExitCode = $r.ExitCode; Duration = $sw.Elapsed; Stdout = $r.Stdout; Stderr = $r.Stderr }
    if ($r.ExitCode -ne 0) {
        Write-LogError -Module "Builder" -Message "Build-live-usb.sh failed" -Command "build-live-usb.sh" -ExitCode $r.ExitCode -Location "Invoke-Build" -RecommendedAction "Check WSL build output above"
        return BuildResult -Tag $Tag -Success $false -Phases $phases
    }
    Write-LogSuccess -Module "Builder" -Message "Image built ($($sw.Elapsed.TotalSeconds.ToString('F1'))s)"

    # Phase 3: zstd compress
    Write-LogInfo -Module "Builder" -Message "Compressing with zstd -$compressLvl..."
    $sw = Start-Timer
    $r = Invoke-WslCommand -Command "zstd -$compressLvl --no-progress '$imgPath' -o '$imgZstPath'" -WslUser $wslUser -TimeoutSeconds 3600
    $sw.Stop()
    $phases += [PSCustomObject]@{ Name = "compress"; Success = ($r.ExitCode -eq 0); ExitCode = $r.ExitCode; Duration = $sw.Elapsed; Stdout = $r.Stdout; Stderr = $r.Stderr }
    if ($r.ExitCode -ne 0) {
        Write-LogError -Module "Builder" -Message "zstd compression failed" -ExitCode $r.ExitCode
        return BuildResult -Tag $Tag -Success $false -Phases $phases
    }
    Write-LogInfo -Module "Builder" -Message "Compressed ($($sw.Elapsed.TotalSeconds.ToString('F1'))s)"

    # Phase 4: Convert to VDI
    Write-LogInfo -Module "Builder" -Message "Converting raw → VDI..."
    $sw = Start-Timer
    $vboxConvertCmd = @"
VBoxManagePath=\$(which VBoxManage 2>/dev/null)
if [ -x "\$VBoxManagePath" ]; then
    "\$VBoxManagePath" convertfromraw '$imgPath' '$vdiPath' --format VDI
else
    qemu-img convert -f raw -O vdi '$imgPath' '$vdiPath'
fi
"@
    $r = Invoke-WslCommand -Command $vboxConvertCmd -WslUser $wslUser -TimeoutSeconds 3600
    $sw.Stop()
    $phases += [PSCustomObject]@{ Name = "convert-vdi"; Success = ($r.ExitCode -eq 0); ExitCode = $r.ExitCode; Duration = $sw.Elapsed; Stdout = $r.Stdout; Stderr = $r.Stderr }
    if ($r.ExitCode -ne 0) {
        Write-LogError -Module "Builder" -Message "VDI conversion failed" -ExitCode $r.ExitCode
        return BuildResult -Tag $Tag -Success $false -Phases $phases
    }
    Write-LogInfo -Module "Builder" -Message "VDI ready ($($sw.Elapsed.TotalSeconds.ToString('F1'))s)"

    # Phase 5: SHA256
    Write-LogInfo -Module "Builder" -Message "Generating SHA256..."
    $sw = Start-Timer
    $r = Invoke-WslCommand -Command "sha256sum '$vdiPath' > '$shaPath'" -WslUser $wslUser -TimeoutSeconds 300
    $sw.Stop()
    $phases += [PSCustomObject]@{ Name = "sha256"; Success = ($r.ExitCode -eq 0); ExitCode = $r.ExitCode; Duration = $sw.Elapsed; Stdout = $r.Stdout; Stderr = $r.Stderr }
    if ($r.ExitCode -ne 0) {
        Write-LogError -Module "Builder" -Message "SHA256 generation failed" -ExitCode $r.ExitCode
        return BuildResult -Tag $Tag -Success $false -Phases $phases
    }

    # Phase 6: Verify VDI exists and has size
    Write-LogInfo -Module "Builder" -Message "Verifying artifacts..."
    $sw = Start-Timer
    $r = Invoke-WslCommand -Command "ls -lh '$vdiPath' '$imgZstPath' '$shaPath'" -WslUser $wslUser
    $sw.Stop()
    $phases += [PSCustomObject]@{ Name = "verify"; Success = ($r.ExitCode -eq 0); ExitCode = $r.ExitCode; Duration = $sw.Elapsed; Stdout = $r.Stdout; Stderr = $r.Stderr }
    if ($r.ExitCode -ne 0) {
        Write-LogError -Module "Builder" -Message "Artifact verification failed" -ExitCode $r.ExitCode
        return BuildResult -Tag $Tag -Success $false -Phases $phases
    }

    # Phase 7: Copy to Windows output directory
    Write-LogInfo -Module "Builder" -Message "Copying artifacts to $winOutDir..."
    $sw = Start-Timer
    # WSL can access Windows paths via /mnt/<drive>
    $winPath = $winOutDir -replace '\\', '/' -replace '^([A-Z]):', '/mnt/$1'
    $copyCmd = "cp '$vdiPath' '$winPath/$vdiFile' && cp '$shaPath' '$winPath/$shaFile' && cp '$imgZstPath' '$winPath/$imgZstFile' && cp '$vdiPath' '$winPath/latest.vdi' && echo COPY_OK"
    $r = Invoke-WslCommand -Command $copyCmd -WslUser $wslUser -TimeoutSeconds 600
    $sw.Stop()
    $phases += [PSCustomObject]@{ Name = "copy-output"; Success = ($r.ExitCode -eq 0 -and $r.Stdout -match "COPY_OK"); ExitCode = $r.ExitCode; Duration = $sw.Elapsed; Stdout = $r.Stdout; Stderr = $r.Stderr }
    if ($r.ExitCode -ne 0 -or $r.Stdout -notmatch "COPY_OK") {
        Write-LogError -Module "Builder" -Message "Copy to output directory failed" -ExitCode $r.ExitCode
        return BuildResult -Tag $Tag -Success $false -Phases $phases
    }
    Write-LogSuccess -Module "Builder" -Message "Artifacts copied to $winOutDir ($($sw.Elapsed.TotalSeconds.ToString('F1'))s)"

    return BuildResult -Tag $Tag -Success $true -Phases $phases
}

function BuildResult {
    [CmdletBinding()]
    param(
        [string]$Tag,
        [bool]$Success,
        [object[]]$Phases
    )
    $totalDur = [System.TimeSpan]::Zero
    foreach ($p in $Phases) { if ($p.Duration) { $totalDur = $totalDur.Add($p.Duration) } }
    return [PSCustomObject]@{
        Tag        = $Tag
        Success    = $Success
        Timestamp  = (Get-Date).ToString("o")
        Phases     = $Phases
        TotalDuration = $totalDur
        PhaseCount = $Phases.Count
        FailedPhase = ($Phases | Where-Object { -not $_.Success } | Select-Object -First 1).Name
    }
}

Export-ModuleMember -Function Invoke-WslCommand, Test-WslAvailable, Invoke-Build, BuildResult
