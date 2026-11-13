import AppKit

/// Draws the slides of a PowerPoint (.pptx) file into a PDF, one page per slide: backgrounds, master and layout
/// decorations, shapes, pictures, text with the styles it inherits from its layout and master, tables and SmartArt.
/// Charts, video, and effects such as shadows or 3-D are not drawn.
@MainActor
final class PresentationPDF {
    private struct Layer {
        let part: String
        let root: XMLElement
    }

    private struct Slide {
        let number: Int
        let slide: Layer
        let layout: Layer?
        let master: Layer?
        let theme: OfficeTheme
        let colorMap: [String: String]
    }

    private struct Frame {
        var rect: CGRect
        var rotation: CGFloat = 0
        var flipH = false
        var flipV = false
    }

    private struct Line {
        var color: RGBA
        var width: CGFloat
        var dash: [CGFloat]?
        var head = false
        var tail = false
    }

    private enum Border {
        case hidden
        case line(Line)
    }

    private enum Fill {
        case empty
        case solid(RGBA)
        case gradient([(CGFloat, RGBA)], angle: CGFloat, radial: Bool)
        case image(CGImage, crop: (l: CGFloat, t: CGFloat, r: CGFloat, b: CGFloat)?)
    }

    private struct Placeholder {
        let type: String
        let idx: String?
    }

    /// Where a text body's look comes from: list styles from the shape itself up to the master, plus the color and
    /// weight a shape style or table style gives its text (which beat everything inherited, but not the run's own).
    private struct TextContext {
        var listStyles: [XMLElement?]
        var styleColor: RGBA?
        var styleBold: Bool?
        var fontScale: CGFloat = 1
        var spacingReduction: CGFloat = 0
    }

    private let package: OfficePackage
    private let mainPart: String
    private let presentation: XMLElement
    private let slideSize: CGSize
    private var tableStyles: [String: XMLElement] = [:]
    private var defaultTableStyle = PresentationPDF.mediumStyle2Id
    private var themes: [String: OfficeTheme] = [:]

    init(_ package: OfficePackage) throws {
        guard let main = package.target(of: "", type: "officeDocument"), let root = package.xml(main) else {
            throw OfficeFormatError()
        }
        self.package = package
        mainPart = main
        presentation = root
        let size = root.child("sldSz")
        let width = emu(size?.attr("cx")), height = emu(size?.attr("cy"))
        slideSize = width > 0 && height > 0 ? CGSize(width: width, height: height) : CGSize(width: 720, height: 540)
        if let part = package.target(of: main, type: "tableStyles"), let styles = package.xml(part) {
            if let def = styles.attr("def") { defaultTableStyle = def }
            for style in styles.elements("tblStyle") {
                if let id = style.attr("styleId") { tableStyles[id] = style }
            }
        }
    }

    func render(to url: URL) throws {
        let rels = package.relationships(of: mainPart)
        let slideParts = presentation.child("sldIdLst")?.elements("sldId").compactMap { slide in
            slide.attr("r:id").flatMap { rels[$0]?.target }
        } ?? []
        let first = Int(presentation.attr("firstSlideNum") ?? "") ?? 1

        let writer = try PDFWriter(url: url)
        var pages = 0
        for (index, part) in slideParts.enumerated() {
            // Hidden slides are left out, as PowerPoint's own "Save as PDF" does.
            guard let root = package.xml(part), root.flag("show") != false else { continue }
            let slide = makeSlide(part, root, number: first + index)
            writer.page(size: slideSize) { cg in self.draw(slide, cg) }
            pages += 1
        }
        writer.close()
        guard pages > 0 else { throw ConversionError("The presentation has no slides to show.") }
    }

    private func makeSlide(_ part: String, _ root: XMLElement, number: Int) -> Slide {
        let layoutPart = package.target(of: part, type: "slideLayout")
        let layout = layoutPart.flatMap { p in package.xml(p).map { Layer(part: p, root: $0) } }
        let masterPart = layoutPart.flatMap { package.target(of: $0, type: "slideMaster") }
        let master = masterPart.flatMap { p in package.xml(p).map { Layer(part: p, root: $0) } }

        var theme = OfficeTheme(nil)
        if let themePart = masterPart.flatMap({ package.target(of: $0, type: "theme") }) {
            if let cached = themes[themePart] {
                theme = cached
            } else {
                theme = OfficeTheme(package.xml(themePart))
                themes[themePart] = theme
            }
        }

        var colorMap = ["bg1": "lt1", "tx1": "dk1", "bg2": "lt2", "tx2": "dk2"]
        for source in [master?.root.child("clrMap"), layout?.root.at("clrMapOvr", "overrideClrMapping"),
                       root.at("clrMapOvr", "overrideClrMapping")] {
            for attribute in source?.attributes ?? [] {
                if let name = attribute.name, let value = attribute.stringValue { colorMap[name] = value }
            }
        }
        return Slide(number: number, slide: Layer(part: part, root: root), layout: layout, master: master,
                     theme: theme, colorMap: colorMap)
    }

    private func draw(_ s: Slide, _ cg: CGContext) {
        let page = CGRect(origin: .zero, size: slideSize)
        cg.setFillColor(RGBA.white.cgColor)
        cg.fill(page)
        if let fill = background(s) { paint(fill, CGPath(rect: page, transform: nil), page, cg) }

        if s.slide.root.flag("showMasterSp") != false {
            if s.layout?.root.flag("showMasterSp") != false, let master = s.master {
                drawTree(master.root.at("cSld", "spTree"), s, master, cg)
            }
            if let layout = s.layout { drawTree(layout.root.at("cSld", "spTree"), s, layout, cg) }
        }
        drawTree(s.slide.root.at("cSld", "spTree"), s, s.slide, cg)
    }

    private func background(_ s: Slide) -> Fill? {
        for layer in [s.slide, s.layout, s.master].compactMap({ $0 }) {
            guard let bg = layer.root.at("cSld", "bg") else { continue }
            if let properties = bg.child("bgPr") { return fill(in: properties, s, layer.part, ph: nil) }
            if let ref = bg.child("bgRef") {
                let idx = Int(ref.number("idx") ?? 0)
                let color = self.color(in: ref, s, ph: nil)
                let list = idx >= 1001 ? s.theme.backgroundFills : s.theme.fillStyles
                let i = idx >= 1001 ? idx - 1001 : idx - 1
                if i >= 0, i < list.count, let themed = fillElement(list[i], s, layer.part, ph: color) { return themed }
                return color.map { .solid($0) }
            }
        }
        return nil
    }

    // MARK: Shape tree

    private func drawTree(_ tree: XMLElement?, _ s: Slide, _ layer: Layer, _ cg: CGContext) {
        for element in tree?.elementChildren ?? [] { drawElement(element, s, layer, cg) }
    }

    private func drawElement(_ el: XMLElement, _ s: Slide, _ layer: Layer, _ cg: CGContext) {
        // Placeholders on layouts and masters are only templates ("Click to add title"); slides fill them in.
        let onTemplate = layer.part == s.layout?.part || layer.part == s.master?.part
        if onTemplate, placeholder(of: el) != nil { return }
        switch el.localName {
        case "sp", "cxnSp": drawShape(el, s, layer, cg)
        case "pic": drawPicture(el, s, layer, cg)
        case "grpSp": drawGroup(el, s, layer, cg)
        case "graphicFrame": drawGraphicFrame(el, s, layer, cg)
        case "AlternateContent":
            if let choice = el.child("Fallback") ?? el.child("Choice") { drawTree(choice, s, layer, cg) }
        default: break
        }
    }

    private func placeholder(of el: XMLElement) -> Placeholder? {
        guard let nv = el.elementChildren.first(where: { $0.localName?.hasPrefix("nv") == true }),
              let ph = nv.child("nvPr")?.child("ph") else { return nil }
        return Placeholder(type: ph.attr("type") ?? "obj", idx: ph.attr("idx"))
    }

    /// The shape, then the layout and master placeholders it takes its position and styles from.
    private func chain(_ el: XMLElement, _ s: Slide, _ layer: Layer) -> [XMLElement] {
        guard layer.part == s.slide.part, let ph = placeholder(of: el) else { return [el] }
        var result = [el]
        let fromLayout = find(ph, in: s.layout, useIndex: true)
        if let fromLayout { result.append(fromLayout) }
        if let fromMaster = find(fromLayout.flatMap { placeholder(of: $0) } ?? ph, in: s.master, useIndex: false) {
            result.append(fromMaster)
        }
        return result
    }

    private func find(_ ph: Placeholder, in layer: Layer?, useIndex: Bool) -> XMLElement? {
        let shapes = (layer?.root.at("cSld", "spTree")?.elementChildren ?? []).filter { placeholder(of: $0) != nil }
        if useIndex, let idx = ph.idx, let match = shapes.first(where: { placeholder(of: $0)?.idx == idx }) { return match }
        if useIndex, let match = shapes.first(where: { placeholder(of: $0)?.type == ph.type }) { return match }
        let wanted = Self.masterType(ph.type)
        return shapes.first { placeholder(of: $0).map { Self.masterType($0.type) } == wanted }
    }

    private static func masterType(_ type: String) -> String {
        switch type {
        case "ctrTitle": return "title"
        case "subTitle", "obj", "chart", "tbl", "clipArt", "dgm", "media", "pic": return "body"
        default: return type
        }
    }

    private func frame(_ xfrm: XMLElement?) -> Frame? {
        guard let xfrm, let off = xfrm.child("off"), let ext = xfrm.child("ext") else { return nil }
        return Frame(rect: CGRect(x: emu(off.attr("x")), y: emu(off.attr("y")),
                                  width: emu(ext.attr("cx")), height: emu(ext.attr("cy"))),
                     rotation: CGFloat(xfrm.number("rot") ?? 0) / 60_000,
                     flipH: xfrm.flag("flipH") == true, flipV: xfrm.flag("flipV") == true)
    }

    private func shapeFrame(_ chain: [XMLElement]) -> Frame? {
        for el in chain {
            if let f = frame(el.child("spPr")?.child("xfrm")) { return f }
        }
        return nil
    }

    /// Runs `body` with the context moved, rotated (and mirrored, unless it's text) into the frame, whose rect is then
    /// centered on the origin.
    private func inFrame(_ f: Frame, _ cg: CGContext, mirror: Bool, _ body: (CGRect) -> Void) {
        cg.saveGState()
        cg.translateBy(x: f.rect.midX, y: f.rect.midY)
        var angle = f.rotation
        if !mirror, f.flipV { angle += 180 }
        if angle != 0 { cg.rotate(by: angle * .pi / 180) }
        if mirror { cg.scaleBy(x: f.flipH ? -1 : 1, y: f.flipV ? -1 : 1) }
        body(CGRect(x: -f.rect.width / 2, y: -f.rect.height / 2, width: f.rect.width, height: f.rect.height))
        cg.restoreGState()
    }

    private func drawShape(_ el: XMLElement, _ s: Slide, _ layer: Layer, _ cg: CGContext) {
        let chain = chain(el, s, layer)
        guard let f = shapeFrame(chain) else { return }
        let properties = chain.compactMap { $0.child("spPr") }
        let style = el.child("style")
        let geometry = properties.first { $0.child("prstGeom") != nil || $0.child("custGeom") != nil }
        let fill = shapeFill(properties, style, s, layer.part)
        let line = shapeLine(properties, style, s)
        inFrame(f, cg, mirror: true) { r in
            let (path, closed) = self.outline(geometry, r)
            if closed, let fill { self.paint(fill, path, r, cg) }
            if let line { self.stroke(path, line, cg) }
        }
        if let body = el.child("txBody") {
            // SmartArt drawings give the text its own box.
            let textFrame = frame(el.child("txXfrm")) ?? f
            drawText(body, chain: chain, frame: textFrame, geometry: geometry, s, layer, style: style, cg)
        }
    }

    private func drawPicture(_ el: XMLElement, _ s: Slide, _ layer: Layer, _ cg: CGContext) {
        let chain = chain(el, s, layer)
        guard let f = shapeFrame(chain), let blipFill = el.child("blipFill"),
              let image = blipImage(blipFill, layer.part) else { return }
        let properties = chain.compactMap { $0.child("spPr") }
        let geometry = properties.first { $0.child("prstGeom") != nil || $0.child("custGeom") != nil }
        let line = shapeLine(properties, el.child("style"), s)
        let cropping = crop(blipFill.child("srcRect"))
        inFrame(f, cg, mirror: true) { r in
            let (path, _) = self.outline(geometry, r)
            cg.saveGState()
            cg.addPath(path)
            cg.clip()
            cg.drawUpright(image, in: r, crop: cropping)
            cg.restoreGState()
            if let line { self.stroke(path, line, cg) }
        }
    }

    private func drawGroup(_ el: XMLElement, _ s: Slide, _ layer: Layer, _ cg: CGContext) {
        guard let xfrm = el.child("grpSpPr")?.child("xfrm"), let f = frame(xfrm) else {
            drawTree(el, s, layer, cg)
            return
        }
        let childOffset = xfrm.child("chOff"), childExtent = xfrm.child("chExt")
        let cx = emu(childOffset?.attr("x")), cy = emu(childOffset?.attr("y"))
        let cw = emu(childExtent?.attr("cx")), ch = emu(childExtent?.attr("cy"))
        inFrame(f, cg, mirror: true) { r in
            // Children are positioned in the group's own coordinate space.
            cg.translateBy(x: r.minX, y: r.minY)
            if cw > 0, ch > 0 { cg.scaleBy(x: r.width / cw, y: r.height / ch) }
            cg.translateBy(x: -cx, y: -cy)
            self.drawTree(el, s, layer, cg)
        }
    }

    private func drawGraphicFrame(_ el: XMLElement, _ s: Slide, _ layer: Layer, _ cg: CGContext) {
        let chain = chain(el, s, layer)
        guard let data = el.at("graphic", "graphicData") else { return }
        let f = chain.lazy.compactMap { self.frame($0.child("xfrm")) }.first
        if let table = data.child("tbl") {
            if let f { drawTable(table, f, s, layer, cg) }
        } else if let relIds = data.child("relIds") {
            if let f { drawDiagram(relIds, f, s, layer, cg) }
        } else if let picture = data.firstDescendant("pic") {
            // Embedded (OLE) objects carry a preview picture. Charts aren't drawn.
            drawPicture(picture, s, layer, cg)
        }
    }

    private func drawDiagram(_ relIds: XMLElement, _ f: Frame, _ s: Slide, _ layer: Layer, _ cg: CGContext) {
        // SmartArt: PowerPoint saves a ready-made drawing of it, linked from the diagram's data part.
        let rels = package.relationships(of: layer.part)
        let dataPart = relIds.attr("r:dm").flatMap { rels[$0]?.target }
        let drawingId = dataPart.flatMap { package.xml($0)?.firstDescendant("dataModelExt")?.attr("relId") }
        guard let drawingPart = drawingId.flatMap({ rels[$0]?.target })
                ?? rels.values.first(where: { $0.type == "diagramDrawing" })?.target,
              let drawing = package.xml(drawingPart) else { return }
        cg.saveGState()
        cg.translateBy(x: f.rect.minX, y: f.rect.minY)
        drawTree(drawing.child("spTree"), s, Layer(part: drawingPart, root: drawing), cg)
        cg.restoreGState()
    }

    // MARK: Fills, lines and colors

    private func shapeFill(_ properties: [XMLElement], _ style: XMLElement?, _ s: Slide, _ part: String) -> Fill? {
        for spPr in properties {
            if let fill = fill(in: spPr, s, part, ph: nil) { return fill }
        }
        guard let ref = style?.child("fillRef"), let idx = ref.number("idx").map({ Int($0) }), idx > 0 else { return nil }
        let color = self.color(in: ref, s, ph: nil)
        let list = idx >= 1001 ? s.theme.backgroundFills : s.theme.fillStyles
        let i = idx >= 1001 ? idx - 1001 : idx - 1
        if i < list.count, let themed = fillElement(list[i], s, part, ph: color) { return themed }
        return color.map { .solid($0) }
    }

    private func fill(in parent: XMLElement?, _ s: Slide, _ part: String, ph: RGBA?) -> Fill? {
        for child in parent?.elementChildren ?? [] {
            if let fill = fillElement(child, s, part, ph: ph) { return fill }
        }
        return nil
    }

    private func fillElement(_ el: XMLElement, _ s: Slide, _ part: String, ph: RGBA?) -> Fill? {
        switch el.localName {
        case "noFill":
            return .empty
        case "solidFill":
            return color(in: el, s, ph: ph).map { .solid($0) } ?? .empty
        case "gradFill":
            let stops = (el.child("gsLst")?.elements("gs") ?? []).compactMap { gs -> (CGFloat, RGBA)? in
                guard let color = color(in: gs, s, ph: ph) else { return nil }
                return (CGFloat(gs.number("pos") ?? 0) / 100_000, color)
            }.sorted { $0.0 < $1.0 }
            guard !stops.isEmpty else { return .empty }
            return .gradient(stops, angle: CGFloat(el.child("lin")?.number("ang") ?? 5_400_000) / 60_000,
                             radial: el.child("path") != nil)
        case "blipFill":
            guard let image = blipImage(el, part) else { return .empty }
            return .image(image, crop: crop(el.child("srcRect")))
        case "pattFill":
            let fg = color(in: el.child("fgClr"), s, ph: ph) ?? .black
            let bg = color(in: el.child("bgClr"), s, ph: ph) ?? .white
            return .solid(bg.mixed(with: fg, 0.5))
        default:
            return nil
        }
    }

    private func blipImage(_ blipFill: XMLElement, _ part: String) -> CGImage? {
        guard let id = blipFill.child("blip")?.attr("r:embed"),
              let target = package.relationships(of: part)[id]?.target else { return nil }
        return package.image(target)
    }

    private func crop(_ rect: XMLElement?) -> (l: CGFloat, t: CGFloat, r: CGFloat, b: CGFloat)? {
        guard let rect else { return nil }
        let side = { (name: String) in CGFloat(rect.number(name) ?? 0) / 100_000 }
        let c = (l: side("l"), t: side("t"), r: side("r"), b: side("b"))
        return c.l == 0 && c.t == 0 && c.r == 0 && c.b == 0 ? nil : c
    }

    private func shapeLine(_ properties: [XMLElement], _ style: XMLElement?, _ s: Slide) -> Line? {
        let explicit = properties.compactMap { $0.child("ln") }
        let ref = style?.child("lnRef")
        let refIndex = ref?.number("idx").map { Int($0) } ?? 0
        let refColor = color(in: ref, s, ph: nil)
        let themed = refIndex > 0 && refIndex <= s.theme.lineStyles.count ? s.theme.lineStyles[refIndex - 1] : nil
        return line(explicit + (themed.map { [$0] } ?? []), s, ph: refColor, styled: refIndex > 0)
    }

    /// A line from `a:ln` elements, nearest first.
    private func line(_ all: [XMLElement], _ s: Slide, ph: RGBA?, styled: Bool) -> Line? {
        var lineColor: RGBA?
        for ln in all {
            if ln.child("noFill") != nil { return nil }
            if let c = color(in: ln.child("solidFill"), s, ph: ph) {
                lineColor = c
                break
            }
            if let gs = ln.at("gradFill", "gsLst", "gs"), let c = color(in: gs, s, ph: ph) {
                lineColor = c
                break
            }
        }
        if lineColor == nil, styled { lineColor = ph }
        guard let lineColor else { return nil }
        let width = all.lazy.compactMap { $0.number("w") }.first.map { max(CGFloat($0) / 12_700, 0.25) } ?? 0.75
        let dash = all.lazy.compactMap { $0.child("prstDash")?.attr("val") }.first.flatMap { Self.dashPattern($0, width) }
        let head = all.lazy.compactMap { $0.child("headEnd")?.attr("type") }.first.map { $0 != "none" } ?? false
        let tail = all.lazy.compactMap { $0.child("tailEnd")?.attr("type") }.first.map { $0 != "none" } ?? false
        return Line(color: lineColor, width: width, dash: dash, head: head, tail: tail)
    }

    private static func dashPattern(_ name: String, _ w: CGFloat) -> [CGFloat]? {
        switch name {
        case "dash": return [4 * w, 3 * w]
        case "sysDash": return [3 * w, w]
        case "dot", "sysDot": return [w, w]
        case "dashDot": return [4 * w, 3 * w, w, 3 * w]
        case "lgDash": return [8 * w, 3 * w]
        case "lgDashDot": return [8 * w, 3 * w, w, 3 * w]
        case "lgDashDotDot": return [8 * w, 3 * w, w, 3 * w, w, 3 * w]
        case "sysDashDot": return [3 * w, w, w, w]
        case "sysDashDotDot": return [3 * w, w, w, w, w, w]
        default: return nil
        }
    }

    private func color(in parent: XMLElement?, _ s: Slide, ph: RGBA?) -> RGBA? {
        for el in parent?.elementChildren ?? [] {
            var base: RGBA?
            switch el.localName {
            case "srgbClr":
                base = RGBA(hex: el.attr("val"))
            case "schemeClr":
                base = schemeColor(el.attr("val"), s, ph: ph)
            case "sysClr":
                base = RGBA(hex: el.attr("lastClr")) ?? (el.attr("val") == "window" ? .white : .black)
            case "prstClr":
                base = Self.presetColors[el.attr("val") ?? ""] ?? .black
            case "scrgbClr":
                let channel = { (name: String) in pow(CGFloat(el.number(name) ?? 0) / 100_000, 1 / 2.2) }
                base = RGBA(r: channel("r"), g: channel("g"), b: channel("b"))
            default:
                continue
            }
            guard let base else { return nil }
            return Self.modified(base, by: el)
        }
        return nil
    }

    private func schemeColor(_ name: String?, _ s: Slide, ph: RGBA?) -> RGBA? {
        guard let name else { return nil }
        if name == "phClr" { return ph ?? .black }
        return s.theme.colors[s.colorMap[name] ?? name] ?? s.theme.colors[name]
    }

    private static func modified(_ base: RGBA, by el: XMLElement) -> RGBA {
        var c = base
        for modifier in el.elementChildren {
            let v = CGFloat(modifier.number("val") ?? 0) / 100_000
            switch modifier.localName {
            case "alpha": c.a = v
            case "lumMod": c = c.hsl { ($0, $1, $2 * v) }
            case "lumOff": c = c.hsl { ($0, $1, $2 + v) }
            case "satMod": c = c.hsl { ($0, $1 * v, $2) }
            case "tint": c = RGBA.white.mixed(with: c, v)
            case "shade": c = RGBA(r: c.r * v, g: c.g * v, b: c.b * v, a: c.a)
            default: break
            }
        }
        return c
    }

    private static let presetColors: [String: RGBA] = [
        "black": .black, "white": .white, "red": RGBA(r: 1, g: 0, b: 0), "green": RGBA(r: 0, g: 0.5, b: 0),
        "blue": RGBA(r: 0, g: 0, b: 1), "yellow": RGBA(r: 1, g: 1, b: 0), "gray": RGBA(r: 0.5, g: 0.5, b: 0.5),
        "orange": RGBA(r: 1, g: 0.65, b: 0), "purple": RGBA(r: 0.5, g: 0, b: 0.5), "cyan": RGBA(r: 0, g: 1, b: 1),
        "magenta": RGBA(r: 1, g: 0, b: 1), "darkGray": RGBA(r: 0.66, g: 0.66, b: 0.66),
        "lightGray": RGBA(r: 0.83, g: 0.83, b: 0.83),
    ]

    private func paint(_ fill: Fill, _ path: CGPath, _ r: CGRect, _ cg: CGContext) {
        switch fill {
        case .empty:
            return
        case .solid(let color):
            cg.addPath(path)
            cg.setFillColor(color.cgColor)
            cg.fillPath()
        case .gradient(let stops, let angle, let radial):
            var locations = stops.map { $0.0 }
            guard let gradient = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
                                            colors: stops.map { $0.1.cgColor } as CFArray, locations: &locations) else { return }
            cg.saveGState()
            cg.addPath(path)
            cg.clip()
            let center = CGPoint(x: r.midX, y: r.midY)
            if radial {
                cg.drawRadialGradient(gradient, startCenter: center, startRadius: 0, endCenter: center,
                                      endRadius: hypot(r.width, r.height) / 2, options: [.drawsAfterEndLocation])
            } else {
                let a = angle * .pi / 180
                let dx = cos(a), dy = sin(a)
                let half = (abs(r.width * dx) + abs(r.height * dy)) / 2
                cg.drawLinearGradient(gradient, start: CGPoint(x: center.x - dx * half, y: center.y - dy * half),
                                      end: CGPoint(x: center.x + dx * half, y: center.y + dy * half),
                                      options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            }
            cg.restoreGState()
        case .image(let image, let cropping):
            cg.saveGState()
            cg.addPath(path)
            cg.clip()
            cg.drawUpright(image, in: r, crop: cropping)
            cg.restoreGState()
        }
    }

    private func stroke(_ path: CGPath, _ line: Line, _ cg: CGContext) {
        cg.saveGState()
        cg.addPath(path)
        cg.setStrokeColor(line.color.cgColor)
        cg.setLineWidth(line.width)
        cg.setLineJoin(.round)
        if let dash = line.dash { cg.setLineDash(phase: 0, lengths: dash) }
        cg.strokePath()
        if line.head || line.tail {
            var points: [CGPoint] = []
            path.applyWithBlock { element in
                let e = element.pointee
                switch e.type {
                case .moveToPoint, .addLineToPoint: points.append(e.points[0])
                case .addQuadCurveToPoint: points.append(contentsOf: [e.points[0], e.points[1]])
                case .addCurveToPoint: points.append(contentsOf: [e.points[0], e.points[1], e.points[2]])
                default: break
                }
            }
            cg.setFillColor(line.color.cgColor)
            if line.head, points.count >= 2 { arrow(at: points[0], from: points[1], line.width, cg) }
            if line.tail, points.count >= 2 { arrow(at: points[points.count - 1], from: points[points.count - 2], line.width, cg) }
        }
        cg.restoreGState()
    }

    private func arrow(at tip: CGPoint, from previous: CGPoint, _ width: CGFloat, _ cg: CGContext) {
        let dx = tip.x - previous.x, dy = tip.y - previous.y
        let length = hypot(dx, dy)
        guard length > 0 else { return }
        let ux = dx / length, uy = dy / length
        let size = max(width * 3, 5)
        let base = CGPoint(x: tip.x - ux * size, y: tip.y - uy * size)
        cg.move(to: tip)
        cg.addLine(to: CGPoint(x: base.x - uy * size / 2, y: base.y + ux * size / 2))
        cg.addLine(to: CGPoint(x: base.x + uy * size / 2, y: base.y - ux * size / 2))
        cg.closePath()
        cg.fillPath()
    }

    // MARK: Geometry

    /// The shape's outline in `r`, and whether it's a closed shape that can be filled.
    private func outline(_ spPr: XMLElement?, _ r: CGRect) -> (CGPath, Bool) {
        if let custom = spPr?.child("custGeom") { return customOutline(custom, r) }
        let preset = spPr?.child("prstGeom")
        var adjust: [String: CGFloat] = [:]
        for guide in preset?.child("avLst")?.elements("gd") ?? [] {
            if let name = guide.attr("name"), let formula = guide.attr("fmla"), formula.hasPrefix("val "),
               let value = Double(formula.dropFirst(4)) {
                adjust[name] = CGFloat(value)
            }
        }
        func adj(_ name: String, _ fallback: CGFloat) -> CGFloat { (adjust[name] ?? fallback) / 100_000 }

        let p = CGMutablePath()
        let x0 = r.minX, y0 = r.minY, x1 = r.maxX, y1 = r.maxY, w = r.width, h = r.height
        let ss = min(w, h)
        func poly(_ points: [(CGFloat, CGFloat)]) {
            p.addLines(between: points.map { CGPoint(x: $0.0, y: $0.1) })
            p.closeSubpath()
        }
        func polyline(_ points: [(CGFloat, CGFloat)]) -> (CGPath, Bool) {
            p.addLines(between: points.map { CGPoint(x: $0.0, y: $0.1) })
            return (p, false)
        }

        switch preset?.attr("prst") ?? "rect" {
        case "roundRect", "flowChartAlternateProcess":
            let radius = min(ss * adj("adj", 16_667), w / 2, h / 2)
            p.addRoundedRect(in: r, cornerWidth: radius, cornerHeight: radius)
        case "flowChartTerminator":
            p.addRoundedRect(in: r, cornerWidth: min(h / 2, w / 2), cornerHeight: h / 2)
        case "ellipse", "flowChartConnector":
            p.addEllipse(in: r)
        case "triangle":
            poly([(x0 + w * adj("adj", 50_000), y0), (x1, y1), (x0, y1)])
        case "rtTriangle":
            poly([(x0, y0), (x1, y1), (x0, y1)])
        case "diamond", "flowChartDecision":
            poly([(r.midX, y0), (x1, r.midY), (r.midX, y1), (x0, r.midY)])
        case "parallelogram", "flowChartInputOutput":
            let o = ss * adj("adj", 25_000)
            poly([(x0 + o, y0), (x1, y0), (x1 - o, y1), (x0, y1)])
        case "trapezoid":
            let o = ss * adj("adj", 25_000)
            poly([(x0 + o, y0), (x1 - o, y0), (x1, y1), (x0, y1)])
        case "hexagon":
            let o = ss * adj("adj", 25_000)
            poly([(x0 + o, y0), (x1 - o, y0), (x1, r.midY), (x1 - o, y1), (x0 + o, y1), (x0, r.midY)])
        case "octagon":
            let o = ss * adj("adj", 29_289)
            poly([(x0 + o, y0), (x1 - o, y0), (x1, y0 + o), (x1, y1 - o), (x1 - o, y1), (x0 + o, y1), (x0, y1 - o), (x0, y0 + o)])
        case "pentagon":
            poly([(r.midX, y0), (x1, y0 + h * 0.382), (x0 + w * 0.809, y1), (x0 + w * 0.191, y1), (x0, y0 + h * 0.382)])
        case "homePlate":
            let o = ss * adj("adj", 50_000)
            poly([(x0, y0), (x1 - o, y0), (x1, r.midY), (x1 - o, y1), (x0, y1)])
        case "chevron":
            let o = ss * adj("adj", 50_000)
            poly([(x0, y0), (x1 - o, y0), (x1, r.midY), (x1 - o, y1), (x0, y1), (x0 + o, r.midY)])
        case "plus":
            let o = ss * adj("adj", 25_000)
            poly([(x0 + o, y0), (x1 - o, y0), (x1 - o, y0 + o), (x1, y0 + o), (x1, y1 - o), (x1 - o, y1 - o),
                  (x1 - o, y1), (x0 + o, y1), (x0 + o, y1 - o), (x0, y1 - o), (x0, y0 + o), (x0 + o, y0 + o)])
        case "rightArrow":
            let half = h * adj("adj1", 50_000) / 2, head = ss * adj("adj2", 50_000)
            poly([(x0, r.midY - half), (x1 - head, r.midY - half), (x1 - head, y0), (x1, r.midY),
                  (x1 - head, y1), (x1 - head, r.midY + half), (x0, r.midY + half)])
        case "leftArrow":
            let half = h * adj("adj1", 50_000) / 2, head = ss * adj("adj2", 50_000)
            poly([(x1, r.midY - half), (x0 + head, r.midY - half), (x0 + head, y0), (x0, r.midY),
                  (x0 + head, y1), (x0 + head, r.midY + half), (x1, r.midY + half)])
        case "downArrow":
            let half = w * adj("adj1", 50_000) / 2, head = ss * adj("adj2", 50_000)
            poly([(r.midX - half, y0), (r.midX + half, y0), (r.midX + half, y1 - head), (x1, y1 - head),
                  (r.midX, y1), (x0, y1 - head), (r.midX - half, y1 - head)])
        case "upArrow":
            let half = w * adj("adj1", 50_000) / 2, head = ss * adj("adj2", 50_000)
            poly([(r.midX - half, y1), (r.midX + half, y1), (r.midX + half, y0 + head), (x1, y0 + head),
                  (r.midX, y0), (x0, y0 + head), (r.midX - half, y0 + head)])
        case "star5":
            poly((0..<10).map { i -> (CGFloat, CGFloat) in
                let angle = -CGFloat.pi / 2 + CGFloat(i) * .pi / 5
                let scale: CGFloat = i % 2 == 0 ? 1 : 0.382
                return (r.midX + cos(angle) * w / 2 * scale, r.midY + sin(angle) * h / 2 * scale)
            })
        case "line", "straightConnector1":
            return polyline([(x0, y0), (x1, y1)])
        case "bentConnector2":
            return polyline([(x0, y0), (x1, y0), (x1, y1)])
        case "bentConnector3":
            let x = x0 + w * adj("adj1", 50_000)
            return polyline([(x0, y0), (x, y0), (x, y1), (x1, y1)])
        case "curvedConnector3":
            let x = x0 + w * adj("adj1", 50_000)
            p.move(to: CGPoint(x: x0, y: y0))
            p.addCurve(to: CGPoint(x: x1, y: y1), control1: CGPoint(x: x, y: y0), control2: CGPoint(x: x, y: y1))
            return (p, false)
        default:
            p.addRect(r)
        }
        return (p, true)
    }

    private func customOutline(_ geometry: XMLElement, _ r: CGRect) -> (CGPath, Bool) {
        let p = CGMutablePath()
        var filled = false
        for path in geometry.child("pathLst")?.elements("path") ?? [] {
            let pw = CGFloat(path.number("w") ?? Double(r.width * 12_700))
            let ph = CGFloat(path.number("h") ?? Double(r.height * 12_700))
            let sx = pw > 0 ? r.width / pw : 0, sy = ph > 0 ? r.height / ph : 0
            let point = { (pt: XMLElement?) in
                CGPoint(x: r.minX + CGFloat(pt?.number("x") ?? 0) * sx, y: r.minY + CGFloat(pt?.number("y") ?? 0) * sy)
            }
            if path.attr("fill") != "none" { filled = true }
            for command in path.elementChildren {
                switch command.localName {
                case "moveTo":
                    p.move(to: point(command.child("pt")))
                case "lnTo":
                    if !p.isEmpty { p.addLine(to: point(command.child("pt"))) }
                case "cubicBezTo":
                    let pts = command.elements("pt").map { point($0) }
                    if pts.count == 3, !p.isEmpty { p.addCurve(to: pts[2], control1: pts[0], control2: pts[1]) }
                case "quadBezTo":
                    let pts = command.elements("pt").map { point($0) }
                    if pts.count == 2, !p.isEmpty { p.addQuadCurve(to: pts[1], control: pts[0]) }
                case "arcTo":
                    guard !p.isEmpty else { continue }
                    let rx = CGFloat(command.number("wR") ?? 0) * sx, ry = CGFloat(command.number("hR") ?? 0) * sy
                    let start = CGFloat(command.number("stAng") ?? 0) / 60_000 * .pi / 180
                    let sweep = CGFloat(command.number("swAng") ?? 0) / 60_000 * .pi / 180
                    let current = p.currentPoint
                    let center = CGPoint(x: current.x - rx * cos(start), y: current.y - ry * sin(start))
                    let steps = max(4, Int(abs(sweep) / (.pi / 18)))
                    for i in 1...steps {
                        let a = start + sweep * CGFloat(i) / CGFloat(steps)
                        p.addLine(to: CGPoint(x: center.x + rx * cos(a), y: center.y + ry * sin(a)))
                    }
                case "close":
                    p.closeSubpath()
                default:
                    break
                }
            }
        }
        return (p, filled)
    }

    // MARK: Text

    private func drawText(_ body: XMLElement, chain: [XMLElement], frame f: Frame, geometry: XMLElement?,
                          _ s: Slide, _ layer: Layer, style: XMLElement?, _ cg: CGContext) {
        let ph = layer.part == s.slide.part ? placeholder(of: chain[0]) : nil
        let bodies = [body] + chain.dropFirst().compactMap { $0.child("txBody") }
        let bodyProperties = bodies.compactMap { $0.child("bodyPr") }
        func bodyAttr(_ name: String) -> String? { bodyProperties.lazy.compactMap { $0.attr(name) }.first }

        var context = TextContext(listStyles: bodies.map { $0.child("lstStyle") } + masterStyles(for: ph, s))
        context.styleColor = color(in: style?.child("fontRef"), s, ph: nil)
        let autofit = bodyProperties.lazy.compactMap { $0.child("normAutofit") ?? $0.child("spAutoFit") ?? $0.child("noAutofit") }.first
        let shrinks = autofit?.localName == "normAutofit"
        if shrinks, let autofit {
            context.fontScale = CGFloat(autofit.number("fontScale") ?? 100_000) / 100_000
            context.spacingReduction = CGFloat(autofit.number("lnSpcReduction") ?? 0) / 100_000
        }

        let insetL = emu(bodyAttr("lIns") ?? "91440"), insetT = emu(bodyAttr("tIns") ?? "45720")
        let insetR = emu(bodyAttr("rIns") ?? "91440"), insetB = emu(bodyAttr("bIns") ?? "45720")
        let anchor = bodyAttr("anchor") ?? "t"
        let wraps = bodyAttr("wrap") != "none"
        let vertical = bodyAttr("vert") ?? "horz"
        let isEllipse = geometry?.child("prstGeom")?.attr("prst") == "ellipse"

        inFrame(f, cg, mirror: false) { r in
            // An ellipse's text sits in the rectangle inscribed in it.
            var box = isEllipse ? r.insetBy(dx: r.width * 0.1464, dy: r.height * 0.1464) : r
            box = CGRect(x: box.minX + insetL, y: box.minY + insetT,
                         width: max(box.width - insetL - insetR, 1), height: max(box.height - insetT - insetB, 1))
            if ["vert", "eaVert", "wordArtVertRtl"].contains(vertical) {
                cg.rotate(by: .pi / 2)
                box = CGRect(x: box.minY, y: -box.maxX, width: box.height, height: box.width)
            } else if vertical == "vert270" {
                cg.rotate(by: -.pi / 2)
                box = CGRect(x: -box.maxY, y: box.minX, width: box.height, height: box.width)
            }

            var scale = context.fontScale
            var text = self.attributed(body, context, s, scale: scale)
            // "Shrink text on overflow": PowerPoint saves the factor it used, but substitute fonts can still run
            // a little longer, so keep shrinking until it fits.
            while shrinks, scale > 0.4, self.height(of: text, width: wraps ? box.width : 100_000) > box.height + 1 {
                scale -= 0.075
                text = self.attributed(body, context, s, scale: scale)
            }
            self.place(text, in: box, anchor: anchor, wraps: wraps)
        }
    }

    private func masterStyles(for ph: Placeholder?, _ s: Slide) -> [XMLElement?] {
        let styles = s.master?.root.child("txStyles")
        guard let ph else { return [presentation.child("defaultTextStyle"), styles?.child("otherStyle")] }
        switch ph.type {
        case "title", "ctrTitle": return [styles?.child("titleStyle")]
        case "dt", "ftr", "sldNum", "hdr": return [styles?.child("otherStyle"), presentation.child("defaultTextStyle")]
        default: return [styles?.child("bodyStyle")]
        }
    }

    private static let drawingOptions: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]

    private func height(of text: NSAttributedString, width: CGFloat) -> CGFloat {
        ceil(text.boundingRect(with: CGSize(width: width, height: 100_000), options: Self.drawingOptions).height)
    }

    private func place(_ text: NSAttributedString, in box: CGRect, anchor: String, wraps: Bool) {
        guard text.length > 0 else { return }
        var rect = box
        if !wraps {
            let natural = ceil(text.boundingRect(with: CGSize(width: 100_000, height: 100_000), options: Self.drawingOptions).width)
            if natural > box.width {
                let alignment = (text.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.alignment ?? .left
                let extra = natural - box.width + 2
                switch alignment {
                case .center: rect.origin.x -= extra / 2
                case .right: rect.origin.x -= extra
                default: break
                }
                rect.size.width += extra
            }
        }
        let textHeight = height(of: text, width: rect.width)
        switch anchor {
        case "ctr": rect.origin.y = box.midY - textHeight / 2
        case "b": rect.origin.y = box.maxY - textHeight
        default: break
        }
        rect.size.height = textHeight + 2
        text.draw(with: rect, options: Self.drawingOptions, context: nil)
    }

    private func attributed(_ body: XMLElement, _ context: TextContext, _ s: Slide, scale: CGFloat) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let paragraphs = body.elements("p")
        var counters = [Int](repeating: 0, count: 9)

        for (index, p) in paragraphs.enumerated() {
            let pPr = p.child("pPr")
            let level = min(max(Int(pPr?.number("lvl") ?? 0), 0), 8)
            let key = "lvl\(level + 1)pPr"
            let levels = [pPr].compactMap { $0 } + context.listStyles.compactMap { $0?.child(key) }
            func pAttr(_ name: String) -> String? { levels.lazy.compactMap { $0.attr(name) }.first }
            func pChild(_ name: String) -> XMLElement? { levels.lazy.compactMap { $0.child(name) }.first }
            let own: [XMLElement?] = [pPr?.child("defRPr"), (context.listStyles.first ?? nil)?.child(key)?.child("defRPr")]
            let inherited: [XMLElement?] = context.listStyles.dropFirst().map { $0?.child(key)?.child("defRPr") }

            let start = result.length
            for item in p.elementChildren {
                switch item.localName {
                case "r", "fld":
                    var text = item.child("t")?.stringValue ?? ""
                    if item.localName == "fld", item.attr("type") == "slidenum" { text = "\(s.number)" }
                    let run = runAttributes(item.child("rPr"), own, inherited, context, s, scale)
                    if run.caps { text = text.uppercased() }
                    result.append(NSAttributedString(string: text, attributes: run.attributes))
                case "br":
                    let run = runAttributes(item.child("rPr"), own, inherited, context, s, scale)
                    result.append(NSAttributedString(string: "\u{2028}", attributes: run.attributes))
                default:
                    break
                }
            }
            let hasText = result.length > start

            // Bullets and numbering.
            let bulletKind = levels.lazy.compactMap { level in
                level.elementChildren.first { ["buNone", "buChar", "buAutoNum", "buBlip"].contains($0.localName ?? "") }
            }.first
            for deeper in (level + 1)..<9 { counters[deeper] = 0 }
            if bulletKind?.localName == "buAutoNum", hasText {
                counters[level] += 1
            } else {
                counters[level] = 0
            }
            if hasText, let bulletKind, bulletKind.localName != "buNone" {
                let bulletFont = pChild("buFont")?.attr("typeface")
                var symbol = "•"
                if bulletKind.localName == "buChar" {
                    symbol = Self.bulletSymbol(bulletKind.attr("char") ?? "•", font: bulletFont)
                } else if bulletKind.localName == "buAutoNum" {
                    let first = Int(bulletKind.attr("startAt") ?? "") ?? 1
                    symbol = Self.autoNumber(bulletKind.attr("type") ?? "arabicPeriod", first + counters[level] - 1)
                }
                var attributes = result.attributes(at: start, effectiveRange: nil)
                attributes.removeValue(forKey: .underlineStyle)
                if let c = color(in: pChild("buClr"), s, ph: nil) { attributes[.foregroundColor] = c.nsColor }
                if let font = attributes[.font] as? NSFont {
                    let size = font.pointSize * CGFloat(pChild("buSzPct")?.number("val") ?? 100_000) / 100_000
                    if let bulletFont, !Self.isSymbolFont(bulletFont), bulletKind.localName == "buChar" {
                        attributes[.font] = OfficeFonts.font(bulletFont, size: size, bold: false, italic: false).0
                    } else {
                        attributes[.font] = NSFontManager.shared.convert(font, toSize: size)
                    }
                }
                result.insert(NSAttributedString(string: symbol + "\t", attributes: attributes), at: start)
            }

            let end = runAttributes(p.child("endParaRPr"), own, inherited, context, s, scale)
            if index < paragraphs.count - 1 {
                result.append(NSAttributedString(string: "\n", attributes: end.attributes))
            }

            let style = NSMutableParagraphStyle()
            switch pAttr("algn") {
            case "ctr": style.alignment = .center
            case "r": style.alignment = .right
            case "just", "dist": style.alignment = .justified
            default: style.alignment = .left
            }
            let marginLeft = emu(pAttr("marL")), indent = emu(pAttr("indent"))
            style.headIndent = marginLeft
            style.firstLineHeadIndent = max(0, marginLeft + indent)
            style.tabStops = marginLeft > 0 ? [NSTextTab(textAlignment: .left, location: marginLeft)] : []
            style.defaultTabInterval = 72
            style.lineBreakMode = .byWordWrapping
            let firstSize = ((hasText ? result.attribute(.font, at: start, effectiveRange: nil) : nil) as? NSFont)?.pointSize
                ?? (end.attributes[.font] as? NSFont)?.pointSize ?? 18
            if let pct = pChild("lnSpc")?.child("spcPct")?.number("val") {
                style.lineHeightMultiple = CGFloat(pct) / 100_000 * (1 - context.spacingReduction)
            } else if let points = pChild("lnSpc")?.child("spcPts")?.number("val") {
                style.minimumLineHeight = CGFloat(points) / 100 * scale
                style.maximumLineHeight = CGFloat(points) / 100 * scale
            } else if context.spacingReduction > 0 {
                style.lineHeightMultiple = 1 - context.spacingReduction
            }
            func spacing(_ name: String) -> CGFloat {
                guard let element = pChild(name) else { return 0 }
                if let points = element.child("spcPts")?.number("val") { return CGFloat(points) / 100 * scale }
                if let pct = element.child("spcPct")?.number("val") { return CGFloat(pct) / 100_000 * firstSize * 1.2 }
                return 0
            }
            if index > 0 { style.paragraphSpacingBefore = spacing("spcBef") }
            style.paragraphSpacing = spacing("spcAft")
            if result.length > start {
                result.addAttribute(.paragraphStyle, value: style, range: NSRange(location: start, length: result.length - start))
            }
        }
        return result
    }

    private struct RunStyle {
        var attributes: [NSAttributedString.Key: Any]
        var caps: Bool
    }

    private func runAttributes(_ rPr: XMLElement?, _ own: [XMLElement?], _ inherited: [XMLElement?],
                               _ context: TextContext, _ s: Slide, _ scale: CGFloat) -> RunStyle {
        let mine = ([rPr] + own).compactMap { $0 }
        let others = inherited.compactMap { $0 }
        let all = mine + others
        func attr(_ name: String) -> String? { all.lazy.compactMap { $0.attr(name) }.first }

        var size = CGFloat(Double(attr("sz") ?? "") ?? 1_800) / 100 * scale
        let bold = mine.lazy.compactMap { $0.flag("b") }.first ?? context.styleBold ?? others.lazy.compactMap { $0.flag("b") }.first ?? false
        let italic = all.lazy.compactMap { $0.flag("i") }.first ?? false
        var typeface = all.lazy.compactMap { $0.child("latin")?.attr("typeface") }.first ?? "+mn-lt"
        if typeface.hasPrefix("+mj") {
            typeface = s.theme.majorFont
        } else if typeface.hasPrefix("+mn") {
            typeface = s.theme.minorFont
        }
        func runColor(_ el: XMLElement) -> RGBA? {
            color(in: el.child("solidFill"), s, ph: nil) ?? color(in: el.at("gradFill", "gsLst", "gs"), s, ph: nil)
        }
        let textColor = mine.lazy.compactMap { runColor($0) }.first ?? context.styleColor
            ?? others.lazy.compactMap { runColor($0) }.first ?? .black

        let baseline = CGFloat(Double(attr("baseline") ?? "") ?? 0) / 100_000
        let fullSize = size
        if baseline != 0 { size *= 0.7 }
        let (font, expansion) = OfficeFonts.font(typeface, size: size, bold: bold, italic: italic)
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: textColor.nsColor]
        if expansion != 0 { attributes[.expansion] = expansion }
        if let underline = attr("u"), underline != "none" { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        if let strike = attr("strike"), strike != "noStrike" { attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
        if let spacing = attr("spc").flatMap(Double.init) { attributes[.kern] = CGFloat(spacing) / 100 * scale }
        if baseline != 0 { attributes[.baselineOffset] = fullSize * baseline }
        let caps = attr("cap").map { $0 == "all" || $0 == "small" } ?? false
        return RunStyle(attributes: attributes, caps: caps)
    }

    private static func isSymbolFont(_ font: String) -> Bool {
        let name = font.lowercased()
        return name.hasPrefix("wingdings") || name == "symbol" || name == "webdings" || name.hasPrefix("monotype sorts")
    }

    /// Wingdings and Symbol bullets are stored as plain letters ("§", "Ø"...). Map the common ones to Unicode.
    private static func bulletSymbol(_ char: String, font: String?) -> String {
        guard let font, isSymbolFont(font) else { return char }
        let map: [String: String] = ["§": "■", "Ø": "➢", "ü": "✓", "q": "❑", "v": "❖", "n": "■", "l": "●", "Ÿ": "•",
                                     "o": "□", "w": "◆", "u": "◆", "à": "→", "è": "➔", "ð": "⇨", "·": "•", "¨": "♦",
                                     "Ö": "➤", "ä": "➢", "æ": "➔", "®": "❖"]
        return map[char] ?? "•"
    }

    private static func autoNumber(_ type: String, _ n: Int) -> String {
        let number: String
        if type.hasPrefix("alphaLc") {
            number = alpha(n)
        } else if type.hasPrefix("alphaUc") {
            number = alpha(n).uppercased()
        } else if type.hasPrefix("romanLc") {
            number = roman(n).lowercased()
        } else if type.hasPrefix("romanUc") {
            number = roman(n)
        } else {
            number = String(n)
        }
        if type.hasSuffix("ParenBoth") { return "(\(number))" }
        if type.hasSuffix("ParenR") { return "\(number))" }
        if type.hasSuffix("Plain") { return number }
        return "\(number)."
    }

    private static func alpha(_ n: Int) -> String {
        guard n > 0 else { return "" }
        let letter = Character(UnicodeScalar(UInt8(97 + (n - 1) % 26)))
        return String(repeating: letter, count: (n - 1) / 26 + 1)
    }

    private static func roman(_ n: Int) -> String {
        var value = max(n, 1)
        var result = ""
        for (amount, symbol) in [(1000, "M"), (900, "CM"), (500, "D"), (400, "CD"), (100, "C"), (90, "XC"), (50, "L"),
                                 (40, "XL"), (10, "X"), (9, "IX"), (5, "V"), (4, "IV"), (1, "I")] {
            while value >= amount {
                result += symbol
                value -= amount
            }
        }
        return result
    }

    // MARK: Tables

    private func drawTable(_ table: XMLElement, _ f: Frame, _ s: Slide, _ layer: Layer, _ cg: CGContext) {
        let widths = table.child("tblGrid")?.elements("gridCol").map { emu($0.attr("w")) } ?? []
        let rows = table.elements("tr")
        guard !widths.isEmpty, !rows.isEmpty else { return }
        let properties = table.child("tblPr")
        let styleId = properties?.child("tableStyleId")?.stringValue ?? defaultTableStyle
        let style = tableStyles[styleId] ?? (styleId == Self.mediumStyle2Id ? Self.mediumStyle2 : nil)
        let firstRow = properties?.flag("firstRow") == true, lastRow = properties?.flag("lastRow") == true
        let firstCol = properties?.flag("firstCol") == true, lastCol = properties?.flag("lastCol") == true
        let bandRow = properties?.flag("bandRow") == true, bandCol = properties?.flag("bandCol") == true
        let rowCount = rows.count, colCount = widths.count

        /// Table style parts that apply to a cell, most important first.
        func regions(_ i: Int, _ j: Int) -> [(String, XMLElement)] {
            guard let style else { return [] }
            var names = ["wholeTbl"]
            if bandCol { names.append((j - (firstCol ? 1 : 0)) % 2 == 0 ? "band1V" : "band2V") }
            let dataRow = i - (firstRow ? 1 : 0)
            if bandRow, dataRow >= 0 { names.append(dataRow % 2 == 0 ? "band1H" : "band2H") }
            if lastCol, j == colCount - 1 { names.append("lastCol") }
            if firstCol, j == 0 { names.append("firstCol") }
            if lastRow, i == rowCount - 1 { names.append("lastRow") }
            if firstRow, i == 0 { names.append("firstRow") }
            return names.reversed().compactMap { name in style.child(name).map { (name, $0) } }
        }

        struct Cell {
            let i: Int, j: Int, rowSpan: Int, colSpan: Int
            let element: XMLElement
            let regions: [(String, XMLElement)]
            let text: NSAttributedString
            let margins: (l: CGFloat, t: CGFloat, r: CGFloat, b: CGFloat)
        }
        var cells: [Cell] = []
        var heights = rows.map { emu($0.attr("h")) }
        var xs: [CGFloat] = [0]
        for w in widths { xs.append(xs[xs.count - 1] + w) }

        for (i, row) in rows.enumerated() {
            for (j, tc) in row.elements("tc").enumerated() where j < colCount {
                if tc.flag("hMerge") == true || tc.flag("vMerge") == true { continue }
                let rowSpan = max(1, Int(tc.attr("rowSpan") ?? "") ?? 1)
                let colSpan = min(max(1, Int(tc.attr("gridSpan") ?? "") ?? 1), colCount - j)
                let applicable = regions(i, j)
                var context = TextContext(listStyles: [tc.at("txBody", "lstStyle"), presentation.child("defaultTextStyle"),
                                                       s.master?.root.at("txStyles", "otherStyle")])
                for (_, region) in applicable {
                    guard let textStyle = region.child("tcTxStyle") else { continue }
                    if context.styleColor == nil {
                        context.styleColor = color(in: textStyle, s, ph: nil) ?? color(in: textStyle.child("fontRef"), s, ph: nil)
                    }
                    if context.styleBold == nil, let b = textStyle.attr("b") { context.styleBold = b == "on" }
                }
                let tcPr = tc.child("tcPr")
                let margins = (l: emu(tcPr?.attr("marL") ?? "91440"), t: emu(tcPr?.attr("marT") ?? "45720"),
                               r: emu(tcPr?.attr("marR") ?? "91440"), b: emu(tcPr?.attr("marB") ?? "45720"))
                let text = tc.child("txBody").map { attributed($0, context, s, scale: 1) } ?? NSAttributedString()
                let width = xs[j + colSpan] - xs[j] - margins.l - margins.r
                if rowSpan == 1, i < heights.count, text.length > 0 {
                    heights[i] = max(heights[i], height(of: text, width: max(width, 1)) + margins.t + margins.b)
                }
                cells.append(Cell(i: i, j: j, rowSpan: min(rowSpan, rowCount - i), colSpan: colSpan, element: tc,
                                  regions: applicable, text: text, margins: margins))
            }
        }
        var ys: [CGFloat] = [0]
        for h in heights { ys.append(ys[ys.count - 1] + h) }

        func rect(_ cell: Cell) -> CGRect {
            CGRect(x: xs[cell.j], y: ys[cell.i], width: xs[cell.j + cell.colSpan] - xs[cell.j],
                   height: ys[cell.i + cell.rowSpan] - ys[cell.i])
        }

        cg.saveGState()
        cg.translateBy(x: f.rect.minX, y: f.rect.minY)
        for cell in cells {
            let r = rect(cell)
            var cellFill = fill(in: cell.element.child("tcPr"), s, layer.part, ph: nil)
            if cellFill == nil {
                for (_, region) in cell.regions {
                    guard let tcStyle = region.child("tcStyle") else { continue }
                    if let themed = fill(in: tcStyle.child("fill"), s, layer.part, ph: nil) {
                        cellFill = themed
                        break
                    }
                    if let ref = tcStyle.child("fillRef"), let c = color(in: ref, s, ph: nil) {
                        cellFill = .solid(c)
                        break
                    }
                }
            }
            if let cellFill { paint(cellFill, CGPath(rect: r, transform: nil), r, cg) }
        }
        for cell in cells where cell.text.length > 0 {
            let r = rect(cell)
            let box = CGRect(x: r.minX + cell.margins.l, y: r.minY + cell.margins.t,
                             width: max(r.width - cell.margins.l - cell.margins.r, 1),
                             height: max(r.height - cell.margins.t - cell.margins.b, 1))
            place(cell.text, in: box, anchor: cell.element.child("tcPr")?.attr("anchor") ?? "t", wraps: true)
        }
        for cell in cells {
            let r = rect(cell)
            let atLeft = cell.j == 0, atRight = cell.j + cell.colSpan >= colCount
            let atTop = cell.i == 0, atBottom = cell.i + cell.rowSpan >= rowCount
            let sides: [(String, String, String, CGPoint, CGPoint)] = [
                ("lnL", atLeft ? "left" : "insideV", "left", CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.minX, y: r.maxY)),
                ("lnR", atRight ? "right" : "insideV", "right", CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY)),
                ("lnT", atTop ? "top" : "insideH", "top", CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY)),
                ("lnB", atBottom ? "bottom" : "insideH", "bottom", CGPoint(x: r.minX, y: r.maxY), CGPoint(x: r.maxX, y: r.maxY)),
            ]
            for (explicitName, tableEdge, regionEdge, from, to) in sides {
                var border: Border?
                if let explicit = cell.element.child("tcPr")?.child(explicitName) {
                    border = line([explicit], s, ph: nil, styled: false).map { .line($0) } ?? Border.hidden
                }
                if border == nil {
                    for (name, region) in cell.regions {
                        // A header row's own "bottom" is the line under it; whole-table edges are the table's.
                        let isRowRegion = name == "firstRow" || name == "lastRow"
                        let isColRegion = name == "firstCol" || name == "lastCol"
                        let horizontal = regionEdge == "top" || regionEdge == "bottom"
                        let key = (isRowRegion && horizontal) || (isColRegion && !horizontal) ? regionEdge : tableEdge
                        guard let edge = region.at("tcStyle", "tcBdr", key) else { continue }
                        border = tableBorder(edge, s)
                        if border != nil { break }
                    }
                }
                guard case .line(let l)? = border else { continue }
                let path = CGMutablePath()
                path.move(to: from)
                path.addLine(to: to)
                stroke(path, l, cg)
            }
        }
        cg.restoreGState()
    }

    private func tableBorder(_ edge: XMLElement, _ s: Slide) -> Border? {
        if let ln = edge.child("ln") {
            return line([ln], s, ph: nil, styled: false).map { .line($0) } ?? Border.hidden
        }
        if let ref = edge.child("lnRef") {
            let idx = ref.number("idx").map { Int($0) } ?? 0
            let refColor = color(in: ref, s, ph: nil)
            let themed = idx > 0 && idx <= s.theme.lineStyles.count ? [s.theme.lineStyles[idx - 1]] : []
            return line(themed, s, ph: refColor, styled: idx > 0).map { .line($0) } ?? Border.hidden
        }
        return nil
    }

    /// PowerPoint's default table style ("Medium Style 2 - Accent 1"). Files only carry the definitions of other
    /// styles, and not always this one.
    private static let mediumStyle2Id = "{5C22544A-7EE6-4342-B048-85BDC9FD1C3A}"
    private static let mediumStyle2Document: XMLDocument? = {
        let white = #"<a:ln w="12700"><a:solidFill><a:schemeClr val="lt1"/></a:solidFill></a:ln>"#
        let xml = """
            <a:tblStyle xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" styleId="\(mediumStyle2Id)">
            <a:wholeTbl><a:tcTxStyle><a:schemeClr val="dk1"/></a:tcTxStyle><a:tcStyle><a:tcBdr>
            <a:left>\(white)</a:left><a:right>\(white)</a:right><a:top>\(white)</a:top><a:bottom>\(white)</a:bottom>
            <a:insideH>\(white)</a:insideH><a:insideV>\(white)</a:insideV></a:tcBdr>
            <a:fill><a:solidFill><a:schemeClr val="accent1"><a:tint val="20000"/></a:schemeClr></a:solidFill></a:fill>
            </a:tcStyle></a:wholeTbl>
            <a:band1H><a:tcStyle><a:fill><a:solidFill><a:schemeClr val="accent1"><a:tint val="40000"/></a:schemeClr>
            </a:solidFill></a:fill></a:tcStyle></a:band1H>
            <a:band1V><a:tcStyle><a:fill><a:solidFill><a:schemeClr val="accent1"><a:tint val="40000"/></a:schemeClr>
            </a:solidFill></a:fill></a:tcStyle></a:band1V>
            <a:lastCol><a:tcTxStyle b="on"><a:schemeClr val="lt1"/></a:tcTxStyle><a:tcStyle><a:fill><a:solidFill>
            <a:schemeClr val="accent1"/></a:solidFill></a:fill></a:tcStyle></a:lastCol>
            <a:firstCol><a:tcTxStyle b="on"><a:schemeClr val="lt1"/></a:tcTxStyle><a:tcStyle><a:fill><a:solidFill>
            <a:schemeClr val="accent1"/></a:solidFill></a:fill></a:tcStyle></a:firstCol>
            <a:lastRow><a:tcTxStyle b="on"><a:schemeClr val="lt1"/></a:tcTxStyle><a:tcStyle><a:tcBdr><a:top>
            <a:ln w="38100"><a:solidFill><a:schemeClr val="lt1"/></a:solidFill></a:ln></a:top></a:tcBdr><a:fill>
            <a:solidFill><a:schemeClr val="accent1"/></a:solidFill></a:fill></a:tcStyle></a:lastRow>
            <a:firstRow><a:tcTxStyle b="on"><a:schemeClr val="lt1"/></a:tcTxStyle><a:tcStyle><a:tcBdr><a:bottom>
            <a:ln w="38100"><a:solidFill><a:schemeClr val="lt1"/></a:solidFill></a:ln></a:bottom></a:tcBdr><a:fill>
            <a:solidFill><a:schemeClr val="accent1"/></a:solidFill></a:fill></a:tcStyle></a:firstRow>
            </a:tblStyle>
            """
        return try? XMLDocument(xmlString: xml, options: [])
    }()

    private static var mediumStyle2: XMLElement? { mediumStyle2Document?.rootElement() }
}

/// EMUs (English Metric Units, 914,400 per inch) to PDF points.
private func emu(_ value: String?) -> CGFloat {
    CGFloat(Double(value ?? "") ?? 0) / 12_700
}
