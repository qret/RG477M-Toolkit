using System.Diagnostics;
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
            BtnInstallDrivers.ToolTip = _isEnglish
                ? "Launches the MediaTek USB VCOM / ADB driver installer so Windows can recognize your console during backup and flashing."
                : "Запустит установщик драйверов MediaTek USB VCOM / ADB, чтобы компьютер корректно видел консоль при бэкапе и прошивке.";
        }
    }

    private void ApplyLanguage()
    {
        if (_isEnglish)
        {
            BtnLangToggle.Content = "RU";
            BtnLangToggle.ToolTip = "Switch the application interface between Russian and English.";
            DeviceCardTitleText.Text = "Device Status";
            LabelFirmwareCaption.Text = "Firmware";
            LabelSlotCaption.Text = "Active Slot";
            LabelMagiskCaption.Text = "Magisk";
            LabelBackupCaption.Text = "Stock Backup";
            GuideTitleText.Text = "Connection Guide (MT6897)";
            GuideAdbText.Text = "• Normal mode (ADB): enable USB debugging on the handheld and plug in USB-C.";
            GuidePreloaderText.Text = "• Auto-Preloader (recommended): during backup, flashing, or rollback over ADB, the handheld auto-reboots and SP Flash Tool catches Preloader without button holds.";
            BtnRebootPreloader.Content = "Reboot to Preloader / BROM (ADB)";
            BtnRebootPreloader.ToolTip = "Sends 'adb reboot' to the connected handheld so MediaTek Preloader VCOM appears (~2-3s window for SP Flash Tool). Steps 1, 2, and 4 also do this automatically.";
            WizardTitleText.Text = "Root & Performance Setup Wizard";
            ToolkitSubtitleText.Text = $"Anbernic RG477M • Stock V1.32 • Magisk {_paths.TargetMagiskVersion} • Toolkit v{_paths.ToolkitVersion}";
            Step1TitleText.Text = "1. Stock Firmware Backup";
            Step1DescText.Text = "Saves factory system partitions to your PC with SHA-256 verification. Changes nothing on the handheld and guarantees safe rollback.";
            Step2TitleText.Text = $"2. Install Magisk {_paths.TargetMagiskVersion} Root (No Data Wipe)";
            Step2DescText.Text = "Automatically builds the patch from your backup and installs Magisk without erasing games, saves, or settings.";
            Step3TitleText.Text = "3. RG477M Optimization Module (FPS, Fan, Audio, Display)";
            Step3DescText.Text = "Smooth 60 FPS in Balance mode, cooler Game mode, quiet smooth fan curves, no display flicker, and no speaker clicks/pops — keeping stock thermal protection active.";
            BtnUninstallPerfModule.Content = "Uninstall";
            BtnUninstallPerfModule.ToolTip = "Marks the optimization module for removal. After the next reboot the console returns to stock performance, fan, display, and audio settings (Magisk root stays intact).";
            Step4TitleText.Text = "1-Click Stock V1.32 Rollback";
            Step4DescText.Text = "Restores original factory partitions from your local backup and completely removes root (Magisk). Your games and data stay intact.";
            BtnRestoreStock.Content = "Restore Stock";
            BtnRestoreStock.ToolTip = "Flashes your original factory init_boot and vbmeta from the saved PC backup and completely removes Magisk root. Your games and user files stay untouched. If the handheld does not boot into Android, power it off completely, hold Vol- + Vol+ (no Power) and plug USB-C.";
            LogExpander.Header = "Operation Console (click to expand)";
            BtnCopyLog.Content = "Copy Log";
            BtnCopyLog.ToolTip = "Copies the full operation log below to the Windows clipboard.";
            BtnClearLog.Content = "Clear";
            BtnClearLog.ToolTip = "Clears text from the operation log window.";
        }
        else
        {
            BtnLangToggle.Content = "EN";
            BtnLangToggle.ToolTip = "Переключить язык интерфейса программы (русский / английский).";
            DeviceCardTitleText.Text = "Состояние консоли";
            LabelFirmwareCaption.Text = "Прошивка";
            LabelSlotCaption.Text = "Активный слот";
            LabelMagiskCaption.Text = "Magisk";
            LabelBackupCaption.Text = "Сток-бэкап";
            GuideTitleText.Text = "Памятка подключения (MT6897)";
            GuideAdbText.Text = "• Обычный режим (ADB): включите отладку по USB на консоли и подключите кабель.";
            GuidePreloaderText.Text = "• Авто-Preloader (рекомендуется): при бэкапе, прошивке и откате по ADB консоль сама перезагрузится и подхватится SP Flash Tool без зажатия кнопок.";
            BtnRebootPreloader.Content = "Перезагрузить в Preloader / BROM (ADB)";
            BtnRebootPreloader.ToolTip = "Отправляет 'adb reboot' на подключённую консоль, чтобы появился порт MediaTek Preloader VCOM (окно ~2–3 с для SP Flash Tool). Шаги 1, 2 и 4 делают это автоматически.";
            WizardTitleText.Text = "Мастер установки и оптимизации";
            ToolkitSubtitleText.Text = $"Anbernic RG477M • Stock V1.32 • Magisk {_paths.TargetMagiskVersion} • Toolkit v{_paths.ToolkitVersion}";
            Step1TitleText.Text = "1. Резервная копия заводской прошивки (бэкап)";
            Step1DescText.Text = "Сохраняет заводские системные разделы на компьютер с проверкой SHA-256. Ничего не меняет на консоли и нужен для безопасного отката.";
            Step2TitleText.Text = $"2. Установка root-доступа Magisk {_paths.TargetMagiskVersion} (без сброса данных)";
            Step2DescText.Text = "Автоматически подготовит патч из вашего бэкапа и установит Magisk без удаления игр, сохранений и настроек.";
            Step3TitleText.Text = "3. Модуль оптимизации RG477M (FPS, кулер, звук, экран)";
            Step3DescText.Text = "Стабильные 60 FPS в «Балансе», меньше нагрева в «Игровом», тихий плавный вентилятор, без мерцаний экрана и щелчков динамиков. Термозащита остаётся включённой.";
            BtnUninstallPerfModule.Content = "Удалить";
            BtnUninstallPerfModule.ToolTip = "Удалит модуль оптимизации с консоли: после следующей перезагрузки вернутся заводские настройки частот, вентилятора, экрана и звука (сам root Magisk останется).";
            Step4TitleText.Text = "Откат на чистый сток V1.32";
            Step4DescText.Text = "Возвращает заводские системные разделы из вашей резервной копии и полностью удаляет root (Magisk). Игры и файлы сохранятся.";
            BtnRestoreStock.Content = "Откатить на сток";
            BtnRestoreStock.ToolTip = "Прошьёт обратно оригинальные заводские разделы (init_boot и vbmeta) из сохранённого бэкапа и полностью уберёт root Magisk. Ваши игры и файлы сохранятся. Если консоль не загружается в Android — выключите её, зажмите Vol- и Vol+ (без Power) и подключите USB-C.";
            LogExpander.Header = "Консоль операций (нажмите, чтобы развернуть)";
            BtnCopyLog.Content = "Копировать лог";
            BtnCopyLog.ToolTip = "Скопировать весь текст из консоли операций в буфер обмена Windows.";
            BtnClearLog.Content = "Очистить";
            BtnClearLog.ToolTip = "Очистить окно лога операций внизу.";
        }

        UpdateDriverUi();
        UpdateActionButtonsState(_latestState);
    }

    private async Task RefreshDeviceStateAsync()
    {
        if (_isPolling || _isBusy) return;
        _isPolling = true;
        try
        {
            _latestState = await _monitor.PollOnceAsync(_isEnglish);
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
        UpdateActionButtonsState(state);
    }

    private void UpdateActionButtonsState(DeviceStateSnapshot state)
    {
        BtnRebootPreloader.IsEnabled = !_isBusy && state.Mode == ConnectionMode.AdbOnline;
        if (state.HasStockBackup)
        {
            BtnReadbackRun.Appearance = ControlAppearance.Success;
            BtnReadbackRun.Content = _isEnglish ? "✓ Backup Ready" : "✓ Бэкап снят";
            BtnReadbackRun.ToolTip = _isEnglish
                ? "A full verified stock firmware backup is already saved in backups/stock. Click only if you want to create a fresh copy."
                : "Полная проверенная копия заводской прошивки уже сохранена на компьютере (backups/stock). Нажмите только если хотите снять бэкап заново.";
        }
        else
        {
            BtnReadbackRun.Appearance = ControlAppearance.Primary;
            BtnReadbackRun.Content = _isEnglish ? "Create Backup" : "Снять бэкап";
            BtnReadbackRun.ToolTip = _isEnglish
                ? "Saves factory system partitions from RG477M to your PC. Changes nothing on the console — required for safe rollback and Magisk installation."
                : "Сохранит заводские системные разделы RG477M на компьютер. Ничего не меняет на консоли — копия нужна, чтобы безопасно ставить Magisk и в любой момент откатиться на сток.";
        }

        if (state.IsMagiskInstalled)
        {
            BtnFlashMagisk.Appearance = ControlAppearance.Success;
            BtnFlashMagisk.Content = _isEnglish ? "✓ Magisk Installed" : "✓ Magisk установлен";
            BtnFlashMagisk.ToolTip = _isEnglish
                ? "Root access (Magisk) is already active on this handheld. Click to rebuild and re-flash Magisk if needed."
                : "Root-доступ (Magisk) уже установлен и работает на подключённой консоли. При необходимости можно переустановить заново по клику.";
        }
        else
        {
            BtnFlashMagisk.Appearance = ControlAppearance.Primary;
            BtnFlashMagisk.Content = _isEnglish ? "Install Magisk" : "Установить Magisk";
            BtnFlashMagisk.ToolTip = _isEnglish
                ? "Automatically prepares a patched boot image from your backup and installs Magisk root without wiping games, saves, or apps."
                : "Автоматически соберёт патч из вашего бэкапа и установит root-доступ Magisk. Ваши игры, сохранения и настройки останутся на месте.";
        }

        switch (state.ModuleState)
        {
            case PerfModuleState.InstalledUpToDate:
                BtnInstallPerfModule.Appearance = ControlAppearance.Success;
                BtnInstallPerfModule.Content = _isEnglish ? "✓ Installed" : "✓ Установлен";
                BtnInstallPerfModule.ToolTip = _isEnglish
                    ? $"Optimization module ({state.InstalledModuleVersion}) is already installed on this console. Click to reinstall over the current version."
                    : $"Модуль оптимизации ({state.InstalledModuleVersion}) уже установлен на консоли. Нажмите, если хотите переустановить его поверх.";
                BtnUninstallPerfModule.Visibility = Visibility.Visible;
                BtnUninstallPerfModule.Content = _isEnglish ? "Uninstall" : "Удалить";
                BtnUninstallPerfModule.IsEnabled = !_isBusy;
                break;

            case PerfModuleState.UpdateAvailable:
                BtnInstallPerfModule.Appearance = ControlAppearance.Primary;
                BtnInstallPerfModule.Content = _isEnglish ? "Update Module" : "Обновить модуль";
                BtnInstallPerfModule.ToolTip = _isEnglish
                    ? $"Installed version: {state.InstalledModuleVersion} → new version {_paths.BundledModuleVersion} is ready. Updates in place without data loss."
                    : $"На консоли установлена версия {state.InstalledModuleVersion} — доступна новая {_paths.BundledModuleVersion}. Обновит модуль без потери настроек.";
                BtnUninstallPerfModule.Visibility = Visibility.Visible;
                BtnUninstallPerfModule.Content = _isEnglish ? "Uninstall" : "Удалить";
                BtnUninstallPerfModule.IsEnabled = !_isBusy;
                break;

            case PerfModuleState.PendingRemoval:
                BtnInstallPerfModule.Appearance = ControlAppearance.Secondary;
                BtnInstallPerfModule.Content = _isEnglish ? "Reinstall" : "Установить заново";
                BtnInstallPerfModule.ToolTip = _isEnglish
                    ? "The module is marked for removal on next reboot. Click to cancel removal by reinstalling."
                    : "Модуль помечен на удаление при следующей перезагрузке. Нажмите, чтобы установить заново и отменить удаление.";
                BtnUninstallPerfModule.Visibility = Visibility.Visible;
                BtnUninstallPerfModule.Content = _isEnglish ? "Removal Pending" : "Удаление после ребута";
                BtnUninstallPerfModule.IsEnabled = false;
                break;

            default:
                BtnInstallPerfModule.Appearance = ControlAppearance.Primary;
                BtnInstallPerfModule.Content = _isEnglish ? "Install Module" : "Установить модуль";
                BtnInstallPerfModule.ToolTip = _isEnglish
                    ? "Installs the RG477M optimization module via Magisk: 60 FPS in Balance, quiet smooth fan curves, no display flicker, and no speaker clicks. Easily removable."
                    : "Установит пакет улучшений RG477M через Magisk: 60 FPS в «Балансе», тихий плавный вентилятор, без мерцаний экрана и щелчков динамиков. Легко удаляется кнопкой «Удалить».";
                BtnUninstallPerfModule.Visibility = Visibility.Collapsed;
                break;
        }
    }

    private async Task ExecuteScriptAsync(string scriptPath, string args, bool expandLog = true)
        => await ExecuteScriptSequenceAsync((scriptPath, args));

    private async Task ExecuteScriptSequenceAsync(params (string ScriptPath, string Args)[] steps)
    {
        if (_isBusy)
        {
            AppendLog("[INFO] " + (_isEnglish ? "Wait for the current operation to finish." : "Дождитесь завершения текущей операции."));
            return;
        }

        _isBusy = true;
        SetActionButtonsEnabled(false);
        LogExpander.IsExpanded = true;

        try
        {
            foreach (var (scriptPath, args) in steps)
            {
                var exitCode = await _runner.RunPowerShellAsync(scriptPath, args, AppendLog, _isEnglish);
                if (exitCode != 0)
                {
                    AppendLog("[ERR] " + (_isEnglish
                        ? $"Step aborted because script exited with code {exitCode}."
                        : $"Операция остановлена (код завершения: {exitCode})."));
                    break;
                }
            }
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
        BtnRebootPreloader.IsEnabled = enabled && _latestState.Mode == ConnectionMode.AdbOnline;
        BtnReadbackRun.IsEnabled = enabled;
        BtnFlashMagisk.IsEnabled = enabled;
        BtnInstallPerfModule.IsEnabled = enabled;
        BtnUninstallPerfModule.IsEnabled = enabled && _latestState.ModuleState != PerfModuleState.PendingRemoval;
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
        _ = RefreshDeviceStateAsync();
    }

    private async void BtnInstallDrivers_Click(object sender, RoutedEventArgs e)
    {
        if (_isBusy)
        {
            AppendLog("[INFO] " + (_isEnglish ? "Wait for the current operation to finish." : "Дождитесь завершения текущей операции."));
            return;
        }

        _isBusy = true;
        BtnInstallDrivers.IsEnabled = false;
        SetActionButtonsEnabled(false);
        LogExpander.IsExpanded = true;
        try
        {
            var (started, msg) = await _driverService.LaunchDriverInstallerAsync(_paths.DriverInstallerExe, _isEnglish);
            AppendLog((started ? "[ OK ] " : "[WARN] ") + msg);
            await CheckDriversStatusAsync();
        }
        finally
        {
            _isBusy = false;
            BtnInstallDrivers.IsEnabled = true;
            SetActionButtonsEnabled(true);
        }
    }

    private async void BtnReadbackRun_Click(object sender, RoutedEventArgs e)
    {
        if (_latestState.HasStockBackup)
        {
            var confirm = System.Windows.MessageBox.Show(
                _isEnglish
                    ? "A verified stock firmware backup already exists in backups/stock.\n\nDo you want to read back and overwrite it again?"
                    : "Полная проверенная резервная копия прошивки в backups/stock уже есть.\n\nСнять бэкап заново и перезаписать файлы?",
                _isEnglish ? "Backup Already Exists" : "Бэкап уже существует",
                System.Windows.MessageBoxButton.YesNo,
                System.Windows.MessageBoxImage.Question);

            if (confirm != System.Windows.MessageBoxResult.Yes) return;
        }

        await ExecuteScriptAsync(_paths.ReadbackScript, "");
    }

    private async void BtnFlashMagisk_Click(object sender, RoutedEventArgs e)
    {
        if (!_latestState.HasStockBackup)
        {
            System.Windows.MessageBox.Show(
                _isEnglish
                    ? "Run a full Stock Firmware Backup first (Step 1)."
                    : "Сначала снимите резервную копию заводской прошивки (Шаг 1).",
                _isEnglish ? "Backup Not Found" : "Бэкап не найден",
                System.Windows.MessageBoxButton.OK,
                System.Windows.MessageBoxImage.Warning);
            return;
        }

        string prompt = _latestState.IsMagiskInstalled
            ? (_isEnglish
                ? "Magisk is already installed on this handheld.\n\nRebuild the patch from your backup and re-flash Magisk over it?"
                : "Magisk уже установлен на этой консоли.\n\nПересобрать патч из бэкапа и прошить Magisk заново?")
            : (_isEnglish
                ? "Build the patch from your backup and install Magisk root onto RG477M (no data wipe)?\n\nIf connected via ADB, the device will automatically reboot into Preloader for flashing."
                : "Подготовить патч из вашего бэкапа и установить root-доступ Magisk на RG477M (без сброса данных)?\n\nЕсли консоль подключена по ADB, она сама перезагрузится в режим прошивки.");

        var confirm = System.Windows.MessageBox.Show(
            prompt,
            _isEnglish ? "Magisk Installation Confirmation" : "Подтверждение установки Magisk",
            System.Windows.MessageBoxButton.YesNo,
            System.Windows.MessageBoxImage.Warning);

        if (confirm != System.Windows.MessageBoxResult.Yes) return;

        await ExecuteScriptSequenceAsync(
            (_paths.PatchMagiskScript, ""),
            (_paths.FlashMagiskScript, "-Execute"));
    }

    private async void BtnInstallPerfModule_Click(object sender, RoutedEventArgs e)
    {
        if (!_latestState.IsMagiskInstalled)
        {
            System.Windows.MessageBox.Show(
                _isEnglish
                    ? "Root access (Magisk) is not active on the connected RG477M yet.\n\n1. Complete Step 2 (Install Magisk) if you haven't already.\n2. If Step 2 just finished, reboot the console once and wait for Android to load.\n3. Make sure the Step 2 button turns green (\"✓ Magisk Installed\"), then try again."
                    : "Root-доступ (Magisk) на подключённой консоли пока не активен.\n\n1. Если вы ещё не выполняли Шаг 2 — сначала установите Magisk.\n2. Если Шаг 2 только что завершился — перезагрузите консоль и дождитесь загрузки Android.\n3. Убедитесь, что кнопка Шага 2 стала зелёной («✓ Magisk установлен»), и повторите попытку.",
                _isEnglish ? "Magisk Root Required" : "Требуется root-доступ Magisk",
                System.Windows.MessageBoxButton.OK,
                System.Windows.MessageBoxImage.Warning);
            return;
        }

        string prompt = _latestState.ModuleState switch
        {
            PerfModuleState.InstalledUpToDate => _isEnglish
                ? $"Optimization module ({_latestState.InstalledModuleVersion}) is already installed.\n\nReinstall it over the current version?"
                : $"Модуль оптимизации ({_latestState.InstalledModuleVersion}) уже установлен.\n\nПереустановить его поверх текущей версии?",
            PerfModuleState.UpdateAvailable => _isEnglish
                ? $"Update optimization module from {_latestState.InstalledModuleVersion} to {_paths.BundledModuleVersion} on the connected RG477M?"
                : $"Обновить модуль оптимизации с {_latestState.InstalledModuleVersion} до {_paths.BundledModuleVersion} на подключённом RG477M?",
            _ => _isEnglish
                ? "Install the RG477M optimization module (60 FPS Balance, smooth fan, click-free speaker audio) onto the connected handheld?"
                : "Установить модуль оптимизации RG477M (60 FPS в «Балансе», тихий вентилятор, чистый звук без щелчков) на подключённую консоль?"
        };

        var confirm = System.Windows.MessageBox.Show(
            prompt,
            _isEnglish ? "Optimization Module" : "Модуль оптимизации",
            System.Windows.MessageBoxButton.YesNo,
            System.Windows.MessageBoxImage.Question);

        if (confirm != System.Windows.MessageBoxResult.Yes) return;
        await ExecuteScriptAsync(_paths.InstallPerfModuleScript, "-Execute");
    }

    private async void BtnUninstallPerfModule_Click(object sender, RoutedEventArgs e)
    {
        var confirm = System.Windows.MessageBox.Show(
            _isEnglish
                ? "Mark the RG477M optimization module for removal on next reboot?"
                : "Удалить модуль оптимизации RG477M (изменения отключатся после перезагрузки)?",
            _isEnglish ? "Uninstall Module" : "Удаление модуля",
            System.Windows.MessageBoxButton.YesNo,
            System.Windows.MessageBoxImage.Warning);

        if (confirm != System.Windows.MessageBoxResult.Yes) return;
        await ExecuteScriptAsync(_paths.InstallPerfModuleScript, "-Execute -Uninstall");
    }

    private async void BtnRestoreStock_Click(object sender, RoutedEventArgs e)
    {
        if (!_latestState.HasStockBackup)
        {
            System.Windows.MessageBox.Show(
                _isEnglish
                    ? "Verified stock backup was not found in backups/stock/. Cannot restore stock without factory images."
                    : "Проверенный бэкап стоковых разделов в папке backups/stock/ не найден. Откат невозможен без заводских образов.",
                _isEnglish ? "Backup Not Found" : "Бэкап не найден",
                System.Windows.MessageBoxButton.OK,
                System.Windows.MessageBoxImage.Warning);
            return;
        }

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

    private async void BtnRebootPreloader_Click(object sender, RoutedEventArgs e)
    {
        if (_isBusy || _latestState.Mode != ConnectionMode.AdbOnline) return;

        _isBusy = true;
        SetActionButtonsEnabled(false);
        LogExpander.IsExpanded = true;
        try
        {
            AppendLog("[AUTO] " + (_isEnglish
                ? "Sending 'adb reboot' so MediaTek Preloader VCOM appears..."
                : "Отправляю 'adb reboot' для перехода в MediaTek Preloader VCOM..."));

            var psi = new ProcessStartInfo
            {
                FileName = _paths.AdbExe,
                Arguments = "reboot",
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardOutput = true,
                RedirectStandardError = true
            };

            using var proc = Process.Start(psi);
            if (proc is null)
            {
                AppendLog("[ERR] " + (_isEnglish ? "Failed to start adb.exe." : "Не удалось запустить adb.exe."));
                return;
            }

            string outText = await proc.StandardOutput.ReadToEndAsync();
            string errText = await proc.StandardError.ReadToEndAsync();
            await proc.WaitForExitAsync();

            if (proc.ExitCode == 0)
            {
                AppendLog("[ OK ] " + (_isEnglish
                    ? "Reboot command sent. Preloader VCOM appears for ~2-3s (if SP Flash Tool is not waiting, Android boots normally)."
                    : "Команда перезагрузки отправлена. Порт Preloader VCOM появится на ~2–3 с (если SP Flash Tool не запущен, далее загрузится Android)."));
            }
            else
            {
                string msg = string.IsNullOrWhiteSpace(errText) ? outText : errText;
                AppendLog($"[ERR] adb reboot ({proc.ExitCode}): {msg.Trim()}");
            }
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

    private void BtnCopyLog_Click(object sender, RoutedEventArgs e)
    {
        if (string.IsNullOrEmpty(LogTextBox.Text)) return;
        try
        {
            Clipboard.SetText(LogTextBox.Text);
        }
        catch (Exception ex)
        {
            AppendLog("[WARN] " + (_isEnglish ? $"Clipboard busy: {ex.Message}" : $"Буфер обмена занят: {ex.Message}"));
        }
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
                        IsMagiskInstalled = false,
                        ModuleState = PerfModuleState.NotInstalled,
                        HasStockBackup = false,
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
                        IsMagiskInstalled = true,
                        ModuleState = PerfModuleState.InstalledUpToDate,
                        InstalledModuleVersion = "v0.1.1",
                        IsSupportedBuild = true,
                        HasStockBackup = true,
                        BackupSummary = "9/9 SHA-256 OK"
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
                        IsMagiskInstalled = false,
                        ModuleState = PerfModuleState.NotInstalled,
                        ComPort = "COM5",
                        HasStockBackup = true,
                        BackupSummary = "9/9 SHA-256 OK"
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
                            ? "Device descriptor request failed — hold ONLY Vol- and Vol+ (do NOT press Power)"
                            : "Сбой дескриптора USB — зажмите ТОЛЬКО Vol- и Vol+ (НЕ нажимайте Power)",
                        Model = "—",
                        Firmware = "—",
                        ActiveSlot = "—",
                        MagiskStatus = "—",
                        IsMagiskInstalled = false,
                        ModuleState = PerfModuleState.NotInstalled,
                        HasStockBackup = true,
                        BackupSummary = "9/9 SHA-256 OK"
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
