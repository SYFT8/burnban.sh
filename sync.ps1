param([switch]$Uninstall, [switch]$NoStart, [switch]$SkipEnroll)

$ErrorActionPreference = "Stop"
$AccountToken = $null
$SecureToken = $null
$Pointer = [IntPtr]::Zero
$PreviousToken = $null
$PreviousUrl = $null
$Temp = $null

try {

function Normalize-SyncVersion([string]$Value) {
    if ([string]::IsNullOrWhiteSpace($Value)) {
        throw "BURNBAN_SYNC_VERSION must be a release version such as v0.2.0"
    }
    $Normalized = if ($Value.StartsWith("v", [StringComparison]::Ordinal)) { $Value.Substring(1) } else { $Value }
    if ($Normalized -cnotmatch '^[0-9]+\.[0-9]+\.[0-9]+(?:[-+][0-9A-Za-z.-]+)?$') {
        throw "BURNBAN_SYNC_VERSION must be a release version such as v0.2.0"
    }
    return $Normalized
}

$VersionInput = if ($env:BURNBAN_SYNC_VERSION) { $env:BURNBAN_SYNC_VERSION } else { "v0.2.0" }
$BaseUrl = if ($env:BURNBAN_SYNC_DOWNLOAD_BASE_URL) {
    $env:BURNBAN_SYNC_DOWNLOAD_BASE_URL
} else {
    ""
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
$TaskName = "Burnban Sync"
$LegacyTaskName = "Burnban Personal Sync"
$NoStart = $NoStart -or $env:BURNBAN_SYNC_NO_START -eq "1"
$SkipEnroll = $SkipEnroll -or $env:BURNBAN_SYNC_SKIP_ENROLL -eq "1"

function Get-SyncBinaryVersion([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    try {
        $Output = @(& $Path --version 2>$null)
        if ($LASTEXITCODE -ne 0 -or $Output.Count -ne 1) { return $null }
        $Line = [string]$Output[0]
        if ($Line -cnotmatch '^burnban-sync ([^\s]+)$') { return $null }
        $ReportedVersion = $Matches[1]
        try { return Normalize-SyncVersion $ReportedVersion } catch { return $null }
    } catch { return $null }
}

function Test-SyncBinary([string]$Path, [string]$ExpectedVersion = "") {
    $FoundVersion = Get-SyncBinaryVersion $Path
    if ([string]::IsNullOrEmpty($FoundVersion)) { return $false }
    return [string]::IsNullOrEmpty($ExpectedVersion) -or $FoundVersion -ceq $ExpectedVersion
}

function Remove-SyncTask {
    foreach ($Name in @($TaskName, $LegacyTaskName)) {
        $Task = Get-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue
        if ($null -ne $Task) {
            if ($Task.Description -ne "Burnban installer managed service") {
                throw "Refusing to remove an unrecognized scheduled task: $Name"
            }
            Stop-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue
            Unregister-ScheduledTask -TaskName $Name -Confirm:$false
        }
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

$RequestedVersion = Normalize-SyncVersion $VersionInput
$Version = "v$RequestedVersion"
$AllowTestRemoteBaseUrl = $false
if (-not [string]::IsNullOrEmpty($env:BURNBAN_SYNC_TEST_ALLOW_REMOTE_BASE_URL)) {
    if (-not [bool]::TryParse($env:BURNBAN_SYNC_TEST_ALLOW_REMOTE_BASE_URL, [ref]$AllowTestRemoteBaseUrl)) {
        throw "BURNBAN_SYNC_TEST_ALLOW_REMOTE_BASE_URL must be true or false"
    }
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
    $AccountToken = $env:BURNBAN_SYNC_ACCOUNT_TOKEN
    $LocalRelease = $BaseUrl -and (Test-Path -LiteralPath $BaseUrl -PathType Container)
    $Product = "Paid Sync"
    if (-not $LocalRelease) {
        if (-not $AccountToken) {
            $SecureToken = Read-Host "Paste the pst_ Personal or tst_ Team management token" -AsSecureString
            $Pointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($SecureToken)
            try {
                $AccountToken = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($Pointer)
            } finally {
                [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($Pointer)
                $Pointer = [IntPtr]::Zero
                $SecureToken.Dispose()
                $SecureToken = $null
            }
        }
        if ($AccountToken -match '^pst_[A-Za-z0-9_-]{16,}$') {
            $Product = "Personal Sync"
            $ReleaseProduct = "personal"
        } elseif ($AccountToken -match '^tst_[A-Za-z0-9_-]{16,}$') {
            $Product = "Team Sync"
            $ReleaseProduct = "team"
        } else {
            throw "A valid pst_ Personal or tst_ Team management token is required"
        }
        $ProductionBaseUrl = "https://sync.burnban.dev/api/v1/$ReleaseProduct/releases/$Version"
        if (-not $BaseUrl) {
            $BaseUrl = $ProductionBaseUrl
        } elseif (-not $AllowTestRemoteBaseUrl -and
                  -not [string]::Equals($BaseUrl, $ProductionBaseUrl, [StringComparison]::Ordinal)) {
            throw "Refusing to send a paid token to a non-production artifact URL; only tests may set BURNBAN_SYNC_TEST_ALLOW_REMOTE_BASE_URL=true"
        }
    }

    function Get-SyncArtifact([string]$Name, [string]$Destination) {
        if (Test-Path -LiteralPath $BaseUrl -PathType Container) {
            Copy-Item -LiteralPath (Join-Path $BaseUrl $Name) -Destination $Destination
            return
        }
        $Uri = [Uri]($BaseUrl.TrimEnd('/') + "/" + $Name)
        if ($Uri.Scheme -ne "https") { throw "Remote release downloads must use HTTPS: $Uri" }
        $Headers = @{ Authorization = "Bearer $AccountToken" }
        $Response = Invoke-WebRequest -UseBasicParsing -Uri $Uri -Headers $Headers -MaximumRedirection 0 -OutFile $Destination -PassThru
        # Windows PowerShell exposes ResponseUri; PowerShell 7 exposes the final
        # RequestUri. Validate the redirect destination as well as the initial URL.
        $FinalUri = $null
        if ($null -ne $Response.BaseResponse.ResponseUri) {
            $FinalUri = [Uri]$Response.BaseResponse.ResponseUri
        } elseif ($null -ne $Response.BaseResponse.RequestMessage) {
            $FinalUri = [Uri]$Response.BaseResponse.RequestMessage.RequestUri
        }
        if ($null -eq $FinalUri -or $FinalUri.Scheme -ne "https" -or $FinalUri.AbsoluteUri -ne $Uri.AbsoluteUri) {
            Remove-Item -LiteralPath $Destination -Force -ErrorAction SilentlyContinue
            throw "Remote release response changed the authenticated download URL: $FinalUri"
        }
    }

    Write-Host "Downloading burnban-sync $Version for windows/$Arch..."
    $Zip = Join-Path $Temp $Archive
    $Checksums = Join-Path $Temp "checksums.txt"
    try {
        Get-SyncArtifact "checksums.txt" $Checksums
    } catch {
        throw "The paid account could not download burnban-sync release $Version. $($_.Exception.Message)"
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
    if (-not (Test-SyncBinary $Candidate $RequestedVersion)) {
        throw "Downloaded executable is not the requested release $Version"
    }

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
        if (-not (Test-SyncBinary $Binary $RequestedVersion)) {
            throw "Installed executable is not the requested release $Version"
        }
        Remove-Item -LiteralPath $Backup -Force -ErrorAction SilentlyContinue
    } catch {
        Remove-Item -LiteralPath $Binary -Force -ErrorAction SilentlyContinue
        if (Test-Path -LiteralPath $Backup) { Move-Item -LiteralPath $Backup -Destination $Binary }
        Remove-Item -LiteralPath $Stage -Force -ErrorAction SilentlyContinue
        throw
    }

    if (-not $SkipEnroll) {
        if ($AccountToken -or -not (Test-Path -LiteralPath $StatePath)) {
            $Ledger = if ($env:BURNBAN_DB) { $env:BURNBAN_DB } else { Join-Path ([Environment]::GetFolderPath("UserProfile")) ".burnban\burnban.db" }
            if (-not (Test-Path -LiteralPath $Ledger -PathType Leaf)) {
                throw "Initialize the free meter first with: burnban setup --if-needed --no-launch"
            }
            $PreviousUrl = $env:BURNBAN_SYNC_URL
            try {
                $env:BURNBAN_SYNC_URL = $ServerUrl
                if ($AccountToken) {
                    # Verify every token-authenticated install or upgrade before
                    # registering the token-free supervisor.
                    $env:BURNBAN_SYNC_ACCOUNT_TOKEN = $AccountToken
                    & $Binary --once
                } else {
                    $env:BURNBAN_SYNC_ACCOUNT_TOKEN = $null
                    & $Binary --enroll
                }
                if ($LASTEXITCODE -ne 0) { throw "Paid Sync enrollment failed" }
            } finally {
                $env:BURNBAN_SYNC_URL = $PreviousUrl
                $env:BURNBAN_SYNC_ACCOUNT_TOKEN = $null
                $PreviousUrl = $null
            }
        }
    }

    # Scheduled processes must never see the one-time management credential.
    $env:BURNBAN_SYNC_ACCOUNT_TOKEN = $null
    $AccountToken = $null

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
        Write-Host "$Product is enrolled and supervised for this user."
    } else {
        Write-Host "Enrollment was skipped; the scheduled task will remain stopped until state exists."
    }
} finally {
    if ($Pointer -ne [IntPtr]::Zero) {
        [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($Pointer)
        $Pointer = [IntPtr]::Zero
    }
    if ($null -ne $SecureToken) {
        $SecureToken.Dispose()
        $SecureToken = $null
    }
    # `irm ... | iex` evaluates in the caller's session. Clear every plaintext
    # copy and the one-time environment credential on success and on failure.
    $env:BURNBAN_SYNC_ACCOUNT_TOKEN = $null
    $AccountToken = $null
    $PreviousToken = $null
    $PreviousUrl = $null
    if (-not [string]::IsNullOrEmpty($Temp)) {
        Remove-Item -LiteralPath $Temp -Recurse -Force -ErrorAction SilentlyContinue
    }
}
