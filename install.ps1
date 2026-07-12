# Launch bootstrap for the canonical MIT installer. The fetched script verifies
# release archives and checksums from:
# https://github.com/burnban/burnban/releases/latest/download/
$ErrorActionPreference = "Stop"
$InstallerUrl = "https://raw.githubusercontent.com/burnban/burnban/main/install.ps1"
$TempInstaller = Join-Path ([System.IO.Path]::GetTempPath()) ("burnban-install-{0}.ps1" -f [guid]::NewGuid())

try {
    Invoke-WebRequest -UseBasicParsing -Uri $InstallerUrl -OutFile $TempInstaller
    & $TempInstaller @args
} finally {
    Remove-Item -LiteralPath $TempInstaller -Force -ErrorAction SilentlyContinue
}
