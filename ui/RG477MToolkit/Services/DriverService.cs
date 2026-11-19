using System.Diagnostics;
using System.IO;

namespace RG477MToolkit.Services;

public sealed class DriverStatus
{
    public bool HasMtkVcom { get; init; }
    public bool HasAdbUsb { get; init; }
    public bool AllReady => HasMtkVcom && HasAdbUsb;
}

public sealed class DriverService
{
    public async Task<DriverStatus> CheckDriversAsync(CancellationToken ct = default)
    {
        try
        {
            var psi = new ProcessStartInfo
            {
                FileName = "pnputil.exe",
                Arguments = "/enum-drivers",
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
                CreateNoWindow = true
            };

            using var proc = Process.Start(psi);
            if (proc is null) return new DriverStatus();

            var stdout = await proc.StandardOutput.ReadToEndAsync(ct);
            await proc.WaitForExitAsync(ct);

            var hasMtk = stdout.Contains("cdc-acm.inf", StringComparison.OrdinalIgnoreCase) ||
                         (stdout.Contains("MediaTek", StringComparison.OrdinalIgnoreCase) &&
                          stdout.Contains("Ports", StringComparison.OrdinalIgnoreCase));

            var hasAdb = stdout.Contains("android_winusb.inf", StringComparison.OrdinalIgnoreCase);

            return new DriverStatus
            {
                HasMtkVcom = hasMtk,
                HasAdbUsb = hasAdb
            };
        }
        catch
        {
            return new DriverStatus();
        }
    }

    public async Task<(bool started, string message)> LaunchDriverInstallerAsync(string? installerPath, bool isEnglish)
    {
        if (string.IsNullOrWhiteSpace(installerPath) || !File.Exists(installerPath))
        {
            return (false, isEnglish
                ? "Driver installer not found in runtime\\driver\\MTK Driver Setup.exe."
                : "Установщик драйверов не найден в runtime\\driver\\MTK Driver Setup.exe.");
        }

        try
        {
            var psi = new ProcessStartInfo
            {
                FileName = installerPath,
                WorkingDirectory = Path.GetDirectoryName(installerPath) ?? "",
                UseShellExecute = true,
                Verb = "runas"
            };

            using var proc = Process.Start(psi);
            if (proc is null)
            {
                return (false, isEnglish ? "Failed to start driver installer." : "Не удалось запустить установщик драйверов.");
            }

            await proc.WaitForExitAsync();
            return (true, isEnglish ? "Driver installer finished." : "Установщик драйверов завершил работу.");
        }
        catch (Exception ex)
        {
            return (false, ex.Message);
        }
    }
}
