# Smoke Testing (M10)

Boot a built VDI in VirtualBox, wait for the system to come up, run health checks and an optional WebUI probe, then shut down and persist a JSON report.

## Dependencies

- **Logger.psm1** — structured logging
- **Utils.psm1** — `Invoke-CommandCapture`, `Get-SystemInformation`
- **VirtualBox.psm1** — VM lifecycle, console log access
- **builder.json** → `smoke_test` block

## Functions

| Function | Description |
|----------|-------------|
| `Get-VmConsoleLogPath` | Resolve the VBox `console.log` path for a VM |
| `Get-VmConsoleLog` | Read the last N lines of console output |
| `Test-VmBootHealthy` | Detect kernel panic, OOM kill, VFS / init failure, failed systemd unit |
| `Wait-VmBootReady` | Poll console for `login:`, Debian banner, or systemd marker; bounded timeout |
| `Test-VmWebUiReachable` | HTTP `GET` against a configured URL (NAT port-forward expected) |
| `Invoke-SmokeTest` | Top-level: create/start VM → wait → health → optional probe → shutdown |
| `Save-SmokeTestResult` | Write `smoke-test.json` to the output directory |

## Configuration (`builder.json`)

```json
"smoke_test": {
  "boot_timeout_seconds": 600,
  "webui_timeout_seconds": 300,
  "webui_url": "http://127.0.0.1:8080",
  "webui_probe_path": "/",
  "auto_shutdown": true
}
```

- `webui_url` may be `null` to skip the probe.
- `auto_shutdown` issues `acpipowerbutton` and waits for `poweroff`; on failure, `poweroff` is forced.

## Phases recorded in the result

`create-vm`, `start-vm`, `wait-boot`, `health-check`, `webui-probe`, `shutdown`. Each phase carries `Success`, `Duration`, and any error / marker.

## Usage

```powershell
Import-Module modules\SmokeTest.psm1 -Force
$config = Get-Configuration
$result  = Invoke-SmokeTest -Config $config -VdiPath "H:\dev\palimage\ppsa-vbox-1.1.5.vdi"
Save-SmokeTestResult -Result $result -OutputDir $config.output.directory
if (-not $result.Success) { throw "Smoke test failed" }
```

## Notes

- WebUI probing requires a host→guest port forward (e.g. `VBoxManage modifyvm ppsa-test --natpf1 "webui,tcp,,8080,,8080"`). Without it the probe will fail even if the service is healthy inside the VM.
- `Wait-VmBootReady` looks for `login:`, `Debian GNU/Linux`, `Welcome to PPSA`, `cloud-init`, or `Started Daily` — any of these counts as booted.
- A failed boot does **not** delete the VDI; the console excerpt is preserved in `smoke-test.json` for triage.
