using System.Diagnostics;

namespace TransformTo;

/// <summary>What you see when you double-click TransformTo.exe: install or remove the right-click menu.</summary>
sealed class InstallerForm : Form
{
    readonly Label state = new() { AutoSize = true, Font = new Font(SystemFonts.MessageBoxFont!, FontStyle.Bold) };
    readonly Button install = new() { AutoSize = true, MinimumSize = new Size(120, 32) };
    readonly Button uninstall = new() { Text = "Uninstall", AutoSize = true, MinimumSize = new Size(120, 32) };

    public InstallerForm()
    {
        Text = "Transform To";
        Icon = Icon.ExtractAssociatedIcon(Environment.ProcessPath!);
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false;
        StartPosition = FormStartPosition.CenterScreen;
        AutoSize = true;
        AutoSizeMode = AutoSizeMode.GrowAndShrink;
        Padding = new Padding(18);

        var layout = new FlowLayoutPanel { FlowDirection = FlowDirection.TopDown, AutoSize = true, WrapContents = false };
        layout.Controls.Add(new Label
        {
            AutoSize = true,
            MaximumSize = new Size(420, 0),
            Text = "Adds \"Transform to\" to the right-click menu of images and Office documents, " +
                   "so you can convert one file or a whole selection to another format.\n\n" +
                   "On Windows 11 it appears under \"Show more options\" (or Shift + right-click).",
        });
        layout.Controls.Add(new Panel { Height = 10 });
        layout.Controls.Add(state);
        layout.Controls.Add(new Panel { Height = 10 });

        var buttons = new FlowLayoutPanel { AutoSize = true, Margin = Padding.Empty };
        buttons.Controls.Add(install);
        buttons.Controls.Add(uninstall);
        layout.Controls.Add(buttons);

        var link = new LinkLabel { Text = "github.com/pedropablochavez/transform-to", AutoSize = true, Margin = new Padding(3, 12, 3, 0) };
        link.LinkClicked += (_, _) =>
            Process.Start(new ProcessStartInfo("https://github.com/pedropablochavez/transform-to") { UseShellExecute = true });
        layout.Controls.Add(link);
        Controls.Add(layout);

        install.Click += (_, _) => Run(Installer.Install, "Installed. Right-click a file and choose \"Transform to\".");
        uninstall.Click += (_, _) => Run(Installer.Uninstall, "Removed from the right-click menu.");
        UpdateState(null);
    }

    void Run(Action action, string message)
    {
        try
        {
            action();
            UpdateState(message);
        }
        catch (Exception ex)
        {
            MessageBox.Show(this, ex.Message, "Transform To", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
    }

    void UpdateState(string? message)
    {
        var installed = Installer.IsInstalled;
        state.Text = message ?? (installed ? "Installed." : "Not installed yet.");
        install.Text = installed ? "Reinstall" : "Install";
        uninstall.Enabled = installed;
    }
}
