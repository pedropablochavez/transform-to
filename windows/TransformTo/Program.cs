namespace TransformTo;

static class Program
{
    const string Usage =
        "Usage:\n" +
        "  TransformTo.exe                              open the installer window\n" +
        "  TransformTo.exe install | uninstall [--quiet]\n" +
        "  TransformTo.exe convert --to <format> [--no-ui] <files...>\n\n" +
        "Formats: jpg png webp gif bmp tiff ico avif pdf pdf-merge docx doc odt rtf txt html xlsx xls ods csv pptx ppt odp";

    [STAThread]
    static int Main(string[] args)
    {
        ApplicationConfiguration.Initialize();
        var quiet = args.Contains("--quiet");

        switch (args.FirstOrDefault()?.ToLowerInvariant())
        {
            case null:
                Application.Run(new InstallerForm());
                return 0;

            case "install":
            case "uninstall":
                try
                {
                    if (args[0].Equals("install", StringComparison.OrdinalIgnoreCase))
                        Installer.Install();
                    else
                        Installer.Uninstall();
                    if (!quiet)
                        MessageBox.Show(args[0].Equals("install", StringComparison.OrdinalIgnoreCase)
                            ? "Transform To is installed. Right-click a file and choose \"Transform to\"."
                            : "Transform To was removed.", "Transform To");
                    return 0;
                }
                catch (Exception ex)
                {
                    if (!quiet)
                        MessageBox.Show(ex.Message, "Transform To", MessageBoxButtons.OK, MessageBoxIcon.Error);
                    return 1;
                }

            case "convert":
                return Convert(args.Skip(1).ToList());

            default:
                MessageBox.Show(Usage, "Transform To");
                return 2;
        }
    }

    static int Convert(List<string> args)
    {
        var toIndex = args.FindIndex(a => a is "--to" or "-t");
        if (toIndex < 0 || toIndex + 1 >= args.Count || !Formats.IsKnownTarget(args[toIndex + 1]))
        {
            MessageBox.Show(Usage, "Transform To");
            return 2;
        }
        var target = args[toIndex + 1].ToLowerInvariant();
        var noUi = args.Contains("--no-ui");
        var files = args.Where((_, i) => i != toIndex && i != toIndex + 1 && !args[i].StartsWith("--"))
                        .Select(Path.GetFullPath)
                        .ToList();
        if (files.Count == 0)
            return 2;

        if (noUi)
        {
            // Scripting / test mode: convert exactly these files, print one line per file, exit code = failures.
            var results = new ConversionJob(files, target).Run(CancellationToken.None);
            foreach (var r in results)
                Console.WriteLine(r.Error == null ? $"OK   {r.Input} -> {r.Output}" : $"FAIL {r.Input}: {r.Error}");
            return results.Count(r => r.Error != null);
        }

        var all = FileCollector.Collect(target, files);
        if (all == null)
            return 0; // another TransformTo process took our files

        var job = new ConversionJob(all.Distinct(StringComparer.OrdinalIgnoreCase).ToList(), target);
        Application.Run(new ProgressForm(job));
        return 0;
    }
}
