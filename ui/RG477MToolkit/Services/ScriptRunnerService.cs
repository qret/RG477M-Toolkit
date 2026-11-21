using System.Diagnostics;
using System.IO;
using System.Text;

namespace RG477MToolkit.Services;

public sealed class ScriptRunnerService
{
    private readonly ToolkitPaths _paths;

    public ScriptRunnerService(ToolkitPaths paths)
    {
        _paths = paths;
    }

    public async Task<int> RunPowerShellAsync(
        string scriptPath,
        string arguments,
        Action<string> onOutput,
        bool isEnglish = false,
        CancellationToken ct = default)
    {
        var psi = new ProcessStartInfo
        {
            FileName = "powershell.exe",
            Arguments = $"-NoProfile -ExecutionPolicy Bypass -File \"{scriptPath}\" {arguments}".Trim(),
            WorkingDirectory = _paths.ProjectRoot,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8,
            UseShellExecute = false,
            CreateNoWindow = true
        };

        using var proc = new Process { StartInfo = psi, EnableRaisingEvents = true };
        proc.OutputDataReceived += (_, e) => { if (e.Data is not null) onOutput(e.Data); };
        proc.ErrorDataReceived += (_, e) => { if (e.Data is not null) onOutput("[ERR] " + e.Data); };

        onOutput($"> powershell -File \"{Path.GetFileName(scriptPath)}\" {arguments}");
        proc.Start();
        proc.BeginOutputReadLine();
        proc.BeginErrorReadLine();

        await proc.WaitForExitAsync(ct);
        onOutput(isEnglish ? $"[Finished with code: {proc.ExitCode}]" : $"[Завершено с кодом: {proc.ExitCode}]");
        return proc.ExitCode;
    }
}
