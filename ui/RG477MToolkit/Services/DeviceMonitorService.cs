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

    public async Task<DeviceStateSnapshot> PollOnceAsync(bool isEnglish = false, CancellationToken ct = default)
    {
        var (hasBackup, backupSummary) = _paths.CheckStockBackup(isEnglish);

        // 1. Сначала проверяем MediaTek Preloader / BROM по PnP USB (в фоновом потоке)
        var (usbMode, usbTitle, usbDetail, usbPort, usbIsDefiniteMtk) = await Task.Run(() => DetectMediaTekUsb(isEnglish), ct);
        if (usbMode != ConnectionMode.Disconnected && (usbMode != ConnectionMode.UsbDescriptorError || usbIsDefiniteMtk))
        {
            return new DeviceStateSnapshot
            {
                Mode = usbMode,
                ModeTitle = usbTitle,
                ModeDetail = usbDetail,
                ComPort = usbPort,
                MagiskStatus = "—",
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

            bool isMagiskInstalled = !string.IsNullOrWhiteSpace(magiskVer) &&
                                     !magiskVer.Equals("none", StringComparison.OrdinalIgnoreCase);

            var magiskText = isMagiskInstalled
                ? magiskVer
                : (isEnglish ? "Not installed (stock)" : "Не установлен (сток)");

            var (moduleState, installedModuleVer) = isMagiskInstalled
                ? await CheckPerfModuleStateAsync(ct)
                : (PerfModuleState.NotInstalled, "");

            return new DeviceStateSnapshot
            {
                Mode = ConnectionMode.AdbOnline,
                ModeTitle = isEnglish ? "ADB Online" : "Подключено (ADB)",
                ModeDetail = isSupported
                    ? (isEnglish ? "RG477M on supported Stock V1.32 — ready" : "RG477M на поддерживаемой прошивке V1.32 — готов к работе")
                    : (isEnglish ? $"Detected device: {model} ({build})" : $"Обнаружено устройство: {model} ({build})"),
                Model = string.IsNullOrWhiteSpace(model) ? "RG477M" : model,
                Firmware = string.IsNullOrWhiteSpace(build) ? "—" : build,
                ActiveSlot = string.IsNullOrWhiteSpace(slot) ? "—" : slot,
                MagiskStatus = magiskText,
                IsMagiskInstalled = isMagiskInstalled,
                ModuleState = moduleState,
                InstalledModuleVersion = installedModuleVer,
                IsSupportedBuild = isSupported,
                HasStockBackup = hasBackup,
                BackupSummary = backupSummary
            };
        }

        // Если ADB не в сети и ранее поймали VID_0000&PID_0002 (сбой дескриптора USB) — показываем подсказку по Кнопкам 43
        if (usbMode == ConnectionMode.UsbDescriptorError)
        {
            return new DeviceStateSnapshot
            {
                Mode = usbMode,
                ModeTitle = usbTitle,
                ModeDetail = usbDetail,
                ComPort = usbPort,
                MagiskStatus = "—",
                HasStockBackup = hasBackup,
                BackupSummary = backupSummary
            };
        }

        return new DeviceStateSnapshot
        {
            Mode = ConnectionMode.Disconnected,
            ModeTitle = isEnglish ? "Disconnected" : "Устройство не подключено",
            ModeDetail = isEnglish
                ? "Connect powered-on RG477M via USB-C (ADB) or boot into BROM"
                : "Подключите включённый RG477M по USB-C (ADB) или переведите в BROM",
            MagiskStatus = isEnglish ? "Not checked" : "Не проверено",
            HasStockBackup = hasBackup,
            BackupSummary = backupSummary
        };
    }

    private async Task<(PerfModuleState state, string version)> CheckPerfModuleStateAsync(CancellationToken ct)
    {
        var res = await RunAdbAsync(
            "shell \"su -c 'if [ -d /data/adb/modules_update/rg477m_perf_tuning ] && [ -f /data/adb/modules_update/rg477m_perf_tuning/module.prop ]; then cat /data/adb/modules_update/rg477m_perf_tuning/module.prop; elif [ -f /data/adb/modules/rg477m_perf_tuning/remove ]; then echo REMOVE; elif [ -f /data/adb/modules/rg477m_perf_tuning/disable ]; then echo DISABLED; elif [ -f /data/adb/modules/rg477m_perf_tuning/module.prop ]; then cat /data/adb/modules/rg477m_perf_tuning/module.prop; else echo NONE; fi' 2>/dev/null || echo NO_ROOT\"",
            ct);

        if (res.exitCode != 0)
            return (PerfModuleState.Unknown, "");

        var outText = res.stdout.Trim();
        if (string.IsNullOrEmpty(outText) || outText.Contains("NO_ROOT", StringComparison.OrdinalIgnoreCase))
            return (PerfModuleState.Unknown, "");

        if (outText.Equals("REMOVE", StringComparison.OrdinalIgnoreCase))
            return (PerfModuleState.PendingRemoval, "");

        if (outText.Equals("NONE", StringComparison.OrdinalIgnoreCase) ||
            outText.Equals("DISABLED", StringComparison.OrdinalIgnoreCase))
            return (PerfModuleState.NotInstalled, "");

        if (outText.Contains("id=rg477m_perf_tuning", StringComparison.OrdinalIgnoreCase))
        {
            string version = "";
            int installedCode = 0;
            foreach (var raw in outText.Split(new[] { '\r', '\n' }, StringSplitOptions.RemoveEmptyEntries))
            {
                var line = raw.Trim();
                var idx = line.IndexOf('=');
                if (idx <= 0) continue;
                var key = line[..idx].Trim();
                var val = line[(idx + 1)..].Trim();
                if (key.Equals("version", StringComparison.Ordinal))
                    version = val;
                else if (key.Equals("versionCode", StringComparison.Ordinal))
                    int.TryParse(val, out installedCode);
            }

            var state = installedCode < _paths.BundledModuleVersionCode
                ? PerfModuleState.UpdateAvailable
                : PerfModuleState.InstalledUpToDate;
            return (state, version);
        }

        return (PerfModuleState.Unknown, "");
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

    private static (ConnectionMode mode, string title, string detail, string port, bool isDefiniteMtk) DetectMediaTekUsb(bool isEnglish)
    {
        try
        {
            using var searcher = new ManagementObjectSearcher(
                "SELECT Name, DeviceID, ConfigManagerErrorCode FROM Win32_PnPEntity WHERE DeviceID LIKE '%VID_0E8D%' OR ConfigManagerErrorCode = 43");

            using var results = searcher.Get();
            foreach (ManagementObject obj in results)
            {
                using (obj)
                {
                    var devId = obj["DeviceID"]?.ToString() ?? "";
                    var name = obj["Name"]?.ToString() ?? "";
                    var errCode = Convert.ToInt32(obj["ConfigManagerErrorCode"] ?? 0);

                    var portMatch = Regex.Match(name, @"\((COM\d+)\)");
                    var port = portMatch.Success ? portMatch.Groups[1].Value : "";
                    var portSuffix = string.IsNullOrEmpty(port) ? "" : $" ({port})";

                    if (devId.Contains("PID_0003", StringComparison.OrdinalIgnoreCase))
                    {
                        return (
                            ConnectionMode.BromMode,
                            $"MediaTek BROM{portSuffix}",
                            isEnglish
                                ? "BootROM active — ready for SP Flash Tool Readback / flashing"
                                : "Режим BootROM активен — готов для Readback / прошивки SP Flash Tool",
                            port,
                            true
                        );
                    }

                    if (devId.Contains("PID_2000", StringComparison.OrdinalIgnoreCase) ||
                        name.Contains("PreLoader", StringComparison.OrdinalIgnoreCase))
                    {
                        return (
                            ConnectionMode.PreloaderVcom,
                            $"MediaTek Preloader{portSuffix}",
                            isEnglish
                                ? "Preloader VCOM port detected — SP Flash Tool will catch the device"
                                : "Порт Preloader VCOM обнаружен — SP Flash Tool сможет перехватить устройство",
                            port,
                            true
                        );
                    }

                    if (errCode == 43 &&
                        (devId.Contains("VID_0E8D", StringComparison.OrdinalIgnoreCase) ||
                         devId.Contains("VID_0000&PID_0002", StringComparison.OrdinalIgnoreCase)))
                    {
                        bool definite = devId.Contains("VID_0E8D", StringComparison.OrdinalIgnoreCase);
                        return (
                            ConnectionMode.UsbDescriptorError,
                            isEnglish ? "USB Error (Code 43)" : "Ошибка USB (Код 43)",
                            isEnglish
                                ? "Do NOT hold Power! Unplug USB, hold ONLY Vol- and Vol+, then plug in USB-C"
                                : "Не удерживайте Power! Отключите кабель, зажмите только Vol- и Vol+, затем подключите USB-C",
                            "",
                            definite
                        );
                    }
                }
            }
        }
        catch
        {
            // WMI может быть временно недоступен; возвращаем Disconnected
        }

        return (ConnectionMode.Disconnected, "", "", "", false);
    }

    private async Task<(int exitCode, string stdout)> RunAdbAsync(string arguments, CancellationToken ct)
    {
        Process? proc = null;
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

            proc = Process.Start(psi);
            if (proc is null) return (-1, "");

            using var timeoutCts = CancellationTokenSource.CreateLinkedTokenSource(ct);
            timeoutCts.CancelAfter(TimeSpan.FromMilliseconds(1800));

            var stdoutTask = proc.StandardOutput.ReadToEndAsync(timeoutCts.Token);
            var stderrTask = proc.StandardError.ReadToEndAsync(timeoutCts.Token);
            await proc.WaitForExitAsync(timeoutCts.Token);

            var stdout = await stdoutTask;
            _ = await stderrTask;
            return (proc.ExitCode, stdout);
        }
        catch
        {
            try
            {
                if (proc is not null && !proc.HasExited)
                    proc.Kill(entireProcessTree: true);
            }
            catch
            {
                // Игнорируем ошибку при аварийном завершении зависшего процесса
            }
            return (-1, "");
        }
        finally
        {
            proc?.Dispose();
        }
    }
}
