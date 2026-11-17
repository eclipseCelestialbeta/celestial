$ErrorActionPreference = 'Stop'
$binary = Join-Path $env:LOCALAPPDATA 'SessionWatch\SessionWatch.exe'
$client = Join-Path $env:LOCALAPPDATA 'CelestialLauncher\launcher\client-main.ps1'
if (-not (Test-Path -LiteralPath $binary)) { throw 'Run Instalar-SessionWatch.ps1 first.' }
if (-not (Test-Path -LiteralPath $client)) { throw 'Official client-main.ps1 not installed. Run the official launcher once and save the license.' }
if (-not (Test-Path -LiteralPath (Join-Path $env:LOCALAPPDATA 'CelestialLauncher\license.dat'))) { throw 'No saved license. First enroll using the official launcher.' }
$old = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like '*Celestial-Tray-Host.ps1*' })
if ($old.Count) { throw 'Old Tray Mode is running. Use its Exit menu before starting Session Watch.' }
$existing = @(Get-Process -Name SessionWatch -ErrorAction SilentlyContinue)
if ($existing.Count) { Write-Host '[*] Session Watch is already running.'; return }
$effective = Get-ExecutionPolicy
if ($effective -in @('Restricted','AllSigned')) {
    throw "PowerShell execution policy is $effective. Review and authorize local scripts first; this package will not silently change the Windows policy."
}
$proc = Start-Process -FilePath $binary -ArgumentList ('"' + $client + '"') -PassThru
Start-Sleep -Seconds 2
$proc.Refresh()
if ($proc.HasExited) {
    $log = Join-Path $env:LOCALAPPDATA 'SessionWatch\monitor.log'
    Write-Host "[ERROR] Monitor exited. See $log" -ForegroundColor Red
    return
}
Write-Host "[+] Session Watch running (PID $($proc.Id))." -ForegroundColor Green
Write-Host '[*] No tray icon. Visible in Task Manager as SessionWatch.exe.'
Write-Host '[*] Stop with Parar-SessionWatch.ps1. No automatic start at Windows login.'
