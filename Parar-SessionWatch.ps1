# Revoking opt-in makes the next official launch ask for permission again.
$consentFile = Join-Path $env:LOCALAPPDATA 'CelestialLauncher\launcher\background-monitor-consent.txt'
if (Test-Path -LiteralPath $consentFile) { Remove-Item -LiteralPath $consentFile -Force }
$binary = Join-Path $env:LOCALAPPDATA 'SessionWatch\SessionWatch.exe'
if (-not (Test-Path -LiteralPath $binary)) { throw 'Session Watch not installed.' }
$proc = @(Get-Process -Name SessionWatch -ErrorAction SilentlyContinue)
if (-not $proc.Count) { Write-Host '[*] Session Watch is not running.'; return }
& $binary --stop
Start-Sleep -Seconds 2
$still = @(Get-Process -Name SessionWatch -ErrorAction SilentlyContinue)
if ($still.Count) {
    Write-Host '[!] Still stopping. Verify the process in Task Manager.' -ForegroundColor Yellow
} else {
    Write-Host '[+] Session Watch stopped.' -ForegroundColor Green
}
