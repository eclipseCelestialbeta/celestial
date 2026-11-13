# Load Windows DPAPI
if ($PSVersionTable.PSEdition -eq 'Core') {
    Add-Type -AssemblyName System.Security.Cryptography.ProtectedData
} else {
    Add-Type -AssemblyName System.Security
}
# CELESTIAL Ã¢â‚¬â€ PUBLIC BOOTSTRAP (Windows PowerShell 5.1+)
# Publishes only the login/download logic. The private release is a signed/hashed ZIP.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# Update this value after deploying the Cloudflare Worker.
$ApiBase = 'https://celestial-gateway.celestialeclipse.workers.dev'
# Optional: pinned code-signing certificate thumbprint. Leave blank until signed.
$TrustedSignerThumbprint = ''
# Set to $true only when your own trusted application really requires elevation.
$LaunchElevated = $false

function Assert-Exe($ExePath, $ExpectedSha256, $ExpectedThumbprint) {
    if (-not (Test-Path -LiteralPath $ExePath -PathType Leaf)) { throw 'Release is missing Celestial.exe.' }
    $h = (Get-FileHash -LiteralPath $ExePath -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($h -ne $ExpectedSha256.ToLowerInvariant()) { throw 'Executable hash mismatch.' }
    if ($ExpectedThumbprint) {
        $sig = Get-AuthenticodeSignature -LiteralPath $ExePath
        if ($sig.Status -ne 'Valid' -or -not $sig.SignerCertificate -or
            $sig.SignerCertificate.Thumbprint.ToUpperInvariant() -ne $ExpectedThumbprint.ToUpperInvariant()) {
            throw 'Code-signing publisher verification failed.'
        }
    }
}

try {
    if ($ApiBase -match 'REPLACE_WITH_' -or $ApiBase -notmatch '^https://') {
        throw 'Configure $ApiBase with the HTTPS URL of your deployed Worker first.'
    }
    if ($TrustedSignerThumbprint -and $TrustedSignerThumbprint -notmatch '^[A-Fa-f0-9]{40,64}$') {
        throw 'Invalid signing-certificate thumbprint configuration.'
    }
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $appDir = Join-Path $env:LOCALAPPDATA 'CelestialLauncher'
    [IO.Directory]::CreateDirectory($appDir) | Out-Null

    # Random installation ID encrypted with Windows DPAPI, never a raw hardware fingerprint.
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
    $licenseKey = (Read-Host 'License key').Trim()
    if ([string]::IsNullOrWhiteSpace($licenseKey)) { throw 'License key is required.' }
    $payload = @{ key = $licenseKey; deviceHash = $deviceHash } | ConvertTo-Json -Compress
    $licenseKey = $null
    Write-Host '[*] Checking license...' -ForegroundColor Cyan
    $session = Invoke-RestMethod -Uri "$ApiBase/v1/login" -Method POST `
        -Body $payload -ContentType 'application/json' -TimeoutSec 30
    if ($session.accessToken -notmatch '^[A-Fa-f0-9]{64}$' -or
        $session.sha256 -notmatch '^[A-Fa-f0-9]{64}$' -or
        $session.exeSha256 -notmatch '^[A-Fa-f0-9]{64}$') {
        throw 'Server returned an invalid session or manifest.'
    }

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
        # Reject unexpected or missing release entries. No source, BAT or scripts are needed.
        $entries = @(Get-ChildItem -LiteralPath $staging -Recurse -File)
        $allowed = @('Celestial.exe', 'celestial_preview_black.png', 'celestial_preview_white.png')
        if ($entries.Count -ne 3 -or @($entries | Where-Object {
            $_.Name -cnotin $allowed -or $_.DirectoryName -ne $staging
        }).Count -gt 0) {
            throw 'Unexpected files in release package.'
        }
        Assert-Exe (Join-Path $staging 'Celestial.exe') $session.exeSha256 $TrustedSignerThumbprint
        if (-not (Test-Path -LiteralPath $releaseDir)) {
            [IO.Directory]::Move($staging, $releaseDir)
        } else {
            # Existing release may be running: leave it untouched, but verify it before use.
            Assert-Exe (Join-Path $releaseDir 'Celestial.exe') $session.exeSha256 $TrustedSignerThumbprint
        }
    } finally {
        if (Test-Path -LiteralPath $zipPath) {
            Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
        }
        if (Test-Path -LiteralPath $staging) {
            Remove-Item -LiteralPath $staging -Force -Recurse -ErrorAction SilentlyContinue
        }
    }

    # Existing UI looks for these optional decorative PNGs in %TEMP%.
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
    Write-Host "[+] Release $($session.version) verified. Starting..." -ForegroundColor Green
    $binaryPath = Join-Path $releaseDir 'Celestial.exe'
    if ($LaunchElevated) {
        # A normal Windows UAC confirmation is displayed; elevation is never silent.
        Start-Process -FilePath $binaryPath -WorkingDirectory $releaseDir -Verb RunAs
    } else {
        Start-Process -FilePath $binaryPath -WorkingDirectory $releaseDir
    }
} catch {
    Write-Host ('[ERROR] ' + $_.Exception.Message) -ForegroundColor Red
    throw
}
