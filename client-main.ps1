param(
    [switch]$EnrollOnly,
    [switch]$TrayMode
)

# Load DPAPI on Windows PowerShell 5.1 and PowerShell 7+.
if ($PSVersionTable.PSEdition -eq 'Core') {
    Add-Type -AssemblyName System.Security.Cryptography.ProtectedData
} else {
    Add-Type -AssemblyName System.Security
}
# CELESTIAL - PUBLIC BOOTSTRAP (Windows PowerShell 5.1+)
# Version: launcher with optional DPAPI-protected, remembered license key.
# The server still validates the license on EVERY launch.
# Lifecycle mode: validate before Roblox starts, then launch a fresh panel for each new Roblox session.
# Foreground mode uses Ctrl+C; tray mode is controlled from the Windows notification area.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$ApiBase = 'https://celestial-gateway.celestialeclipse.workers.dev'
$TrustedSignerThumbprint = ''
$LaunchElevated = $false

function Assert-Exe($ExePath, $ExpectedSha256, $ExpectedThumbprint) {
    if (-not (Test-Path -LiteralPath $ExePath -PathType Leaf)) {
        throw 'Release is missing Nova Application.exe.'
    }
    $h = (Get-FileHash -LiteralPath $ExePath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($h -ne $ExpectedSha256.ToLowerInvariant()) {
        throw 'Executable hash mismatch.'
    }
    if ($ExpectedThumbprint) {
        $sig = Get-AuthenticodeSignature -LiteralPath $ExePath
        if ($sig.Status -ne 'Valid' -or -not $sig.SignerCertificate -or
            $sig.SignerCertificate.Thumbprint.ToUpperInvariant() -ne $ExpectedThumbprint.ToUpperInvariant()) {
            throw 'Code-signing publisher verification failed.'
        }
    }
}

function Save-ProtectedLicense([string] $File, [string] $Key) {
    $bytes = [Text.Encoding]::UTF8.GetBytes($Key)
    try {
        $encrypted = [Security.Cryptography.ProtectedData]::Protect(
            $bytes, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
        [IO.File]::WriteAllBytes($File, $encrypted)
    } finally {
        [Array]::Clear($bytes, 0, $bytes.Length)
    }
}

function Read-ProtectedLicense([string] $File) {
    if (-not (Test-Path -LiteralPath $File -PathType Leaf)) { return '' }
    $plain = $null
    try {
        $plain = [Security.Cryptography.ProtectedData]::Unprotect(
            [IO.File]::ReadAllBytes($File), $null,
            [Security.Cryptography.DataProtectionScope]::CurrentUser)
        return [Text.Encoding]::UTF8.GetString($plain).Trim()
    } catch {
        Write-Warning 'Saved license could not be read. It will be requested again.'
        return ''
    } finally {
        if ($null -ne $plain) { [Array]::Clear($plain, 0, $plain.Length) }
    }
}

function Invoke-LicenseLogin([string] $Key, [string] $DeviceHash, [string] $Base) {
    $body = @{ key = $Key; deviceHash = $DeviceHash } | ConvertTo-Json -Compress
    return Invoke-RestMethod -Uri "$Base/v1/login" -Method POST `
        -Body $body -ContentType 'application/json' -TimeoutSec 30
}

# The EXE needs a valid Roblox top-level window during WinMain initialization.
function Get-RobloxSession {
    $games = @(Get-Process -Name 'RobloxPlayerBeta' -ErrorAction SilentlyContinue |
        Where-Object { $_.MainWindowHandle -ne [IntPtr]::Zero })
    if ($games.Count -eq 0) { return $null }
    return ($games | Select-Object -First 1)
}

function Stop-OwnedPanel($Process) {
    if ($null -eq $Process) { return }
    try {
        $Process.Refresh()
        if (-not $Process.HasExited) {
            Stop-Process -Id $Process.Id -Force -ErrorAction SilentlyContinue
            try { $Process.WaitForExit(4000) | Out-Null } catch { }
        }
    } catch { }
}

try {
    if ($ApiBase -notmatch '^https://') { throw 'API URL must use HTTPS.' }
    if ($TrustedSignerThumbprint -and $TrustedSignerThumbprint -notmatch '^[A-Fa-f0-9]{40,64}$') {
        throw 'Invalid signing-certificate thumbprint configuration.'
    }
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $appDir = Join-Path $env:LOCALAPPDATA 'CelestialLauncher'
    [IO.Directory]::CreateDirectory($appDir) | Out-Null
    $licenseFile = Join-Path $appDir 'license.dat'

    # Random installation ID, protected with Windows DPAPI.
    $deviceFile = Join-Path $appDir 'device.dat'
    if (Test-Path -LiteralPath $deviceFile) {
        $deviceBytes = [Security.Cryptography.ProtectedData]::Unprotect(
            [IO.File]::ReadAllBytes($deviceFile), $null,
            [Security.Cryptography.DataProtectionScope]::CurrentUser)
    } else {
        $deviceBytes = New-Object byte[] 32
        $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
        try { $rng.GetBytes($deviceBytes) } finally { $rng.Dispose() }
        $sealed = [Security.Cryptography.ProtectedData]::Protect(
            $deviceBytes, $null, [Security.Cryptography.DataProtectionScope]::CurrentUser)
        [IO.File]::WriteAllBytes($deviceFile, $sealed)
    }
    $sha = [Security.Cryptography.SHA256]::Create()
    try {
        $deviceHash = ([BitConverter]::ToString($sha.ComputeHash($deviceBytes))).Replace('-', '').ToLowerInvariant()
    } finally { $sha.Dispose() }
    [Array]::Clear($deviceBytes, 0, $deviceBytes.Length)

    Write-Host ''
    Write-Host '  CELESTIAL | PRIVATE RELEASE' -ForegroundColor Magenta
    Write-Host '  Licensed access + integrity verification' -ForegroundColor DarkGray
    Write-Host ''

    $licenseKey = Read-ProtectedLicense $licenseFile
    $fromSaved = -not [string]::IsNullOrWhiteSpace($licenseKey)
    if ($fromSaved) {
        Write-Host '[*] Found saved, Windows-protected license. Validating...' -ForegroundColor Cyan
    } else {
        if ($TrayMode) { throw 'No stored license is available for background login. Run the official command in a visible PowerShell window to save your key.' }
        $licenseKey = (Read-Host 'License key').Trim()
        if ([string]::IsNullOrWhiteSpace($licenseKey)) { throw 'License key is required.' }
    }

    Write-Host '[*] Checking license with server...' -ForegroundColor Cyan
    try {
        $session = Invoke-LicenseLogin $licenseKey $deviceHash $ApiBase
    } catch {
        $statusCode = 0
        try { $statusCode = [int]$_.Exception.Response.StatusCode } catch { }
        if ($fromSaved -and $statusCode -eq 403) {
            # A revoked/invalid saved key must never bypass server validation.
            Remove-Item -LiteralPath $licenseFile -Force -ErrorAction SilentlyContinue
            if ($TrayMode) { throw 'Saved license rejected by server (403). Re-run the official command visibly to enter a new key.' }
            Write-Warning 'Saved license was rejected by the server. Enter a valid license.'
            $licenseKey = (Read-Host 'License key').Trim()
            if ([string]::IsNullOrWhiteSpace($licenseKey)) { throw 'License key is required.' }
            $fromSaved = $false
            $session = Invoke-LicenseLogin $licenseKey $deviceHash $ApiBase
        } else {
            throw
        }
    }

    if ($session.accessToken -notmatch '^[A-Fa-f0-9]{64}$' -or
        $session.launchToken -notmatch '^[A-Fa-f0-9]{64}$' -or
        $session.sha256 -notmatch '^[A-Fa-f0-9]{64}$' -or
        $session.exeSha256 -notmatch '^[A-Fa-f0-9]{64}$') {
        throw 'Server returned an invalid session or manifest.'
    }
    if (-not $fromSaved) {
        $remember = (Read-Host 'Remember license on this Windows account? (Y/N)').Trim()
        if ($remember -match '^(?i:y|yes|s|sim)$') {
            Save-ProtectedLicense $licenseFile $licenseKey
            Write-Host '[+] License saved with Windows DPAPI (CurrentUser).' -ForegroundColor Green
        }
    }
    # Enrollment validates a key and optionally stores it; it never downloads or starts the panel.
    if ($EnrollOnly) {
        if (Test-Path -LiteralPath $licenseFile -PathType Leaf) {
            Write-Host '[+] License enrollment finished. Tray Mode can start.' -ForegroundColor Green
        } else {
            Write-Warning 'Tray Mode requires you to choose Y when asked to remember your license.'
        }
        $licenseKey = $null
        return
    }
    # Retain the validated license in this PowerShell process only while the monitor runs.
    # Each new game session is revalidated against Cloudflare (no bypass of revoked keys).
    $monitorKey = $licenseKey
    $licenseKey = $null

    $zipPath = Join-Path $appDir ('release-' + [Guid]::NewGuid().ToString('N') + '.zip')
    $releaseRoot = Join-Path $appDir 'releases'
    [IO.Directory]::CreateDirectory($releaseRoot) | Out-Null
    $releaseDir = Join-Path $releaseRoot $session.sha256.ToLowerInvariant()
    $staging = Join-Path $releaseRoot ('staging-' + [Guid]::NewGuid().ToString('N'))
    try {
        Write-Host '[*] Retrieving authorized release...' -ForegroundColor Cyan
        Invoke-WebRequest -Uri "$ApiBase/v1/download" -Headers @{
            Authorization = 'Bearer ' + $session.accessToken
        } -OutFile $zipPath -UseBasicParsing -TimeoutSec 180
        $zipHash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($zipHash -ne $session.sha256.ToLowerInvariant()) {
            throw 'Package integrity verification failed.'
        }
        [IO.Directory]::CreateDirectory($staging) | Out-Null
        Expand-Archive -LiteralPath $zipPath -DestinationPath $staging -Force
        $entries = @(Get-ChildItem -LiteralPath $staging -Recurse -File)
        $allowed = @('Nova Application.exe', 'celestial_preview_black.png', 'celestial_preview_white.png')
        if ($entries.Count -ne 3 -or @($entries | Where-Object {
            $_.Name -cnotin $allowed -or $_.DirectoryName -ne $staging
        }).Count -gt 0) {
            throw 'Unexpected files in release package.'
        }
        Assert-Exe (Join-Path $staging 'Nova Application.exe') $session.exeSha256 $TrustedSignerThumbprint
        if (-not (Test-Path -LiteralPath $releaseDir)) {
            [IO.Directory]::Move($staging, $releaseDir)
        } else {
            Assert-Exe (Join-Path $releaseDir 'Nova Application.exe') $session.exeSha256 $TrustedSignerThumbprint
        }
    } finally {
        if (Test-Path -LiteralPath $zipPath) {
            Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $staging) {
            Remove-Item -LiteralPath $staging -Force -Recurse -ErrorAction SilentlyContinue
        }
    }

    foreach ($avatar in @('celestial_preview_black.png', 'celestial_preview_white.png')) {
        $image = Join-Path $releaseDir $avatar
        if (Test-Path -LiteralPath $image -PathType Leaf) {
            try {
                Copy-Item -LiteralPath $image -Destination (Join-Path $env:TEMP $avatar) -Force -ErrorAction Stop
            } catch [System.IO.IOException] {
                Write-Warning "Image in use: $avatar. Keeping existing image."
            }
        }
    }
    Write-Host "[+] Release $($session.version) verified. Game-aware launcher ready." -ForegroundColor Green
    $binaryPath = Join-Path $releaseDir 'Nova Application.exe'

    # Visible, user-controlled supervisor: no Windows service, no startup task.
    # A second invocation cannot start a second watcher in the same logon session.
    $guard = [System.Threading.Mutex]::new($false, 'Local\CelestialEclipseRobloxLauncher')
    $guardOwned = $false
    $panelProc = $null
    try {
        try {
            $guardOwned = $guard.WaitOne(0, $false)
        } catch [System.Threading.AbandonedMutexException] {
            $guardOwned = $true
        }
        if (-not $guardOwned) {
            throw 'The Roblox session launcher is already running. Use its existing PowerShell window.'
        }
        if ($TrayMode) {
            Write-Host '[*] Key accepted. Waiting for Roblox (tray-controlled monitor).' -ForegroundColor Cyan
        } else {
            Write-Host '[*] Key accepted. Waiting for Roblox. Keep this PowerShell window open.' -ForegroundColor Cyan
            Write-Host '[*] F4 closes the panel while Roblox is open. Ctrl+C ends this monitor.' -ForegroundColor DarkGray
        }

        while ($true) {
            # Get-RobloxSession returns a real foreground-capable game window.
            # This avoids running the EXE before Roblox has created its window.
            $game = Get-RobloxSession
            if ($null -eq $game) {
                Start-Sleep -Milliseconds 1200
                continue
            }
            $gamePid = [int]$game.Id
            $gameWindow = $game.MainWindowHandle.ToInt64()
            Write-Host "[*] Roblox detected (PID $gamePid). Waiting for game window to stabilize..." -ForegroundColor Cyan
            Start-Sleep -Seconds 20
            $stableGame = Get-RobloxSession
            if ($null -eq $stableGame -or [int]$stableGame.Id -ne $gamePid -or
                $stableGame.MainWindowHandle.ToInt64() -ne $gameWindow) {
                continue
            }

            # Re-check the license server on EACH new Roblox game session.
            # If the server has a new release, refuse to run an outdated cached binary.
            Write-Host '[*] Revalidating license for the new game session...' -ForegroundColor Cyan
            $sessionNow = Invoke-LicenseLogin $monitorKey $deviceHash $ApiBase
            if ($sessionNow.launchToken -notmatch '^[A-Fa-f0-9]{64}$' -or
                $sessionNow.sha256 -notmatch '^[A-Fa-f0-9]{64}$' -or
                $sessionNow.exeSha256 -notmatch '^[A-Fa-f0-9]{64}$') {
                throw 'Server returned an invalid release manifest.'
            }
            if ($sessionNow.sha256.ToLowerInvariant() -ne $session.sha256.ToLowerInvariant() -or
                $sessionNow.exeSha256.ToLowerInvariant() -ne $session.exeSha256.ToLowerInvariant()) {
                throw 'A newer release is available. Restart the launcher to download and verify it.'
            }
            Assert-Exe $binaryPath $session.exeSha256 $TrustedSignerThumbprint

            $stableGame = Get-RobloxSession
            if ($null -eq $stableGame -or [int]$stableGame.Id -ne $gamePid -or
                $stableGame.MainWindowHandle.ToInt64() -ne $gameWindow) {
                continue
            }

            # Never stop another unrelated process: only manage the process we start.
            $existingPanels = @(Get-Process -Name 'Nova Application' -ErrorAction SilentlyContinue)
            if ($existingPanels.Count -gt 0) {
                Write-Warning 'Nova Application.exe is already running. Close the old panel with F4; then monitoring will continue.'
                while (@(Get-Process -Name 'Nova Application' -ErrorAction SilentlyContinue).Count -gt 0) {
                    Start-Sleep -Milliseconds 1500
                }
                continue
            }

            Write-Host '[+] Roblox is ready. Launching Nova Application.exe...' -ForegroundColor Green
            # CELESTIAL_LICENSE_GATE_V104. PowerShell 5.1 inherits process env vars.
            if ($LaunchElevated) {
                throw 'License-gated launch currently requires LaunchElevated = $false.'
            }
            $previousToken = [Environment]::GetEnvironmentVariable('CELESTIAL_LAUNCH_TOKEN', 'Process')
            $previousDevice = [Environment]::GetEnvironmentVariable('CELESTIAL_DEVICE_HASH', 'Process')
            try {
                [Environment]::SetEnvironmentVariable('CELESTIAL_LAUNCH_TOKEN', $sessionNow.launchToken, 'Process')
                [Environment]::SetEnvironmentVariable('CELESTIAL_DEVICE_HASH', $deviceHash, 'Process')
                $panelProc = Start-Process -FilePath $binaryPath -WorkingDirectory $releaseDir -PassThru
            } finally {
                [Environment]::SetEnvironmentVariable('CELESTIAL_LAUNCH_TOKEN', $previousToken, 'Process')
                [Environment]::SetEnvironmentVariable('CELESTIAL_DEVICE_HASH', $previousDevice, 'Process')
            }
            $panelClosedByUser = $false
            while ($true) {
                Start-Sleep -Milliseconds 900
                try {
                    $panelProc.Refresh()
                    if ($panelProc.HasExited) {
                        $panelClosedByUser = $true
                        break
                    }
                } catch {
                    $panelClosedByUser = $true
                    break
                }
                $currentGame = Get-RobloxSession
                if ($null -eq $currentGame -or [int]$currentGame.Id -ne $gamePid -or
                    $currentGame.MainWindowHandle.ToInt64() -ne $gameWindow) {
                    break
                }
            }
            if ($panelClosedByUser) {
                Write-Host '[*] Nova Application closed while Roblox was active. Ending monitor (F4/manual exit).' -ForegroundColor Yellow
                break
            }
            Write-Host '[*] Roblox session ended. Closing the old panel and waiting for a new Roblox session...' -ForegroundColor Yellow
            Stop-OwnedPanel $panelProc
            $panelProc = $null
        }
    } finally {
        if ($null -ne $panelProc) { Stop-OwnedPanel $panelProc }
        $monitorKey = $null
        if ($guardOwned) { $guard.ReleaseMutex() }
        if ($null -ne $guard) { $guard.Dispose() }
    }
} catch {
    Write-Host ('[ERROR] ' + $_.Exception.Message) -ForegroundColor Red
    throw
}
