import AppKit
import SwiftUI

/// Borderless, non-activating, always-on-top panel. It can take key focus only in click mode
/// (opened from the menu bar / Open With), where Esc and clicks need to reach it.
final class RadialPanel: NSPanel {
    var allowKey = false
    var onResignKey: (() -> Void)?
    var onEscape: (() -> Void)?

    init() {
        super.init(contentRect: NSRect(origin: .zero, size: Geo.size),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        acceptsMouseMovedEvents = true
        isMovable = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { allowKey }
    override var canBecomeMain: Bool { false }
    override func resignKey() { super.resignKey(); onResignKey?() }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape?() } else { super.keyDown(with: event) }
    }
}

/// Transparent layer over the SwiftUI ring that receives the file drop and the mouse.
final class DropCatcher: NSView {
    weak var controller: RadialController?

    override var isFlipped: Bool { true }

    override init(frame: NSRect) {
        super.init(frame: frame)
        registerForDraggedTypes([.fileURL])
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self))
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    private func local(_ info: NSDraggingInfo) -> CGPoint { convert(info.draggingLocation, from: nil) }

    private static func urls(_ info: NSDraggingInfo) -> [URL] {
        (info.draggingPasteboard.readObjects(forClasses: [NSURL.self],
                                             options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
    }

    /// Always copy semantics: the source app must never treat our drop as a move and delete the file.
    private static func operation(_ info: NSDraggingInfo) -> NSDragOperation {
        let mask = info.draggingSourceOperationMask
        for op: NSDragOperation in [.copy, .generic, .link] where mask.contains(op) { return op }
        return []
    }

    override func draggingEntered(_ info: NSDraggingInfo) -> NSDragOperation {
        controller?.dragEntered(Self.urls(info))
        controller?.track(local(info))
        return Self.operation(info)
    }

    override func draggingUpdated(_ info: NSDraggingInfo) -> NSDragOperation {
        controller?.track(local(info))
        return Self.operation(info)
    }

    override func draggingExited(_ info: NSDraggingInfo?) { controller?.setHover(nil) }
    override func prepareForDragOperation(_ info: NSDraggingInfo) -> Bool { true }

    override func performDragOperation(_ info: NSDraggingInfo) -> Bool {
        guard let controller else { return false }
        if controller.activate(at: local(info)) { return true }
        controller.hide()
        return false
    }

    override func mouseMoved(with event: NSEvent) {
        guard controller?.clickMode == true else { return }
        controller?.track(convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        if controller?.clickMode == true { controller?.setHover(nil) }
    }

    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) { controller?.click(at: convert(event.locationInWindow, from: nil)) }
    override func rightMouseDown(with event: NSEvent) { controller?.hide() }
}

@MainActor final class RadialController {
    let model = RadialModel()
    private let panel = RadialPanel()
    private let catcher = DropCatcher(frame: NSRect(origin: .zero, size: Geo.size))
    private(set) var isShown = false
    private var outsideClicks: Any?
    /// Demo/screenshot mode: stays open when focus moves elsewhere.
    var pinned = false

    var clickMode: Bool { model.clickMode }
    var frame: NSRect { panel.frame }

    init() {
        let root = NSView(frame: NSRect(origin: .zero, size: Geo.size))
        let host = NSHostingView(rootView: RadialView(model: model))
        host.sizingOptions = []
        host.frame = root.bounds
        host.autoresizingMask = [.width, .height]
        catcher.autoresizingMask = [.width, .height]
        root.addSubview(host)
        root.addSubview(catcher)
        panel.contentView = root
        catcher.controller = self
        panel.onResignKey = { [weak self] in
            guard let self, self.model.clickMode, !self.pinned else { return }
            self.hide()
        }
        panel.onEscape = { [weak self] in self?.hide() }
    }

    /// `p` is the cursor in global AppKit coordinates (bottom-left origin).
    func show(at p: NSPoint, files: [URL], mode: Mode, clickMode: Bool) {
        model.load(files)
        var mode = mode
        if clickMode, !model.available(mode), let first = Mode.allCases.first(where: model.available) { mode = first }
        model.mode = mode
        model.hover = nil
        model.clickMode = clickMode

        let screen = NSScreen.screens.first { NSMouseInRect(p, $0.frame, false) } ?? NSScreen.main
        var origin = NSPoint(x: p.x - Geo.center.x, y: p.y + Geo.center.y - Geo.size.height)
        if let f = screen?.frame {
            origin.x = min(max(origin.x, f.minX), f.maxX - Geo.size.width)
            origin.y = min(max(origin.y, f.minY), f.maxY - Geo.size.height)
        }
        panel.setFrameOrigin(origin)
        panel.allowKey = clickMode
        panel.ignoresMouseEvents = false
        catcher.registerForDraggedTypes([.fileURL])
        model.appear = false
        isShown = true
        panel.orderFrontRegardless()
        if clickMode {
            NSApp.activate()
            panel.makeKey()
            // a click anywhere else closes it, even if the panel never got key focus
            if outsideClicks == nil {
                outsideClicks = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, !self.pinned else { return }
                        self.hide()
                    }
                }
            }
        }
        DispatchQueue.main.async {
            withAnimation(.spring(duration: 0.32, bounce: 0.3)) { self.model.appear = true }
        }
    }

    func hide(fast: Bool = false) {
        guard isShown else { return }
        isShown = false
        // stop catching drops and clicks at once, so a drop during the fade reaches whatever is underneath
        panel.ignoresMouseEvents = true
        catcher.unregisterDraggedTypes()
        if let m = outsideClicks {
            NSEvent.removeMonitor(m)
            outsideClicks = nil
        }
        withAnimation(.easeOut(duration: fast ? 0.08 : 0.14)) {
            model.appear = false
            model.hover = nil
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + (fast ? 0.1 : 0.16)) { [weak self] in
            guard let self, !self.isShown else { return }
            self.panel.orderOut(nil)
        }
    }

    /// Whether a global point is over the petals or the key card (not the panel's transparent margins).
    func isNear(_ p: NSPoint) -> Bool {
        let f = panel.frame
        let local = CGPoint(x: p.x - f.minX, y: f.maxY - p.y)
        if hypot(local.x - Geo.center.x, local.y - Geo.center.y) <= Geo.rOut + 34 { return true }
        let card = CGRect(x: Geo.center.x - Geo.cardW / 2, y: Geo.cardTop, width: Geo.cardW, height: Geo.cardH)
        return card.insetBy(dx: -14, dy: -14).contains(local)
    }

    func switchMode(_ m: Mode) {
        guard isShown, m != model.mode else { return }
        withAnimation(.spring(duration: 0.44, bounce: 0.2)) {
            model.mode = m
            model.hover = nil
        }
    }

    func setHover(_ i: Int?) {
        guard model.hover != i else { return }
        withAnimation(.spring(duration: 0.28, bounce: 0.32)) { model.hover = i }
    }

    // MARK: Events from DropCatcher

    func dragEntered(_ urls: [URL]) {
        let files = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        if !files.isEmpty, files != model.files { model.load(files) }
    }

    func track(_ p: CGPoint) {
        switch Geo.hit(p, count: model.items.count) {
        case .petal(let i): setHover(i)
        case .chip(let m): setHover(nil); switchMode(m)
        case .hub, .none: setHover(nil)
        }
    }

    /// Runs the petal under `p`. Returns false if there isn't one.
    @discardableResult func activate(at p: CGPoint) -> Bool {
        guard case .petal(let i) = Geo.hit(p, count: model.items.count), i < model.items.count else { return false }
        let action = model.items[i]
        let files = model.files
        hide(fast: true)
        // let the drag session finish before any share sheet or prompt appears
        DispatchQueue.main.async { action.perform(files) }
        return true
    }

    func click(at p: CGPoint) {
        switch Geo.hit(p, count: model.items.count) {
        case .petal: activate(at: p)
        case .chip(let m): switchMode(m)
        case .hub: cycleMode()
        case .none: hide()
        }
    }

    private func cycleMode() {
        let all = Mode.allCases
        switchMode(all[(model.mode.rawValue + 1) % all.count])
    }
}
