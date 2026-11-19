using System.IO;
using System.Text.Json;

namespace RG477MToolkit.Services;

public sealed class ToolkitPaths
{
    public string ProjectRoot { get; }
    public string AdbExe { get; private set; } = "adb.exe";
    public string? SpftDir { get; private set; }
    public string? MagiskApk { get; private set; }
    public string? DriverInstallerExe { get; private set; }
    public string ToolkitVersion { get; private set; } = "0.1.0";
    public string TargetMagiskVersion { get; private set; } = "v31.1";

    public string BackupsStockDir => Path.Combine(ProjectRoot, "backups", "stock");
    public string ReadbackScript => Path.Combine(ProjectRoot, "scripts", "backup", "readback-stock.ps1");
    public string RestoreScript => Path.Combine(ProjectRoot, "scripts", "backup", "restore-stock.ps1");
    public string PatchMagiskScript => Path.Combine(ProjectRoot, "scripts", "magisk", "patch-init-boot.ps1");
    public string FlashMagiskScript => Path.Combine(ProjectRoot, "scripts", "magisk", "flash-magisk.ps1");
    public string BuildPerfModuleScript => Path.Combine(ProjectRoot, "scripts", "module", "build-perf-module.ps1");
    public string InstallPerfModuleScript => Path.Combine(ProjectRoot, "scripts", "module", "install-perf-module.ps1");

    public ToolkitPaths()
    {
        ProjectRoot = ResolveProjectRoot();
        LoadVersionProperties();
        LoadBundledRuntimePaths();
        LoadLocalPaths();
        ResolveDriverInstaller();
    }

    private void LoadBundledRuntimePaths()
    {
        var bundledAdb = Path.Combine(ProjectRoot, "runtime", "adb", "adb.exe");
        if (File.Exists(bundledAdb)) AdbExe = bundledAdb;

        var bundledSpft = Path.Combine(ProjectRoot, "runtime", "spflashtool");
        if (File.Exists(Path.Combine(bundledSpft, "SPFlashToolV6.exe"))) SpftDir = bundledSpft;

        var bundledMagisk = Path.Combine(ProjectRoot, "runtime", "magisk", $"Magisk-{TargetMagiskVersion}.apk");
        if (File.Exists(bundledMagisk)) MagiskApk = bundledMagisk;
    }

    private void ResolveDriverInstaller()
    {
        var candidates = new List<string>
        {
            Path.Combine(ProjectRoot, "runtime", "driver", "MTK Driver Setup.exe"),
            Path.Combine(ProjectRoot, "runtime", "spflashtool", "Driver", "MTK Driver Setup.exe")
        };
        if (!string.IsNullOrWhiteSpace(SpftDir))
            candidates.Add(Path.Combine(SpftDir, "Driver", "MTK Driver Setup.exe"));

        DriverInstallerExe = candidates.FirstOrDefault(File.Exists);
    }

    private static string ResolveProjectRoot()
    {
        var dir = new DirectoryInfo(AppContext.BaseDirectory);
        while (dir is not null)
        {
            if (File.Exists(Path.Combine(dir.FullName, "version.properties")) &&
                Directory.Exists(Path.Combine(dir.FullName, "scripts")))
            {
                return dir.FullName;
            }
            dir = dir.Parent;
        }

        // Fallback: текущая рабочая директория (удобно при dotnet run из корня проекта)
        var cwd = new DirectoryInfo(Directory.GetCurrentDirectory());
        while (cwd is not null)
        {
            if (File.Exists(Path.Combine(cwd.FullName, "version.properties")) &&
                Directory.Exists(Path.Combine(cwd.FullName, "scripts")))
            {
                return cwd.FullName;
            }
            cwd = cwd.Parent;
        }

        return Directory.GetCurrentDirectory();
    }

    private void LoadVersionProperties()
    {
        var path = Path.Combine(ProjectRoot, "version.properties");
        if (!File.Exists(path)) return;

        foreach (var raw in File.ReadAllLines(path))
        {
            var line = raw.Trim();
            if (string.IsNullOrEmpty(line) || line.StartsWith('#')) continue;
            var idx = line.IndexOf('=');
            if (idx <= 0) continue;

            var key = line[..idx].Trim();
            var val = line[(idx + 1)..].Trim();
            if (key.Equals("APP_VERSION", StringComparison.OrdinalIgnoreCase) || key.Equals("VERSION", StringComparison.OrdinalIgnoreCase)) ToolkitVersion = val;
            else if (key.Equals("MAGISK_VERSION", StringComparison.OrdinalIgnoreCase)) TargetMagiskVersion = val;
        }
    }

    private void LoadLocalPaths()
    {
        var localPathsFile = Path.Combine(ProjectRoot, "local.paths.json");
        if (!File.Exists(localPathsFile)) return;

        try
        {
            using var doc = JsonDocument.Parse(File.ReadAllText(localPathsFile));
            var root = doc.RootElement;
            if (root.TryGetProperty("adb", out var adbEl) && !string.IsNullOrWhiteSpace(adbEl.GetString()))
                AdbExe = adbEl.GetString()!;
            if (root.TryGetProperty("spft_dir", out var spftEl))
                SpftDir = spftEl.GetString();
            if (root.TryGetProperty("magisk_apk", out var magiskEl))
                MagiskApk = magiskEl.GetString();
        }
        catch
        {
            // Игнорируем повреждённый пользовательский конфиг, оставляя дефолт PATH
        }
    }

    public (bool hasBackup, string summary) CheckStockBackup()
    {
        if (!Directory.Exists(BackupsStockDir))
            return (false, "Папка backups/stock отсутствует");

        string[] required =
        [
            "boot_a.img", "boot_b.img",
            "init_boot_a.img", "init_boot_b.img",
            "vbmeta_a.img", "vbmeta_b.img",
            "preloader_a.bin", "preloader_b.bin"
        ];

        var present = required.Count(f => File.Exists(Path.Combine(BackupsStockDir, f)));
        var withSha = required.Count(f => File.Exists(Path.Combine(BackupsStockDir, f + ".sha256")));

        if (present == required.Length)
            return (true, $"Готов ({present}/{required.Length} разделов, SHA-256: {withSha})");

        if (present > 0)
            return (false, $"Неполный ({present}/{required.Length} разделов)");

        return (false, "Сделайте Readback до прошивки");
    }
}
