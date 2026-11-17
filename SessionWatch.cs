// Session Watch - user-controlled foreground-session supervisor (no tray icon).
// Builds as a Windows subsystem app. Visible in Task Manager as SessionWatch.exe.
// No autostart, persistence, injection, process impersonation, or execution-policy change.
using System;
using System.Diagnostics;
using System.IO;
using System.Management;
using System.Threading;

internal static class SessionWatch
{
    private const string MutexName = @"Local\SessionWatchSupervisorV1";
    private const string StopEventName = @"Local\SessionWatchSupervisorStopV1";
    private static readonly string LogFolder = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "SessionWatch");
    private static readonly string LogPath = Path.Combine(LogFolder, "monitor.log");

    private static void Log(string message)
    {
        try
        {
            Directory.CreateDirectory(LogFolder);
            File.AppendAllText(LogPath,
                DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + " " + message + Environment.NewLine);
        }
        catch (IOException) { }
        catch (UnauthorizedAccessException) { }
    }

    private static int StopRunning()
    {
        try
        {
            using (EventWaitHandle stop = EventWaitHandle.OpenExisting(StopEventName))
            {
                stop.Set();
                return 0;
            }
        }
        catch (WaitHandleCannotBeOpenedException) { return 2; }
    }

    // Only stop the panel process that our own PowerShell client started.
    private static void StopOwnedPanel(int launcherPid)
    {
        try
        {
            string query = "SELECT ProcessId, Name FROM Win32_Process WHERE ParentProcessId=" + launcherPid;
            using (ManagementObjectSearcher search = new ManagementObjectSearcher(query))
            {
                foreach (ManagementObject item in search.Get())
                {
                    try
                    {
                        string name = Convert.ToString(item["Name"]);
                        if (!string.Equals(name, "Nova Application.exe", StringComparison.OrdinalIgnoreCase))
                            continue;
                        int pid = Convert.ToInt32(item["ProcessId"]);
                        using (Process panel = Process.GetProcessById(pid))
                        {
                            if (!panel.HasExited) panel.Kill();
                        }
                        Log("Stopped a panel started by the monitored launcher (PID " + pid + ").");
                    }
                    catch (Exception ex) { Log("Panel close warning: " + ex.GetType().Name); }
                }
            }
        }
        catch (Exception ex) { Log("Panel lookup warning: " + ex.GetType().Name); }
    }

    private static int Main(string[] args)
    {
        if (args.Length == 1 && args[0] == "--stop") return StopRunning();
        if (args.Length != 1 || !Path.IsPathRooted(args[0]) ||
            !string.Equals(Path.GetExtension(args[0]), ".ps1", StringComparison.OrdinalIgnoreCase) ||
            !File.Exists(args[0]))
        {
            Log("Invalid launcher path. Start it through Iniciar-SessionWatch.ps1.");
            return 3;
        }

        bool newMutex;
        using (Mutex mutex = new Mutex(true, MutexName, out newMutex))
        {
            if (!newMutex) { Log("Another Session Watch is already running."); return 4; }
            try
            {
                using (EventWaitHandle stop = new EventWaitHandle(false, EventResetMode.AutoReset, StopEventName))
                {
                    string shell = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System),
                        @"WindowsPowerShell\v1.0\powershell.exe");
                    if (!File.Exists(shell)) shell = "powershell.exe";

                    ProcessStartInfo psi = new ProcessStartInfo();
                    psi.FileName = shell;
                    psi.Arguments = "-NoProfile -NonInteractive -File \"" + args[0] + "\" -TrayMode";
                    psi.UseShellExecute = false;
                    psi.CreateNoWindow = true;
                    psi.WindowStyle = ProcessWindowStyle.Hidden;
                    psi.WorkingDirectory = Path.GetDirectoryName(args[0]);

                    using (Process client = Process.Start(psi))
                    {
                        if (client == null) { Log("Could not start client."); return 5; }
                        Log("Started authorized session client (PID " + client.Id + ").");
                        bool requestedStop = false;
                        while (true)
                        {
                            if (stop.WaitOne(1000)) { requestedStop = true; break; }
                            client.Refresh();
                            if (client.HasExited) break;
                        }
                        if (requestedStop)
                        {
                            Log("User requested stop.");
                            StopOwnedPanel(client.Id);
                            client.Refresh();
                            if (!client.HasExited) client.Kill();
                            client.WaitForExit(3000);
                        }
                        else
                        {
                            Log("Client exited, code " + client.ExitCode + ". Session Watch finished.");
                        }
                    }
                }
            }
            catch (Exception ex)
            {
                Log("ERROR: " + ex.GetType().Name + " - " + ex.Message);
                return 6;
            }
            finally
            {
                mutex.ReleaseMutex();
            }
        }
        return 0;
    }
}
