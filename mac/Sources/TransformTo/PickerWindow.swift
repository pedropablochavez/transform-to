import AppKit

/// "Transform 12 files to:" followed by one button per format; then progress and a summary.
@MainActor
final class PickerWindow: NSObject, NSWindowDelegate {
    let window: NSWindow
    var onClose: (() -> Void)?

    private let files: [URL]
    private let formats: [TargetFormat]
    private let status = NSTextField(wrappingLabelWithString: "")
    private let progress = NSProgressIndicator()
    private let showButton = NSButton(title: "Show in Finder", target: nil, action: nil)
    private var formatButtons: [NSButton] = []
    private var job: ConversionJob?
    private var outputs: [URL] = []
    private var failures: [String] = []
    private var done = 0

    init(files: [URL]) {
        self.files = files
        self.formats = Formats.targets(for: files)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 200),
                          styleMask: [.titled, .closable], backing: .buffered, defer: false)
        super.init()
        window.title = "Transform To"
        window.isReleasedWhenClosed = false
        window.delegate = self
        build()
        window.center()
    }

    private func build() {
        let title = NSTextField(labelWithString: files.count == 1
            ? "Transform \"\(files[0].lastPathComponent)\" to:"
            : "Transform \(files.count) files to:")
        title.font = .boldSystemFont(ofSize: 13)
        title.lineBreakMode = .byTruncatingMiddle

        formatButtons = formats.enumerated().map { index, format in
            let button = NSButton(title: format.label, target: self, action: #selector(choose(_:)))
            button.tag = index
            button.bezelStyle = .rounded
            return button
        }
        let columns = 3
        var rows: [[NSView]] = stride(from: 0, to: formatButtons.count, by: columns).map {
            Array(formatButtons[$0..<min($0 + columns, formatButtons.count)])
        }
        if var last = rows.popLast() {
            while last.count < columns { last.append(NSGridCell.emptyContentView) }
            rows.append(last)
        }
        let grid = NSGridView(views: rows)
        grid.rowSpacing = 8
        grid.columnSpacing = 8
        for i in 0..<grid.numberOfColumns { grid.column(at: i).width = 132 }

        if formats.isEmpty {
            status.stringValue = "These files can't be transformed. Supported: images (JPG, PNG, HEIC, WEBP, GIF, TIFF, BMP, ICO, AVIF) and Office documents."
        }
        progress.isIndeterminate = false
        progress.minValue = 0
        progress.maxValue = Double(files.count)
        progress.isHidden = true
        showButton.target = self
        showButton.action = #selector(showInFinder)
        showButton.isHidden = true

        let stack = NSStackView(views: [title, grid, progress, status, showButton])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 18, right: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false
        progress.widthAnchor.constraint(equalTo: grid.widthAnchor).isActive = true
        status.widthAnchor.constraint(equalTo: grid.widthAnchor).isActive = true

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        window.contentView = content
    }

    @objc private func choose(_ sender: NSButton) {
        let target = formats[sender.tag]
        formatButtons.forEach { $0.isEnabled = false }
        progress.isHidden = false
        status.stringValue = files.count == 1 ? "Converting…" : "Converting… 0 of \(files.count)"

        let job = ConversionJob(files: files, target: target)
        self.job = job
        Task { @MainActor in
            await job.run { result in self.fileDone(result) }
            self.finish()
        }
    }

    private func fileDone(_ result: FileResult) {
        done += 1
        progress.doubleValue = Double(done)
        if let output = result.output {
            outputs.append(output)
        } else {
            failures.append("\(result.input.lastPathComponent): \(result.error ?? "failed")")
        }
        if files.count > 1 {
            status.stringValue = "Converting… \(done) of \(files.count)"
        }
    }

    private func finish() {
        let ok = done - failures.count
        showButton.isHidden = outputs.isEmpty
        if failures.isEmpty {
            status.stringValue = ok == 1 ? "Done." : "Done. \(ok) files converted."
            // Everything went fine: get out of the way on our own.
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                self.window.close()
            }
        } else {
            status.stringValue = "\(ok) converted, \(failures.count) failed:\n" + failures.joined(separator: "\n")
        }
    }

    @objc private func showInFinder() {
        NSWorkspace.shared.activateFileViewerSelecting(Array(Set(outputs)))
    }

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        job?.isCancelled = true
        onClose?()
    }
}
