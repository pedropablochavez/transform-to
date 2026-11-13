import AppKit

/// Prints the visible sheets of an Excel (.xlsx) workbook into a PDF the way Excel paginates them: column widths, row
/// heights, number and date formats, fonts, fills, borders, merged cells, wrapped text and the sheet's page setup
/// (orientation, paper, margins, scale, fit to page). Light gridlines are drawn so plain tables stay readable.
/// Charts and pictures placed on sheets are not drawn.
@MainActor
final class SpreadsheetPDF {
    private struct Font {
        var name: String?
        var size: CGFloat = 11
        var bold = false
        var italic = false
        var underline = false
        var strike = false
        var color: RGBA?
    }

    private struct Edge {
        var color: RGBA
        var width: CGFloat
    }

    private struct Style {
        var font = Font()
        var fill: RGBA?
        var numFmt = 0
        var horizontal: String?
        var vertical: String?
        var wrap = false
        var indent: CGFloat = 0
        var left: Edge?
        var right: Edge?
        var top: Edge?
        var bottom: Edge?

        var showsWithoutValue: Bool { fill != nil || left != nil || right != nil || top != nil || bottom != nil }
    }

    private enum Kind {
        case text, number, logical
    }

    private struct Cell {
        var text: String
        var style: Int
        var kind: Kind
    }

    private struct Key: Hashable {
        let row: Int
        let col: Int
    }

    private struct Merge {
        let top: Int, left: Int, bottom: Int, right: Int
    }

    private struct Sheet {
        var cells: [Key: Cell] = [:]
        var columnsInRow: [Int: [Int]] = [:]
        var colWidths: [Int: CGFloat] = [:]
        var rowHeights: [Int: CGFloat] = [:]
        var defaultColWidth: CGFloat = 48
        var defaultRowHeight: CGFloat = 15
        var merges: [Merge] = []
        var mergedCells: [Key: Int] = [:]
        var maxRow = 0
        var maxCol = 0
        var landscape = false
        var paper: CGSize?
        var margins = (l: CGFloat(50.4), r: CGFloat(50.4), t: CGFloat(54), b: CGFloat(54))
        var scale: CGFloat = 1
        var fitToPage = false
        var fitWidth = 1
        var fitHeight = 1
        var overThenDown = false
        var centered = false

        func width(_ col: Int) -> CGFloat { colWidths[col] ?? defaultColWidth }
        func height(_ row: Int) -> CGFloat { rowHeights[row] ?? defaultRowHeight }
    }

    private struct Token {
        let literal: Bool
        let text: String
    }

    private let package: OfficePackage
    private let workbookPart: String
    private let workbook: XMLElement
    private let theme: OfficeTheme
    private let date1904: Bool
    private var sharedStrings: [String] = []
    private var styles: [Style] = []
    private var customFormats: [Int: String] = [:]
    private var palette = SpreadsheetPDF.defaultPalette
    private var defaultFont = Font()
    private var numberFormatters: [String: NumberFormatter] = [:]
    private var dateFormatters: [String: DateFormatter] = [:]

    init(_ package: OfficePackage) throws {
        guard let main = package.target(of: "", type: "officeDocument"), let root = package.xml(main) else {
            throw OfficeFormatError()
        }
        self.package = package
        workbookPart = main
        workbook = root
        theme = OfficeTheme(package.target(of: main, type: "theme").flatMap { package.xml($0) })
        date1904 = root.child("workbookPr")?.flag("date1904") == true
        loadSharedStrings()
        loadStyles()
    }

    func render(to url: URL) throws {
        let rels = package.relationships(of: workbookPart)
        let writer = try PDFWriter(url: url)
        var pages = 0
        for entry in workbook.child("sheets")?.elements("sheet") ?? [] {
            guard entry.attr("state") == nil || entry.attr("state") == "visible",
                  let id = entry.attr("r:id"), let rel = rels[id], rel.type == "worksheet",
                  let root = package.xml(rel.target) else { continue }
            pages += draw(parseSheet(root), writer)
        }
        writer.close()
        guard pages > 0 else { throw ConversionError("The spreadsheet is empty.") }
    }

    // MARK: Workbook parts

    private func loadSharedStrings() {
        guard let part = package.target(of: workbookPart, type: "sharedStrings"), let table = package.xml(part) else { return }
        sharedStrings = table.elements("si").map { si in
            if let t = si.child("t") { return Self.decode(t.stringValue ?? "") }
            return Self.decode(si.elements("r").compactMap { $0.child("t")?.stringValue }.joined())
        }
    }

    private func loadStyles() {
        guard let part = package.target(of: workbookPart, type: "styles"), let sheet = package.xml(part) else { return }
        let custom = sheet.at("colors", "indexedColors")?.elements("rgbColor").compactMap { RGBA(hex: $0.attr("rgb")) } ?? []
        if !custom.isEmpty { palette = custom }
        for format in sheet.child("numFmts")?.elements("numFmt") ?? [] {
            if let id = format.number("numFmtId"), let code = format.attr("formatCode") { customFormats[Int(id)] = code }
        }
        let fonts = sheet.child("fonts")?.elements("font").map { parseFont($0) } ?? []
        let fills = sheet.child("fills")?.elements("fill").map { parseFill($0) } ?? []
        let borders = sheet.child("borders")?.elements("border").map { parseBorder($0) } ?? []
        defaultFont = fonts.first ?? Font()

        styles = sheet.child("cellXfs")?.elements("xf").map { xf in
            var style = Style()
            style.font = defaultFont
            if let i = xf.number("fontId").map({ Int($0) }), i >= 0, i < fonts.count { style.font = fonts[i] }
            if let i = xf.number("fillId").map({ Int($0) }), i >= 0, i < fills.count { style.fill = fills[i] }
            if let i = xf.number("borderId").map({ Int($0) }), i >= 0, i < borders.count {
                (style.left, style.right, style.top, style.bottom) = borders[i]
            }
            style.numFmt = xf.number("numFmtId").map { Int($0) } ?? 0
            if let alignment = xf.child("alignment") {
                style.horizontal = alignment.attr("horizontal")
                style.vertical = alignment.attr("vertical")
                style.wrap = alignment.flag("wrapText") == true
                style.indent = CGFloat(alignment.number("indent") ?? 0) * 9
            }
            return style
        } ?? []
    }

    private func parseFont(_ el: XMLElement) -> Font {
        var font = Font()
        font.name = el.child("name")?.attr("val")
        if let size = el.child("sz")?.number("val") { font.size = CGFloat(size) }
        font.bold = el.child("b").map { $0.flag("val") ?? true } ?? false
        font.italic = el.child("i").map { $0.flag("val") ?? true } ?? false
        font.strike = el.child("strike").map { $0.flag("val") ?? true } ?? false
        font.underline = el.child("u").map { $0.attr("val") != "none" } ?? false
        font.color = color(el.child("color"))
        return font
    }

    private func parseFill(_ el: XMLElement) -> RGBA? {
        if let pattern = el.child("patternFill") {
            switch pattern.attr("patternType") ?? "none" {
            case "none": return nil
            case "solid": return color(pattern.child("fgColor")) ?? color(pattern.child("bgColor"))
            default:
                // Hatched patterns: draw their average color.
                let fg = color(pattern.child("fgColor")) ?? .black
                let bg = color(pattern.child("bgColor")) ?? .white
                return bg.mixed(with: fg, 0.3)
            }
        }
        return color(el.at("gradientFill", "stop", "color"))
    }

    private func parseBorder(_ el: XMLElement) -> (Edge?, Edge?, Edge?, Edge?) {
        func edge(_ name: String) -> Edge? {
            guard let side = el.child(name), let style = side.attr("style"), style != "none" else { return nil }
            let width: CGFloat
            switch style {
            case "hair": width = 0.25
            case "medium", "mediumDashed", "mediumDashDot", "mediumDashDotDot", "slantDashDot": width = 1
            case "thick", "double": width = 1.5
            default: width = 0.5
            }
            return Edge(color: color(side.child("color")) ?? .black, width: width)
        }
        return (edge("left"), edge("right"), edge("top"), edge("bottom"))
    }

    private func color(_ el: XMLElement?) -> RGBA? {
        guard let el, el.flag("auto") != true else { return nil }
        var result: RGBA?
        if let rgb = el.attr("rgb") {
            result = RGBA(hex: rgb)
        } else if let index = el.number("theme").map({ Int($0) }), index >= 0, index < OfficeTheme.excelOrder.count {
            result = theme.colors[OfficeTheme.excelOrder[index]]
        } else if let index = el.number("indexed").map({ Int($0) }), index >= 0, index < palette.count {
            result = palette[index]
        }
        if let tint = el.number("tint"), tint != 0, let base = result {
            let t = CGFloat(tint)
            result = base.hsl { h, s, l in (h, s, t < 0 ? l * (1 + t) : l * (1 - t) + t) }
        }
        return result
    }

    // MARK: Sheets

    private func parseSheet(_ root: XMLElement) -> Sheet {
        var sheet = Sheet()
        let format = root.child("sheetFormatPr")
        if let width = format?.number("defaultColWidth") {
            sheet.defaultColWidth = Self.points(forWidth: CGFloat(width))
        } else if let base = format?.number("baseColWidth") {
            sheet.defaultColWidth = ceil((CGFloat(base) * 7 + 5) / 8) * 8 * 0.75
        }
        if let height = format?.number("defaultRowHeight") { sheet.defaultRowHeight = CGFloat(height) }

        for col in root.child("cols")?.elements("col") ?? [] {
            guard let lo = col.number("min").map({ Int($0) }), let hi = col.number("max").map({ Int($0) }), lo >= 1, hi >= lo else { continue }
            let width = col.flag("hidden") == true ? 0 : Self.points(forWidth: CGFloat(col.number("width") ?? 9.14))
            for c in lo...min(hi, 16_384) { sheet.colWidths[c] = width }
        }

        var autoHeightRows: [Int] = []
        var nextRow = 1
        for row in root.child("sheetData")?.elements("row") ?? [] {
            let r = row.number("r").map { Int($0) } ?? nextRow
            nextRow = r + 1
            if row.flag("hidden") == true {
                sheet.rowHeights[r] = 0
            } else if let height = row.number("ht") {
                sheet.rowHeights[r] = CGFloat(height)
            } else {
                autoHeightRows.append(r)
            }
            var nextCol = 1
            for c in row.elements("c") {
                let (cellRow, cellCol) = c.attr("r").flatMap { Self.reference($0) } ?? (r, nextCol)
                nextCol = cellCol + 1
                let styleIndex = c.number("s").map { Int($0) } ?? 0
                let style = self.style(styleIndex)
                let cell: Cell
                if let shown = value(c, style) {
                    cell = Cell(text: shown.0, style: styleIndex, kind: shown.1)
                } else if style.showsWithoutValue {
                    cell = Cell(text: "", style: styleIndex, kind: .text)
                } else {
                    continue
                }
                let key = Key(row: cellRow, col: cellCol)
                if sheet.cells[key] == nil { sheet.columnsInRow[cellRow, default: []].append(cellCol) }
                sheet.cells[key] = cell
                sheet.maxRow = max(sheet.maxRow, cellRow)
                sheet.maxCol = max(sheet.maxCol, cellCol)
            }
        }

        for merge in root.child("mergeCells")?.elements("mergeCell") ?? [] {
            let parts = (merge.attr("ref") ?? "").split(separator: ":").compactMap { Self.reference(String($0)) }
            guard parts.count == 2 else { continue }
            let m = Merge(top: min(parts[0].0, parts[1].0), left: min(parts[0].1, parts[1].1),
                          bottom: max(parts[0].0, parts[1].0), right: max(parts[0].1, parts[1].1))
            guard (m.bottom - m.top + 1) * (m.right - m.left + 1) <= 100_000 else { continue }
            sheet.merges.append(m)
            for r in m.top...m.bottom {
                for c in m.left...m.right { sheet.mergedCells[Key(row: r, col: c)] = sheet.merges.count - 1 }
            }
            sheet.maxRow = max(sheet.maxRow, m.bottom)
            sheet.maxCol = max(sheet.maxCol, m.right)
        }

        // Rows saved without a height are sized to their content when Excel opens the file; do the same.
        for r in autoHeightRows {
            var needed = sheet.defaultRowHeight
            for c in sheet.columnsInRow[r] ?? [] {
                guard let cell = sheet.cells[Key(row: r, col: c)], !cell.text.isEmpty, sheet.mergedCells[Key(row: r, col: c)] == nil else { continue }
                let style = self.style(cell.style)
                let text = attributed(cell.text, style, alignment: .left, wraps: style.wrap)
                if style.wrap {
                    let width = max(sheet.width(c) - 4, 1)
                    needed = max(needed, ceil(text.boundingRect(with: CGSize(width: width, height: 100_000),
                                                                options: [.usesLineFragmentOrigin, .usesFontLeading]).height) + 3)
                } else if let font = text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont {
                    let line = ceil(font.ascender - font.descender + font.leading) + 1.5
                    if line > needed + 0.5 { needed = line }
                }
            }
            sheet.rowHeights[r] = needed
        }

        if let setup = root.child("pageSetup") {
            sheet.landscape = setup.attr("orientation") == "landscape"
            sheet.paper = Self.paperSizes[Int(setup.number("paperSize") ?? 0)]
            if let scale = setup.number("scale"), scale >= 10, scale <= 400 { sheet.scale = CGFloat(scale) / 100 }
            sheet.fitWidth = setup.number("fitToWidth").map { Int($0) } ?? 1
            sheet.fitHeight = setup.number("fitToHeight").map { Int($0) } ?? 1
            sheet.overThenDown = setup.attr("pageOrder") == "overThenDown"
        }
        sheet.fitToPage = root.at("sheetPr", "pageSetUpPr")?.flag("fitToPage") == true
        if let margins = root.child("pageMargins") {
            let inch = { (name: String, fallback: Double) in CGFloat(margins.number(name) ?? fallback) * 72 }
            sheet.margins = (l: inch("left", 0.7), r: inch("right", 0.7), t: inch("top", 0.75), b: inch("bottom", 0.75))
        }
        sheet.centered = root.child("printOptions")?.flag("horizontalCentered") == true
        return sheet
    }

    private func style(_ index: Int) -> Style {
        if index >= 0, index < styles.count { return styles[index] }
        var style = Style()
        style.font = defaultFont
        return style
    }

    private func value(_ c: XMLElement, _ style: Style) -> (String, Kind)? {
        let type = c.attr("t") ?? "n"
        if type == "inlineStr" {
            guard let inline = c.child("is") else { return nil }
            let text = inline.child("t")?.stringValue ?? inline.elements("r").compactMap { $0.child("t")?.stringValue }.joined()
            return text.isEmpty ? nil : (Self.decode(text), .text)
        }
        guard let raw = c.child("v")?.stringValue, !raw.isEmpty else { return nil }
        switch type {
        case "s":
            guard let index = Int(raw), index >= 0, index < sharedStrings.count, !sharedStrings[index].isEmpty else { return nil }
            return (sharedStrings[index], .text)
        case "b":
            return (raw == "1" ? "TRUE" : "FALSE", .logical)
        case "e":
            return (raw, .logical)
        case "str":
            return (Self.decode(raw), .text)
        case "d":
            return (raw.hasSuffix("T00:00:00") ? String(raw.dropLast(9)) : raw, .number)
        default:
            guard let number = Double(raw) else { return (raw, .text) }
            return (format(number, style.numFmt), .number)
        }
    }

    /// "AB12" → (row 12, column 28).
    private static func reference(_ ref: String) -> (Int, Int)? {
        var col = 0, row = 0
        for scalar in ref.uppercased().unicodeScalars {
            switch scalar.value {
            case 36: continue
            case 65...90 where row == 0: col = col * 26 + Int(scalar.value - 64)
            case 48...57: row = row * 10 + Int(scalar.value - 48)
            default: return nil
            }
        }
        return row > 0 && col > 0 ? (row, col) : nil
    }

    /// Column widths are stored in "characters" of the default font's digit width (7 pixels for Calibri 11).
    private static func points(forWidth width: CGFloat) -> CGFloat {
        width <= 0 ? 0 : (width * 7).rounded() * 0.75
    }

    private static let paperSizes: [Int: CGSize] = [
        1: CGSize(width: 612, height: 792), 3: CGSize(width: 792, height: 1224), 5: CGSize(width: 612, height: 1008),
        8: CGSize(width: 842, height: 1191), 9: CGSize(width: 595, height: 842), 11: CGSize(width: 420, height: 595),
    ]

    /// Excel writes some characters as "_x000D_".
    private static func decode(_ text: String) -> String {
        guard text.contains("_x"), let regex = try? NSRegularExpression(pattern: "_x([0-9A-Fa-f]{4})_") else { return text }
        let ns = text as NSString
        var result = ""
        var last = 0
        for match in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: match.range.location - last))
            if let value = UInt32(ns.substring(with: match.range(at: 1)), radix: 16), let scalar = UnicodeScalar(value) {
                result.append(Character(scalar))
            }
            last = match.range.location + match.range.length
        }
        return result + ns.substring(from: last)
    }

    // MARK: Pages

    private func draw(_ sheet: Sheet, _ writer: PDFWriter) -> Int {
        guard sheet.maxRow > 0, sheet.maxCol > 0 else { return 0 }
        var paper = sheet.paper ?? (Locale.current.usesMetricSystem ? CGSize(width: 595, height: 842) : CGSize(width: 612, height: 792))
        if sheet.landscape { paper = CGSize(width: paper.height, height: paper.width) }
        let printable = CGSize(width: max(paper.width - sheet.margins.l - sheet.margins.r, 72),
                               height: max(paper.height - sheet.margins.t - sheet.margins.b, 72))
        let widths = (1...sheet.maxCol).map { sheet.width($0) }
        let heights = (1...sheet.maxRow).map { sheet.height($0) }

        var scale = sheet.scale
        if sheet.fitToPage {
            var fit: CGFloat = 1
            let totalWidth = widths.reduce(0, +), totalHeight = heights.reduce(0, +)
            if sheet.fitWidth > 0, totalWidth > 0 { fit = min(fit, printable.width * CGFloat(sheet.fitWidth) / totalWidth) }
            if sheet.fitHeight > 0, totalHeight > 0 { fit = min(fit, printable.height * CGFloat(sheet.fitHeight) / totalHeight) }
            scale = max(fit, 0.1)
        }
        let columnBands = bands(widths, limit: printable.width / scale)
        let rowBands = bands(heights, limit: printable.height / scale)
        let order: [(ClosedRange<Int>, ClosedRange<Int>)] = sheet.overThenDown
            ? rowBands.flatMap { rows in columnBands.map { (rows, $0) } }
            : columnBands.flatMap { cols in rowBands.map { ($0, cols) } }

        var pages = 0
        for (rows, cols) in order where hasContent(sheet, rows, cols) {
            writer.page(size: paper) { cg in
                var bandWidth: CGFloat = 0
                for c in cols { bandWidth += widths[c - 1] * scale }
                let left = sheet.centered ? (paper.width - bandWidth) / 2 : sheet.margins.l
                cg.translateBy(x: left, y: sheet.margins.t)
                cg.scaleBy(x: scale, y: scale)
                self.drawPage(sheet, rows, cols, widths, heights, cg)
            }
            pages += 1
        }
        return pages
    }

    /// Splits rows or columns (sizes in order) into runs that each fit on a page.
    private func bands(_ sizes: [CGFloat], limit: CGFloat) -> [ClosedRange<Int>] {
        var result: [ClosedRange<Int>] = []
        var start = 1
        var used: CGFloat = 0
        for (i, size) in sizes.enumerated() {
            let index = i + 1
            if used + size > limit + 0.01, index > start {
                result.append(start...(index - 1))
                start = index
                used = 0
            }
            used += size
        }
        result.append(start...sizes.count)
        return result
    }

    private func hasContent(_ sheet: Sheet, _ rows: ClosedRange<Int>, _ cols: ClosedRange<Int>) -> Bool {
        for r in rows {
            if let columns = sheet.columnsInRow[r], columns.contains(where: { cols.contains($0) }) { return true }
        }
        return sheet.merges.contains { $0.bottom >= rows.lowerBound && $0.top <= rows.upperBound && $0.right >= cols.lowerBound && $0.left <= cols.upperBound }
    }

    private func drawPage(_ sheet: Sheet, _ rows: ClosedRange<Int>, _ cols: ClosedRange<Int>,
                          _ widths: [CGFloat], _ heights: [CGFloat], _ cg: CGContext) {
        // Positions relative to the page's first row and column (negative before it, for merges that start earlier).
        /// Total size of rows/columns `from..<to` (1-based).
        func span(_ sizes: [CGFloat], _ from: Int, _ to: Int) -> CGFloat {
            var total: CGFloat = 0
            var i = from
            while i < to {
                total += sizes[i - 1]
                i += 1
            }
            return total
        }
        func x(_ col: Int) -> CGFloat {
            col >= cols.lowerBound ? span(widths, cols.lowerBound, col) : -span(widths, col, cols.lowerBound)
        }
        func y(_ row: Int) -> CGFloat {
            row >= rows.lowerBound ? span(heights, rows.lowerBound, row) : -span(heights, row, rows.lowerBound)
        }
        var xs: [Int: CGFloat] = [:]
        var position: CGFloat = 0
        for c in cols {
            xs[c] = position
            position += widths[c - 1]
        }
        let pageWidth = position
        var ys: [Int: CGFloat] = [:]
        position = 0
        for r in rows {
            ys[r] = position
            position += heights[r - 1]
        }
        let pageHeight = position
        func cellRect(_ r: Int, _ c: Int) -> CGRect {
            CGRect(x: xs[c] ?? x(c), y: ys[r] ?? y(r), width: widths[c - 1], height: heights[r - 1])
        }
        func mergeRect(_ m: Merge) -> CGRect {
            CGRect(x: x(m.left), y: y(m.top), width: span(widths, m.left, m.right + 1),
                   height: span(heights, m.top, m.bottom + 1))
        }
        let merges = sheet.merges.filter {
            $0.bottom >= rows.lowerBound && $0.top <= rows.upperBound && $0.right >= cols.lowerBound && $0.left <= cols.upperBound
        }

        cg.saveGState()
        cg.clip(to: CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight))

        // Gridlines, then fills over them (merged areas hide the lines inside), then borders, then text.
        cg.setStrokeColor(RGBA(r: 0.84, g: 0.84, b: 0.84).cgColor)
        cg.setLineWidth(0.5)
        for c in cols where widths[c - 1] > 0 {
            cg.move(to: CGPoint(x: xs[c]!, y: 0))
            cg.addLine(to: CGPoint(x: xs[c]!, y: pageHeight))
        }
        cg.move(to: CGPoint(x: pageWidth, y: 0))
        cg.addLine(to: CGPoint(x: pageWidth, y: pageHeight))
        for r in rows where heights[r - 1] > 0 {
            cg.move(to: CGPoint(x: 0, y: ys[r]!))
            cg.addLine(to: CGPoint(x: pageWidth, y: ys[r]!))
        }
        cg.move(to: CGPoint(x: 0, y: pageHeight))
        cg.addLine(to: CGPoint(x: pageWidth, y: pageHeight))
        cg.strokePath()

        var visible: [(Key, Cell, CGRect)] = []
        for r in rows {
            for c in sheet.columnsInRow[r] ?? [] where cols.contains(c) {
                let key = Key(row: r, col: c)
                guard sheet.mergedCells[key] == nil, let cell = sheet.cells[key] else { continue }
                visible.append((key, cell, cellRect(r, c)))
            }
        }
        for m in merges {
            let key = Key(row: m.top, col: m.left)
            visible.append((key, sheet.cells[key] ?? Cell(text: "", style: 0, kind: .text), mergeRect(m)))
        }

        for (key, cell, r) in visible {
            let isMerge = sheet.mergedCells[key] != nil
            let fill = sheet.cells[key] == nil ? nil : style(cell.style).fill
            if let fill = fill ?? (isMerge ? RGBA.white : nil) {
                cg.setFillColor(fill.cgColor)
                cg.fill(r)
            }
        }
        for (key, cell, r) in visible where sheet.cells[key] != nil {
            let style = self.style(cell.style)
            let sides: [(Edge?, CGPoint, CGPoint)] = [
                (style.left, CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.minX, y: r.maxY)),
                (style.right, CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY)),
                (style.top, CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY)),
                (style.bottom, CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY)),
            ]
            for (edge, from, to) in sides {
                guard let edge else { continue }
                cg.setStrokeColor(edge.color.cgColor)
                cg.setLineWidth(edge.width)
                cg.move(to: from)
                cg.addLine(to: to)
                cg.strokePath()
            }
        }

        for (key, cell, r) in visible where !cell.text.isEmpty {
            let style = self.style(cell.style)
            let horizontal = style.horizontal ?? (cell.kind == .number ? "right" : cell.kind == .logical ? "center" : "general")
            // Text that doesn't fit spills into empty neighbours, as on screen.
            var room = r
            if !style.wrap, cell.kind == .text, sheet.mergedCells[key] == nil {
                func empty(_ c: Int) -> Bool {
                    let k = Key(row: key.row, col: c)
                    return cols.contains(c) && sheet.mergedCells[k] == nil && (sheet.cells[k]?.text.isEmpty ?? true)
                }
                if horizontal == "general" || horizontal == "left" || horizontal == "center" {
                    var c = key.col + 1
                    while empty(c) { room.size.width += widths[c - 1]; c += 1 }
                }
                if horizontal == "right" || horizontal == "center" {
                    var c = key.col - 1
                    while c >= 1, empty(c) { room.origin.x -= widths[c - 1]; room.size.width += widths[c - 1]; c -= 1 }
                }
            }
            drawText(cell, style, horizontal: horizontal, in: r, room: room, cg)
        }
        cg.restoreGState()
    }

    private func attributed(_ text: String, _ style: Style, alignment: NSTextAlignment, wraps: Bool) -> NSAttributedString {
        let font = style.font
        let (nsFont, expansion) = OfficeFonts.font(font.name ?? defaultFont.name, size: font.size, bold: font.bold, italic: font.italic)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineBreakMode = wraps ? .byWordWrapping : .byClipping
        var attributes: [NSAttributedString.Key: Any] = [
            .font: nsFont, .foregroundColor: (font.color ?? .black).nsColor, .paragraphStyle: paragraph,
        ]
        if expansion != 0 { attributes[.expansion] = expansion }
        if font.underline { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if font.strike { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        let shown = wraps ? text : text.replacingOccurrences(of: "\n", with: " ")
        return NSAttributedString(string: shown, attributes: attributes)
    }

    private func drawText(_ cell: Cell, _ style: Style, horizontal: String, in r: CGRect, room: CGRect, _ cg: CGContext) {
        let alignment: NSTextAlignment
        switch horizontal {
        case "center", "centerContinuous", "distributed": alignment = .center
        case "right": alignment = .right
        case "justify": alignment = .justified
        default: alignment = .left
        }
        let options: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]
        var text = attributed(cell.text, style, alignment: alignment, wraps: style.wrap)
        let padding: CGFloat = 2
        var box: CGRect
        if style.wrap {
            let width = max(r.width - 2 * padding - style.indent, 1)
            let height = ceil(text.boundingRect(with: CGSize(width: width, height: 100_000), options: options).height)
            box = CGRect(x: r.minX + padding + (alignment == .left ? style.indent : 0), y: 0, width: width, height: height)
        } else {
            var size = text.boundingRect(with: CGSize(width: 100_000, height: 100_000), options: options).size
            // A number that doesn't fit shows as ### in Excel rather than a misleading cut-off figure.
            if cell.kind == .number, size.width > r.width - 2 * padding, let font = text.attribute(.font, at: 0, effectiveRange: nil) as? NSFont {
                let hashWidth = NSAttributedString(string: "#", attributes: [.font: font]).size().width
                let count = max(1, Int((r.width - 2 * padding) / max(hashWidth, 1)))
                text = attributed(String(repeating: "#", count: count), style, alignment: alignment, wraps: false)
                size = text.boundingRect(with: CGSize(width: 100_000, height: 100_000), options: options).size
            }
            let width = ceil(size.width) + 2
            let originX: CGFloat
            switch alignment {
            case .right: originX = r.maxX - padding - width
            case .center: originX = r.midX - width / 2
            default: originX = r.minX + padding + style.indent
            }
            box = CGRect(x: originX, y: 0, width: width, height: ceil(size.height))
        }
        switch style.vertical {
        case "top": box.origin.y = r.minY + 1
        case "center", "distributed", "justify": box.origin.y = r.midY - box.height / 2
        default: box.origin.y = r.maxY - box.height - 1
        }
        box.size.height += 2
        cg.saveGState()
        cg.clip(to: style.wrap ? r : room)
        text.draw(with: box, options: options, context: nil)
        cg.restoreGState()
    }

    // MARK: Number formats

    private static let builtInFormats: [Int: String] = [
        0: "General", 1: "0", 2: "0.00", 3: "#,##0", 4: "#,##0.00", 5: "$#,##0_);($#,##0)", 6: "$#,##0_);[Red]($#,##0)",
        7: "$#,##0.00_);($#,##0.00)", 8: "$#,##0.00_);[Red]($#,##0.00)", 9: "0%", 10: "0.00%", 11: "0.00E+00",
        12: "General", 13: "General", 15: "d-mmm-yy", 16: "d-mmm", 17: "mmm-yy", 18: "h:mm AM/PM",
        19: "h:mm:ss AM/PM", 20: "h:mm", 21: "h:mm:ss", 37: "#,##0 ;(#,##0)", 38: "#,##0 ;[Red](#,##0)",
        39: "#,##0.00;(#,##0.00)", 40: "#,##0.00;[Red](#,##0.00)", 45: "mm:ss", 46: "[h]:mm:ss", 47: "mm:ss",
        48: "##0.0E+0", 49: "@",
    ]

    private func format(_ value: Double, _ id: Int) -> String {
        if id == 14 || id == 22, customFormats[id] == nil {
            // The "short date" formats follow the reader's own regional settings, in Excel too.
            let key = "short-\(id)"
            if dateFormatters[key] == nil {
                let f = DateFormatter()
                f.timeZone = TimeZone(identifier: "UTC")
                f.dateStyle = .short
                f.timeStyle = id == 22 ? .short : .none
                dateFormatters[key] = f
            }
            return dateFormatters[key]!.string(from: date(value))
        }
        return format(value, code: customFormats[id] ?? Self.builtInFormats[id] ?? "General")
    }

    private func format(_ value: Double, code: String) -> String {
        let sections = Self.sections(code)
        var section = sections.first ?? "General"
        var v = value
        var signShown = false
        if value < 0, sections.count > 1, !sections[1].isEmpty {
            section = sections[1]
            v = -value
            signShown = true
        } else if value == 0, sections.count > 2 {
            section = sections[2]
        }
        let tokens = Self.tokenize(section)
        let formatChars = tokens.filter { !$0.literal }.map(\.text).joined().lowercased()
        if formatChars.isEmpty, !tokens.isEmpty { return tokens.map(\.text).joined() }
        let isDate = formatChars.contains { "ymdhs".contains($0) }
        if formatChars.contains("general") || formatChars == "@" || formatChars.isEmpty || (formatChars.contains("/") && !isDate) {
            return Self.general(value)
        }
        if isDate {
            return formatDate(v, tokens)
        }
        return formatNumber(v, tokens, negative: value < 0 && !signShown)
    }

    private static func sections(_ code: String) -> [String] {
        var result: [String] = []
        var current = ""
        var inQuotes = false, inBrackets = false, escaped = false
        for ch in code {
            if escaped {
                current.append(ch)
                escaped = false
                continue
            }
            switch ch {
            case "\\": escaped = true
            case "\"": inQuotes.toggle()
            case "[" where !inQuotes: inBrackets = true
            case "]" where !inQuotes: inBrackets = false
            case ";" where !inQuotes && !inBrackets:
                result.append(current)
                current = ""
                continue
            default: break
            }
            current.append(ch)
        }
        result.append(current)
        return result
    }

    private static func tokenize(_ section: String) -> [Token] {
        let chars = Array(section)
        var tokens: [Token] = []
        var i = 0
        while i < chars.count {
            let ch = chars[i]
            switch ch {
            case "\"":
                var j = i + 1
                var text = ""
                while j < chars.count, chars[j] != "\"" {
                    text.append(chars[j])
                    j += 1
                }
                tokens.append(Token(literal: true, text: text))
                i = j + 1
            case "\\":
                if i + 1 < chars.count { tokens.append(Token(literal: true, text: String(chars[i + 1]))) }
                i += 2
            case "_":
                tokens.append(Token(literal: true, text: " "))
                i += 2
            case "*":
                i += 2
            case "[":
                var j = i + 1
                var text = ""
                while j < chars.count, chars[j] != "]" {
                    text.append(chars[j])
                    j += 1
                }
                if text.hasPrefix("$") {
                    // Currency and locale: [$€-407] shows "€".
                    let symbol = text.dropFirst().split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
                    if !symbol.isEmpty { tokens.append(Token(literal: true, text: symbol)) }
                } else if ["h", "hh", "m", "mm", "s", "ss"].contains(text.lowercased()) {
                    tokens.append(Token(literal: false, text: text))
                }
                i = j + 1
            default:
                tokens.append(Token(literal: false, text: String(ch)))
                i += 1
            }
        }
        return tokens
    }

    private func formatNumber(_ value: Double, _ tokens: [Token], negative: Bool) -> String {
        let isDigit = { (t: Token) in !t.literal && "0#?".contains(t.text) }
        guard let first = tokens.firstIndex(where: isDigit), let last = tokens.lastIndex(where: isDigit) else {
            return tokens.map(\.text).joined()
        }
        var core = tokens[first...last].filter { !$0.literal }.map(\.text).joined()
        let prefix = tokens[..<first].map(\.text).joined()
        var suffixTokens = Array(tokens[(last + 1)...])
        var v = value
        for t in tokens where !t.literal && t.text == "%" { v *= 100 }
        // Commas right after the digits divide by a thousand each.
        while let t = suffixTokens.first, !t.literal, t.text == "," {
            suffixTokens.removeFirst()
            v /= 1000
        }
        let suffix = suffixTokens.map(\.text).joined()

        let body: String
        if let e = core.firstIndex(where: { $0 == "E" || $0 == "e" }) {
            let mantissa = core[..<e]
            let decimals = mantissa.split(separator: ".", omittingEmptySubsequences: false).dropFirst().first?.count ?? 0
            body = Self.scientific(abs(v), decimals)
        } else {
            core = core.replacingOccurrences(of: "?", with: "#")
            let parts = core.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
            let integer = String(parts[0]), fraction = parts.count > 1 ? String(parts[1]) : ""
            let key = core
            if numberFormatters[key] == nil {
                let f = NumberFormatter()
                f.locale = .current
                f.numberStyle = .decimal
                f.usesGroupingSeparator = integer.contains(",")
                f.minimumIntegerDigits = integer.filter { $0 == "0" }.count
                f.minimumFractionDigits = fraction.filter { $0 == "0" }.count
                f.maximumFractionDigits = fraction.filter { $0 == "0" || $0 == "#" }.count
                f.roundingMode = .halfUp
                numberFormatters[key] = f
            }
            body = numberFormatters[key]!.string(from: NSNumber(value: abs(v))) ?? String(abs(v))
        }
        let isZero = !body.contains { $0.isNumber && $0 != "0" }
        return (negative && !isZero ? "-" : "") + prefix + body + suffix
    }

    private static func scientific(_ value: Double, _ decimals: Int) -> String {
        guard value != 0 else { return String(format: "%.\(decimals)fE+00", 0.0) }
        var exponent = Int(floor(log10(value)))
        var mantissa = value / pow(10, Double(exponent))
        let factor = pow(10, Double(decimals))
        mantissa = (mantissa * factor).rounded() / factor
        if mantissa >= 10 {
            mantissa /= 10
            exponent += 1
        }
        return String(format: "%.\(decimals)f", mantissa) + "E" + (exponent < 0 ? "-" : "+") + String(format: "%02d", abs(exponent))
    }

    private static let generalFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.locale = .current
        f.numberStyle = .decimal
        f.usesGroupingSeparator = false
        f.usesSignificantDigits = true
        f.maximumSignificantDigits = 10
        return f
    }()

    private static func general(_ value: Double) -> String {
        let magnitude = abs(value)
        if value == 0 { return "0" }
        if magnitude >= 1e11 || magnitude < 1e-9 {
            var text = scientific(magnitude, 5)
            // 1.20000E+11 → 1.2E+11
            if let e = text.firstIndex(of: "E") {
                var mantissa = String(text[..<e])
                while mantissa.hasSuffix("0") { mantissa.removeLast() }
                if mantissa.hasSuffix(".") { mantissa.removeLast() }
                text = mantissa + text[e...]
            }
            return (value < 0 ? "-" : "") + text
        }
        if value == value.rounded(), magnitude < 1e15 { return String(Int64(value)) }
        return generalFormatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    private func formatDate(_ value: Double, _ tokens: [Token]) -> String {
        struct Item {
            let ch: Character
            let literal: Bool
        }
        let items = tokens.flatMap { token in token.text.map { Item(ch: $0, literal: token.literal) } }
        let lowerCode = String(items.filter { !$0.literal }.map(\.ch)).lowercased()
        let twelveHour = lowerCode.contains("am/pm") || lowerCode.contains("a/p")
        func lower(_ k: Int) -> Character? {
            k < items.count && !items[k].literal ? Character(items[k].ch.lowercased()) : nil
        }
        func matches(_ word: String, at k: Int) -> Bool {
            for (offset, ch) in word.enumerated() where lower(k + offset) != ch { return false }
            return true
        }
        var pattern = ""
        func literal(_ text: String) {
            pattern += "'" + text.replacingOccurrences(of: "'", with: "''") + "'"
        }
        var afterHour = false
        var i = 0
        while i < items.count {
            if items[i].literal {
                literal(String(items[i].ch))
                i += 1
                continue
            }
            guard let c = lower(i) else { break }
            if c == "a", matches("am/pm", at: i) {
                pattern += "a"
                i += 5
                continue
            }
            if c == "a", matches("a/p", at: i) {
                pattern += "a"
                i += 3
                continue
            }
            guard "ymdhs".contains(c) else {
                literal(String(items[i].ch))
                i += 1
                continue
            }
            var count = 0
            while lower(i + count) == c { count += 1 }
            switch c {
            case "y":
                pattern += count <= 2 ? "yy" : "yyyy"
            case "d":
                pattern += count == 1 ? "d" : count == 2 ? "dd" : count == 3 ? "EEE" : "EEEE"
            case "h":
                pattern += twelveHour ? (count == 1 ? "h" : "hh") : (count == 1 ? "H" : "HH")
            case "s":
                pattern += count == 1 ? "s" : "ss"
            default:
                // "m" is minutes right after hours or right before seconds, months otherwise.
                var k = i + count
                while let l = lower(k), !"ymdhs".contains(l), l != "a" { k += 1 }
                let beforeSeconds = lower(k) == "s"
                if count <= 2, afterHour || beforeSeconds {
                    pattern += count == 1 ? "m" : "mm"
                } else {
                    pattern += count == 1 ? "M" : count == 2 ? "MM" : count == 3 ? "MMM" : count == 4 ? "MMMM" : "MMMMM"
                }
            }
            afterHour = c == "h"
            i += count
        }
        if dateFormatters[pattern] == nil {
            let f = DateFormatter()
            f.locale = .current
            f.timeZone = TimeZone(identifier: "UTC")
            f.dateFormat = pattern
            dateFormatters[pattern] = f
        }
        return dateFormatters[pattern]!.string(from: date(value))
    }

    /// Excel stores dates as days since 1900 (with its famous fake 29 February 1900) or since 1904.
    private func date(_ serial: Double) -> Date {
        if date1904 { return Date(timeIntervalSince1970: -2_082_844_800 + (serial * 86_400).rounded()) }
        let days = serial < 61 ? serial + 1 : serial
        return Date(timeIntervalSince1970: -2_209_161_600 + (days * 86_400).rounded())
    }

    private static let defaultPalette: [RGBA] = [
        "000000", "FFFFFF", "FF0000", "00FF00", "0000FF", "FFFF00", "FF00FF", "00FFFF",
        "000000", "FFFFFF", "FF0000", "00FF00", "0000FF", "FFFF00", "FF00FF", "00FFFF",
        "800000", "008000", "000080", "808000", "800080", "008080", "C0C0C0", "808080",
        "9999FF", "993366", "FFFFCC", "CCFFFF", "660066", "FF8080", "0066CC", "CCCCFF",
        "000080", "FF00FF", "FFFF00", "00FFFF", "800080", "800000", "008080", "0000FF",
        "00CCFF", "CCFFFF", "CCFFCC", "FFFF99", "99CCFF", "FF99CC", "CC99FF", "FFCC99",
        "3366FF", "33CCCC", "99CC00", "FFCC00", "FF9900", "FF6600", "666699", "969696",
        "003366", "339966", "003300", "333300", "993300", "993366", "333399", "333333",
        "000000", "FFFFFF",
    ].compactMap { RGBA(hex: $0) }
}
