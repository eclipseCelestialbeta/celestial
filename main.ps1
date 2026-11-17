# CELESTIAL ECLIPSE - Official Tray Launcher
# Version: launcher tray integration for release 1.0.4.
# Intended invocation: iex (irm 'https://raw.githubusercontent.com/eclipseCelestialbeta/celestial/main/main.ps1')
# Visible notification-area control, no Windows service, startup task, or persistence at sign-in.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$rawBase = 'https://raw.githubusercontent.com/eclipseCelestialbeta/celestial/main'
$appRoot = Join-Path $env:LOCALAPPDATA 'CelestialLauncher'
$installDir = Join-Path $appRoot 'launcher'
$licenseFile = Join-Path $appRoot 'license.dat'
$hostMutexName = 'Local\CelestialWaitModeTrayHost'

function Test-MonitorAlreadyActive {
    $check = New-Object System.Threading.Mutex($false, $hostMutexName)
    $owned = $false
    try {
        try {
            $owned = $check.WaitOne(0, $false)
        } catch [System.Threading.AbandonedMutexException] {
            $owned = $true
        }
        if ($owned) { $check.ReleaseMutex() }
        return (-not $owned)
    } finally {
        $check.Dispose()
    }
}

function Get-PublicScript([string]$FileName, [string]$TargetDir) {
    $uri = "$rawBase/$FileName"
    $destination = Join-Path $TargetDir $FileName
    $response = Invoke-WebRequest -Uri $uri -UseBasicParsing -TimeoutSec 40
    if ($response.StatusCode -ne 200 -or [string]::IsNullOrWhiteSpace($response.Content)) {
        throw "Download failed for $FileName."
    }
    [IO.File]::WriteAllText($destination, [string]$response.Content, [Text.UTF8Encoding]::new($false))
    $tokens = $null
    $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($destination, [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors.Count -gt 0) {
        throw "The GitHub script $FileName contains a syntax error: $($errors[0].Message)"
    }
}

try {
    if (Test-MonitorAlreadyActive) {
        Write-Host '[*] Tray Mode already active. Right-click its notification-area icon and choose Exit before updating.' -ForegroundColor Yellow
        return
    }
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    [IO.Directory]::CreateDirectory($appRoot) | Out-Null
    [IO.Directory]::CreateDirectory($installDir) | Out-Null
    $staging = Join-Path $appRoot ('launcher-staging-' + [Guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($staging) | Out-Null
    try {
        Get-PublicScript 'client-main.ps1' $staging
        Get-PublicScript 'Celestial-Tray-Host.ps1' $staging
        foreach ($name in @('client-main.ps1', 'Celestial-Tray-Host.ps1')) {
            Copy-Item -LiteralPath (Join-Path $staging $name) -Destination (Join-Path $installDir $name) -Force
        }
    } finally {
        Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
    }

    $clientScript = Join-Path $installDir 'client-main.ps1'
    $hostScript = Join-Path $installDir 'Celestial-Tray-Host.ps1'
    if (-not (Test-Path -LiteralPath $licenseFile -PathType Leaf)) {
        Write-Host '[*] First run: please validate your license and choose Y to remember it for Tray Mode.' -ForegroundColor Cyan
        & $clientScript -EnrollOnly
        if (-not (Test-Path -LiteralPath $licenseFile -PathType Leaf)) {
            Write-Host '[!] Tray Mode not started. A remembered license is required. Run the official command again and choose Y.' -ForegroundColor Yellow
            return
        }
    }

    # The tray process is independent of the interactive PowerShell window.
    # All process names and parameters remain visible in Windows Task Manager.
    $psExe = Join-Path $PSHOME 'powershell.exe'
    $quotedHost = '"' + $hostScript + '"'
    $quotedClient = '"' + $clientScript + '"'
    $arguments = @('-NoProfile', '-STA', '-WindowStyle', 'Hidden', '-File', $quotedHost, '-LauncherPath', $quotedClient)
    $proc = Start-Process -FilePath $psExe -ArgumentList $arguments -WindowStyle Hidden -PassThru
    Start-Sleep -Milliseconds 1200
    $proc.Refresh()
    if ($proc.HasExited) {
        throw 'The Tray Mode process exited right away. Check your PowerShell script permissions and run again.'
    }
    Write-Host "[+] Celestial Tray Mode started (PID $($proc.Id))." -ForegroundColor Green
    Write-Host '[*] The icon is in the Windows notification area near the clock.' -ForegroundColor Cyan
    Write-Host '[*] Right-click the icon and choose Exit to stop the monitor.' -ForegroundColor Cyan
    Write-Host '[*] You can close this PowerShell window; the monitor stays available until Exit or sign-out.' -ForegroundColor Cyan
} catch {
    Write-Host ('[ERROR] ' + $_.Exception.Message) -ForegroundColor Red
    throw
}
