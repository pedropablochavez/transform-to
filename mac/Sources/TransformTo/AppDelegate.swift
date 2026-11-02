import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var pickers: [PickerWindow] = []
    private var welcome: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Finder's right-click "Transform to…" item comes from the NSServices entry in Info.plist.
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()

        // When Finder launches us for the service (or to open files) the request arrives right after launch;
        // only show the welcome window if nothing else did.
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 700_000_000)
            if self.pickers.isEmpty { self.showWelcome() }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    /// Files dropped on the app icon.
    func application(_ application: NSApplication, open urls: [URL]) {
        showPicker(for: urls)
    }

    /// Called by the Services menu ("Transform to…" in Finder's right-click menu).
    @objc func transformFiles(_ pasteboard: NSPasteboard, userData: String, error: AutoreleasingUnsafeMutablePointer<NSString>) {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        showPicker(for: urls)
    }

    private func showPicker(for urls: [URL]) {
        guard !urls.isEmpty else { return }
        let picker = PickerWindow(files: urls)
        picker.onClose = { [weak self, weak picker] in
            self?.pickers.removeAll { $0 === picker }
        }
        pickers.append(picker)
        picker.show()
        // Close the welcome window only after the picker is up, or the app would quit on "last window closed".
        welcome?.close()
        welcome = nil
    }

    private func showWelcome() {
        let text = NSTextField(wrappingLabelWithString: """
            Transform To is ready.

            In Finder, select one or more files, right-click and choose \
            Quick Actions › Transform to… (on some macOS versions: Services › Transform to…).

            You can also drop files on the Transform To icon in the Dock.

            Don't see it? Open System Settings › Keyboard › Keyboard Shortcuts › Services › Files and Folders \
            and tick "Transform to…".
            """)
        text.preferredMaxLayoutWidth = 380

        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.widthAnchor.constraint(equalToConstant: 64).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 64).isActive = true

        let stack = NSStackView(views: [icon, text])
        stack.orientation = .horizontal
        stack.alignment = .top
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 220),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Transform To"
        window.isReleasedWhenClosed = false
        window.contentView = stack
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        welcome = window
    }
}
