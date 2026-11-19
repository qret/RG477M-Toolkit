using System.Windows.Controls;
using System.Windows.Media;
using RG477MToolkit.Models;

namespace RG477MToolkit.Controls;

public partial class Rg477mDeviceCanvas : UserControl
{
    public Rg477mDeviceCanvas()
    {
        InitializeComponent();
    }

    public void UpdateState(DeviceStateSnapshot state, bool isEnglish = false)
    {
        var neutral = new SolidColorBrush(Color.FromRgb(0x3F, 0x45, 0x52));
        var neutralText = new SolidColorBrush(Color.FromRgb(0x71, 0x71, 0x7A));

        VolUpButton.Background = neutral;
        VolDownButton.Background = neutral;
        VolHintLabel.Foreground = neutralText;
        PowerButton.Background = neutral;
        PowerHintLabel.Foreground = new SolidColorBrush(Color.FromRgb(0x52, 0x52, 0x5B));
        PowerHintLabel.Text = "Power";

        switch (state.Mode)
        {
            case ConnectionMode.AdbOnline:
                var green = Color.FromRgb(0x22, 0xC5, 0x5E);
                ChassisGlowEffect.Color = green;
                ChassisGlowEffect.Opacity = 0.75;
                BodyShell.BorderBrush = new SolidColorBrush(Color.FromRgb(0x22, 0xC5, 0x5E));
                UsbPort.Background = new SolidColorBrush(green);
                UsbLabel.Foreground = new SolidColorBrush(green);
                ScreenDisplay.Background = new SolidColorBrush(Color.FromRgb(0x0B, 0x1A, 0x12));
                ScreenTitle.Text = state.Model;
                ScreenSubtitle.Text = $"ADB Online • {state.Firmware}";
                ScreenSubtitle.Foreground = new SolidColorBrush(Color.FromRgb(0x4A, 0xDE, 0x80));
                ScreenMeta.Text = isEnglish
                    ? $"Slot: {state.ActiveSlot} • Magisk: {state.MagiskStatus}"
                    : $"Слот: {state.ActiveSlot} • Magisk: {state.MagiskStatus}";
                ScreenMeta.Foreground = new SolidColorBrush(Color.FromRgb(0xA1, 0xA1, 0xAA));
                break;

            case ConnectionMode.PreloaderVcom:
            case ConnectionMode.BromMode:
                var amber = Color.FromRgb(0xF5, 0x9E, 0x0B);
                ChassisGlowEffect.Color = amber;
                ChassisGlowEffect.Opacity = 0.8;
                BodyShell.BorderBrush = new SolidColorBrush(amber);
                UsbPort.Background = new SolidColorBrush(amber);
                UsbLabel.Foreground = new SolidColorBrush(amber);
                VolUpButton.Background = new SolidColorBrush(amber);
                VolDownButton.Background = new SolidColorBrush(amber);
                VolHintLabel.Foreground = new SolidColorBrush(amber);
                ScreenDisplay.Background = new SolidColorBrush(Color.FromRgb(0x1C, 0x14, 0x08));
                ScreenTitle.Text = state.Mode == ConnectionMode.BromMode ? "BROM ACTIVE" : "PRELOADER";
                ScreenSubtitle.Text = string.IsNullOrEmpty(state.ComPort)
                    ? "MediaTek VCOM"
                    : (isEnglish ? $"Port {state.ComPort}" : $"Порт {state.ComPort}");
                ScreenSubtitle.Foreground = new SolidColorBrush(Color.FromRgb(0xFB, 0xBF, 0x24));
                ScreenMeta.Text = isEnglish ? "Ready for SP Flash Tool V6" : "Готов для SP Flash Tool V6";
                ScreenMeta.Foreground = new SolidColorBrush(Color.FromRgb(0xD4, 0xD4, 0xD8));
                break;

            case ConnectionMode.UsbDescriptorError:
                var red = Color.FromRgb(0xEF, 0x44, 0x44);
                var amberBrush = new SolidColorBrush(Color.FromRgb(0xF5, 0x9E, 0x0B));
                ChassisGlowEffect.Color = red;
                ChassisGlowEffect.Opacity = 0.8;
                BodyShell.BorderBrush = new SolidColorBrush(red);
                UsbPort.Background = new SolidColorBrush(red);
                UsbLabel.Foreground = new SolidColorBrush(red);
                VolUpButton.Background = amberBrush;
                VolDownButton.Background = amberBrush;
                VolHintLabel.Foreground = amberBrush;
                PowerButton.Background = new SolidColorBrush(red);
                PowerHintLabel.Foreground = new SolidColorBrush(red);
                PowerHintLabel.Text = isEnglish ? "Do NOT press Power!" : "НЕ жать Power!";
                ScreenDisplay.Background = new SolidColorBrush(Color.FromRgb(0x1F, 0x0D, 0x0E));
                ScreenTitle.Text = isEnglish ? "USB Code 43" : "USB Код 43";
                ScreenSubtitle.Text = isEnglish ? "Hold ONLY Vol+ and Vol-" : "Зажмите ТОЛЬКО Vol+ и Vol-";
                ScreenSubtitle.Foreground = new SolidColorBrush(Color.FromRgb(0xF8, 0x71, 0x71));
                ScreenMeta.Text = isEnglish
                    ? "Unplug USB and retry without Power"
                    : "Отключите USB и повторите без Power";
                break;

            default:
                ChassisGlowEffect.Color = Color.FromRgb(0x3F, 0x3F, 0x46);
                ChassisGlowEffect.Opacity = 0.45;
                BodyShell.BorderBrush = new SolidColorBrush(Color.FromRgb(0x3A, 0x3F, 0x4B));
                UsbPort.Background = neutral;
                UsbLabel.Foreground = neutralText;
                ScreenDisplay.Background = new SolidColorBrush(Color.FromRgb(0x0D, 0x11, 0x17));
                ScreenTitle.Text = "RG477M";
                ScreenSubtitle.Text = isEnglish ? "Waiting for device..." : "Ожидание подключения...";
                ScreenSubtitle.Foreground = neutralText;
                ScreenMeta.Text = isEnglish ? "ADB or hold Vol+ / Vol- for BROM" : "ADB или Vol+ / Vol- для BROM";
                ScreenMeta.Foreground = new SolidColorBrush(Color.FromRgb(0x52, 0x52, 0x5B));
                break;
        }
    }
}
