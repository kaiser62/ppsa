# Configuration.psm1 - PPSA Local Builder Configuration Module
# Milestone 1: Load and validate builder.json

function Get-Configuration {
    [CmdletBinding()]
    param(
        [string]$Path = (Join-Path (Split-Path $PSScriptRoot -Parent) "builder.json")
    )

    if (-not (Test-Path $Path)) {
        throw "Configuration file not found: $Path"
    }

    try {
        $config = Get-Content $Path -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    } catch {
        throw "Failed to parse configuration file '$Path': $_"
    }

    $required = @("output", "wsl", "github", "virtualbox", "logging", "build")
    $missing = @()
    foreach ($section in $required) {
        if (-not $config.$section) { $missing += $section }
    }
    if ($missing.Count -gt 0) {
        throw "Missing required configuration sections: $($missing -join ', ')"
    }

    return $config
}

Export-ModuleMember -Function Get-Configuration
