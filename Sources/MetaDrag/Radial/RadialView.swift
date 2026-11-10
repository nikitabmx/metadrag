import AppKit
import Observation
import SwiftUI

@MainActor @Observable
final class RadialModel {
    var files: [URL] = []
    var mode: Mode = .convert
    var rings: [Mode: [Action]] = [:]
    var hover: Int?
    var appear = false
    var clickMode = false
    var title = ""
    var subtitle = ""
    var icon: NSImage?
    @ObservationIgnored private var loadToken = UUID()

    var items: [Action] { rings[mode] ?? [] }
    func available(_ m: Mode) -> Bool { !(rings[m] ?? []).isEmpty }

    func load(_ urls: [URL]) {
        guard let first = urls.first else { return }
        files = urls
        var r: [Mode: [Action]] = [:]
        for m in Mode.allCases { r[m] = Catalog.actions(for: urls, mode: m) }
        rings = r
        if urls.count == 1 {
            title = first.lastPathComponent
            subtitle = Files.isDirectory(first) ? "Folder" : Fmt.bytes(Files.size(first))
        } else {
            title = "\(urls.count) files"
            subtitle = urls.contains(where: Files.isDirectory) ? "" : Fmt.bytes(Files.total(urls))
        }
        icon = Thumbs.icon(first)
        let token = UUID()
        loadToken = token
        Task.detached(priority: .userInitiated) {
            guard let img = Thumbs.small(first) else { return }
            await MainActor.run { if self.loadToken == token { self.icon = img } }
        }
    }

    var emptyText: String {
        let ext = files.count == 1 ? files[0].pathExtension.lowercased() : ""
        let what = files.count > 1 ? "these files" : (ext.isEmpty ? "this" : ".\(ext)")
        let alt = Mode.allCases.first { $0 != mode && available($0) }
        let hint = alt.map { " · try \($0.glyph) \($0.title)" } ?? ""
        switch mode {
        case .convert: return "Can't convert \(what)\(hint)"
        case .tools: return "No tools for \(what)\(hint)"
        case .share: return "Nothing to share"
        }
    }
}

// MARK: - Ring

struct RadialView: View {
    let model: RadialModel

    var body: some View {
        let items = model.items
        let n = min(items.count, Geo.slots)
        ZStack(alignment: .topLeading) {
            GlassEffectContainer(spacing: 1) {
                ZStack(alignment: .topLeading) {
                    ForEach(0..<Geo.slots, id: \.self) { i in
                        let (a0, a1) = Geo.angles(i, n)
                        let on = model.hover == i
                        Color.clear
                            .frame(width: Geo.size.width, height: Geo.size.height)
                            .glassEffect(on ? .regular.tint(.black.opacity(0.86)) : .regular,
                                         in: PetalShape(a0: a0, a1: a1, lift: on ? 1 : 0))
                    }
                    Color.clear
                        .frame(width: Geo.size.width, height: Geo.size.height)
                        .glassEffect(.regular, in: HubShape())
                }
            }

            // the black accent: the picked petal turns to black glass with a bright rim,
            // which also keeps it readable on dark wallpapers
            ForEach(0..<n, id: \.self) { i in
                let (a0, a1) = Geo.angles(i, n)
                let on = model.hover == i
                let shape = PetalShape(a0: a0, a1: a1, lift: on ? 1 : 0)
                ZStack {
                    shape.fill(Ink.petal)
                    shape.stroke(Ink.rimGradient, lineWidth: 0.9)
                }
                .shadow(color: .black.opacity(0.35), radius: 12, y: 5)
                .opacity(on ? 1 : 0)
            }

            ZStack(alignment: .topLeading) {
                ForEach(0..<n, id: \.self) { i in
                    PetalLabel(action: items[i], on: model.hover == i)
                        .position(Geo.labelPoint(i, n, lifted: model.hover == i))
                }
                if n == 0 {
                    Image(systemName: model.mode.symbol)
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .position(x: Geo.center.x, y: Geo.center.y - (Geo.rIn + Geo.rOut) / 2)
                }
            }
            .frame(width: Geo.size.width, height: Geo.size.height)
            .id(model.mode)
            .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: Geo.anchor)))

            HubGlyph(mode: model.mode)
                .position(Geo.center)

            BottomCard(model: model)
                .position(x: Geo.center.x, y: Geo.cardTop + Geo.cardH / 2)
        }
        .frame(width: Geo.size.width, height: Geo.size.height)
        .scaleEffect(model.appear ? 1 : 0.86, anchor: Geo.anchor)
        .opacity(model.appear ? 1 : 0)
        .allowsHitTesting(false)
    }
}

struct PetalLabel: View {
    let action: Action
    let on: Bool

    var body: some View {
        Group {
            if let symbol = action.symbol {
                VStack(spacing: 5) {
                    Image(systemName: symbol)
                        .font(.system(size: 17, weight: .medium))
                        .frame(height: 20)
                    Text(action.title.uppercased())
                        .font(.system(size: 9, weight: .bold))
                        .tracking(0.6)
                }
            } else {
                Text(action.title)
                    .font(.system(size: 14.5, weight: .bold))
                    .tracking(0.7)
            }
        }
        .foregroundStyle(on ? AnyShapeStyle(Color.white) : AnyShapeStyle(.primary))
        .scaleEffect(on ? 1.08 : 1)
        .fixedSize()
    }
}

struct HubGlyph: View {
    let mode: Mode

    var body: some View {
        VStack(spacing: 2) {
            Text(mode.glyph)
                .font(.system(size: 30, weight: .regular))
            Text(mode.title.uppercased())
                .font(.system(size: 8.5, weight: .bold))
                .tracking(1.4)
                .foregroundStyle(.secondary)
        }
        .id(mode)
        .transition(.blurReplace)
    }
}

// MARK: - Caption + key switcher

struct BottomCard: View {
    let model: RadialModel
    @Namespace private var ns

    var body: some View {
        VStack(spacing: 4) {
            caption
                .frame(height: Geo.captionH)
                .frame(maxWidth: .infinity)
            HStack(spacing: 0) {
                ForEach(Mode.allCases) { chip($0) }
            }
            .frame(height: Geo.chipH)
        }
        .padding(.top, Geo.cardPad + 2)
        .padding(.bottom, Geo.cardPad)
        .padding(.horizontal, Geo.cardPad)
        .frame(width: Geo.cardW, height: Geo.cardH)
        .glassEffect(.regular, in: .rect(cornerRadius: 21))
    }

    @ViewBuilder private var caption: some View {
        let items = model.items
        if let h = model.hover, h < items.count {
            HStack(spacing: 6) {
                Text(items[h].title).font(.system(size: 12, weight: .bold))
                Text(items[h].hint).font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .padding(.horizontal, 12)
            .transition(.opacity)
        } else if items.isEmpty {
            Text(model.emptyText)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, 12)
        } else {
            HStack(spacing: 6) {
                if let icon = model.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fill)
                        .frame(width: 16, height: 16)
                        .clipShape(.rect(cornerRadius: 3.5))
                }
                Text(model.title)
                    .font(.system(size: 11.5, weight: .semibold))
                    .truncationMode(.middle)
                if !model.subtitle.isEmpty {
                    Text(model.subtitle)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .layoutPriority(1)
                }
            }
            .lineLimit(1)
            .padding(.horizontal, 12)
        }
    }

    private func chip(_ m: Mode) -> some View {
        let active = m == model.mode
        return HStack(spacing: 5) {
            Text(m.glyph).font(.system(size: 12.5, weight: .semibold))
            Text(m.title).font(.system(size: 11.5, weight: .semibold))
        }
        .foregroundStyle(active ? AnyShapeStyle(Color.white)
                                : AnyShapeStyle(Color.primary.opacity(model.available(m) ? 0.78 : 0.3)))
        .frame(width: Geo.chipW, height: Geo.chipH)
        .background {
            if active {
                Capsule()
                    .fill(Ink.fill)
                    .overlay(Capsule().strokeBorder(Ink.rim, lineWidth: 0.7))
                    .shadow(color: .black.opacity(0.28), radius: 6, y: 2)
                    .matchedGeometryEffect(id: "thumb", in: ns)
            }
        }
    }
}
