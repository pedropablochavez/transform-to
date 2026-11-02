namespace TransformTo;

enum Engine { Image, Word, Excel, PowerPoint }

/// <summary>A format a file can be transformed to. Id is what goes on the command line.</summary>
record TargetFormat(string Id, string Label, string Extension);

static class Formats
{
    static readonly TargetFormat[] ImageTargets =
    [
        new("jpg", "JPG", "jpg"),
        new("png", "PNG", "png"),
        new("webp", "WEBP", "webp"),
        new("gif", "GIF", "gif"),
        new("bmp", "BMP", "bmp"),
        new("tiff", "TIFF", "tiff"),
        new("ico", "ICO (icon)", "ico"),
        new("avif", "AVIF", "avif"),
        new("pdf", "PDF", "pdf"),
        new("pdf-merge", "PDF (all in one file)", "pdf"),
    ];

    static readonly TargetFormat[] WordTargets =
    [
        new("pdf", "PDF", "pdf"),
        new("docx", "DOCX (Word)", "docx"),
        new("doc", "DOC (Word 97-2003)", "doc"),
        new("odt", "ODT (OpenDocument)", "odt"),
        new("rtf", "RTF", "rtf"),
        new("txt", "TXT (plain text)", "txt"),
        new("html", "HTML", "html"),
    ];

    static readonly TargetFormat[] ExcelTargets =
    [
        new("pdf", "PDF", "pdf"),
        new("xlsx", "XLSX (Excel)", "xlsx"),
        new("xls", "XLS (Excel 97-2003)", "xls"),
        new("ods", "ODS (OpenDocument)", "ods"),
        new("csv", "CSV", "csv"),
    ];

    static readonly TargetFormat[] PowerPointTargets =
    [
        new("pdf", "PDF", "pdf"),
        new("pptx", "PPTX (PowerPoint)", "pptx"),
        new("ppt", "PPT (PowerPoint 97-2003)", "ppt"),
        new("odp", "ODP (OpenDocument)", "odp"),
    ];

    /// <summary>Input extensions (lowercase, no dot) and the engine that reads them.</summary>
    public static readonly Dictionary<string, Engine> Inputs = new()
    {
        ["jpg"] = Engine.Image, ["jpeg"] = Engine.Image, ["jfif"] = Engine.Image,
        ["png"] = Engine.Image, ["bmp"] = Engine.Image, ["gif"] = Engine.Image,
        ["tif"] = Engine.Image, ["tiff"] = Engine.Image, ["webp"] = Engine.Image,
        ["heic"] = Engine.Image, ["heif"] = Engine.Image, ["avif"] = Engine.Image,
        ["ico"] = Engine.Image, ["svg"] = Engine.Image,

        ["docx"] = Engine.Word, ["doc"] = Engine.Word, ["odt"] = Engine.Word, ["rtf"] = Engine.Word,
        ["xlsx"] = Engine.Excel, ["xls"] = Engine.Excel, ["ods"] = Engine.Excel, ["csv"] = Engine.Excel,
        ["pptx"] = Engine.PowerPoint, ["ppt"] = Engine.PowerPoint, ["odp"] = Engine.PowerPoint,
    };

    public static TargetFormat[] TargetsFor(Engine engine) => engine switch
    {
        Engine.Image => ImageTargets,
        Engine.Word => WordTargets,
        Engine.Excel => ExcelTargets,
        _ => PowerPointTargets,
    };

    /// <summary>Formats offered in the menu for a given input extension (never the format it already is).</summary>
    public static IEnumerable<TargetFormat> TargetsForExtension(string ext) =>
        TargetsFor(Inputs[ext]).Where(t => Canonical(t.Extension) != Canonical(ext));

    public static TargetFormat? Find(Engine engine, string id) =>
        TargetsFor(engine).FirstOrDefault(t => t.Id.Equals(id, StringComparison.OrdinalIgnoreCase));

    public static bool IsKnownTarget(string id) =>
        Enum.GetValues<Engine>().Any(e => Find(e, id) != null);

    public static string ExtensionOf(string path) =>
        Path.GetExtension(path).TrimStart('.').ToLowerInvariant();

    /// <summary>Folds aliases together so a .jpeg never offers "JPG" and a .tif never offers "TIFF".</summary>
    static string Canonical(string ext) => ext switch
    {
        "jpeg" or "jfif" => "jpg",
        "tif" => "tiff",
        "heif" => "heic",
        _ => ext,
    };
}
