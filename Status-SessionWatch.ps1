$running = @(Get-Process -Name SessionWatch -ErrorAction SilentlyContinue)
if ($running.Count) {
    $running | Select-Object Id, ProcessName, StartTime | Format-Table -AutoSize
} else {
    Write-Host '[*] Session Watch is not running.'
}
$log = Join-Path $env:LOCALAPPDATA 'SessionWatch\monitor.log'
if (Test-Path -LiteralPath $log) {
    Write-Host '[*] Most recent status messages:'
    Get-Content -LiteralPath $log -Tail 8
}
