using System.Windows;
using System.Windows.Media;
using System.Windows.Threading;
using RG477MToolkit.Models;
using RG477MToolkit.Services;
using Wpf.Ui.Controls;

namespace RG477MToolkit;

public partial class MainWindow : FluentWindow
{
    private readonly ToolkitPaths _paths;
    private readonly DeviceMonitorService _monitor;
    private readonly ScriptRunnerService _runner;
    private readonly DriverService _driverService;
    private readonly DispatcherTimer _pollTimer;
    private bool _isBusy;
    private bool _isPolling;
    private bool _isEnglish;
    private DeviceStateSnapshot _latestState = new();
    private DriverStatus _driverStatus = new();

    public MainWindow()
    {
        InitializeComponent();

        _paths = new ToolkitPaths();
        _monitor = new DeviceMonitorService(_paths);
        _runner = new ScriptRunnerService(_paths);
        _driverService = new DriverService();

        ApplyLanguage();

        _pollTimer = new DispatcherTimer
        {
            Interval = TimeSpan.FromMilliseconds(1600)
        };
        _pollTimer.Tick += async (_, _) => await RefreshDeviceStateAsync();
        Loaded += async (_, _) =>
        {
            await CheckDriversStatusAsync();
            await RefreshDeviceStateAsync();
            _pollTimer.Start();
        };
        Closed += (_, _) => _pollTimer.Stop();
    }

    private async Task CheckDriversStatusAsync()
    {
        _driverStatus = await _driverService.CheckDriversAsync();
        UpdateDriverUi();
    }

    private void UpdateDriverUi()
    {
        if (_driverStatus.AllReady)
        {
            DriverBanner.Visibility = Visibility.Collapsed;
            DriverOkBadge.Visibility = Visibility.Visible;
            DriverOkBadgeText.Text = _isEnglish ? "Drivers: OK" : "Драйверы: OK";
        }
        else
        {
            DriverOkBadge.Visibility = Visibility.Collapsed;
            DriverBanner.Visibility = Visibility.Visible;
            DriverBannerTitle.Text = _isEnglish
                ? "MediaTek VCOM / ADB Drivers Required"
                : "Требуются драйверы MediaTek VCOM / ADB";
            DriverBannerDesc.Text = _isEnglish
                ? "Drivers were not detected on this PC. Install once to enable Readback and flashing."
                : "Драйверы не найдены в системе. Установите их один раз для работы Readback и прошивки.";
            BtnInstallDrivers.Content = _isEnglish ? "Install Drivers" : "Установить драйверы";
        }
    }

    private void ApplyLanguage()
    {
        if (_isEnglish)
        {
            BtnLangToggle.Content = "RU";
            DeviceCardTitleText.Text = "Device Status";
            LabelFirmwareCaption.Text = "Firmware";
            LabelSlotCaption.Text = "Active Slot";
            LabelMagiskCaption.Text = "Magisk";
            LabelBackupCaption.Text = "Stock Backup";
            GuideTitleText.Text = "Connection Guide (MT6897)";
            GuideAdbText.Text = "• Normal mode (ADB): enable USB debugging on the handheld and plug in USB-C.";
            GuidePreloaderText.Text = "• Auto-Preloader (recommended): during flashing over ADB, the device auto-reboots and SP Flash Tool catches Preloader without button holds.";
            GuideBromText.Text = "• Manual BROM (unbrick): power off completely, hold Vol+ and Vol- (do NOT press Power!) and plug in USB-C.";
            WizardTitleText.Text = "Root & Performance Setup Wizard";
            ToolkitSubtitleText.Text = $"Anbernic RG477M • Stock V1.32 • Magisk {_paths.TargetMagiskVersion} • Toolkit v{_paths.ToolkitVersion}";
            Step1TitleText.Text = "1. Stock Readback Backup";
            Step1DescText.Text = "Reads back stock boot, init_boot, vbmeta, preloader (A/B) and seccfg with SHA-256 verification before any writes.";
            BtnReadbackDryRun.Content = "Generate XML";
            BtnReadbackRun.Content = "Run Readback";
            Step2TitleText.Text = $"2. Patch & Flash Magisk {_paths.TargetMagiskVersion} (No Data Wipe)";
            Step2DescText.Text = "Patches stock init_boot with headless overlay setup and re-signs vbmeta with AOSP testkey for locked bootloader.";
            BtnPatchMagisk.Content = "Build Patch";
            BtnFlashDryRun.Content = "Dry-Run Flash";
            BtnFlashMagisk.Content = "Flash Magisk";
            Step3TitleText.Text = "3. Performance & Frame Pacing Module (Balance / Game)";
            Step3DescText.Text = "Unlocks 900 MHz GPU cap in Balance, tunes Mali-G615 GED boost and eliminates 1s SurfaceFlinger flicker while keeping thermal_core active.";
            BtnBuildModule.Content = "Build ZIP";
            BtnModuleDryRun.Content = "Dry-Run";
            BtnInstallPerfModule.Content = "Install Module";
            BtnUninstallPerfModule.Content = "Uninstall";
            Step4TitleText.Text = "1-Click Stock V1.32 Rollback";
            Step4DescText.Text = "Restores original vbmeta and init_boot from local Readback backup.";
            BtnRestoreDryRun.Content = "Dry-Run";
            BtnRestoreStock.Content = "Restore Stock";
            LogExpander.Header = "Operation Console (click to expand)";
            BtnCopyLog.Content = "Copy Log";
            BtnClearLog.Content = "Clear";
        }
        else
        {
            BtnLangToggle.Content = "EN";
            DeviceCardTitleText.Text = "Состояние консоли";
            LabelFirmwareCaption.Text = "Прошивка";
            LabelSlotCaption.Text = "Активный слот";
            LabelMagiskCaption.Text = "Magisk";
            LabelBackupCaption.Text = "Сток-бэкап";
            GuideTitleText.Text = "Памятка подключения (MT6897)";
            GuideAdbText.Text = "• Обычный режим (ADB): включите отладку по USB на консоли и подключите кабель.";
            GuidePreloaderText.Text = "• Авто-Preloader (рекомендуется): при запуске прошивки по ADB консоль сама перезагрузится и подхватится SP Flash Tool без зажатия кнопок.";
            GuideBromText.Text = "• Ручной BROM (если не загружается): полностью выключите консоль, зажмите Vol+ и Vol- (НЕ нажимайте Power!) и вставьте USB-C.";
            WizardTitleText.Text = "Мастер установки и оптимизации";
            ToolkitSubtitleText.Text = $"Anbernic RG477M • Stock V1.32 • Magisk {_paths.TargetMagiskVersion} • Toolkit v{_paths.ToolkitVersion}";
            Step1TitleText.Text = "1. Readback-бэкап стоковых разделов";
            Step1DescText.Text = "Сохраняет boot, init_boot, vbmeta, preloader (A/B) и seccfg с проверкой SHA-256 перед любыми изменениями.";
            BtnReadbackDryRun.Content = "Генерация XML";
            BtnReadbackRun.Content = "Снять бэкап";
            Step2TitleText.Text = $"2. Патч и установка Magisk {_paths.TargetMagiskVersion} (без сброса данных)";
            Step2DescText.Text = "Патчит родной init_boot с headless-настройкой и подписывает vbmeta тем же AOSP testkey для заблокированного загрузчика.";
            BtnPatchMagisk.Content = "Собрать патч";
            BtnFlashDryRun.Content = "Dry-Run прошивки";
            BtnFlashMagisk.Content = "Прошить Magisk";
            Step3TitleText.Text = "3. Модуль производительности GPU/CPU (Баланс / Игровой)";
            Step3DescText.Text = "Снимает лимит 900 МГц в Балансе, ускоряет GED-буст Mali-G615 и убирает 1-сек мерцания SurfaceFlinger при сохранении термозащиты.";
            BtnBuildModule.Content = "Собрать ZIP";
            BtnModuleDryRun.Content = "Dry-Run";
            BtnInstallPerfModule.Content = "Установить модуль";
            BtnUninstallPerfModule.Content = "Удалить";
            Step4TitleText.Text = "Откат на чистый сток V1.32";
            Step4DescText.Text = "Возвращает оригинальные vbmeta и init_boot из локального Readback-бэкапа в 1 клик.";
            BtnRestoreDryRun.Content = "Dry-Run";
            BtnRestoreStock.Content = "Откатить на сток";
            LogExpander.Header = "Консоль операций (нажмите, чтобы развернуть)";
            BtnCopyLog.Content = "Копировать лог";
            BtnClearLog.Content = "Очистить";
        }
    }

    private async Task RefreshDeviceStateAsync()
    {
        if (_isPolling || _isBusy) return;
        _isPolling = true;
        try
        {
            _latestState = await _monitor.PollOnceAsync();
            ApplyState(_latestState);
        }
        finally
        {
            _isPolling = false;
        }
    }

    private void ApplyState(DeviceStateSnapshot state)
    {
        DeviceCanvas.UpdateState(state);
        ModeDetailText.Text = state.ModeDetail;
        FirmwareText.Text = state.Firmware;
        SlotText.Text = state.ActiveSlot;
        MagiskText.Text = state.MagiskStatus;
        BackupText.Text = state.BackupSummary;

        StatusBadgeText.Text = state.ModeTitle;
        switch (state.Mode)
        {
            case ConnectionMode.AdbOnline:
                StatusBadge.Background = new SolidColorBrush(Color.FromRgb(0x14, 0x53, 0x2D));
                StatusBadgeText.Foreground = new SolidColorBrush(Color.FromRgb(0x86, 0xEF, 0xAC));
                break;
            case ConnectionMode.PreloaderVcom:
            case ConnectionMode.BromMode:
                StatusBadge.Background = new SolidColorBrush(Color.FromRgb(0x78, 0x35, 0x0F));
                StatusBadgeText.Foreground = new SolidColorBrush(Color.FromRgb(0xFD, 0xE6, 0x8A));
                break;
            case ConnectionMode.UsbDescriptorError:
                StatusBadge.Background = new SolidColorBrush(Color.FromRgb(0x7F, 0x1D, 0x1D));
                StatusBadgeText.Foreground = new SolidColorBrush(Color.FromRgb(0xFC, 0xA5, 0xA5));
                break;
            default:
                StatusBadge.Background = new SolidColorBrush(Color.FromRgb(0x27, 0x27, 0x2A));
                StatusBadgeText.Foreground = new SolidColorBrush(Color.FromRgb(0xA1, 0xA1, 0xAA));
                break;
        }
    }

    private async Task ExecuteScriptAsync(string scriptPath, string args, bool expandLog = true)
    {
        if (_isBusy)
        {
            AppendLog("[INFO] " + (_isEnglish ? "Wait for the current operation to finish." : "Дождитесь завершения текущей операции."));
            return;
        }

        _isBusy = true;
        SetActionButtonsEnabled(false);
        if (expandLog) LogExpander.IsExpanded = true;

        try
        {
            await _runner.RunPowerShellAsync(scriptPath, args, AppendLog);
        }
        catch (Exception ex)
        {
            AppendLog("[ERR] " + ex.Message);
        }
        finally
        {
            _isBusy = false;
            SetActionButtonsEnabled(true);
            await RefreshDeviceStateAsync();
        }
    }

    private void SetActionButtonsEnabled(bool enabled)
    {
        BtnReadbackDryRun.IsEnabled = enabled;
        BtnReadbackRun.IsEnabled = enabled;
        BtnPatchMagisk.IsEnabled = enabled;
        BtnFlashDryRun.IsEnabled = enabled;
        BtnFlashMagisk.IsEnabled = enabled;
        BtnBuildModule.IsEnabled = enabled;
        BtnModuleDryRun.IsEnabled = enabled;
        BtnInstallPerfModule.IsEnabled = enabled;
        BtnUninstallPerfModule.IsEnabled = enabled;
        BtnRestoreDryRun.IsEnabled = enabled;
        BtnRestoreStock.IsEnabled = enabled;
    }

    private void AppendLog(string line)
    {
        Dispatcher.Invoke(() =>
        {
            LogTextBox.AppendText(line + Environment.NewLine);
            LogTextBox.ScrollToEnd();
        });
    }

    private void BtnLangToggle_Click(object sender, RoutedEventArgs e)
    {
        _isEnglish = !_isEnglish;
        ApplyLanguage();
        UpdateDriverUi();
    }

    private async void BtnInstallDrivers_Click(object sender, RoutedEventArgs e)
    {
        BtnInstallDrivers.IsEnabled = false;
        LogExpander.IsExpanded = true;
        try
        {
            var (started, msg) = await _driverService.LaunchDriverInstallerAsync(_paths.DriverInstallerExe, _isEnglish);
            AppendLog((started ? "[ OK ] " : "[WARN] ") + msg);
            await CheckDriversStatusAsync();
        }
        finally
        {
            BtnInstallDrivers.IsEnabled = true;
        }
    }

    private async void BtnReadbackDryRun_Click(object sender, RoutedEventArgs e)
        => await ExecuteScriptAsync(_paths.ReadbackScript, "-GenerateOnly");

    private async void BtnReadbackRun_Click(object sender, RoutedEventArgs e)
        => await ExecuteScriptAsync(_paths.ReadbackScript, "");

    private async void BtnPatchMagisk_Click(object sender, RoutedEventArgs e)
        => await ExecuteScriptAsync(_paths.PatchMagiskScript, "");

    private async void BtnFlashDryRun_Click(object sender, RoutedEventArgs e)
        => await ExecuteScriptAsync(_paths.FlashMagiskScript, "");

    private async void BtnFlashMagisk_Click(object sender, RoutedEventArgs e)
    {
        if (!_latestState.HasStockBackup)
        {
            System.Windows.MessageBox.Show(
                _isEnglish
                    ? "Run a full Stock Readback Backup first (Step 1)."
                    : "Сначала выполните полный Readback-бэкап стоковых разделов (Шаг 1).",
                _isEnglish ? "Backup not found" : "Бэкап не найден",
                System.Windows.MessageBoxButton.OK,
                System.Windows.MessageBoxImage.Warning);
            return;
        }

        var confirm = System.Windows.MessageBox.Show(
            _isEnglish
                ? "Write patched init_boot and vbmeta (testkey) to RG477M storage?\n\nIf connected via ADB, the device will auto-reboot into Preloader for flashing."
                : "Записать пропатченный init_boot и vbmeta (testkey) в память RG477M?\n\nЕсли устройство подключено по ADB, оно автоматически перезагрузится в Preloader для прошивки.",
            _isEnglish ? "Flash Confirmation" : "Подтверждение прошивки",
            System.Windows.MessageBoxButton.YesNo,
            System.Windows.MessageBoxImage.Warning);

        if (confirm != System.Windows.MessageBoxResult.Yes) return;
        await ExecuteScriptAsync(_paths.FlashMagiskScript, "-Execute");
    }

    private async void BtnBuildModule_Click(object sender, RoutedEventArgs e)
        => await ExecuteScriptAsync(_paths.BuildPerfModuleScript, "");

    private async void BtnModuleDryRun_Click(object sender, RoutedEventArgs e)
        => await ExecuteScriptAsync(_paths.InstallPerfModuleScript, "-DryRun");

    private async void BtnInstallPerfModule_Click(object sender, RoutedEventArgs e)
    {
        var confirm = System.Windows.MessageBox.Show(
            _isEnglish
                ? "Install rg477m_perf_tuning Magisk module onto the connected RG477M?"
                : "Установить Magisk-модуль производительности rg477m_perf_tuning на подключённый RG477M?",
            _isEnglish ? "Install Module" : "Установка модуля Magisk",
            System.Windows.MessageBoxButton.YesNo,
            System.Windows.MessageBoxImage.Question);

        if (confirm != System.Windows.MessageBoxResult.Yes) return;
        await ExecuteScriptAsync(_paths.InstallPerfModuleScript, "-Execute");
    }

    private async void BtnUninstallPerfModule_Click(object sender, RoutedEventArgs e)
    {
        var confirm = System.Windows.MessageBox.Show(
            _isEnglish
                ? "Mark rg477m_perf_tuning module for removal on next reboot?"
                : "Пометить модуль rg477m_perf_tuning на удаление при следующей перезагрузке?",
            _isEnglish ? "Uninstall Module" : "Удаление модуля",
            System.Windows.MessageBoxButton.YesNo,
            System.Windows.MessageBoxImage.Warning);

        if (confirm != System.Windows.MessageBoxResult.Yes) return;
        await ExecuteScriptAsync(_paths.InstallPerfModuleScript, "-Execute -Uninstall");
    }

    private async void BtnRestoreDryRun_Click(object sender, RoutedEventArgs e)
        => await ExecuteScriptAsync(_paths.RestoreScript, "");

    private async void BtnRestoreStock_Click(object sender, RoutedEventArgs e)
    {
        var confirm = System.Windows.MessageBox.Show(
            _isEnglish
                ? "Restore original stock vbmeta and init_boot from backups/stock/?"
                : "Восстановить оригинальные стоковые vbmeta и init_boot из backups/stock/?",
            _isEnglish ? "Stock Rollback Confirmation" : "Подтверждение отката на сток",
            System.Windows.MessageBoxButton.YesNo,
            System.Windows.MessageBoxImage.Warning);

        if (confirm != System.Windows.MessageBoxResult.Yes) return;
        await ExecuteScriptAsync(_paths.RestoreScript, "-Execute");
    }

    private void BtnCopyLog_Click(object sender, RoutedEventArgs e)
    {
        if (!string.IsNullOrEmpty(LogTextBox.Text))
            Clipboard.SetText(LogTextBox.Text);
    }

    private void BtnClearLog_Click(object sender, RoutedEventArgs e)
        => LogTextBox.Clear();
}
