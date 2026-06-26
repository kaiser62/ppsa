# Builder (M6)

WSL build execution: runs `build-live-usb.sh`, compresses, converts to VDI, verifies, and copies artifacts.

## Dependencies

- **Logger.psm1** — for structured logging
- **Utils.psm1** — for `Invoke-CommandCapture`
- **WSL** with target Linux distro and user
- **Sudo access** to run `build-live-usb.sh`

## Functions

| Function | Description |
|----------|-------------|
| Invoke-WslCommand | Run a bash command in WSL, capture output |
| Test-WslAvailable | Quick check if WSL is accessible |
| Invoke-Build | Full build: prepare → build → compress → VDI → SHA256 → verify → copy |
| BuildResult | Construct a build result object with phase details |

## Build Phases

1. **prepare-dir** — mkdir in WSL
2. **build-image** — `build-live-usb.sh --output --size`
3. **compress** — `zstd -N` on raw image
4. **convert-vdi** — VBoxManage or qemu-img
5. **sha256** — checksum the VDI
6. **verify** — check files exist with `ls`
7. **copy-output** — copy artifacts to Windows output dir

## Usage

```powershell
Import-Module modules\Builder.psm1
$config = Get-Configuration
$result = Invoke-Build -Config $config -Tag "local-20260627-010000"
if ($result.Success) {
    Write-Host "Build OK in $($result.TotalDuration.TotalMinutes.ToString('F1')) min"
}
```
