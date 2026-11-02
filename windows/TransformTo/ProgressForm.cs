using System.Diagnostics;

namespace TransformTo;

/// <summary>Small window that runs a conversion job, shows progress and lists anything that failed.</summary>
sealed class ProgressForm : Form
{
    readonly ConversionJob job;
    readonly CancellationTokenSource cancel = new();
    readonly Label status = new() { AutoSize = false, Dock = DockStyle.Top, Height = 44, TextAlign = ContentAlignment.MiddleLeft };
    readonly ProgressBar bar = new() { Dock = DockStyle.Top, Height = 18 };
    readonly ListBox errors = new() { Dock = DockStyle.Fill, Visible = false, HorizontalScrollbar = true, IntegralHeight = false };
    readonly Button openFolder = new() { Text = "Open folder", AutoSize = true, Enabled = false };
    readonly Button close = new() { Text = "Cancel", AutoSize = true };
    int done, failed;
    string? lastOutput;

    public ProgressForm(ConversionJob job)
    {
        this.job = job;
        Text = $"Transform to {job.TargetLabel}";
        Icon = Icon.ExtractAssociatedIcon(Environment.ProcessPath!);
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = MinimizeBox = false;
        StartPosition = FormStartPosition.CenterScreen;
        ClientSize = new Size(460, 130);
        Padding = new Padding(14);
        TopMost = true;

        bar.Maximum = job.Files.Count;
        status.Text = job.Files.Count == 1
            ? $"Converting {Path.GetFileName(job.Files[0])}…"
            : $"Converting {job.Files.Count} files…";

        var buttons = new FlowLayoutPanel { Dock = DockStyle.Bottom, FlowDirection = FlowDirection.RightToLeft, AutoSize = true, Padding = new Padding(0, 8, 0, 0) };
        buttons.Controls.Add(close);
        buttons.Controls.Add(openFolder);

        Controls.Add(errors);
        Controls.Add(new Panel { Dock = DockStyle.Top, Height = 8 });
        Controls.Add(bar);
        Controls.Add(status);
        Controls.Add(buttons);

        close.Click += (_, _) =>
        {
            if (cancel.IsCancellationRequested || done == job.Files.Count) Close();
            else { cancel.Cancel(); close.Text = "Close"; status.Text = "Stopping after the current file…"; }
        };
        openFolder.Click += (_, _) =>
        {
            if (lastOutput != null)
                Process.Start("explorer.exe", $"/select,\"{lastOutput}\"");
        };
        job.FileDone += r => BeginInvoke(() => OnFileDone(r));
        Shown += (_, _) => Start();
    }

    void Start()
    {
        // Office automation only works on an STA thread, so don't use the thread pool.
        var thread = new Thread(() =>
        {
            try
            {
                job.Run(cancel.Token);
            }
            catch (Exception ex)
            {
                BeginInvoke(() => ShowError(ex.Message));
            }
            BeginInvoke(Finish);
        });
        thread.SetApartmentState(ApartmentState.STA);
        thread.IsBackground = true;
        thread.Start();
    }

    void OnFileDone(FileResult result)
    {
        done++;
        bar.Value = Math.Min(done, bar.Maximum);
        if (result.Error == null)
        {
            lastOutput = result.Output;
            openFolder.Enabled = true;
        }
        else
        {
            failed++;
            ShowError($"{Path.GetFileName(result.Input)}: {result.Error}");
        }
        if (job.Files.Count > 1)
            status.Text = $"Converting… {done} of {job.Files.Count}";
    }

    void ShowError(string message)
    {
        if (!errors.Visible)
        {
            errors.Visible = true;
            ClientSize = new Size(560, 300);
            FormBorderStyle = FormBorderStyle.Sizable;
        }
        errors.Items.Add(message);
    }

    async void Finish()
    {
        close.Text = "Close";
        var ok = done - failed;
        if (cancel.IsCancellationRequested)
            status.Text = $"Stopped. {ok} converted.";
        else if (failed == 0)
            status.Text = ok == 1 ? "Done." : $"Done. {ok} files converted.";
        else
            status.Text = $"{ok} converted, {failed} failed:";

        if (failed == 0 && !cancel.IsCancellationRequested)
        {
            // Everything went fine: get out of the way on our own.
            await Task.Delay(1500);
            if (!IsDisposed)
                Close();
        }
    }
}
