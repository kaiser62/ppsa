# Artifacts (M7)

Verification, manifest generation, and latest-symlink management for build outputs.

## Functions

| Function | Description |
|----------|-------------|
| Test-Artifact | Verify file: exists, size ≥ minimum, SHA256 match |
| Test-VdiIntegrity | Check VDI validity (qemu-img check or header magic) |
| New-ArtifactManifest | Generate manifest.json with all artifact hashes and sizes |
| Update-LatestSymlink | Copy a VDI as `latest.vdi` with `Copy-Verified` |
| Get-ArtifactInfo | Get file info: exists, size, hash, modified time |

## Usage

```powershell
Import-Module modules\Artifacts.psm1

$check = Test-Artifact -Path "output.vdi" -MinSizeMB 100
if (-not $check.Valid) { $check.Issues }

$manifest = New-ArtifactManifest -Tag "build-001" -FilePaths @("a.vdi","b.img.zst") -OutputPath "manifest.json"

Update-LatestSymlink -SourceVdi "build-001.vdi" -OutputDir "H:\dev\palimage"
```
