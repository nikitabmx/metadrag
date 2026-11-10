import AppKit

/// Opens the ring when you press ⇧, ⌥ or ⌘ *during* a file drag; the key picks the ring.
///
/// Polls global state (`NSEvent.pressedMouseButtons` / `modifierFlags`), which needs no
/// Accessibility or Input Monitoring permission and can't stall input the way an event tap can.
///
/// Guards against false triggers:
/// * only fires once the system drag pasteboard changes after the mouse went down, i.e. a real
///   drag-and-drop session started (not a window move, a text selection or a marquee);
/// * only file drags count;
/// * the key must go down *after* the click. Keys held from before keep their usual Finder
///   meaning, so an ordinary ⌥-drag copy or ⌘-drag move never pops the ring.
@MainActor final class DragWatcher {
    private let radial: RadialController
    private let dragPasteboard = NSPasteboard(name: .drag)
    private var timer: Timer?

    private var downAt: NSPoint?
    private var dragCountAtDown = 0
    private var pending: Mode?
    private var fired = false
    private var nonFileDrag = false
    private var prevFlags: NSEvent.ModifierFlags = []
    private var releaseScheduled = false

    init(radial: RadialController) { self.radial = radial }

    func start() {
        let t = Timer(timeInterval: 1.0 / 90, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func tick() {
        let lbtn = NSEvent.pressedMouseButtons & 1 != 0
        let flags = NSEvent.modifierFlags.intersection(Mode.triggerFlags)
        let pressed = Mode.pressed(flags.subtracting(prevFlags))
        prevFlags = flags
        let pos = NSEvent.mouseLocation

        if radial.isShown {
            if let m = pressed { radial.switchMode(m) }      // press another key → morph to its ring
            guard !radial.clickMode else { return }
            if !lbtn {
                // a drop on a petal lands via performDragOperation; anything else just closes
                if !releaseScheduled {
                    releaseScheduled = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
                        guard let self else { return }
                        self.releaseScheduled = false
                        if !self.radial.clickMode { self.radial.hide() }
                    }
                }
                return
            }
            if !radial.isNear(pos) {
                radial.hide()        // dragged away from the ring: the file is going somewhere else
                fired = false
                pending = nil
            }
            return
        }

        guard lbtn else {
            downAt = nil
            pending = nil
            fired = false
            nonFileDrag = false
            return
        }
        guard let start = downAt else {
            downAt = pos
            dragCountAtDown = dragPasteboard.changeCount
            pending = nil
            fired = false
            nonFileDrag = false
            return
        }
        if let m = pressed { pending = m }
        guard Settings.enabled, !fired, !nonFileDrag,
              let mode = pending, flags.contains(mode.flag),
              hypot(pos.x - start.x, pos.y - start.y) >= 4,
              dragPasteboard.changeCount != dragCountAtDown else { return }

        let files = Self.files(dragPasteboard)
        guard !files.isEmpty else { nonFileDrag = true; return }
        fired = true
        radial.show(at: pos, files: files, mode: mode, clickMode: false)
    }

    static func files(_ pb: NSPasteboard) -> [URL] {
        let urls = (pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        return urls.filter { FileManager.default.fileExists(atPath: $0.path) }
    }
}
