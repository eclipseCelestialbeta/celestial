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
    'Instalar-SessionWatch.ps1' = 'C2AC3098A9FED73AB229B4FEE314FB6FCBBAD92759EE02471880F7D93C9954B2'
    'Iniciar-SessionWatch.ps1' = '528A435E592BF473718A5781ADD16B2A96919760AE723345BB27F20DF7FCA02B'
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
    Write-Host '[!] This Windows session blocks local PowerShell scripts.' -ForegroundColor Yellow
    Write-Host '[*] Session Watch requires local client/installer scripts from the official GitHub repository.' -ForegroundColor Yellow
    Write-Host '[*] You can review the sources first. Any policy change is temporary for this session and child processes.' -ForegroundColor Cyan
    $answer = Read-Host 'Allow local scripts for this PowerShell session only? Type YES'
    if ($answer -cne 'YES') { throw 'Cancelled. No policy was changed.' }
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
    Write-Host 'SESSION WATCH - optional background session monitor' -ForegroundColor Cyan
    Write-Host 'The application starts without a tray icon or desktop window, remains visible in Task Manager,'
    Write-Host 'and monitors the game session so the licensed client can reconnect after restarting the game.'
    Write-Host 'It does not start with Windows. To quit, use Parar-SessionWatch.ps1 or Task Manager.'
    $consent = Read-Host 'Install and run this monitor on your PC? Type YES'
    if ($consent -cne 'YES') { Write-Host '[*] Cancelled by user.'; return }
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
    if (-not (Test-Path -LiteralPath $licenseFile -PathType Leaf)) {
        Write-Host '[*] First run: validate your key and choose Y to save it for reconnection.' -ForegroundColor Cyan
        & $clientScript -EnrollOnly
        if (-not (Test-Path -LiteralPath $licenseFile -PathType Leaf)) {
            Write-Host '[!] A saved license is required for unattended reconnection.' -ForegroundColor Yellow
            return
        }
    }
    & (Join-Path $installDir 'Instalar-SessionWatch.ps1')
    & (Join-Path $installDir 'Iniciar-SessionWatch.ps1')
    Write-Host '[*] Stop: & "$env:LOCALAPPDATA\CelestialLauncher\launcher\Parar-SessionWatch.ps1"'
    Write-Host '[*] Status: & "$env:LOCALAPPDATA\CelestialLauncher\launcher\Status-SessionWatch.ps1"'
} catch {
    Write-Host ('[ERROR] ' + $_.Exception.Message) -ForegroundColor Red
    throw
}
