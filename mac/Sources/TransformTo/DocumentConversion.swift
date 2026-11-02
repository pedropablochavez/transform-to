import AppKit

/// Office documents: LibreOffice when it's installed (best fidelity, all formats), otherwise the text system
/// built into macOS, which handles Word/RTF/ODT text documents but not spreadsheets or presentations.
@MainActor
enum DocumentConversion {
    static func convert(_ input: URL, to output: URL, ext: String, engine: Engine) async throws {
        if let soffice = libreOffice {
            try await convertWithLibreOffice(soffice, input, output, ext)
            return
        }
        guard engine == .document else {
            throw ConversionError("Spreadsheets and presentations need LibreOffice (free): https://www.libreoffice.org")
        }
        try convertWithTextSystem(input, output, ext)
    }

    static var libreOffice: URL? {
        ["/Applications/LibreOffice.app/Contents/MacOS/soffice",
         NSHomeDirectory() + "/Applications/LibreOffice.app/Contents/MacOS/soffice"]
            .first { FileManager.default.isExecutableFile(atPath: $0) }
            .map { URL(fileURLWithPath: $0) }
    }

    private static func convertWithLibreOffice(_ soffice: URL, _ input: URL, _ output: URL, _ ext: String) async throws {
        let fm = FileManager.default
        // LibreOffice names the output itself, so convert into a scratch folder and move the result.
        let scratch = fm.temporaryDirectory.appendingPathComponent("TransformTo-\(UUID().uuidString)")
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: scratch) }

        // A private profile lets conversion work even while the user has LibreOffice open.
        let profile = fm.temporaryDirectory.appendingPathComponent("TransformTo-LibreOfficeProfile")
        let filter: String
        switch ext {
        case "txt": filter = "txt:Text (encoded):UTF8"
        case "csv": filter = "csv:Text - txt - csv (StarCalc):44,34,76"
        default: filter = ext
        }

        let process = Process()
        process.executableURL = soffice
        process.arguments = ["-env:UserInstallation=\(profile.absoluteString)", "--headless", "--norestore",
                             "--convert-to", filter, "--outdir", scratch.path, input.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            process.terminationHandler = { _ in continuation.resume() }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume()
            }
        }

        guard let produced = try fm.contentsOfDirectory(at: scratch, includingPropertiesForKeys: nil).first else {
            throw ConversionError("LibreOffice could not convert the file.")
        }
        try fm.moveItem(at: produced, to: output)
    }

    private static func convertWithTextSystem(_ input: URL, _ output: URL, _ ext: String) throws {
        let text = try NSAttributedString(url: input, options: [:], documentAttributes: nil)
        let type: NSAttributedString.DocumentType
        switch ext {
        case "pdf":
            try renderPDF(text, to: output)
            return
        case "txt":
            try text.string.write(to: output, atomically: true, encoding: .utf8)
            return
        case "docx": type = .officeOpenXML
        case "doc": type = .docFormat
        case "odt": type = .openDocument
        case "rtf": type = .rtf
        case "html": type = .html
        default: throw ConversionError("Can't write .\(ext) without LibreOffice.")
        }
        let data = try text.data(from: NSRange(location: 0, length: text.length), documentAttributes: [.documentType: type])
        try data.write(to: output)
    }

    /// Lays the text out on real pages (Letter/A4 depending on the Mac's region) and prints them to a PDF file.
    private static func renderPDF(_ text: NSAttributedString, to output: URL) throws {
        let printInfo = NSPrintInfo(dictionary: [
            .jobDisposition: NSPrintInfo.JobDisposition.save,
            .jobSavingURL: output,
        ])
        printInfo.paperSize = NSPrintInfo.shared.paperSize
        printInfo.topMargin = 72
        printInfo.bottomMargin = 72
        printInfo.leftMargin = 72
        printInfo.rightMargin = 72
        printInfo.horizontalPagination = .fit
        printInfo.verticalPagination = .automatic
        printInfo.isHorizontallyCentered = false
        printInfo.isVerticallyCentered = false

        let width = printInfo.paperSize.width - printInfo.leftMargin - printInfo.rightMargin
        let view = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 1))
        view.textStorage?.setAttributedString(text)
        if let layout = view.layoutManager, let container = view.textContainer {
            layout.ensureLayout(for: container)
            view.setFrameSize(NSSize(width: width, height: ceil(layout.usedRect(for: container).height) + 1))
        }

        let operation = NSPrintOperation(view: view, printInfo: printInfo)
        operation.showsPrintPanel = false
        operation.showsProgressPanel = false
        guard operation.run(), FileManager.default.fileExists(atPath: output.path) else {
            throw ConversionError("Couldn't create the PDF.")
        }
    }
}
