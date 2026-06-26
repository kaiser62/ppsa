# Configuration (M1)

The local builder reads settings from `builder.json` at the repository root.

## Sections

| Section | Key | Default | Description |
|---------|-----|---------|-------------|
| output | directory | `H:\dev\palimage` | Output directory for artifacts |
| output | artifact_size_mb | `8192` | Raw image size in MB |
| output | compression_level | `10` | zstd compression level |
| wsl | user | `artho` | WSL user for build commands |
| wsl | project_path | `/mnt/d/Dev/palworld-self-containing-server` | Project path inside WSL |
| github | repository | `kaiser62/ppsa` | GitHub repository |
| github | issue_number | `1` | Issue to watch for test reports |
| github | poll_interval_seconds | `10` | Polling interval for new comments |
| virtualbox | vm_name | `ppsa-test` | VirtualBox VM name for testing |
| virtualbox | memory_mb | `8192` | VM memory (8GB+ recommended for Palworld Steam download) |
| virtualbox | cpus | `8` | VM CPU count (4+ recommended; 2 CPUs causes RCU stalls under load) |
| logging | retention_days | `30` | Days to keep logs |
| logging | directory | `H:\dev\palimage\logs` | Log output directory |
| logging | levels | `[TRACE..SUCCESS]` | Enabled log levels |
| build | retry_count | `3` | Build retry attempts |
| build | wsl_home_build_dir | `/home/artho/build` | WSL build directory |

## Usage

```powershell
Import-Module modules\Configuration.psm1
$config = Get-Configuration
Write-Host $config.output.directory
```
