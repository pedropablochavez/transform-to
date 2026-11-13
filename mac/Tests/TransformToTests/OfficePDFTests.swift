import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import TransformTo

/// Converts every .pptx/.xlsx in $OFFICE_FIXTURES to PDF and saves PNG previews of the pages in $OFFICE_OUTPUT, so a
/// CI run (on a Mac without Office or LibreOffice) shows what the built-in renderer produces.
/// Without OFFICE_FIXTURES only the error-handling test runs.
@MainActor
final class OfficePDFTests: XCTestCase {
    private var fixtures: [URL] {
        get throws {
            guard let folder = ProcessInfo.processInfo.environment["OFFICE_FIXTURES"] else {
                throw XCTSkip("Set OFFICE_FIXTURES to a folder of .pptx/.xlsx files.")
            }
            return try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: folder), includingPropertiesForKeys: nil)
                .filter { OfficePDF.canConvert($0) }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
    }

    func testConvertsFixtures() throws {
        let files = try fixtures
        XCTAssertFalse(files.isEmpty)
        let output = URL(fileURLWithPath: ProcessInfo.processInfo.environment["OFFICE_OUTPUT"] ?? NSTemporaryDirectory())
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

        for file in files {
            let name = file.deletingPathExtension().lastPathComponent + "-" + file.pathExtension
            let pdf = output.appendingPathComponent(name + ".pdf")
            try? FileManager.default.removeItem(at: pdf)
            try OfficePDF.convert(file, to: pdf)
            let document = try XCTUnwrap(CGPDFDocument(pdf as CFURL))
            XCTAssertGreaterThan(document.numberOfPages, 0)
            print("\(file.lastPathComponent): \(document.numberOfPages) page(s)")
            for index in 1...min(document.numberOfPages, 16) {
                guard let page = document.page(at: index) else { continue }
                savePNG(page, to: output.appendingPathComponent("\(name)-page\(index).png"))
            }
        }
    }

    func testRejectsFileThatIsNotOffice() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("broken-\(UUID().uuidString).pptx")
        try Data("not a zip".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let pdf = file.appendingPathExtension("pdf")
        XCTAssertThrowsError(try OfficePDF.convert(file, to: pdf)) { error in
            XCTAssertTrue(error.localizedDescription.contains("couldn't be read"), error.localizedDescription)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: pdf.path))
    }

    private func savePNG(_ page: CGPDFPage, to url: URL) {
        let box = page.getBoxRect(.mediaBox)
        let scale: CGFloat = 1.5
        let width = Int(box.width * scale), height = Int(box.height * scale)
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.scaleBy(x: scale, y: scale)
        context.translateBy(x: -box.minX, y: -box.minY)
        context.drawPDFPage(page)
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
    }
}
