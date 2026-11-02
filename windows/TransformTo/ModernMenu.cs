using System.ComponentModel;
using System.Diagnostics;
using System.Security.Cryptography.X509Certificates;
using System.Text;

namespace TransformTo;

/// <summary>
/// The Windows 11 main context menu (not "Show more options"). Windows only shows handlers from packaged apps
/// there, so we register a sparse MSIX package whose external location is the install folder. The package and the
/// handler DLL (windows/ShellExtension) are embedded in TransformTo.exe by the release build.
///
/// The package is signed with the project's self-signed certificate, which Windows must trust before it installs
/// the package: that's the one step that needs admin rights (a single UAC prompt on first install).
/// </summary>
static class ModernMenu
{
    const string PackageName = "TransformTo";
    const string Dll = "TransformToShell.dll", Msix = "TransformTo.msix", Cer = "TransformTo.cer";

    public static bool IsAvailable =>
        Environment.OSVersion.Version.Build >= 22000 && new[] { Dll, Msix, Cer }.All(HasResource);

    /// <summary>Returns null when the menu is installed, otherwise why it couldn't be.</summary>
    public static string? Install(string dir)
    {
        foreach (var name in new[] { Dll, Msix, Cer })
            Extract(name, Path.Combine(dir, name));
        WriteMenuFile(Path.Combine(dir, "menu.txt"));

        if (!IsCertificateTrusted() && !TrustCertificateElevated())
            return "Windows needs permission (admin) to trust the Transform To certificate. " +
                   "Without it the menu stays under \"Show more options\".";

        var msix = Quote(Path.Combine(dir, Msix));
        var (ok, output) = PowerShell(
            $"Get-AppxPackage -Name {PackageName} | Remove-AppxPackage; " +
            $"Add-AppxPackage -Path {msix} -ExternalLocation {Quote(dir)} -ErrorAction Stop");
        return ok ? null : $"Windows refused the context-menu package: {output}";
    }

    public static void Uninstall() =>
        PowerShell($"Get-AppxPackage -Name {PackageName} | Remove-AppxPackage");

    /// <summary>Runs elevated (TransformTo.exe trust-cert): adds our embedded certificate to the machine's Trusted People.</summary>
    public static void TrustCertificate()
    {
        using var store = new X509Store(StoreName.TrustedPeople, StoreLocation.LocalMachine);
        store.Open(OpenFlags.ReadWrite);
        store.Add(LoadCertificate());
    }

    static bool IsCertificateTrusted()
    {
        var thumbprint = LoadCertificate().Thumbprint;
        foreach (var name in new[] { StoreName.TrustedPeople, StoreName.Root })
        {
            using var store = new X509Store(name, StoreLocation.LocalMachine);
            store.Open(OpenFlags.ReadOnly);
            if (store.Certificates.Find(X509FindType.FindByThumbprint, thumbprint, false).Count > 0)
                return true;
        }
        return false;
    }

    static bool TrustCertificateElevated()
    {
        try
        {
            using var process = Process.Start(new ProcessStartInfo(Environment.ProcessPath!, "trust-cert")
            {
                UseShellExecute = true,
                Verb = "runas",
            })!;
            process.WaitForExit();
            return process.ExitCode == 0 && IsCertificateTrusted();
        }
        catch (Win32Exception)
        {
            return false; // UAC prompt was declined
        }
    }

    static X509Certificate2 LoadCertificate()
    {
        using var stream = Resource(Cer);
        using var buffer = new MemoryStream();
        stream.CopyTo(buffer);
        return X509CertificateLoader.LoadCertificate(buffer.ToArray());
    }

    /// <summary>
    /// menu.txt tells TransformToShell.dll which formats to offer for which extensions, so the C++ side never
    /// needs its own copy of Formats.cs.
    /// </summary>
    static void WriteMenuFile(string path)
    {
        var text = new StringBuilder();
        var seen = new HashSet<string>();
        foreach (var engine in Enum.GetValues<Engine>())
            foreach (var target in Formats.TargetsFor(engine))
                if (seen.Add(target.Id))
                    text.Append($"T\t{target.Id}\t{target.Label}\n");
        foreach (var ext in Formats.Inputs.Keys)
            text.Append($"E\t.{ext}\t{string.Join(',', Formats.TargetsForExtension(ext).Select(t => t.Id))}\n");
        File.WriteAllText(path, text.ToString(), new UTF8Encoding(false));
    }

    static bool HasResource(string name) =>
        typeof(ModernMenu).Assembly.GetManifestResourceInfo(name) != null;

    static Stream Resource(string name) =>
        typeof(ModernMenu).Assembly.GetManifestResourceStream(name)
        ?? throw new InvalidOperationException($"{name} is missing from this build.");

    static void Extract(string name, string destination)
    {
        using var source = Resource(name);
        try
        {
            using var target = File.Create(destination);
            source.CopyTo(target);
        }
        catch (IOException) when (File.Exists(destination))
        {
            // Explorer's COM surrogate still has the old DLL loaded. A loaded DLL can't be overwritten but it can
            // be renamed, so move it aside and write the new one.
            File.Move(destination, $"{destination}.{DateTime.Now.Ticks}.old");
            using var target = File.Create(destination);
            source.CopyTo(target);
        }
    }

    static string Quote(string value) => "'" + value.Replace("'", "''") + "'";

    static (bool Ok, string Output) PowerShell(string command)
    {
        var psi = new ProcessStartInfo("powershell.exe")
        {
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
        };
        foreach (var arg in new[] { "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass", "-Command", command })
            psi.ArgumentList.Add(arg);
        using var process = Process.Start(psi)!;
        var stderr = process.StandardError.ReadToEndAsync();
        var stdout = process.StandardOutput.ReadToEnd();
        process.WaitForExit();
        return (process.ExitCode == 0, (stderr.Result + stdout).Trim());
    }
}
