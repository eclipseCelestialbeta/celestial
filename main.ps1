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
# Keep the PowerShell console open. Ctrl+C stops the monitor. No hidden service or persistence.
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
    # Retain the validated license in this PowerShell process only while the monitor runs.
    # Each new game session is revalidat
