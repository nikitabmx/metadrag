import AppKit
import ServiceManagement

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let radial = RadialController()
    private lazy var watcher = DragWatcher(radial: radial)
    private var launched = false
    private var queued: [URL] = []

    private let enabledItem = NSMenuItem(title: "Enabled", action: #selector(toggleEnabled), keyEquivalent: "")
    private let besideItem = NSMenuItem(title: "Next to the Original", action: #selector(saveBeside), keyEquivalent: "")
    private let folderItem = NSMenuItem(title: "In a “MetaDrag” Folder", action: #selector(saveInFolder), keyEquivalent: "")
    private let loginItem = NSMenuItem(title: "Open at Login", action: #selector(toggleLogin), keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        Settings.register()
        buildStatusItem()
        watcher.start()
        launched = true
        if Demo.handle(CommandLine.arguments, radial: radial) { return }
        if !queued.isEmpty {
            open(queued)
            queued = []
        } else if !Settings.welcomed {
            Settings.welcomed = true
            ToastCenter.shared.info("MetaDrag is ready", "Start dragging a file, then press ⇧ ⌥ or ⌘",
                                    symbol: "hand.draw", seconds: 9)
        }
    }

    /// Finder → Open With → MetaDrag, or files dropped on the app icon.
    func application(_ sender: NSApplication, open urls: [URL]) {
        let files = urls.filter(\.isFileURL)
        guard launched else { queued += files; return }
        open(files)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        chooseFile()
        return false
    }

    private func open(_ files: [URL]) {
        guard !files.isEmpty else { return }
        radial.show(at: NSEvent.mouseLocation, files: files, mode: .convert, clickMode: true)
    }

    // MARK: Menu bar

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = Icons.status()
        statusItem.button?.toolTip = "MetaDrag"

        let menu = NSMenu()
        menu.delegate = self
        menu.addItem(.sectionHeader(title: "MetaDrag"))
        enabledItem.target = self
        menu.addItem(enabledItem)
        menu.addItem(.separator())

        menu.addItem(.sectionHeader(title: "Drag a file, then press"))
        for m in Mode.allCases {
            let item = NSMenuItem(title: "\(m.glyph)  \(m.title)", action: #selector(showHowTo), keyEquivalent: "")
            item.target = self
            item.image = NSImage(systemSymbolName: m.symbol, accessibilityDescription: nil)
            item.badge = NSMenuItemBadge(string: m.keyName)
            menu.addItem(item)
        }
        menu.addItem(.separator())

        let choose = NSMenuItem(title: "Choose File…", action: #selector(chooseFile), keyEquivalent: "o")
        choose.target = self
        menu.addItem(choose)

        let save = NSMenuItem(title: "Save Results", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for item in [besideItem, folderItem] { item.target = self; sub.addItem(item) }
        save.submenu = sub
        menu.addItem(save)

        loginItem.target = self
        menu.addItem(loginItem)
        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit MetaDrag", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        statusItem.menu = menu
        refresh()
    }

    func menuNeedsUpdate(_ menu: NSMenu) { refresh() }

    private func refresh() {
        enabledItem.state = Settings.enabled ? .on : .off
        besideItem.state = Settings.useSubfolder ? .off : .on
        folderItem.state = Settings.useSubfolder ? .on : .off
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        statusItem.button?.appearsDisabled = !Settings.enabled
    }

    @objc private func toggleEnabled() {
        Settings.enabled.toggle()
        refresh()
    }

    @objc private func saveBeside() { Settings.useSubfolder = false; refresh() }
    @objc private func saveInFolder() { Settings.useSubfolder = true; refresh() }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            ToastCenter.shared.failure("Couldn't change Login Items", error.localizedDescription)
        }
        refresh()
    }

    @objc private func showHowTo() {
        ToastCenter.shared.info("How it works", "Start dragging a file in Finder, then press ⇧ ⌥ or ⌘ and drop on a slice",
                                symbol: "hand.draw", seconds: 6)
    }

    @objc private func chooseFile() {
        NSApp.activate()
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = true
        panel.message = "Choose files for MetaDrag"
        panel.prompt = "Choose"
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let screen = NSScreen.main?.visibleFrame ?? .zero
        radial.show(at: NSPoint(x: screen.midX, y: screen.midY), files: panel.urls, mode: .convert, clickMode: true)
    }
}

// MARK: - Icons

enum Icons {
    /// A tiny six-petal ring with a hub, as a template image for the menu bar.
    static func status() -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
            let c = NSPoint(x: 9, y: 9)
            NSColor.black.setFill()
            for i in 0..<6 {
                let a = CGFloat(i) * 60 + 90
                let p = NSBezierPath()
                p.appendArc(withCenter: c, radius: 8.4, startAngle: a - 23, endAngle: a + 23)
                p.appendArc(withCenter: c, radius: 5.0, startAngle: a + 23, endAngle: a - 23, clockwise: true)
                p.close()
                p.fill()
            }
            NSBezierPath(ovalIn: NSRect(x: 6, y: 6, width: 6, height: 6)).fill()
            return true
        }
        img.isTemplate = true
        return img
    }
}

// MARK: - Demo / self-test hooks

/// `--demo convert|tools|share [--hover N] files…` shows the ring pinned at the screen centre.
/// `--demo toasts files…` shows sample notifications.
/// `--run <action-id> files…` runs one action headlessly, prints the result and quits.
@MainActor enum Demo {
    static func handle(_ args: [String], radial: RadialController) -> Bool {
        if let i = args.firstIndex(of: "--run"), i + 2 < args.count {
            run(id: args[i + 1], files: args[(i + 2)...].map { URL(fileURLWithPath: $0) })
            return true
        }
        guard let i = args.firstIndex(of: "--demo") else { return false }
        let rest = Array(args[(i + 1)...])
        let what = rest.first ?? "convert"
        var hover: Int?
        var files: [URL] = []
        var j = 1
        while j < rest.count {
            if rest[j] == "--hover", j + 1 < rest.count { hover = Int(rest[j + 1]); j += 2; continue }
            files.append(URL(fileURLWithPath: rest[j]))
            j += 1
        }
        if what == "toasts" { toasts(files); return true }
        let mode: Mode = ["convert": .convert, "tools": .tools, "share": .share][what] ?? .convert
        guard !files.isEmpty else { return false }
        let screen = NSScreen.main?.frame ?? .zero
        radial.pinned = true
        radial.show(at: NSPoint(x: screen.midX, y: screen.midY), files: files, mode: mode, clickMode: true)
        if let hover {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { radial.setHover(hover) }
        }
        return true
    }

    private static func run(id: String, files: [URL]) {
        let action = Mode.allCases.lazy.flatMap { Catalog.actions(for: files, mode: $0) }.first { $0.id == id }
        guard let action else {
            print("FAIL no action \(id) for these files")
            exit(2)
        }
        Runner.onFinish = { result in
            switch result {
            case .success(let r):
                print("OK \(r.title) | \(r.detail) | \(r.badge ?? "-") | \(r.outputs.map(\.path).joined(separator: ", "))")
            case .failure(let e):
                print("FAIL \(e.localizedDescription)")
            }
            fflush(stdout)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { exit(0) }
        }
        action.perform(files)
    }

    private static func toasts(_ files: [URL]) {
        let c = ToastCenter.shared
        _ = c.begin("Converting to PNG…", files.first?.lastPathComponent ?? "Sunset.jpg")
        c.finish(c.begin("Compressing…", "photo.jpg"),
                 OpResult(title: "Compressed", detail: "4.2 MB → 1.1 MB · quality 62", badge: "−74%", outputs: Array(files.prefix(1))))
        c.info("Text copied", "214 words · “Quarterly report, draft 3”", symbol: "text.viewfinder", seconds: 600)
    }
}
