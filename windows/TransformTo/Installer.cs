using System.Diagnostics;
using System.Runtime.InteropServices;
using Microsoft.Win32;

namespace TransformTo;

/// <summary>
/// Adds/removes "Transform to" in Explorer. On Windows 11 builds that carry the shell extension it goes in the main
/// menu (see <see cref="ModernMenu"/>). Otherwise it's a classic cascading menu under HKEY_CURRENT_USER, which needs
/// no admin rights and shows under "Show more options" on Windows 11. Classic layout per input extension:
///   HKCU\Software\Classes\SystemFileAssociations\.jpg\shell\TransformTo        (MUIVerb, SubCommands="")
///   HKCU\Software\Classes\SystemFileAssociations\.jpg\shell\TransformTo\shell\01_png\command
/// </summary>
static class Installer
{
    const string VerbKey = "TransformTo";
    const string UninstallKey = @"Software\Microsoft\Windows\CurrentVersion\Uninstall\TransformTo";

    public static string InstallDir =>
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Programs", "TransformTo");

    public static string InstalledExe => Path.Combine(InstallDir, "TransformTo.exe");

    public static bool IsInstalled
    {
        get
        {
            using var key = Registry.CurrentUser.OpenSubKey(UninstallKey);
            return key != null;
        }
    }

    static bool RunningFromInstallDir =>
        string.Equals(Path.GetFullPath(Environment.ProcessPath!), Path.GetFullPath(InstalledExe), StringComparison.OrdinalIgnoreCase);

    /// <summary>Installs and returns a sentence telling the user where to find the menu.</summary>
    public static string Install()
    {
        Directory.CreateDirectory(InstallDir);
        if (!RunningFromInstallDir)
            File.Copy(Environment.ProcessPath!, InstalledExe, overwrite: true);

        RemoveMenus();
        string result;
        var modernError = ModernMenu.IsAvailable ? ModernMenu.Install(InstallDir) : "";
        if (modernError == null)
        {
            result = "Right-click a file and choose \"Transform to\".";
        }
        else
        {
            AddClassicMenus(InstalledExe);
            result = Environment.OSVersion.Version.Build >= 22000
                ? "Right-click a file › \"Show more options\" › \"Transform to\"." + (modernError.Length > 0 ? "\n\n" + modernError : "")
                : "Right-click a file and choose \"Transform to\".";
        }

        WriteUninstallEntry(InstalledExe);
        NotifyShell();
        return result;
    }

    static void AddClassicMenus(string exe)
    {
        foreach (var ext in Formats.Inputs.Keys)
        {
            using var verb = Registry.CurrentUser.CreateSubKey($@"Software\Classes\SystemFileAssociations\.{ext}\shell\{VerbKey}");
            verb.SetValue("MUIVerb", "Transform to");
            verb.SetValue("Icon", $"\"{exe}\",0");
            verb.SetValue("SubCommands", "");
            // Without "Player" the menu disappears when more than 15 files are selected.
            verb.SetValue("MultiSelectModel", "Player");

            var i = 1;
            foreach (var target in Formats.TargetsForExtension(ext))
            {
                using var item = verb.CreateSubKey($@"shell\{i++:00}_{target.Id}");
                item.SetValue("MUIVerb", target.Label);
                item.SetValue("MultiSelectModel", "Player");
                using var command = item.CreateSubKey("command");
                command.SetValue("", $"\"{exe}\" convert --to {target.Id} \"%1\"");
            }
        }
    }

    static void WriteUninstallEntry(string exe)
    {
        using (var uninstall = Registry.CurrentUser.CreateSubKey(UninstallKey))
        {
            var version = typeof(Installer).Assembly.GetName().Version!;
            uninstall.SetValue("DisplayName", "Transform To");
            uninstall.SetValue("DisplayVersion", $"{version.Major}.{version.Minor}.{version.Build}");
            uninstall.SetValue("Publisher", "Transform To contributors");
            uninstall.SetValue("DisplayIcon", exe);
            uninstall.SetValue("InstallLocation", InstallDir);
            uninstall.SetValue("UninstallString", $"\"{exe}\" uninstall");
            uninstall.SetValue("QuietUninstallString", $"\"{exe}\" uninstall --quiet");
            uninstall.SetValue("URLInfoAbout", "https://github.com/pedropablochavez/transform-to");
            uninstall.SetValue("NoModify", 1, RegistryValueKind.DWord);
            uninstall.SetValue("NoRepair", 1, RegistryValueKind.DWord);
            uninstall.SetValue("EstimatedSize", (int)(new FileInfo(exe).Length / 1024), RegistryValueKind.DWord);
        }
    }

    public static void Uninstall()
    {
        RemoveMenus();
        if (Environment.OSVersion.Version.Build >= 22000)
            ModernMenu.Uninstall();
        Registry.CurrentUser.DeleteSubKeyTree(UninstallKey, throwOnMissingSubKey: false);
        NotifyShell();

        if (!Directory.Exists(InstallDir))
            return;
        if (RunningFromInstallDir)
        {
            // An exe can't delete itself while running: let a hidden cmd remove the folder once we have exited.
            Process.Start(new ProcessStartInfo("cmd.exe",
                $"/c ping 127.0.0.1 -n 3 > nul & rmdir /s /q \"{InstallDir}\"")
            {
                CreateNoWindow = true,
                UseShellExecute = false,
                WorkingDirectory = Path.GetTempPath(),
            });
        }
        else
        {
            try { Directory.Delete(InstallDir, true); } catch { }
        }
    }

    static void RemoveMenus()
    {
        using var assoc = Registry.CurrentUser.OpenSubKey(@"Software\Classes\SystemFileAssociations", writable: true);
        if (assoc == null)
            return;
        foreach (var ext in assoc.GetSubKeyNames())
            assoc.DeleteSubKeyTree($@"{ext}\shell\{VerbKey}", throwOnMissingSubKey: false);
    }

    [DllImport("shell32.dll")]
    static extern void SHChangeNotify(int eventId, uint flags, IntPtr item1, IntPtr item2);

    static void NotifyShell()
    {
        const int SHCNE_ASSOCCHANGED = 0x08000000;
        SHChangeNotify(SHCNE_ASSOCCHANGED, 0, IntPtr.Zero, IntPtr.Zero);
    }
}
