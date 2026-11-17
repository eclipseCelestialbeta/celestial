param(
    [Parameter(Mandatory = $true)]
    [string]$LauncherPath
)

# Visible and user-controllable Windows notification-area app.
# Runs one separately monitored session launcher. No automatic OS startup.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$mutex = [System.Threading.Mutex]::new($false, 'Local\CelestialWaitModeTrayHost')
$ownsMutex = $false
try {
    try {
        $ownsMutex = $mutex.WaitOne(0, $false)
    } catch [System.Threading.AbandonedMutexException] {
        $ownsMutex = $true
    }
    if (-not $ownsMutex) {
        $mutex.Dispose()
        return
    }

    $script:monitor = $null
    $script:timer = $null
    $script:tray = $null
    $script:context = $null

    function Stop-OurMonitor {
        if ($null -eq $script:monitor) { return }
        $pidToStop = [int]$script:monitor.Id
        try {
            $script:monitor.Refresh()
            if (-not $script:monitor.HasExited) {
                # Close only the panel spawned by our exact launcher process.
                # Never stop game processes or unrelated Nova Application instances.
                Get-CimInstance Win32_Process -Filter "ParentProcessId = $pidToStop" -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -eq 'Nova Application.exe' } |
                    ForEach-Object {
                        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
                    }
                Stop-Process -Id $pidToStop -Force -ErrorAction SilentlyContinue
            }
        } catch { }
    }

    $psExe = Join-Path $PSHOME 'powershell.exe'
    $quotedLauncher = '"' + $LauncherPath + '"'
    $script:monitor = Start-Process -FilePath $psExe -ArgumentList @(
        '-NoProfile', '-STA', '-WindowStyle', 'Hidden', '-File', $quotedLauncher, '-TrayMode' 
    ) -WindowStyle Hidden -PassThru

    $script:context = New-Object System.Windows.Forms.ApplicationContext
    $script:tray = New-Object System.Windows.Forms.NotifyIcon
    $script:tray.Icon = [System.Drawing.SystemIcons]::Application
    $script:tray.Text = 'Celestial Eclipse - Wait Mode'
    $script:tray.Visible = $true

    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $script:statusItem = New-Object System.Windows.Forms.ToolStripMenuItem('Monitor: iniciando')
    $script:statusItem.Enabled = $false
    [void]$menu.Items.Add($script:statusItem)
    [void]$menu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    $exitItem = New-Object System.Windows.Forms.ToolStripMenuItem('Sair e encerrar monitor')
    [void]$menu.Items.Add($exitItem)
    $script:tray.ContextMenuStrip = $menu

    $script:timer = New-Object System.Windows.Forms.Timer
    $script:timer.Interval = 2000
    $script:timer.Add_Tick({
        try {
            $script:monitor.Refresh()
            if ($script:monitor.HasExited) {
                $script:statusItem.Text = 'Monitor: encerrado (reinicie pelo comando oficial)'
                $script:tray.Text = 'Celestial Eclipse - monitor encerrado'
                $script:timer.Stop()
                return
            }
            $rbx = @(Get-Process -Name 'RobloxPlayerBeta' -ErrorAction SilentlyContinue)
            if ($rbx.Count -eq 0) {
                $script:statusItem.Text = 'Monitor: aguardando Roblox'
            } else {
                $script:statusItem.Text = 'Monitor: Roblox detectado'
            }
        } catch {
            $script:statusItem.Text = 'Monitor: estado indisponivel'
        }
    })
    $exitItem.Add_Click({
        $script:timer.Stop()
        Stop-OurMonitor
        $script:tray.Visible = $false
        $script:context.ExitThread()
    })

    $script:timer.Start()
    [System.Windows.Forms.Application]::Run($script:context)
}
finally {
    if ($null -ne $script:timer) {
        $script:timer.Stop()
        $script:timer.Dispose()
    }
    if ($null -ne $script:tray) {
        $script:tray.Visible = $false
        $script:tray.Dispose()
    }
    if ($ownsMutex) {
        Stop-OurMonitor
        $mutex.ReleaseMutex()
        $mutex.Dispose()
    }
}
