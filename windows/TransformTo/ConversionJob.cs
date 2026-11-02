namespace TransformTo;

record FileResult(string Input, string? Output, string? Error);

/// <summary>Converts a batch of files to one target format, reporting each file as it finishes.</summary>
sealed class ConversionJob(IReadOnlyList<string> files, string targetId)
{
    public IReadOnlyList<string> Files => files;
    public string TargetId => targetId;
    public string TargetLabel =>
        Enum.GetValues<Engine>().Select(e => Formats.Find(e, targetId)).FirstOrDefault(t => t != null)?.Label
        ?? targetId.ToUpperInvariant();

    public event Action<FileResult>? FileDone;

    /// <summary>Runs synchronously. Call it from an STA thread (Office automation needs one).</summary>
    public List<FileResult> Run(CancellationToken cancel)
    {
        var results = new List<FileResult>();
        void Report(FileResult r)
        {
            results.Add(r);
            FileDone?.Invoke(r);
        }

        var groups = files.GroupBy(f => Formats.Inputs.TryGetValue(Formats.ExtensionOf(f), out var e) ? e : (Engine?)null);
        foreach (var group in groups)
        {
            if (group.Key is not Engine engine)
            {
                foreach (var f in group)
                    Report(new(f, null, $"Unsupported file type (.{Formats.ExtensionOf(f)})."));
                continue;
            }

            var target = Formats.Find(engine, targetId);
            if (target == null)
            {
                foreach (var f in group)
                    Report(new(f, null, $"A .{Formats.ExtensionOf(f)} file can't be transformed to {TargetLabel}."));
                continue;
            }

            if (target.Id == "pdf-merge")
            {
                RunMerge(group.ToList(), cancel, Report);
                continue;
            }

            using var office = engine == Engine.Image ? null : new OfficeConverter(engine);
            foreach (var input in group)
            {
                if (cancel.IsCancellationRequested)
                    return results;
                string? output = null;
                try
                {
                    if (!File.Exists(input))
                        throw new FileNotFoundException("The file no longer exists.");
                    if (Formats.ExtensionOf(input) == target.Extension)
                    {
                        Report(new(input, null, $"Already a .{target.Extension} file, skipped."));
                        continue;
                    }
                    output = UniqueOutputPath(input, target.Extension);
                    if (office == null)
                        ImageConverter.Convert(input, output, target);
                    else
                        office.Convert(input, output, target);
                    Report(new(input, output, null));
                }
                catch (Exception ex)
                {
                    if (output != null && File.Exists(output))
                        TryDelete(output);
                    Report(new(input, null, Describe(ex)));
                }
            }
        }
        return results;
    }

    static void RunMerge(List<string> inputs, CancellationToken cancel, Action<FileResult> report)
    {
        var ordered = inputs.Order(StringComparer.CurrentCultureIgnoreCase).ToList();
        var first = ordered[0];
        var output = UniquePath(Path.Combine(Path.GetDirectoryName(first)!,
            Path.GetFileNameWithoutExtension(first) + " (merged).pdf"));
        try
        {
            ImageConverter.MergeToPdf(ordered, output, _ => cancel.ThrowIfCancellationRequested());
            foreach (var f in ordered)
                report(new(f, output, null));
        }
        catch (Exception ex)
        {
            TryDelete(output);
            foreach (var f in ordered)
                report(new(f, null, Describe(ex)));
        }
    }

    public static string UniqueOutputPath(string input, string ext) =>
        UniquePath(Path.ChangeExtension(input, ext));

    static string UniquePath(string path)
    {
        if (!File.Exists(path))
            return path;
        var dir = Path.GetDirectoryName(path)!;
        var name = Path.GetFileNameWithoutExtension(path);
        var ext = Path.GetExtension(path);
        for (var i = 1; ; i++)
        {
            var candidate = Path.Combine(dir, $"{name} ({i}){ext}");
            if (!File.Exists(candidate))
                return candidate;
        }
    }

    static string Describe(Exception ex) =>
        ex is System.Runtime.InteropServices.COMException com
            ? $"Office couldn't open or save the file ({com.Message.Trim()})"
            : ex.Message;

    static void TryDelete(string path)
    {
        try { File.Delete(path); } catch { }
    }
}
