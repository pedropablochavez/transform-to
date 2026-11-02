import CoreGraphics
import Foundation
import ImageIO

struct ConversionError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Image conversion with ImageIO, which ships with macOS (no extra libraries).
enum ImageConversion {
    static func convert(_ input: URL, to output: URL, ext: String) throws {
        let source = try open(input)

        if ext == "pdf" {
            try writePDF([try orientedImage(source)], to: output)
            return
        }

        guard let type = utType(for: ext) else { throw ConversionError("Can't write .\(ext) images.") }
        let frameCount = CGImageSourceGetCount(source)
        let keepFrames = frameCount > 1 && (ext == "gif" || ext == "tiff")
        guard let destination = CGImageDestinationCreateWithURL(output as CFURL, type as CFString, keepFrames ? frameCount : 1, nil) else {
            throw ConversionError("Can't create the output file.")
        }

        if keepFrames {
            // Animated GIF / multi-page TIFF: copy every frame with its timing.
            for index in 0..<frameCount {
                CGImageDestinationAddImageFromSource(destination, source, index, nil)
            }
        } else {
            var image = try orientedImage(source)
            if ext == "jpg" { image = try flattened(image) }       // JPG has no transparency: use white, not black
            if ext == "ico" { image = try squared(image, maxSide: 256) } // icons are square, 256 px at most
            let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.92]
            CGImageDestinationAddImage(destination, image, options as CFDictionary)
        }

        guard CGImageDestinationFinalize(destination) else { throw ConversionError("Couldn't save the image.") }
    }

    /// Combines every input image into one PDF, one page per image.
    static func mergeToPDF(_ inputs: [URL], to output: URL) throws {
        let images = try inputs.map { try orientedImage(try open($0)) }
        try writePDF(images, to: output)
    }

    private static func open(_ url: URL) throws -> CGImageSource {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 else {
            throw ConversionError("Can't read this image.")
        }
        return source
    }

    private static func utType(for ext: String) -> String? {
        switch ext {
        case "jpg": return "public.jpeg"
        case "png": return "public.png"
        case "heic": return "public.heic"
        case "tiff": return "public.tiff"
        case "gif": return "com.compuserve.gif"
        case "bmp": return "com.microsoft.bmp"
        case "ico": return "com.microsoft.ico"
        default: return nil
        }
    }

    /// The biggest frame (an .ico holds many sizes), with the EXIF rotation of phone photos applied.
    private static func orientedImage(_ source: CGImageSource) throws -> CGImage {
        var best = CGImageSourceGetPrimaryImageIndex(source)
        var bestSide = 0
        for index in 0..<CGImageSourceGetCount(source) {
            let props = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any] ?? [:]
            let side = max(props[kCGImagePropertyPixelWidth] as? Int ?? 0, props[kCGImagePropertyPixelHeight] as? Int ?? 0)
            if side > bestSide {
                best = index
                bestSide = side
            }
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: max(bestSide, 1),
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, best, options as CFDictionary) else {
            throw ConversionError("Can't decode this image.")
        }
        return image
    }

    private static func flattened(_ image: CGImage) throws -> CGImage {
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else {
            throw ConversionError("Out of memory.")
        }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(rect)
        context.draw(image, in: rect)
        guard let result = context.makeImage() else { throw ConversionError("Out of memory.") }
        return result
    }

    private static func squared(_ image: CGImage, maxSide: Int) throws -> CGImage {
        let side = min(maxSide, max(image.width, image.height))
        let scale = CGFloat(side) / CGFloat(max(image.width, image.height))
        let width = CGFloat(image.width) * scale, height = CGFloat(image.height) * scale
        guard let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ConversionError("Out of memory.")
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: (CGFloat(side) - width) / 2, y: (CGFloat(side) - height) / 2, width: width, height: height))
        guard let result = context.makeImage() else { throw ConversionError("Out of memory.") }
        return result
    }

    private static func writePDF(_ images: [CGImage], to output: URL) throws {
        guard let context = CGContext(output as CFURL, mediaBox: nil, nil) else {
            throw ConversionError("Can't create the PDF.")
        }
        for image in images {
            var box = CGRect(x: 0, y: 0, width: image.width, height: image.height)
            context.beginPage(mediaBox: &box)
            context.draw(image, in: box)
            context.endPage()
        }
        context.closePDF()
    }
}
