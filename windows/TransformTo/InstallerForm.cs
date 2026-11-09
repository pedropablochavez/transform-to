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

        var photo = new PictureBox
        {
            Image = Image.FromStream(typeof(InstallerForm).Assembly.GetManifestResourceStream("installer-photo.jpg")!),
            Size = LogicalToDeviceUnits(new Size(200, 284)),
            SizeMode = PictureBoxSizeMode.Zoom,
            Margin = Padding.Empty,
        };
        var layout = new FlowLayoutPanel { FlowDirection = FlowDirection.TopDown, AutoSize = true, WrapContents = false, Margin = new Padding(18) };
        layout.Controls.Add(new Label
        {
            AutoSize = true,
            MaximumSize = new Size(420, 0),
            Text = "Adds \"Transform to\" to the right-click menu of images and Office documents, " +
                   "so you can convert one file or a whole selection to another format.\n\n" +
                   "On Windows 11, Windows asks once for permission to trust the app's certificate " +
                   "so the menu can appear in the main right-click menu.",
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

        var root = new TableLayoutPanel { AutoSize = true, ColumnCount = 2, RowCount = 1, Margin = Padding.Empty };
        root.Controls.Add(photo, 0, 0);
        root.Controls.Add(layout, 1, 0);
        Controls.Add(root);

        install.Click += (_, _) => Run(() => "Installed. " + Installer.Install());
        uninstall.Click += (_, _) => Run(() =>
        {
            Installer.Uninstall();
            return "Removed from the right-click menu.";
        });
        UpdateState(null);
    }

    void Run(Func<string> action)
    {
        UseWaitCursor = true;
        try
        {
            UpdateState(action());
        }
        catch (Exception ex)
        {
            MessageBox.Show(this, ex.Message, "Transform To", MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
        finally
        {
            UseWaitCursor = false;
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
