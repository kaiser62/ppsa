# Artifacts.psm1 - PPSA Artifact Verification and Manifest
# Milestone 7: Verify build outputs, generate manifest, manage latest symlink.

function Test-Artifact {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$Path,
        [string]$ExpectedHash,
        [int]$MinSizeMB = 0
    )
    $issues = @()

    if (-not (Test-Path $Path)) {
        $issues += "File not found"
        return [PSCustomObject]@{ Valid = $false; Issues = $issues; SizeMB = $null; Hash = $null }
    }

    $item = Get-Item $Path
    $sizeMB = [math]::Round($item.Length / 1MB, 2)

    if ($MinSizeMB -gt 0 -and $sizeMB -lt $MinSizeMB) {
        $issues += "Size ${sizeMB}MB < minimum ${MinSizeMB}MB"
    }

    $hash = $null
    if ($ExpectedHash) {
        $actual = (Get-FileHash -Path $Path -Algorithm SHA256).Hash.ToLower()
        $expected = $ExpectedHash.ToLower()
        if ($actual -ne $expected) {
            $issues += "SHA256 mismatch: expected $expected, got $actual"
        } else {
            $hash = $actual
        }
    } else {
        $hash = (Get-FileHash -Path $Path -Algorithm SHA256).Hash
    }

    return [PSCustomObject]@{
        Valid   = ($issues.Count -eq 0)
        Issues  = $issues
        SizeMB  = $sizeMB
        Hash    = $hash
        Path    = $Path
    }
}

function Test-VdiIntegrity {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)] [string]$VdiPath)

    if (-not (Test-Path $VdiPath)) {
        return [PSCustomObject]@{ Valid = $false; Error = "VDI not found"; Details = $null }
    }

    # Try qemu-img check (more portable)
    try {
        $r = Invoke-CommandCapture -FileName "qemu-img" -Arguments @("check", $VdiPath) -TimeoutSeconds 60
        if ($r.ExitCode -eq 0) {
            return [PSCustomObject]@{ Valid = $true; Error = $null; Details = $r.Stdout.Trim() }
        }
        return [PSCustomObject]@{ Valid = $false; Error = "qemu-img check failed (exit $($r.ExitCode))"; Details = $r.Stderr.Trim() }
    } catch {
        # qemu-img not available or check failed
        # Fallback: just verify it's a valid VDI by checking header
        try {
            $fs = [System.IO.File]::OpenRead($VdiPath)
            $header = New-Object byte[] 64
            $null = $fs.Read($header, 0, 64)
            $fs.Close()
            $magic = [System.Text.Encoding]::ASCII.GetString($header[0..3])
            if ($magic -ne "<<< ") {
                return [PSCustomObject]@{ Valid = $false; Error = "Invalid VDI header magic: '$magic'"; Details = $null }
            }
            return [PSCustomObject]@{ Valid = $true; Error = $null; Details = "VDI header OK (qemu-img not available)" }
        } catch {
            return [PSCustomObject]@{ Valid = $false; Error = "Cannot read VDI: $_"; Details = $null }
        }
    }
}

function New-ArtifactManifest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$Tag,
        [string[]]$FilePaths,
        [string]$OutputPath
    )
    $entries = @()
    foreach ($fp in $FilePaths) {
        $test = Test-Artifact -Path $fp
        $entries += [PSCustomObject]@{
            FileName  = Split-Path $fp -Leaf
            FullPath  = $fp
            Exists    = (Test-Path $fp)
            SizeMB    = $test.SizeMB
            SHA256    = $test.Hash
            Valid     = $test.Valid
        }
    }
    $manifest = [PSCustomObject]@{
        Tag       = $Tag
        CreatedAt = (Get-Date).ToString("o")
        Artifacts = $entries
        TotalArtifacts = $entries.Count
        ValidArtifacts = @($entries | Where-Object { $_.Valid }).Count
    }
    if ($OutputPath) {
        $manifest | ConvertTo-Json -Depth 10 | Set-Content -Path $OutputPath -Encoding UTF8
    }
    return $manifest
}

function Update-LatestSymlink {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory=$true)]
        [string]$SourceVdi,
        [string]$OutputDir
    )
    if (-not (Test-Path $SourceVdi)) { throw "Source VDI not found: $SourceVdi" }
    if (-not $OutputDir) { $OutputDir = Split-Path $SourceVdi -Parent }

    $latestPath = Join-Path $OutputDir "latest.vdi"
    $null = Copy-Verified -Source $SourceVdi -Destination $latestPath
    Write-LogInfo -Module "Artifacts" -Message "Updated latest.vdi → $SourceVdi"
    return $latestPath
}

function Get-ArtifactInfo {
    [CmdletBinding()]
    param([Parameter(Mandatory=$true)] [string]$Path)
    if (-not (Test-Path $Path)) {
        return [PSCustomObject]@{ Exists = $false; Path = $Path; SizeMB = $null; Hash = $null }
    }
    $item = Get-Item $Path
    return [PSCustomObject]@{
        Exists  = $true
        Path    = $Path
        SizeMB  = [math]::Round($item.Length / 1MB, 2)
        SizeGB  = [math]::Round($item.Length / 1GB, 2)
        Hash    = (Get-FileHash -Path $Path -Algorithm SHA256).Hash
        Modified = $item.LastWriteTime.ToString("o")
    }
}

Export-ModuleMember -Function Test-Artifact, Test-VdiIntegrity, New-ArtifactManifest, Update-LatestSymlink, Get-ArtifactInfo
