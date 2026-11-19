using System.Windows;

namespace RG477MToolkit;

public partial class App : Application
{
    protected override void OnStartup(StartupEventArgs e)
    {
        base.OnStartup(e);

        string? screenshotDir = null;
        for (int i = 0; i < e.Args.Length - 1; i++)
        {
            if (string.Equals(e.Args[i], "--capture-screenshots", StringComparison.OrdinalIgnoreCase))
            {
                screenshotDir = e.Args[i + 1];
                break;
            }
        }

        var window = new MainWindow(screenshotDir);
        window.Show();
    }
}
