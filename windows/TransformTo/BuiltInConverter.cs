using Lokad.OoxPdf;
using Lokad.OoxPdf.Fonts;

namespace TransformTo;

/// <summary>
/// Turns PowerPoint, Word and Excel files into PDF without Office or LibreOffice, so the most common document
/// conversion works on any PC. PPTX/DOCX go through Lokad.OoxPdf, XLSX through MiniPdf; both are plain managed code.
/// </summary>
static class BuiltInConverter
{
    public static bool CanConvert(string inputExt, string targetExt) =>
        targetExt == "pdf" && inputExt is "pptx" or "docx" or "xlsx";

    public static void ConvertToPdf(string input, string output)
    {
        // Write to a scratch file first so a failure never leaves a half-written PDF next to the original.
        var temp = output + ".tmp";
        try
        {
            try
            {
                if (Formats.ExtensionOf(input) == "xlsx")
                {
                    MiniSoftware.MiniPdf.ConvertToPdf(input, temp);
                }
                else
                {
                    OoxPdfConverter.Convert(input, temp, new OoxPdfOptions
                    {
                        InputKind = Formats.ExtensionOf(input) == "pptx" ? OoxPdfInputKind.Pptx : OoxPdfInputKind.Docx,
                        FontResolver = Fonts,
                    });
                }
            }
            catch (Exception ex) when (ex is InvalidDataException or ArgumentException or FormatException
                                           or InvalidOperationException or NotSupportedException
                                           or System.Xml.XmlException or KeyNotFoundException)
            {
                // The libraries' own messages ("Central Directory corrupt", ...) mean nothing to most people.
                throw new InvalidOperationException(
                    "The file couldn't be read. It may be damaged, password-protected or not really a " +
                    $".{Formats.ExtensionOf(input)} file.", ex);
            }

            if (!File.Exists(temp) || new FileInfo(temp).Length == 0)
                throw new InvalidOperationException("The file could not be converted.");
            File.Move(temp, output);
        }
        finally
        {
            try { File.Delete(temp); } catch { }
        }
    }

    static readonly SubstitutingFontResolver Fonts = new(new WindowsFontResolver());

    /// <summary>
    /// When a document uses a font this PC doesn't have (very common without Office: Aptos, Calibri, ...), the library
    /// would pick the alphabetically first installed font, which can be something decorative. Pick a look-alike instead.
    /// </summary>
    sealed class SubstitutingFontResolver(IFontResolver inner) : IFontResolver
    {
        public FontFaceResolution Resolve(FontRequest request)
        {
            var resolved = inner.Resolve(request);
            if (!resolved.IsFallback)
                return resolved;
            foreach (var family in Substitutes(request.FamilyName))
            {
                var candidate = inner.Resolve(new FontRequest(family, request.Bold, request.Italic));
                if (!candidate.IsFallback)
                    return new FontFaceResolution(request.FamilyName, candidate.ResolvedFamily, candidate.Style,
                                                  candidate.Source, true);
            }
            return resolved;
        }

        static string[] Substitutes(string family)
        {
            var name = family.ToLowerInvariant();
            if (name.Contains("mono") || name.Contains("courier") || name.Contains("consol") || name.Contains("code"))
                return ["Consolas", "Courier New"];
            if (name.Contains("narrow") || name.Contains("condensed"))
                return ["Arial Narrow", "Bahnschrift SemiCondensed", "Calibri", "Arial"];
            if (name.Contains("serif") && !name.Contains("sans") || name.Contains("times") || name.Contains("roman")
                || name.Contains("georgia") || name.Contains("garamond") || name.Contains("cambria")
                || name.Contains("book") || name.Contains("baskerville") || name.Contains("palatino")
                || name.Contains("merriweather") || name.Contains("playfair") || name.Contains("lora"))
                return ["Cambria", "Georgia", "Times New Roman"];
            if (name.Contains("light"))
                return ["Calibri Light", "Segoe UI Light", "Calibri", "Arial"];
            return ["Calibri", "Segoe UI", "Arial"];
        }
    }
}
