using ImageMagick;
using ImageMagick.Formats;

namespace TransformTo;

static class ImageConverter
{
    // Formats that can hold several frames (animated GIF -> animated WEBP, multi-page TIFF -> PDF, ...).
    static readonly HashSet<string> MultiFrameTargets = ["gif", "webp", "tiff", "pdf"];

    public static void Convert(string input, string output, TargetFormat target)
    {
        using var frames = Read(input);

        if (MultiFrameTargets.Contains(target.Extension) && frames.Count > 1)
        {
            if (target.Extension == "gif" || target.Extension == "webp")
                frames.Coalesce();
            foreach (var frame in frames)
                Prepare(frame, target.Extension);
            frames.Write(output, FormatFor(target.Extension));
            return;
        }

        // Single-frame target: keep the biggest frame (an .ico holds many sizes, the largest is the useful one).
        var image = frames.OrderByDescending(f => (long)f.Width * f.Height).First();
        Prepare(image, target.Extension);
        image.Write(output, FormatFor(target.Extension));
    }

    /// <summary>Combines every input image into one PDF, one page per image.</summary>
    public static void MergeToPdf(IReadOnlyList<string> inputs, string output, Action<string>? onFileRead = null)
    {
        using var pages = new MagickImageCollection();
        foreach (var input in inputs)
        {
            using var frames = Read(input);
            foreach (var frame in frames)
            {
                var page = (MagickImage)frame.Clone();
                Prepare(page, "pdf");
                pages.Add(page);
            }
            onFileRead?.Invoke(input);
        }
        pages.Write(output, MagickFormat.Pdf);
    }

    static MagickImageCollection Read(string input)
    {
        var settings = new MagickReadSettings();
        var ext = Formats.ExtensionOf(input);
        if (ext == "svg")
            settings.Density = new Density(192); // render vectors at 2x instead of a blurry 96 dpi
        else if (ext == "nef")
            settings.Defines = new DngReadDefines { UseCameraWhiteBalance = true }; // match what the photographer saw
        var frames = new MagickImageCollection(input, settings);
        if (ext == "nef")
            foreach (var frame in frames)
                frame.Depth = 8; // RAW reports 16 bits but this Q8 build holds 8; don't write files twice the size for nothing
        return frames;
    }

    static void Prepare(IMagickImage<byte> image, string ext)
    {
        image.AutoOrient(); // phone photos store rotation in EXIF; bake it in so it survives the conversion

        switch (ext)
        {
            case "jpg":
            case "pdf":
                // No transparency in JPG: put it on white instead of letting it turn black.
                if (image.HasAlpha)
                {
                    image.BackgroundColor = MagickColors.White;
                    image.Alpha(AlphaAction.Remove);
                }
                image.Quality = 92;
                break;
            case "webp":
            case "avif":
                image.Quality = 90;
                break;
            case "ico":
                // Icons are square and at most 256px; pad to a square and embed the standard sizes.
                var side = Math.Max(image.Width, image.Height);
                image.BackgroundColor = MagickColors.Transparent;
                image.Extent(side, side, Gravity.Center);
                if (side > 256)
                    image.Resize(256, 256);
                image.Settings.SetDefine(MagickFormat.Icon, "auto-resize", "256,128,64,48,32,16");
                break;
        }
    }

    static MagickFormat FormatFor(string ext) => ext switch
    {
        "jpg" => MagickFormat.Jpeg,
        "png" => MagickFormat.Png,
        "webp" => MagickFormat.WebP,
        "gif" => MagickFormat.Gif,
        "bmp" => MagickFormat.Bmp,
        "tiff" => MagickFormat.Tiff,
        "ico" => MagickFormat.Icon,
        "avif" => MagickFormat.Avif,
        "pdf" => MagickFormat.Pdf,
        _ => throw new NotSupportedException($"Can't write .{ext} images."),
    };
}
