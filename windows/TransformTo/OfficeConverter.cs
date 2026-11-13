using System.Diagnostics;
using System.Runtime.InteropServices;

namespace TransformTo;

/// <summary>
/// Converts documents with Microsoft Office (through COM) when it is installed. Without Office, PPTX/DOCX/XLSX to PDF
/// uses the built-in converter, and everything else uses LibreOffice if it's there.
/// One instance is opened per batch and closed at the end, so converting 50 files doesn't launch Word 50 times.
/// Must be used from an STA thread.
/// </summary>
sealed class OfficeConverter : IDisposable
{
    readonly Engine engine;
    dynamic? app;
    bool started;
    bool quitOnDispose;
    string? sofficePath;

    public OfficeConverter(Engine engine) => this.engine = engine;

    public void Convert(string input, string output, TargetFormat target)
    {
        EnsureStarted();
        var inputExt = Formats.ExtensionOf(input);
        var builtIn = BuiltInConverter.CanConvert(inputExt, target.Extension);

        if (app != null)
        {
            try
            {
                ConvertWithOffice(input, output, target.Extension);
                return;
            }
            // Office can be installed yet unusable (unactivated, broken repair, ...). Don't let that block a PDF.
            catch (COMException) when (builtIn)
            {
                TryDelete(output);
            }
        }

        if (builtIn)
        {
            try
            {
                BuiltInConverter.ConvertToPdf(input, output);
                return;
            }
            catch when (sofficePath != null)
            {
                TryDelete(output);
            }
        }

        if (sofficePath == null)
            throw new InvalidOperationException(target.Extension == "pdf"
                ? $"Converting a .{inputExt} file needs Microsoft Office or LibreOffice (free: https://www.libreoffice.org). " +
                  $"Tip: .{ModernExtension()} files convert to PDF without them."
                : $"Converting to {target.Label} needs Microsoft Office or LibreOffice (free: https://www.libreoffice.org)." +
                  (BuiltInConverter.CanConvert(inputExt, "pdf") ? " Converting to PDF works without them." : ""));
        ConvertWithLibreOffice(input, output, target.Extension);
    }

    string ModernExtension() => engine switch
    {
        Engine.Word => "docx",
        Engine.Excel => "xlsx",
        _ => "pptx",
    };

    void EnsureStarted()
    {
        if (started)
            return;
        started = true;

        var progId = engine switch
        {
            Engine.Word => "Word.Application",
            Engine.Excel => "Excel.Application",
            _ => "PowerPoint.Application",
        };
        var type = Type.GetTypeFromProgID(progId);
        if (type != null)
        {
            try
            {
                app = Activator.CreateInstance(type)!;
                const int msoAutomationSecurityForceDisable = 3; // never run macros from the files we open
                app.AutomationSecurity = msoAutomationSecurityForceDisable;
                switch (engine)
                {
                    case Engine.Word:
                        app.Visible = false;
                        app.DisplayAlerts = 0; // wdAlertsNone
                        quitOnDispose = app.Documents.Count == 0;
                        break;
                    case Engine.Excel:
                        app.Visible = false;
                        app.DisplayAlerts = false;
                        quitOnDispose = app.Workbooks.Count == 0;
                        break;
                    default:
                        // PowerPoint is single-instance: if the user already has it open, leave it open when done.
                        app.DisplayAlerts = 1; // ppAlertsNone
                        quitOnDispose = app.Presentations.Count == 0;
                        break;
                }
                return;
            }
            catch (Exception ex) when (ex is COMException or Microsoft.CSharp.RuntimeBinder.RuntimeBinderException)
            {
                // Office is registered but won't start; carry on as if it weren't installed.
                if (app != null)
                {
                    try { Marshal.FinalReleaseComObject(app); } catch { }
                    app = null;
                }
            }
        }

        sofficePath = FindLibreOffice();
    }

    static void TryDelete(string path)
    {
        try { File.Delete(path); } catch { }
    }

    void ConvertWithOffice(string input, string output, string ext)
    {
        switch (engine)
        {
            case Engine.Word:
            {
                // A bogus password makes protected files fail fast instead of popping an invisible prompt.
                dynamic doc = app!.Documents.Open(input, false, true, false, "\u0001");
                try
                {
                    int format = ext switch
                    {
                        "pdf" => 17, "docx" => 16, "doc" => 0, "odt" => 23,
                        "rtf" => 6, "txt" => 7, "html" => 10,
                        _ => throw new NotSupportedException(ext),
                    };
                    doc.SaveAs2(output, format);
                }
                finally
                {
                    doc.Close(0);
                    Marshal.FinalReleaseComObject(doc);
                }
                break;
            }
            case Engine.Excel:
            {
                dynamic book = app!.Workbooks.Open(input, 0, true, Type.Missing, "\u0001");
                try
                {
                    if (ext == "pdf")
                        book.ExportAsFixedFormat(0, output);
                    else
                        book.SaveAs(output, ext switch
                        {
                            "xlsx" => 51, "xls" => 56, "ods" => 60, "csv" => 62,
                            _ => throw new NotSupportedException(ext),
                        });
                }
                finally
                {
                    book.Close(false);
                    Marshal.FinalReleaseComObject(book);
                }
                break;
            }
            default:
            {
                const int msoTrue = -1, msoFalse = 0;
                dynamic pres = app!.Presentations.Open(input, msoTrue, msoFalse, msoFalse);
                try
                {
                    pres.SaveAs(output, ext switch
                    {
                        "pdf" => 32, "pptx" => 24, "ppt" => 1, "odp" => 35,
                        _ => throw new NotSupportedException(ext),
                    });
                }
                finally
                {
                    pres.Close();
                    Marshal.FinalReleaseComObject(pres);
                }
                break;
            }
        }
    }

    void ConvertWithLibreOffice(string input, string output, string ext)
    {
        var filter = ext switch
        {
            "txt" => "txt:Text (encoded):UTF8",
            "csv" => "csv:Text - txt - csv (StarCalc):44,34,76",
            _ => ext,
        };
        // LibreOffice names the output itself, so convert into a scratch folder and move the result.
        var scratch = Directory.CreateTempSubdirectory("TransformTo-").FullName;
        var profile = new Uri(Path.Combine(Path.GetTempPath(), "TransformTo-LibreOfficeProfile")).AbsoluteUri;
        try
        {
            var psi = new ProcessStartInfo(sofficePath!)
            {
                UseShellExecute = false,
                CreateNoWindow = true,
                RedirectStandardError = true,
                RedirectStandardOutput = true,
            };
            // A private profile lets conversion work even while the user has LibreOffice open.
            foreach (var arg in new[] { $"-env:UserInstallation={profile}", "--headless", "--norestore",
                                         "--convert-to", filter, "--outdir", scratch, input })
                psi.ArgumentList.Add(arg);

            using var process = Process.Start(psi)!;
            var stderr = process.StandardError.ReadToEndAsync();
            process.StandardOutput.ReadToEnd();
            if (!process.WaitForExit(TimeSpan.FromMinutes(5)))
            {
                process.Kill(true);
                throw new TimeoutException("LibreOffice took too long.");
            }
            var produced = Directory.GetFiles(scratch).FirstOrDefault()
                ?? throw new InvalidOperationException($"LibreOffice could not convert the file. {stderr.Result}".Trim());
            File.Move(produced, output);
        }
        finally
        {
            try { Directory.Delete(scratch, true); } catch { }
        }
    }

    static string? FindLibreOffice()
    {
        foreach (var root in new[] { Environment.SpecialFolder.ProgramFiles, Environment.SpecialFolder.ProgramFilesX86 })
        {
            var candidate = Path.Combine(Environment.GetFolderPath(root), "LibreOffice", "program", "soffice.exe");
            if (File.Exists(candidate))
                return candidate;
        }
        return (Environment.GetEnvironmentVariable("PATH") ?? "")
            .Split(Path.PathSeparator, StringSplitOptions.RemoveEmptyEntries)
            .Select(dir => Path.Combine(dir, "soffice.exe"))
            .FirstOrDefault(File.Exists);
    }

    [DllImport("user32.dll")]
    static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint processId);

    public void Dispose()
    {
        if (app == null)
            return;
        Process? excel = null;
        try
        {
            if (quitOnDispose)
            {
                if (engine == Engine.Excel)
                {
                    GetWindowThreadProcessId(new IntPtr((int)app.Hwnd), out var pid);
                    excel = Process.GetProcessById((int)pid);
                }
                if (engine == Engine.Word)
                    app.Quit(0);
                else
                    app.Quit();
            }
        }
        catch { }
        Marshal.FinalReleaseComObject(app);
        app = null;

        // Office only exits once every COM proxy is gone, including the hidden ones `dynamic` creates for
        // app.Workbooks, app.Documents, ... Collecting twice releases them.
        GC.Collect();
        GC.WaitForPendingFinalizers();
        GC.Collect();
        GC.WaitForPendingFinalizers();

        // Excel is known to linger anyway. It's our own hidden /automation instance, so make sure it's gone.
        if (excel != null && !excel.WaitForExit(3000))
        {
            try { excel.Kill(); } catch { }
        }
    }
}
