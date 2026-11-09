import Foundation

enum Engine: Sendable {
    case image, document, spreadsheet, presentation
}

/// A format files can be transformed to. `id` matches the Windows version's command-line ids.
struct TargetFormat: Hashable, Sendable {
    let id: String
    let label: String
    let ext: String
}

enum Formats {
    // ImageIO can read WEBP/AVIF but not write them, so they're inputs only on Mac.
    static let imageTargets: [TargetFormat] = [
        .init(id: "jpg", label: "JPG", ext: "jpg"),
        .init(id: "png", label: "PNG", ext: "png"),
        .init(id: "heic", label: "HEIC", ext: "heic"),
        .init(id: "gif", label: "GIF", ext: "gif"),
        .init(id: "bmp", label: "BMP", ext: "bmp"),
        .init(id: "tiff", label: "TIFF", ext: "tiff"),
        .init(id: "ico", label: "ICO (icon)", ext: "ico"),
        .init(id: "pdf", label: "PDF", ext: "pdf"),
        .init(id: "pdf-merge", label: "PDF (all in one)", ext: "pdf"),
    ]

    static let documentTargets: [TargetFormat] = [
        .init(id: "pdf", label: "PDF", ext: "pdf"),
        .init(id: "docx", label: "DOCX (Word)", ext: "docx"),
        .init(id: "doc", label: "DOC (Word 97)", ext: "doc"),
        .init(id: "odt", label: "ODT", ext: "odt"),
        .init(id: "rtf", label: "RTF", ext: "rtf"),
        .init(id: "txt", label: "TXT", ext: "txt"),
        .init(id: "html", label: "HTML", ext: "html"),
    ]

    static let spreadsheetTargets: [TargetFormat] = [
        .init(id: "pdf", label: "PDF", ext: "pdf"),
        .init(id: "xlsx", label: "XLSX (Excel)", ext: "xlsx"),
        .init(id: "xls", label: "XLS (Excel 97)", ext: "xls"),
        .init(id: "ods", label: "ODS", ext: "ods"),
        .init(id: "csv", label: "CSV", ext: "csv"),
    ]

    static let presentationTargets: [TargetFormat] = [
        .init(id: "pdf", label: "PDF", ext: "pdf"),
        .init(id: "pptx", label: "PPTX (PowerPoint)", ext: "pptx"),
        .init(id: "ppt", label: "PPT (PowerPoint 97)", ext: "ppt"),
        .init(id: "odp", label: "ODP", ext: "odp"),
    ]

    static let inputs: [String: Engine] = [
        "jpg": .image, "jpeg": .image, "jfif": .image, "png": .image, "bmp": .image, "gif": .image,
        "tif": .image, "tiff": .image, "webp": .image, "heic": .image, "heif": .image, "avif": .image,
        "ico": .image, "nef": .image,
        "docx": .document, "doc": .document, "odt": .document, "rtf": .document,
        "xlsx": .spreadsheet, "xls": .spreadsheet, "ods": .spreadsheet, "csv": .spreadsheet,
        "pptx": .presentation, "ppt": .presentation, "odp": .presentation,
    ]

    static func targets(for engine: Engine) -> [TargetFormat] {
        switch engine {
        case .image: return imageTargets
        case .document: return documentTargets
        case .spreadsheet: return spreadsheetTargets
        case .presentation: return presentationTargets
        }
    }

    static func engine(of url: URL) -> Engine? {
        inputs[url.pathExtension.lowercased()]
    }

    /// Formats every selected file can be transformed to, minus the format they all already are.
    static func targets(for urls: [URL]) -> [TargetFormat] {
        let engines = urls.compactMap(engine(of:))
        guard let first = engines.first else { return [] }
        var common = targets(for: first)
        for engine in engines.dropFirst() {
            let ids = Set(targets(for: engine).map(\.id))
            common = common.filter { ids.contains($0.id) }
        }
        let current = Set(urls.map { canonical($0.pathExtension.lowercased()) })
        return common.filter { !(current.count == 1 && current.contains(canonical($0.ext))) }
    }

    /// Folds aliases together so a .jpeg never offers "JPG" and a .tif never offers "TIFF".
    static func canonical(_ ext: String) -> String {
        switch ext {
        case "jpeg", "jfif": return "jpg"
        case "tif": return "tiff"
        case "heif": return "heic"
        default: return ext
        }
    }
}
