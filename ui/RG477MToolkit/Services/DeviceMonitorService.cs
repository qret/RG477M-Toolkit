using System.Diagnostics;
using System.Management;
using System.Text.RegularExpressions;
using RG477MToolkit.Models;

namespace RG477MToolkit.Services;

public sealed class DeviceMonitorService
{
    private readonly ToolkitPaths _paths;

    public DeviceMonitorService(ToolkitPaths paths)
    {
        _paths = paths;
    }

    public async Task<DeviceStateSnapshot> PollOnceAsync(CancellationToken ct = default)
    {
        var (hasBackup, backupSummary) = _paths.CheckStockBackup();

        // 1. Сначала проверяем MediaTek Preloader / BROM по PnP USB
        var usbState = DetectMediaTekUsb();
        if (usbState.mode != ConnectionMode.Disconnected)
        {
            return new DeviceStateSnapshot
            {
                Mode = usbState.mode,
                ModeTitle = usbState.title,
                ModeDetail = usbState.detail,
                ComPort = usbState.port,
                HasStockBackup = hasBackup,
                BackupSummary = backupSummary
            };
        }

        // 2. Проверяем ADB
        var adbDevices = await RunAdbAsync("devices", ct);
        if (adbDevices.exitCode == 0 && HasOnlineAdbDevice(adbDevices.stdout))
        {
            var model = (await RunAdbAsync("shell getprop ro.product.model", ct)).stdout.Trim();
            var build = (await RunAdbAsync("shell getprop ro.build.display.id", ct)).stdout.Trim();
            var slot = (await RunAdbAsync("shell getprop ro.boot.slot_suffix", ct)).stdout.Trim();
            var magiskVer = (await RunAdbAsync("shell \"magisk -v 2>/dev/null || echo none\"", ct)).stdout.Trim();

            var isSupported = model.Equals("RG477M", StringComparison.OrdinalIgnoreCase) &&
                              build.Contains("V1.32", StringComparison.OrdinalIgnoreCase);

            var magiskText = magiskVer == "none" || string.IsNullOrWhiteSpace(magiskVer)
                ? "Не установлен (сток)"
                : magiskVer;

            return new DeviceStateSnapshot
            {
                Mode = ConnectionMode.AdbOnline,
                ModeTitle = "ADB Online",
                ModeDetail = isSupported
                    ? "RG477M на поддерживаемой прошивке V1.32 — готов к работе"
                    : $"Обнаружено устройство: {model} ({build})",
                Model = string.IsNullOrWhiteSpace(model) ? "RG477M" : model,
                Firmware = string.IsNullOrWhiteSpace(build) ? "—" : build,
                ActiveSlot = string.IsNullOrWhiteSpace(slot) ? "—" : slot,
                MagiskStatus = magiskText,
                IsSupportedBuild = isSupported,
                HasStockBackup = hasBackup,
                BackupSummary = backupSummary
            };
        }

        return new DeviceStateSnapshot
        {
            Mode = ConnectionMode.Disconnected,
            ModeTitle = "Устройство не подключено",
            ModeDetail = "Подключите включённый RG477M по USB-C (ADB) или переведите в BROM",
            HasStockBackup = hasBackup,
            BackupSummary = backupSummary
        };
    }

    private static bool HasOnlineAdbDevice(string output)
    {
        foreach (var line in output.Split(new[] { '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries))
        {
            if (line.StartsWith("List of devices", StringComparison.OrdinalIgnoreCase)) continue;
            if (Regex.IsMatch(line, @"\S+\s+device\b")) return true;
        }
        return false;
    }

    private static (ConnectionMode mode, string title, string detail, string port) DetectMediaTekUsb()
    {
        try
        {
            using var searcher = new ManagementObjectSearcher(
                "SELECT Name, DeviceID, ConfigManagerErrorCode FROM Win32_PnPEntity WHERE DeviceID LIKE '%VID_0E8D%' OR ConfigManagerErrorCode = 43");

            foreach (var obj in searcher.Get())
            {
                var devId = obj["DeviceID"]?.ToString() ?? "";
                var name = obj["Name"]?.ToString() ?? "";
                var errCode = Convert.ToInt32(obj["ConfigManagerErrorCode"] ?? 0);

                var portMatch = Regex.Match(name, @"\((COM\d+)\)");
                var port = portMatch.Success ? portMatch.Groups[1].Value : "";

                if (devId.Contains("PID_0003", StringComparison.OrdinalIgnoreCase))
                {
                    return (
                        ConnectionMode.BromMode,
                        $"MediaTek BROM ({port})",
                        "Режим BootROM активен — готов для Readback / прошивки SP Flash Tool",
                        port
                    );
                }

                if (devId.Contains("PID_2000", StringComparison.OrdinalIgnoreCase) ||
                    name.Contains("PreLoader", StringComparison.OrdinalIgnoreCase))
                {
                    return (
                        ConnectionMode.PreloaderVcom,
                        $"MediaTek Preloader ({port})",
                        "Порт Preloader VCOM обнаружен — SP Flash Tool сможет перехватить устройство",
                        port
                    );
                }

                if (errCode == 43 && name.Contains("USB", StringComparison.OrdinalIgnoreCase))
                {
                    return (
                        ConnectionMode.UsbDescriptorError,
                        "Ошибка USB (Код 43)",
                        "Не удерживайте Power! Отключите кабель, зажмите только Vol+ и Vol-, затем подключите USB-C",
                        ""
                    );
                }
            }
        }
        catch
        {
            // WMI может быть временно недоступен; возвращаем Disconnected
        }

        return (ConnectionMode.Disconnected, "", "", "");
    }

    private async Task<(int exitCode, string stdout)> RunAdbAsync(string arguments, CancellationToken ct)
    {
        try
        {
            var psi = new ProcessStartInfo
            {
                FileName = _paths.AdbExe,
                Arguments = arguments,
                RedirectStandardOutput = true,
                RedirectStandardError = true,
                UseShellExecute = false,
                CreateNoWindow = true
            };

            using var proc = Process.Start(psi);
            if (proc is null) return (-1, "");

            var stdoutTask = proc.StandardOutput.ReadToEndAsync(ct);
            using var timeoutCts = CancellationTokenSource.CreateLinkedTokenSource(ct);
            timeoutCts.CancelAfter(TimeSpan.FromMilliseconds(1800));
            await proc.WaitForExitAsync(timeoutCts.Token);
            var stdout = await stdoutTask;
            return (proc.ExitCode, stdout);
        }
        catch
        {
            return (-1, "");
        }
    }
}
