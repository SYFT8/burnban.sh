param([switch]$Uninstall, [switch]$NoStart, [switch]$SkipEnroll)

$ErrorActionPreference = "Stop"
$Repo = "SYFT8/burnban.dev"
$Version = if ($env:BURNBAN_SYNC_VERSION) { $env:BURNBAN_SYNC_VERSION } else { "v0.1.0" }
$BaseUrl = if ($env:BURNBAN_SYNC_DOWNLOAD_BASE_URL) {
    $env:BURNBAN_SYNC_DOWNLOAD_BASE_URL
} else {
    "https://github.com/$Repo/releases/download/burnban-sync-$Version"
}
$InstallDir = if ($env:BURNBAN_SYNC_INSTALL_DIR) {
    $env:BURNBAN_SYNC_INSTALL_DIR
} else {
    Join-Path $env:LOCALAPPDATA "Burnban\bin"
}
$Binary = Join-Path $InstallDir "burnban-sync.exe"
$StatePath = if ($env:BURNBAN_SYNC_STATE) {
    $env:BURNBAN_SYNC_STATE
} else {
    Join-Path ([Environment]::GetFolderPath("UserProfile")) ".burnban\personal-sync.json"
}
$ServerUrl = if ($env:BURNBAN_SYNC_URL) { $env:BURNBAN_SYNC_URL } else { "https://sync.burnban.dev" }
$TaskName = "Burnban Personal Sync"
$NoStart = $NoStart -or $env:BURNBAN_SYNC_NO_START -eq "1"
$SkipEnroll = $SkipEnroll -or $env:BURNBAN_SYNC_SKIP_ENROLL -eq "1"

function Test-SyncBinary([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    try {
        $Output = & $Path --version 2>$null
        return ($LASTEXITCODE -eq 0 -and "$Output" -match '^burnban-sync\s')
    } catch { return $false }
}

function Remove-SyncTask {
    $Task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    if ($null -ne $Task) {
        if ($Task.Description -ne "Burnban installer managed service") {
            throw "Refusing to remove an unrecognized scheduled task: $TaskName"
        }
        Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    }
}

if ($Uninstall -or $env:BURNBAN_SYNC_UNINSTALL -eq "1") {
    Remove-SyncTask
    if (Test-Path -LiteralPath $Binary) {
        if (-not (Test-SyncBinary $Binary)) {
            throw "Refusing to remove a file that is not burnban-sync: $Binary"
        }
        Remove-Item -LiteralPath $Binary -Force
    }
    Write-Host "burnban-sync removed; enrollment state retained at $StatePath"
    exit 0
}

$Architecture = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
switch ($Architecture.ToUpperInvariant()) {
    "AMD64" { $Arch = "amd64" }
    "ARM64" { $Arch = "arm64" }
    default { throw "Unsupported Windows architecture: $Architecture" }
}
$Archive = "burnban-sync_windows_$Arch.zip"
$Temp = Join-Path ([IO.Path]::GetTempPath()) ("burnban-sync-install-" + [Guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $Temp | Out-Null

function Get-SyncArtifact([string]$Name, [string]$Destination) {
    if (Test-Path -LiteralPath $BaseUrl -PathType Container) {
        Copy-Item -LiteralPath (Join-Path $BaseUrl $Name) -Destination $Destination
        return
    }
    $Uri = [Uri]($BaseUrl.TrimEnd('/') + "/" + $Name)
    if ($Uri.Scheme -ne "https") { throw "Remote release downloads must use HTTPS: $Uri" }
    Invoke-WebRequest -UseBasicParsing -Uri $Uri -OutFile $Destination
}

try {
    Write-Host "Downloading burnban-sync $Version for windows/$Arch..."
    $Zip = Join-Path $Temp $Archive
    $Checksums = Join-Path $Temp "checksums.txt"
    try {
        Get-SyncArtifact "checksums.txt" $Checksums
    } catch {
        throw "burnban-sync release $Version is not buyer-accessible yet; retry after the published launch. $($_.Exception.Message)"
    }
    Get-SyncArtifact $Archive $Zip
    $ChecksumLine = Get-Content $Checksums | Where-Object { $_ -match ("\s" + [Regex]::Escape($Archive) + "$") } | Select-Object -First 1
    if (-not $ChecksumLine) { throw "$Archive is missing from checksums.txt" }
    $Expected = ($ChecksumLine -split '\s+')[0].ToLowerInvariant()
    $Actual = (Get-FileHash -Algorithm SHA256 $Zip).Hash.ToLowerInvariant()
    if ($Actual -ne $Expected) { throw "Checksum verification failed for $Archive" }

    $Extracted = Join-Path $Temp "extract"
    Expand-Archive -LiteralPath $Zip -DestinationPath $Extracted
    $Candidate = Join-Path $Extracted "burnban-sync.exe"
    if (-not (Test-SyncBinary $Candidate)) { throw "Downloaded executable failed validation" }

    Remove-SyncTask
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
    $Stage = Join-Path $InstallDir (".burnban-sync-" + [Guid]::NewGuid().ToString("N") + ".exe")
    $Backup = Join-Path $InstallDir (".burnban-sync-backup-" + [Guid]::NewGuid().ToString("N") + ".exe")
    Copy-Item -LiteralPath $Candidate -Destination $Stage
    if (Test-Path -LiteralPath $Binary) {
        if (-not (Test-SyncBinary $Binary)) { throw "Refusing to replace a file that is not burnban-sync: $Binary" }
        Move-Item -LiteralPath $Binary -Destination $Backup
    }
    try {
        Move-Item -LiteralPath $Stage -Destination $Binary
        if (-not (Test-SyncBinary $Binary)) { throw "Installed executable failed validation" }
        Remove-Item -LiteralPath $Backup -Force -ErrorAction SilentlyContinue
    } catch {
        Remove-Item -LiteralPath $Binary -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $Backup) { Move-Item -LiteralPath $Backup -Destination $Binary }
        Remove-Item -LiteralPath $Stage -Force -ErrorAction SilentlyContinue
        throw
    }

    if (-not (Test-Path -LiteralPath $StatePath) -and -not $SkipEnroll) {
        $Ledger = if ($env:BURNBAN_DB) { $env:BURNBAN_DB } else { Join-Path ([Environment]::GetFolderPath("UserProfile")) ".burnban\burnban.db" }
        if (-not (Test-Path -LiteralPath $Ledger -PathType Leaf)) {
            throw "Initialize the free meter first with: burnban setup --if-needed --no-launch"
        }
        $PreviousUrl = $env:BURNBAN_SYNC_URL
        try {
            $env:BURNBAN_SYNC_URL = $ServerUrl
            & $Binary --enroll
            if ($LASTEXITCODE -ne 0) { throw "Personal Sync enrollment failed" }
        } finally {
            $env:BURNBAN_SYNC_URL = $PreviousUrl
        }
    }

    $UserId = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    $Action = New-ScheduledTaskAction -Execute $Binary
    $Trigger = New-ScheduledTaskTrigger -AtLogOn -User $UserId
    $Settings = New-ScheduledTaskSettingsSet -RestartCount 99 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero)
    $Principal = New-ScheduledTaskPrincipal -UserId $UserId -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName $TaskName -Action $Action -Trigger $Trigger -Settings $Settings `
        -Principal $Principal -Description "Burnban installer managed service" -Force | Out-Null
    if (-not $NoStart -and (Test-Path -LiteralPath $StatePath)) {
        Start-ScheduledTask -TaskName $TaskName
    }

    Write-Host "burnban-sync installed: $Binary" -ForegroundColor Green
    if (Test-Path -LiteralPath $StatePath) {
        Write-Host "Personal Sync is enrolled and supervised for this user."
    } else {
        Write-Host "Enrollment was skipped; the scheduled task will remain stopped until state exists."
    }
} finally {
    Remove-Item -LiteralPath $Temp -Recurse -Force -ErrorAction SilentlyContinue
}
