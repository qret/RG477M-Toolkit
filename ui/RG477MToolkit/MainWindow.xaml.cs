using System.IO;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
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
    private readonly string? _screenshotDir;
    private bool _captureStarted;
    private bool _isBusy;
    private bool _isPolling;
    private bool _isEnglish;
    private DeviceStateSnapshot _latestState = new();
    private DriverStatus _driverStatus = new();

    public MainWindow() : this(null)
    {
    }

    public MainWindow(string? screenshotDir)
    {
        _screenshotDir = string.IsNullOrWhiteSpace(screenshotDir) ? null : screenshotDir;
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
            if (_screenshotDir is not null)
            {
                Width = 1080;
                Height = 835;
                return;
            }
            await CheckDriversStatusAsync();
            await RefreshDeviceStateAsync();
            _pollTimer.Start();
        };
        ContentRendered += async (_, _) =>
        {
            if (_screenshotDir is null || _captureStarted) return;
            _captureStarted = true;
            await CaptureAllScreenshotsAsync(_screenshotDir);
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
        DeviceCanvas.UpdateState(state, _isEnglish);
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
        ApplyState(_latestState);
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

    private async Task CaptureAllScreenshotsAsync(string outputDir)
    {
        Directory.CreateDirectory(outputDir);
        LogExpander.IsExpanded = false;
        await Task.Delay(250);

        foreach (bool isEn in new[] { false, true })
        {
            string lang = isEn ? "en" : "ru";
            _isEnglish = isEn;
            ApplyLanguage();

            var scenarios = new (string Slug, DriverStatus Drivers, DeviceStateSnapshot State)[]
            {
                (
                    "disconnected",
                    new DriverStatus { HasMtkVcom = false, HasAdbUsb = false },
                    new DeviceStateSnapshot
                    {
                        Mode = ConnectionMode.Disconnected,
                        ModeTitle = isEn ? "Disconnected" : "Устройство не подключено",
                        ModeDetail = isEn ? "Connect RG477M via USB-C (ADB or Preloader/BROM)" : "Подключите RG477M по USB-C (ADB или Preloader/BROM)",
                        Model = "—",
                        Firmware = "—",
                        ActiveSlot = "—",
                        MagiskStatus = isEn ? "Not checked" : "Не проверено",
                        BackupSummary = isEn ? "Not found" : "Бэкап не найден"
                    }
                ),
                (
                    "adb-online",
                    new DriverStatus { HasMtkVcom = true, HasAdbUsb = true },
                    new DeviceStateSnapshot
                    {
                        Mode = ConnectionMode.AdbOnline,
                        ModeTitle = isEn ? "ADB Online" : "Подключено (ADB)",
                        ModeDetail = isEn ? "RG477M • Stock V1.32 • Ready" : "RG477M • Сток V1.32 • Готово к работе",
                        Model = "RG477M",
                        Firmware = "V1.32 (V654202605282152)",
                        ActiveSlot = "_b",
                        MagiskStatus = "v31.1 (root)",
                        IsSupportedBuild = true,
                        HasStockBackup = true,
                        BackupSummary = "7/7 SHA-256 OK"
                    }
                ),
                (
                    "preloader",
                    new DriverStatus { HasMtkVcom = true, HasAdbUsb = true },
                    new DeviceStateSnapshot
                    {
                        Mode = ConnectionMode.PreloaderVcom,
                        ModeTitle = "PreLoader VCOM (COM5)",
                        ModeDetail = isEn ? "SP Flash Tool V6 ready • Do not unplug USB" : "Готов к SP Flash Tool V6 • Не отключайте кабель",
                        Model = "RG477M",
                        Firmware = "V1.32",
                        ActiveSlot = "_b",
                        MagiskStatus = "—",
                        ComPort = "COM5",
                        HasStockBackup = true,
                        BackupSummary = "7/7 SHA-256 OK"
                    }
                ),
                (
                    "error-code43",
                    new DriverStatus { HasMtkVcom = false, HasAdbUsb = true },
                    new DeviceStateSnapshot
                    {
                        Mode = ConnectionMode.UsbDescriptorError,
                        ModeTitle = isEn ? "USB Code 43" : "Ошибка USB (Код 43)",
                        ModeDetail = isEn
                            ? "Device descriptor request failed — hold ONLY Vol+ and Vol- (do NOT press Power)"
                            : "Сбой дескриптора USB — зажмите ТОЛЬКО Vol+ и Vol- (НЕ нажимайте Power)",
                        Model = "—",
                        Firmware = "—",
                        ActiveSlot = "—",
                        MagiskStatus = "—",
                        HasStockBackup = true,
                        BackupSummary = "7/7 SHA-256 OK"
                    }
                )
            };

            foreach (var (slug, drivers, state) in scenarios)
            {
                _driverStatus = drivers;
                _latestState = state;
                UpdateDriverUi();
                ApplyState(state);
                UpdateLayout();
                await Task.Delay(150);

                if (Content is FrameworkElement root)
                {
                    SaveElementPng(root, Path.Combine(outputDir, $"ui-{slug}-{lang}.png"));
                }
            }
        }

        Application.Current.Shutdown(0);
    }

    private static void SaveElementPng(FrameworkElement root, string path)
    {
        root.UpdateLayout();
        int width = Math.Max(1, (int)Math.Ceiling(root.ActualWidth));
        int height = Math.Max(1, (int)Math.Ceiling(root.ActualHeight));

        var dv = new DrawingVisual();
        using (DrawingContext dc = dv.RenderOpen())
        {
            dc.DrawRectangle(new SolidColorBrush(Color.FromRgb(0x18, 0x18, 0x1B)), null, new Rect(0, 0, width, height));
            dc.DrawRectangle(new VisualBrush(root), null, new Rect(0, 0, width, height));
        }

        var rtb = new RenderTargetBitmap(width, height, 96, 96, PixelFormats.Pbgra32);
        rtb.Render(dv);

        var encoder = new PngBitmapEncoder();
        encoder.Frames.Add(BitmapFrame.Create(rtb));
        using FileStream fs = File.Create(path);
        encoder.Save(fs);
    }
}
