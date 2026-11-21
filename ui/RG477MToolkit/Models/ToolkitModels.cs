namespace RG477MToolkit.Models;

public enum ConnectionMode
{
    Disconnected,
    AdbOnline,
    PreloaderVcom,
    BromMode,
    UsbDescriptorError
}

public enum PerfModuleState
{
    Unknown,
    NotInstalled,
    InstalledUpToDate,
    UpdateAvailable,
    PendingRemoval
}

public sealed class DeviceStateSnapshot
{
    public ConnectionMode Mode { get; init; } = ConnectionMode.Disconnected;
    public string ModeTitle { get; init; } = "Устройство не подключено";
    public string ModeDetail { get; init; } = "Подключите RG477M по USB-C (ADB или Preloader/BROM)";
    public string Model { get; init; } = "—";
    public string Firmware { get; init; } = "—";
    public string ActiveSlot { get; init; } = "—";
    public string MagiskStatus { get; init; } = "Не проверено";
    public bool IsMagiskInstalled { get; init; }
    public PerfModuleState ModuleState { get; init; } = PerfModuleState.Unknown;
    public string InstalledModuleVersion { get; init; } = "";
    public bool IsSupportedBuild { get; init; }
    public bool HasStockBackup { get; init; }
    public string BackupSummary { get; init; } = "Бэкап не найден";
    public string ComPort { get; init; } = "";
}
