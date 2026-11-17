# SESSION WATCH - PUBLIC LAUNCHER (OPT-IN)
# Existing license authentication and Cloudflare release are preserved.
# Starts a user-controlled monitor without a notification-area icon.
# The monitor is visible in Task Manager as SessionWatch.exe and never autostarts with Windows.
# To stop it: & "$env:LOCALAPPDATA\CelestialLauncher\launcher\Parar-SessionWatch.ps1"
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$rawBase = 'https://raw.githubusercontent.com/eclipseCelestialbeta/celestial/main'
$appRoot = Join-Path $env:LOCALAPPDATA 'CelestialLauncher'
$installDir = Join-Path $appRoot 'launcher'
$licenseFile = Join-Path $appRoot 'license.dat'
$trayMutexName = 'Local\CelestialWaitModeTrayHost'

# Pinned public source hashes are refreshed whenever this launcher is published.
$expected = @{
    'client-main.ps1' = '7DDA5FB68D6DE422D6F594B0FCF22989D1BCF2A21EE217C961A25980B638D95D'
    'SessionWatch.cs' = '8CC7070C0AEEE4B92210C4ECF80657C997567BF25EF6B5E3C8AB798F5B7C83FA'
    'Instalar-SessionWatch.ps1' = '311575C07B3CDDC0ECE60130A4ED3420EE47B531BEF0E5CEFAE385D9F611A432'
    'Iniciar-SessionWatch.ps1' = 'D18F9AA134DF75F94448881496F50C896B25A7FF34BF3809FD62A330097733C6'
    'Parar-SessionWatch.ps1' = 'EB256C9F70AA52B6FFB0FC8FD8BA6C67D22A0DB0842E3B37FC0AAE7E0D101016'
    'Status-SessionWatch.ps1' = '12821E22DB5DDE905BB1D94B52B2C5FB130A0E027F18B5D20396FCCCE5ACC8B8'
}

function Test-TrayMonitorActive {
    $check = New-Object System.Threading.Mutex($false, $trayMutexName)
    $owned = $false
    try {
        try { $owned = $check.WaitOne(0, $false) }
        catch [System.Threading.AbandonedMutexException] { $owned = $true }
        if ($owned) { $check.ReleaseMutex() }
        return (-not $owned)
    } finally { $check.Dispose() }
}

function Ensure-LocalScriptPolicy {
    $policy = Get-ExecutionPolicy
    if ($policy -notin @('Restricted', 'AllSigned')) { return }
    $machine = Get-ExecutionPolicy -Scope MachinePolicy
    $user = Get-ExecutionPolicy -Scope UserPolicy
    if ($machine -ne 'Undefined' -or $user -ne 'Undefined') {
        throw "Script policy managed by administrator (MachinePolicy=$machine; UserPolicy=$user). Use an approved signed installer."
    }
    Write-Host '[!] Windows is blocking local PowerShell scripts. This change applies only to this session.' -ForegroundColor Yellow
    Write-Host 'Review the downloaded scripts before allowing them to run.'
    $answer = (Read-Host 'Allow local scripts for this session? (Y/N)').Trim()
    if ($answer -notmatch '^(?i:y|yes)$') { throw 'Cancelled. Execution policy was not changed.' }
    Set-ExecutionPolicy -Scope Process -ExecutionPolicy RemoteSigned -Force -ErrorAction Stop
    if ((Get-ExecutionPolicy) -in @('Restricted','AllSigned')) { throw 'Windows still blocks local scripts; use a signed installer.' }
}

function Get-PublicSource([string]$FileName, [string]$TargetDir) {
    if (-not $expected.ContainsKey($FileName)) { throw "Unapproved source: $FileName" }
    $destination = Join-Path $TargetDir $FileName
    $response = Invoke-WebRequest -Uri "$rawBase/$FileName" -UseBasicParsing -TimeoutSec 45
    if ($response.StatusCode -ne 200 -or [string]::IsNullOrWhiteSpace([string]$response.Content)) {
        throw "Download failed for $FileName"
    }
    [IO.File]::WriteAllText($destination, [string]$response.Content, [Text.UTF8Encoding]::new($false))
    $actual = (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash.ToUpperInvariant()
    if ($actual -ne $expected[$FileName]) { throw "Source hash mismatch for $FileName. No code was installed." }
    if ($FileName.EndsWith('.ps1', [StringComparison]::OrdinalIgnoreCase)) {
        $tokens = $null; $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile($destination,[ref]$tokens,[ref]$errors) | Out-Null
        if ($errors.Count -gt 0) { throw "PowerShell parser error in $FileName`: $($errors[0].Message)" }
    }
}

try {
    if (@(Get-Process -Name SessionWatch -ErrorAction SilentlyContinue).Count -gt 0) {
        Write-Host '[*] Session Watch is already running.' -ForegroundColor Yellow
        Write-Host '[*] To update, stop it using Parar-SessionWatch.ps1, then run the official launcher again.' -ForegroundColor Yellow
        return
    }
    if (Test-TrayMonitorActive) {
        Write-Host '[!] Old Tray Mode is still running. Right-click its icon and choose Exit before updating.' -ForegroundColor Yellow
        return
    }
    Ensure-LocalScriptPolicy
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    [IO.Directory]::CreateDirectory($appRoot) | Out-Null
    [IO.Directory]::CreateDirectory($installDir) | Out-Null
    $staging = Join-Path $appRoot ('source-staging-' + [Guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($staging) | Out-Null
    try {
        foreach ($name in $expected.Keys) { Get-PublicSource $name $staging }
        foreach ($name in $expected.Keys) {
            Copy-Item -LiteralPath (Join-Path $staging $name) -Destination (Join-Path $installDir $name) -Force
        }
    } finally {
        Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
    }
    $clientScript = Join-Path $installDir 'client-main.ps1'
    # Validate the saved license on every manual launch; if absent or revoked,
    # the official client prompts for a new key and can save it with Windows DPAPI.
    if (-not (Test-Path -LiteralPath $licenseFile -PathType Leaf)) {
        Write-Host '[*] Enter your license key. Choose Y to save it for automatic reconnection.' -ForegroundColor Cyan
    }
    & $clientScript -EnrollOnly
    if (-not (Test-Path -LiteralPath $licenseFile -PathType Leaf)) {
        Write-Host '[!] Save a valid license before enabling automatic reconnection.' -ForegroundColor Yellow
        return
    }

    # Explicit opt-in: this separate monitor continues running after the
    # initial PowerShell window closes. It never starts with Windows.
    Write-Host '[*] Session Watch runs in the background after this window closes.' -ForegroundColor Cyan
    $consent = (Read-Host 'Start background monitor? (Y/N)').Trim()
    if ($consent -notmatch '^(?i:y|yes)$') {
        Write-Host '[*] Background monitor not started.'
        return
    }

    & (Join-Path $installDir 'Instalar-SessionWatch.ps1')
    & (Join-Path $installDir 'Iniciar-SessionWatch.ps1')
    Write-Host '[+] Session Watch started. You can close this PowerShell window.' -ForegroundColor Green
} catch {
    Write-Host ('[ERROR] ' + $_.Exception.Message) -ForegroundColor Red
    throw
}
