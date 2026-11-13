import AppKit
import Compression
import ImageIO

/// PowerPoint and Excel files to PDF with nothing but macOS itself: the file is unzipped and its XML drawn with
/// Core Graphics and the AppKit text system. macOS has no public API that renders Office files (Quick Look does it
/// out of process and WebKit only on iOS), so this plays the role Lokad.OoxPdf and MiniPdf play on Windows.
@MainActor
enum OfficePDF {
    static func canConvert(_ input: URL) -> Bool {
        ["pptx", "xlsx"].contains(input.pathExtension.lowercased())
    }

    static func convert(_ input: URL, to output: URL) throws {
        let ext = input.pathExtension.lowercased()
        // Write to a scratch file first so a failure never leaves a half-written PDF next to the original.
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("TransformTo-\(UUID().uuidString).pdf")
        defer { try? FileManager.default.removeItem(at: temp) }
        do {
            let package = try OfficePackage(url: input)
            if ext == "pptx" {
                try PresentationPDF(package).render(to: temp)
            } else {
                try SpreadsheetPDF(package).render(to: temp)
            }
        } catch let error as ConversionError {
            throw error
        } catch {
            throw ConversionError("The file couldn't be read. It may be damaged, password-protected or not really a .\(ext) file.")
        }
        try FileManager.default.moveItem(at: temp, to: output)
    }
}

struct OfficeFormatError: Error {}

// MARK: - ZIP

/// Just enough of a ZIP reader for Office files, which are ZIP archives of XML parts (stored or deflated).
struct ZipArchive {
    private let data: Data
    private var entries: [String: Entry] = [:]

    private struct Entry {
        let method: Int
        let compressedSize: Int
        let size: Int
        let headerOffset: Int
    }

    init(url: URL) throws {
        data = try Data(contentsOf: url, options: .mappedIfSafe)
        let count = data.count
        guard count >= 22 else { throw OfficeFormatError() }

        // The central directory's end record sits in the last 22 bytes plus an optional comment.
        var end = -1
        var i = count - 22
        let lowest = max(0, count - 22 - 65_535)
        while i >= lowest {
            if data[i] == 0x50, data[i + 1] == 0x4b, data[i + 2] == 0x05, data[i + 3] == 0x06 {
                end = i
                break
            }
            i -= 1
        }
        guard end >= 0 else { throw OfficeFormatError() }

        let total = try u16(end + 10)
        var p = try u32(end + 16)
        for _ in 0..<total {
            guard try u32(p) == 0x0201_4b50 else { throw OfficeFormatError() }
            let method = try u16(p + 10)
            let compressed = try u32(p + 20)
            let size = try u32(p + 24)
            let nameLength = try u16(p + 28)
            let extraLength = try u16(p + 30)
            let commentLength = try u16(p + 32)
            let offset = try u32(p + 42)
            guard p + 46 + nameLength <= count else { throw OfficeFormatError() }
            let name = String(decoding: data[(p + 46)..<(p + 46 + nameLength)], as: UTF8.self)
            entries[name.lowercased()] = Entry(method: method, compressedSize: compressed, size: size, headerOffset: offset)
            p += 46 + nameLength + extraLength + commentLength
        }
    }

    func read(_ name: String) throws -> Data? {
        guard let entry = entries[name.lowercased()] else { return nil }
        let header = entry.headerOffset
        guard try u32(header) == 0x0403_4b50 else { throw OfficeFormatError() }
        let nameLength = try u16(header + 26)
        let extraLength = try u16(header + 28)
        let start = header + 30 + nameLength + extraLength
        guard start + entry.compressedSize <= data.count else { throw OfficeFormatError() }
        let raw = data.subdata(in: start..<(start + entry.compressedSize))
        switch entry.method {
        case 0: return raw
        case 8: return try inflate(raw, size: entry.size)
        default: throw OfficeFormatError()
        }
    }

    private func inflate(_ raw: Data, size: Int) throws -> Data {
        guard size > 0 else { return Data() }
        guard !raw.isEmpty, size < 1 << 30 else { throw OfficeFormatError() }
        var output = Data(count: size)
        let written = output.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) -> Int in
            raw.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
                // COMPRESSION_ZLIB is raw DEFLATE, exactly what ZIP stores.
                compression_decode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, size,
                                          src.bindMemory(to: UInt8.self).baseAddress!, raw.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written == size else { throw OfficeFormatError() }
        return output
    }

    private func u16(_ offset: Int) throws -> Int {
        guard offset >= 0, offset + 2 <= data.count else { throw OfficeFormatError() }
        return Int(data[offset]) | Int(data[offset + 1]) << 8
    }

    private func u32(_ offset: Int) throws -> Int {
        try u16(offset) | u16(offset + 2) << 16
    }
}

// MARK: - Package parts and relationships

@MainActor
final class OfficePackage {
    struct Relationship {
        let type: String
        let target: String
    }

    private let zip: ZipArchive
    private var documents: [String: XMLDocument] = [:]
    private var relationshipCache: [String: [String: Relationship]] = [:]
    private var imageCache: [String: CGImage] = [:]

    init(url: URL) throws {
        zip = try ZipArchive(url: url)
    }

    func data(_ part: String) -> Data? {
        try? zip.read(part)
    }

    func xml(_ part: String) -> XMLElement? {
        if let document = documents[part] { return document.rootElement() }
        guard let data = data(part),
              let document = try? XMLDocument(data: data, options: [.nodeLoadExternalEntitiesNever]) else { return nil }
        documents[part] = document
        return document.rootElement()
    }

    /// The relationships of a part, by id, with targets resolved to part names. "" is the package itself.
    func relationships(of part: String) -> [String: Relationship] {
        if let cached = relationshipCache[part] { return cached }
        let dir = (part as NSString).deletingLastPathComponent
        let file = (part as NSString).lastPathComponent
        let relsPart = dir.isEmpty ? "_rels/\(file).rels" : "\(dir)/_rels/\(file).rels"
        var result: [String: Relationship] = [:]
        for rel in xml(relsPart)?.elements("Relationship") ?? [] {
            guard let id = rel.attr("Id"), let target = rel.attr("Target"), rel.attr("TargetMode") != "External" else { continue }
            let type = (rel.attr("Type") ?? "").components(separatedBy: "/").last ?? ""
            result[id] = Relationship(type: type, target: Self.resolve(target, from: dir))
        }
        relationshipCache[part] = result
        return result
    }

    func target(of part: String, type: String) -> String? {
        relationships(of: part).values.first { $0.type == type }?.target
    }

    func image(_ part: String) -> CGImage? {
        if let cached = imageCache[part] { return cached }
        guard let data = data(part),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        imageCache[part] = image
        return image
    }

    static func resolve(_ target: String, from dir: String) -> String {
        var components = target.hasPrefix("/") ? [] : dir.split(separator: "/").map(String.init)
        for component in target.split(separator: "/") {
            if component == ".." {
                if !components.isEmpty { components.removeLast() }
            } else if component != "." {
                components.append(String(component))
            }
        }
        let path = components.joined(separator: "/")
        return path.removingPercentEncoding ?? path
    }
}

extension XMLElement {
    var elementChildren: [XMLElement] {
        children?.compactMap { $0 as? XMLElement } ?? []
    }

    /// First child element with this local name (namespace prefixes are ignored).
    func child(_ name: String) -> XMLElement? {
        children?.first { $0.kind == .element && $0.localName == name } as? XMLElement
    }

    func at(_ names: String...) -> XMLElement? {
        var element: XMLElement? = self
        for name in names { element = element?.child(name) }
        return element
    }

    func elements(_ name: String) -> [XMLElement] {
        elementChildren.filter { $0.localName == name }
    }

    func firstDescendant(_ name: String) -> XMLElement? {
        for child in elementChildren {
            if child.localName == name { return child }
            if let found = child.firstDescendant(name) { return found }
        }
        return nil
    }

    /// An attribute by name. "r:id" matches any prefixed attribute whose local name is "id"; "id" only an unprefixed one.
    func attr(_ name: String) -> String? {
        guard let attributes else { return nil }
        if let colon = name.firstIndex(of: ":") {
            let local = String(name[name.index(after: colon)...])
            return attributes.first { ($0.name ?? "").contains(":") && $0.localName == local }?.stringValue
        }
        return attributes.first { $0.name == name }?.stringValue
    }

    func number(_ name: String) -> Double? {
        attr(name).flatMap(Double.init)
    }

    /// OOXML booleans are written "1", "true" or "on".
    func flag(_ name: String) -> Bool? {
        guard let value = attr(name) else { return nil }
        return value == "1" || value == "true" || value == "on"
    }
}

// MARK: - Colors, themes and fonts

struct RGBA {
    var r: CGFloat
    var g: CGFloat
    var b: CGFloat
    var a: CGFloat = 1

    static let black = RGBA(r: 0, g: 0, b: 0)
    static let white = RGBA(r: 1, g: 1, b: 1)

    /// "RRGGBB", or Excel's "AARRGGBB" (whose alpha Excel itself ignores).
    init?(hex: String?) {
        guard var hex, hex.count == 6 || hex.count == 8 else { return nil }
        if hex.count == 8 { hex = String(hex.dropFirst(2)) }
        guard let value = UInt32(hex, radix: 16) else { return nil }
        r = CGFloat((value >> 16) & 0xFF) / 255
        g = CGFloat((value >> 8) & 0xFF) / 255
        b = CGFloat(value & 0xFF) / 255
    }

    init(r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat = 1) {
        self.r = r
        self.g = g
        self.b = b
        self.a = a
    }

    var cgColor: CGColor { CGColor(srgbRed: r, green: g, blue: b, alpha: a) }
    var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }

    func mixed(with other: RGBA, _ amount: CGFloat) -> RGBA {
        RGBA(r: r + (other.r - r) * amount, g: g + (other.g - g) * amount, b: b + (other.b - b) * amount, a: a)
    }

    /// Changes hue/saturation/luminance, the space Office's color modifiers work in.
    func hsl(_ change: (CGFloat, CGFloat, CGFloat) -> (CGFloat, CGFloat, CGFloat)) -> RGBA {
        let maxC = max(r, g, b), minC = min(r, g, b)
        var h: CGFloat = 0, s: CGFloat = 0
        let l = (maxC + minC) / 2
        let d = maxC - minC
        if d > 0 {
            s = l > 0.5 ? d / (2 - maxC - minC) : d / (maxC + minC)
            if maxC == r {
                h = (g - b) / d + (g < b ? 6 : 0)
            } else if maxC == g {
                h = (b - r) / d + 2
            } else {
                h = (r - g) / d + 4
            }
            h /= 6
        }
        var (nh, ns, nl) = change(h, s, l)
        ns = min(max(ns, 0), 1)
        nl = min(max(nl, 0), 1)
        nh = nh - floor(nh)
        guard ns > 0 else { return RGBA(r: nl, g: nl, b: nl, a: a) }
        let q = nl < 0.5 ? nl * (1 + ns) : nl + ns - nl * ns
        let p = 2 * nl - q
        func channel(_ t0: CGFloat) -> CGFloat {
            var t = t0
            if t < 0 { t += 1 }
            if t > 1 { t -= 1 }
            if t < 1 / 6 { return p + (q - p) * 6 * t }
            if t < 1 / 2 { return q }
            if t < 2 / 3 { return p + (q - p) * (2 / 3 - t) * 6 }
            return p
        }
        return RGBA(r: channel(nh + 1 / 3), g: channel(nh), b: channel(nh - 1 / 3), a: a)
    }
}

/// The parts of a DrawingML theme (ppt/theme/theme1.xml, xl/theme/theme1.xml) that drawing needs.
struct OfficeTheme {
    var colors: [String: RGBA] = [:]
    var majorFont = "Calibri Light"
    var minorFont = "Calibri"
    var fillStyles: [XMLElement] = []
    var lineStyles: [XMLElement] = []
    var backgroundFills: [XMLElement] = []

    /// Excel refers to theme colors by number, with light and dark swapped compared to the theme's own order.
    static let excelOrder = ["lt1", "dk1", "lt2", "dk2", "accent1", "accent2", "accent3", "accent4", "accent5",
                             "accent6", "hlink", "folHlink"]

    init(_ root: XMLElement?) {
        colors = ["dk1": .black, "lt1": .white, "dk2": RGBA(hex: "44546A")!, "lt2": RGBA(hex: "E7E6E6")!,
                  "accent1": RGBA(hex: "4472C4")!, "accent2": RGBA(hex: "ED7D31")!, "accent3": RGBA(hex: "A5A5A5")!,
                  "accent4": RGBA(hex: "FFC000")!, "accent5": RGBA(hex: "5B9BD5")!, "accent6": RGBA(hex: "70AD47")!,
                  "hlink": RGBA(hex: "0563C1")!, "folHlink": RGBA(hex: "954F72")!]
        guard let elements = root?.child("themeElements") else { return }
        for entry in elements.child("clrScheme")?.elementChildren ?? [] {
            guard let name = entry.localName else { continue }
            if let color = RGBA(hex: entry.child("srgbClr")?.attr("val")) ?? RGBA(hex: entry.child("sysClr")?.attr("lastClr")) {
                colors[name] = color
            }
        }
        if let font = elements.at("fontScheme", "majorFont", "latin")?.attr("typeface"), !font.isEmpty { majorFont = font }
        if let font = elements.at("fontScheme", "minorFont", "latin")?.attr("typeface"), !font.isEmpty { minorFont = font }
        fillStyles = elements.at("fmtScheme", "fillStyleLst")?.elementChildren ?? []
        lineStyles = elements.at("fmtScheme", "lnStyleLst")?.elements("ln") ?? []
        backgroundFills = elements.at("fmtScheme", "bgFillStyleLst")?.elementChildren ?? []
    }
}

/// Office documents name fonts that a Mac without Office doesn't have (Calibri, Aptos, Cambria...). Use a look-alike
/// that ships with macOS, narrowed a little where the original is narrower, so lines break about where they did.
@MainActor
enum OfficeFonts {
    private static var installed: [String: Bool] = [:]

    private static let substitutes: [String: (String, CGFloat)] = {
        var map: [String: (String, CGFloat)] = [:]
        for name in ["calibri", "calibri light", "carlito", "aptos narrow"] { map[name] = ("Helvetica Neue", 0.9) }
        for name in ["aptos", "aptos display", "aptos light", "segoe ui", "segoe ui light", "segoe ui semibold",
                     "corbel", "candara", "franklin gothic book", "franklin gothic medium", "century gothic",
                     "tw cen mt", "dengxian", "yu gothic", "meiryo", "malgun gothic"] {
            map[name] = ("Helvetica Neue", 1)
        }
        for name in ["cambria", "cambria math", "constantia", "book antiqua", "garamond", "caladea", "bookman old style",
                     "century", "century schoolbook"] {
            map[name] = ("Times New Roman", 1)
        }
        for name in ["consolas", "lucida console", "cascadia code", "cascadia mono"] { map[name] = ("Menlo", 1) }
        map["palatino linotype"] = ("Palatino", 1)
        return map
    }()

    /// Font plus the glyph expansion to apply (NSAttributedString's `.expansion`, a log factor).
    static func font(_ family: String?, size: CGFloat, bold: Bool, italic: Bool) -> (NSFont, CGFloat) {
        let size = max(size, 1)
        let requested = (family ?? "").trimmingCharacters(in: .whitespaces)
        var name = "Helvetica Neue"
        var widthFactor: CGFloat = 1
        if !requested.isEmpty, isInstalled(requested) {
            name = requested
        } else if let substitute = substitutes[requested.lowercased()] {
            (name, widthFactor) = substitute
        }

        var traits: NSFontTraitMask = []
        if bold { traits.insert(.boldFontMask) }
        if italic { traits.insert(.italicFontMask) }
        let manager = NSFontManager.shared
        let font = manager.font(withFamily: name, traits: traits, weight: bold ? 9 : 5, size: size)
            ?? manager.font(withFamily: name, traits: [], weight: 5, size: size).map { manager.convert($0, toHaveTrait: traits) }
            ?? (bold ? NSFont.boldSystemFont(ofSize: size) : NSFont.systemFont(ofSize: size))
        return (font, log(widthFactor))
    }

    private static func isInstalled(_ family: String) -> Bool {
        if let known = installed[family] { return known }
        let found = NSFontManager.shared.availableMembers(ofFontFamily: family) != nil
        installed[family] = found
        return found
    }
}

// MARK: - PDF output

/// A multi-page PDF where every page is drawn top-down (y grows downwards, as in Office files), with AppKit text
/// drawing available.
@MainActor
final class PDFWriter {
    private let context: CGContext

    init(url: URL) throws {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else {
            throw ConversionError("Couldn't create the PDF.")
        }
        self.context = context
    }

    func page(size: CGSize, _ draw: (CGContext) -> Void) {
        var box = CGRect(origin: .zero, size: size)
        let boxData = withUnsafeBytes(of: &box) { Data($0) }
        context.beginPDFPage([kCGPDFContextMediaBox as String: boxData] as CFDictionary)
        context.saveGState()
        context.translateBy(x: 0, y: size.height)
        context.scaleBy(x: 1, y: -1)
        let previous = NSGraphicsContext.current
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        draw(context)
        NSGraphicsContext.current = previous
        context.restoreGState()
        context.endPDFPage()
    }

    func close() {
        context.closePDF()
    }
}

extension CGContext {
    /// Draws an image the right way up in a top-down context, optionally cropped first (fractions of each side).
    func drawUpright(_ image: CGImage, in rect: CGRect, crop: (l: CGFloat, t: CGFloat, r: CGFloat, b: CGFloat)? = nil) {
        var image = image
        if let crop {
            let w = CGFloat(image.width), h = CGFloat(image.height)
            let l = max(0, crop.l), t = max(0, crop.t), r = max(0, crop.r), b = max(0, crop.b)
            let area = CGRect(x: w * l, y: h * t, width: w * (1 - l - r), height: h * (1 - t - b)).integral
            if area.width >= 1, area.height >= 1, let cropped = image.cropping(to: area) { image = cropped }
        }
        saveGState()
        translateBy(x: rect.minX, y: rect.maxY)
        scaleBy(x: 1, y: -1)
        interpolationQuality = .high
        draw(image, in: CGRect(origin: .zero, size: rect.size))
        restoreGState()
    }
}
