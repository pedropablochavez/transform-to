import Foundation

struct FileResult: Sendable {
    let input: URL
    let output: URL?
    let error: String?
}

/// Converts a batch of files to one target format, reporting each file as it finishes.
@MainActor
final class ConversionJob {
    let files: [URL]
    let target: TargetFormat
    var isCancelled = false

    init(files: [URL], target: TargetFormat) {
        self.files = files
        self.target = target
    }

    func run(onFile: (FileResult) -> Void) async {
        if target.id == "pdf-merge" {
            let ordered = files.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
            let first = ordered[0]
            let output = Self.uniquePath(first.deletingLastPathComponent()
                .appendingPathComponent(first.deletingPathExtension().lastPathComponent + " (merged).pdf"))
            do {
                try ImageConversion.mergeToPDF(ordered, to: output)
                ordered.forEach { onFile(FileResult(input: $0, output: output, error: nil)) }
            } catch {
                try? FileManager.default.removeItem(at: output)
                ordered.forEach { onFile(FileResult(input: $0, output: nil, error: error.localizedDescription)) }
            }
            return
        }

        for input in files {
            if isCancelled { return }
            // Give the window a chance to redraw the progress bar between files.
            try? await Task.sleep(nanoseconds: 10_000_000)

            guard let engine = Formats.engine(of: input) else {
                onFile(FileResult(input: input, output: nil, error: "Unsupported file type (.\(input.pathExtension))."))
                continue
            }
            guard Formats.targets(for: engine).contains(where: { $0.id == target.id }) else {
                onFile(FileResult(input: input, output: nil, error: "Can't be transformed to \(target.label)."))
                continue
            }
            if Formats.canonical(input.pathExtension.lowercased()) == target.ext {
                onFile(FileResult(input: input, output: nil, error: "Already a .\(target.ext) file, skipped."))
                continue
            }

            let output = Self.uniquePath(input.deletingPathExtension().appendingPathExtension(target.ext))
            do {
                if engine == .image {
                    try ImageConversion.convert(input, to: output, ext: target.ext)
                } else {
                    try await DocumentConversion.convert(input, to: output, ext: target.ext, engine: engine)
                }
                onFile(FileResult(input: input, output: output, error: nil))
            } catch {
                try? FileManager.default.removeItem(at: output)
                onFile(FileResult(input: input, output: nil, error: error.localizedDescription))
            }
        }
    }

    /// "photo.png", or "photo (1).png", "photo (2).png"... if that name is taken.
    static func uniquePath(_ url: URL) -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return url }
        let dir = url.deletingLastPathComponent()
        let name = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        var i = 1
        while true {
            let candidate = dir.appendingPathComponent("\(name) (\(i)).\(ext)")
            if !fm.fileExists(atPath: candidate.path) { return candidate }
            i += 1
        }
    }
}
