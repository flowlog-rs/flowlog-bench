# =============================================================================
# tools/env/env.ps1 — one-time Windows bootstrap.
# =============================================================================
#
# Per AGENTS.md (lines 274-276): bench env is heavier than test env. This
# installs souffle, duckdb, GNU time (via msys/git-bash), rustup, python.
#
# Run elevated:
#   PowerShell (Admin) > Set-ExecutionPolicy -Scope Process Bypass; .\tools\env\env.ps1
#
# Idempotent: choco install / rustup install no-op if already present.
# =============================================================================

$ErrorActionPreference = 'Stop'

function Log($m)  { Write-Host "[env]  $m" -ForegroundColor Cyan }
function OK($m)   { Write-Host "[ok]   $m" -ForegroundColor Green }
function Warn($m) { Write-Host "[warn] $m" -ForegroundColor Yellow }
function Die($m)  { Write-Host "[ERROR] $m" -ForegroundColor Red; exit 1 }

# 1. Chocolatey (package manager).
if (-not (Get-Command choco -ErrorAction SilentlyContinue)) {
    Log "installing chocolatey ..."
    Set-ExecutionPolicy Bypass -Scope Process -Force
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.ServicePointManager]::SecurityProtocol -bor 3072
    iex ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
} else {
    OK "chocolatey already installed"
}

# 2. Rust toolchain.
if (-not (Get-Command rustup -ErrorAction SilentlyContinue)) {
    Log "installing rustup-init via choco ..."
    choco install -y rustup.install
    & "$env:USERPROFILE\.cargo\bin\rustup.exe" default stable
} else {
    OK "rustup already installed"
}

# 3. Bench deps via choco. souffle is not packaged for Windows; warn.
Log "installing core bench deps via choco ..."
choco install -y python3 wget unzip 7zip git protoc jq
choco install -y duckdb.cli 2>$null
if ($LASTEXITCODE -ne 0) {
    Warn "duckdb.cli not in choco repos; download from https://duckdb.org/docs/installation/"
}

Warn "Soufflé does not have an official Windows build."
Warn "  Recommended: run cross_engine.sh from WSL2 (Linux env applies)."

OK "windows env bootstrap complete (run from a fresh shell to pick up PATH changes)"
