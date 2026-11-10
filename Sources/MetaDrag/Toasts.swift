import AppKit
import Observation
import SwiftUI

@MainActor @Observable
final class ToastModel: Identifiable {
    enum Phase { case working, done, info, failed }

    let id = UUID()
    var phase: Phase
    var title: String
    var detail: String
    var badge: String?
    var outputs: [URL] = []
    var undoable = false
    var thumbnail: NSImage?
    var symbol: String?
    var shown = false
    var hovering = false
    @ObservationIgnored var dismissToken = UUID()

    init(phase: Phase, title: String, detail: String, symbol: String? = nil) {
        self.phase = phase
        self.title = title
        self.detail = detail
        self.symbol = symbol
    }
}

final class ToastPanel: NSPanel {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        becomesKeyOnlyIfNeeded = true
        animationBehavior = .none
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Buttons work on the first click even though the app is never frontmost.
final class FirstClickHostingView<V: View>: NSHostingView<V> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@MainActor final class ToastCenter {
    static let shared = ToastCenter()
    static let width: CGFloat = 348
    static let pad: CGFloat = 18           // transparent margin around the card for the glass shadow
    static let margin: CGFloat = 8
    static let spacing: CGFloat = 10
    static let maxVisible = 4

    private struct Entry { let model: ToastModel; let panel: ToastPanel; let host: NSView }
    private var stack: [Entry] = []        // newest first

    // MARK: Public

    func begin(_ title: String, _ detail: String) -> ToastModel {
        present(ToastModel(phase: .working, title: title, detail: detail))
    }

    @discardableResult
    func info(_ title: String, _ detail: String, symbol: String, seconds: Double = 4) -> ToastModel {
        let m = present(ToastModel(phase: .info, title: title, detail: detail, symbol: symbol))
        autoDismiss(m, after: seconds)
        return m
    }

    func failure(_ title: String, _ detail: String) {
        let m = present(ToastModel(phase: .failed, title: title, detail: detail, symbol: "exclamationmark"))
        autoDismiss(m, after: 7)
    }

    func finish(_ m: ToastModel, _ r: OpResult) {
        m.title = r.title
        m.detail = r.detail
        m.badge = r.badge
        m.outputs = r.outputs
        m.undoable = r.undoable && !r.outputs.isEmpty
        m.symbol = r.symbol ?? (r.outputs.isEmpty ? "checkmark" : nil)
        m.phase = r.outputs.isEmpty ? .info : .done
        if r.symbol == nil, let first = r.outputs.first {
            Task {
                let img = await Thumbs.best(first)
                m.thumbnail = img
                self.relayout()
            }
        }
        relayout()
        autoDismiss(m, after: m.phase == .done ? 7 : 4)
    }

    func fail(_ m: ToastModel, _ message: String) {
        let what = m.title.hasSuffix("…") ? String(m.title.dropLast()) : m.title
        m.title = "\(what) failed"
        m.detail = message
        m.symbol = "exclamationmark"
        m.badge = nil
        m.phase = .failed
        relayout()
        autoDismiss(m, after: 9)
    }

    // MARK: Actions

    private func open(_ m: ToastModel) {
        guard !m.outputs.isEmpty else { return }
        if m.outputs.count == 1 {
            NSWorkspace.shared.open(m.outputs[0])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting(m.outputs)
        }
        dismiss(m)
    }

    private func reveal(_ m: ToastModel) {
        NSWorkspace.shared.activateFileViewerSelecting(m.outputs)
        dismiss(m)
    }

    /// Undo = move what we created to the Trash (recoverable), never a hard delete.
    private func undo(_ m: ToastModel) {
        var moved = 0
        for url in m.outputs where (try? FileManager.default.trashItem(at: url, resultingItemURL: nil)) != nil {
            moved += 1
        }
        m.outputs = []
        m.badge = nil
        m.thumbnail = nil
        m.phase = .info
        m.symbol = "arrow.uturn.backward"
        m.title = "Undone"
        m.detail = moved > 0 ? "Moved \(Fmt.plural(moved, "item")) to the Trash" : "Nothing left to undo"
        relayout()
        autoDismiss(m, after: 2.5)
    }

    // MARK: Stack

    private func present(_ m: ToastModel) -> ToastModel {
        let panel = ToastPanel()
        let view = ToastView(model: m,
                             open: { [weak self] in self?.open(m) },
                             reveal: { [weak self] in self?.reveal(m) },
                             undo: { [weak self] in self?.undo(m) },
                             close: { [weak self] in self?.dismiss(m) })
        let host = FirstClickHostingView(rootView: view)
        host.sizingOptions = [.intrinsicContentSize]     // fittingSize drives the panel frame
        panel.contentView = host
        stack.insert(Entry(model: m, panel: panel, host: host), at: 0)

        // too many: drop the oldest finished ones
        while stack.count > Self.maxVisible, let old = stack.last(where: { $0.model.phase != .working }) {
            dismiss(old.model)
        }
        relayout(newcomer: m)
        panel.orderFrontRegardless()
        DispatchQueue.main.async {
            withAnimation(.spring(duration: 0.5, bounce: 0.28)) { m.shown = true }
        }
        return m
    }

    func dismiss(_ m: ToastModel) {
        guard let i = stack.firstIndex(where: { $0.model === m }) else { return }
        let entry = stack.remove(at: i)
        m.dismissToken = UUID()
        withAnimation(.easeIn(duration: 0.18)) { m.shown = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { entry.panel.orderOut(nil) }
        relayout()
    }

    private func autoDismiss(_ m: ToastModel, after seconds: Double) {
        let token = UUID()
        m.dismissToken = token
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(seconds))
            while m.hovering && m.dismissToken == token { try? await Task.sleep(for: .seconds(0.4)) }
            if m.dismissToken == token { self.dismiss(m) }
        }
    }

    private func relayout(newcomer: ToastModel? = nil) {
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(mouse, $0.frame, false) }) ?? NSScreen.main else { return }
        let vf = screen.visibleFrame
        var cardTop = vf.maxY - Self.margin
        for e in stack {
            let h = ceil(e.host.fittingSize.height)
            let w = Self.width + 2 * Self.pad
            let frame = NSRect(x: vf.maxX - Self.margin - Self.width - Self.pad,
                               y: cardTop + Self.pad - h, width: w, height: h)
            if e.model === newcomer || !e.panel.isVisible {
                e.panel.setFrame(frame, display: true)
            } else if e.panel.frame != frame {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.32
                    ctx.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.25, 1)
                    e.panel.animator().setFrame(frame, display: true)
                }
            }
            cardTop -= (h - 2 * Self.pad) + Self.spacing
        }
    }
}

// MARK: - View

struct ToastView: View {
    let model: ToastModel
    let open: () -> Void
    let reveal: () -> Void
    let undo: () -> Void
    let close: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            leading
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 7) {
                    Text(model.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    if let badge = model.badge {
                        Text(badge)
                            .font(.system(size: 10.5, weight: .bold))
                            .monospacedDigit()
                            .foregroundStyle(.white)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Ink.fill))
                            .overlay(Capsule().strokeBorder(Ink.rim, lineWidth: 0.6))
                    }
                }
                Text(model.detail)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if model.phase == .done {
                    HStack(spacing: 6) {
                        Button("Open", action: open).buttonStyle(InkButton())
                        Button("Show in Finder", action: reveal).buttonStyle(SoftButton())
                        if model.undoable { Button("Undo", action: undo).buttonStyle(SoftButton()) }
                    }
                    .padding(.top, 7)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .padding(.trailing, 16)
            .padding(.top, 2)
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(width: ToastCenter.width, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 22))
        .overlay(alignment: .topTrailing) {
            if model.hovering && model.phase != .working {
                Button(action: close) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(.primary.opacity(0.1)))
                }
                .buttonStyle(.plain)
                .padding(9)
                .transition(.opacity)
            }
        }
        .onHover { h in withAnimation(.easeOut(duration: 0.15)) { model.hovering = h } }
        .padding(ToastCenter.pad)
        .offset(x: model.shown ? 0 : 60)
        .opacity(model.shown ? 1 : 0)
        .animation(.spring(duration: 0.4, bounce: 0.2), value: model.phase)
    }

    @ViewBuilder private var leading: some View {
        if model.phase == .done, let thumb = model.thumbnail {
            Image(nsImage: thumb)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: 44, height: 44)
                .clipShape(.rect(cornerRadius: 11))
                .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(.primary.opacity(0.12), lineWidth: 0.5))
                .transition(.scale(scale: 0.6).combined(with: .opacity))
        } else {
            ZStack {
                Circle().fill(Ink.fill)
                Circle().strokeBorder(Ink.rim, lineWidth: 0.7)
                if model.phase == .working {
                    Spinner()
                } else {
                    Image(systemName: model.symbol ?? "checkmark")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.white)
                        .contentTransition(.symbolEffect(.replace))
                }
            }
            .frame(width: 44, height: 44)
            .shadow(color: .black.opacity(0.22), radius: 5, y: 2)
        }
    }
}

struct Spinner: View {
    @State private var spin = false

    var body: some View {
        Circle()
            .trim(from: 0.1, to: 0.78)
            .stroke(Color.white, style: StrokeStyle(lineWidth: 2.4, lineCap: .round))
            .frame(width: 20, height: 20)
            .rotationEffect(.degrees(spin ? 360 : 0))
            .animation(.linear(duration: 0.85).repeatForever(autoreverses: false), value: spin)
            .onAppear { spin = true }
    }
}

struct InkButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 13)
            .padding(.vertical, 5)
            .background(Capsule().fill(Ink.fill))
            .overlay(Capsule().strokeBorder(Ink.rim, lineWidth: 0.7))
            .opacity(configuration.isPressed ? 0.8 : 1)
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.spring(duration: 0.2), value: configuration.isPressed)
            .contentShape(Capsule())
    }
}

struct SoftButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(Capsule().fill(.primary.opacity(configuration.isPressed ? 0.16 : 0.08)))
            .scaleEffect(configuration.isPressed ? 0.95 : 1)
            .animation(.spring(duration: 0.2), value: configuration.isPressed)
            .contentShape(Capsule())
    }
}
