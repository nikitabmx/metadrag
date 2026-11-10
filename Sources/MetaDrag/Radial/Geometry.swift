import SwiftUI

/// Layout of the radial menu, shared by the SwiftUI view and the AppKit hit-testing.
/// Coordinates are top-left based (SwiftUI / flipped NSView). Angles are degrees,
/// 0 = 12 o'clock, growing clockwise.
enum Geo {
    static let size = CGSize(width: 440, height: 450)
    static let center = CGPoint(x: 220, y: 194)
    static let rOut: CGFloat = 148
    static let rIn: CGFloat = 66
    static let rHub: CGFloat = 54
    static let gap: CGFloat = 6           // constant-width gap between petals
    static let corner: CGFloat = 13
    static let lift: CGFloat = 7          // how far a hovered petal slides outward
    static let slots = 10

    static let chipW: CGFloat = 100
    static let chipH: CGFloat = 30
    static let cardW: CGFloat = chipW * 3 + 12
    static let cardTop: CGFloat = center.y + rOut + 22
    static let captionH: CGFloat = 22
    static let cardPad: CGFloat = 6
    static let cardH: CGFloat = cardPad + 2 + captionH + 4 + chipH + cardPad
    static let chipCenterY: CGFloat = cardTop + cardPad + 2 + captionH + 4 + chipH / 2

    static var anchor: UnitPoint { UnitPoint(x: center.x / size.width, y: center.y / size.height) }

    static func chipRect(_ m: Mode) -> CGRect {
        CGRect(x: center.x - chipW * 1.5 + CGFloat(m.rawValue) * chipW, y: chipCenterY - chipH / 2,
               width: chipW, height: chipH)
    }

    /// Start/end angle of slot `i` when the ring has `n` petals. Unused slots collapse to a point
    /// so petals grow and shrink smoothly when the count changes. With no petals, slot 0 is an open ring.
    static func angles(_ i: Int, _ n: Int) -> (Double, Double) {
        if n == 0 { return i == 0 ? (0, 360) : (180, 180) }
        let span = 360 / Double(n)
        if i >= n { return (360 - span / 2, 360 - span / 2) }
        let mid = Double(i) * span
        return (mid - span / 2, mid + span / 2)
    }

    static func point(_ r: CGFloat, _ deg: Double, from c: CGPoint = center) -> CGPoint {
        let a = deg * .pi / 180
        return CGPoint(x: c.x + r * CGFloat(sin(a)), y: c.y - r * CGFloat(cos(a)))
    }

    static func labelPoint(_ i: Int, _ n: Int, lifted: Bool) -> CGPoint {
        let (a0, a1) = angles(i, n)
        return point((rIn + rOut) / 2 + (lifted ? lift + 2 : 0), (a0 + a1) / 2)
    }

    enum Hit: Equatable { case none, hub, petal(Int), chip(Mode) }

    static func hit(_ p: CGPoint, count n: Int) -> Hit {
        for m in Mode.allCases where chipRect(m).insetBy(dx: 0, dy: -5).contains(p) { return .chip(m) }
        let dx = Double(p.x - center.x), dy = Double(p.y - center.y)
        let d = hypot(dx, dy)
        if d <= Double(rHub) + 3 { return .hub }
        guard n > 0, d <= Double(rOut) + 30 else { return .none }
        var a = atan2(dx, -dy) * 180 / .pi
        if a < 0 { a += 360 }
        let span = 360 / Double(n)
        return .petal(Int((a + span / 2) / span) % n)
    }
}

/// A ring sector with rounded corners and a constant-width gap to its neighbours.
/// Built as the Minkowski sum of a smaller sharp sector and a disc (fill ∪ round-joined stroke).
struct PetalShape: Shape {
    var a0: Double
    var a1: Double
    var lift: Double

    var animatableData: AnimatablePair<AnimatablePair<Double, Double>, Double> {
        get { AnimatablePair(AnimatablePair(a0, a1), lift) }
        set { a0 = newValue.first.first; a1 = newValue.first.second; lift = newValue.second }
    }

    func path(in rect: CGRect) -> Path {
        guard a1 - a0 > 0.5 else { return Path() }
        let mid = (a0 + a1) / 2
        let c = Geo.point(Geo.lift * lift, mid)            // the whole petal slides outward
        let r = Geo.corner
        let rIn = Geo.rIn + r
        let rOut = Geo.rOut + 4 * lift - r
        let d = Geo.gap / 2 + r                             // side edges sit this far off the radial line
        let dIn = asin(min(1, Double(d / rIn))) * 180 / .pi
        let dOut = asin(min(1, Double(d / rOut))) * 180 / .pi
        let o0 = a0 + dOut, o1 = a1 - dOut, i0 = a0 + dIn, i1 = a1 - dIn
        guard o1 > o0 + 0.1, i1 > i0 + 0.1 else { return Path() }

        var pts: [CGPoint] = []
        let no = max(3, Int((o1 - o0) / 2))
        for k in 0...no { pts.append(Geo.point(rOut, o0 + (o1 - o0) * Double(k) / Double(no), from: c)) }
        let ni = max(2, Int((i1 - i0) / 3))
        for k in 0...ni { pts.append(Geo.point(rIn, i1 - (i1 - i0) * Double(k) / Double(ni), from: c)) }
        var core = Path()
        core.addLines(pts)
        core.closeSubpath()
        return core.union(core.strokedPath(StrokeStyle(lineWidth: 2 * r, lineCap: .round, lineJoin: .round)))
    }
}

struct HubShape: Shape {
    func path(in rect: CGRect) -> Path {
        Path(ellipseIn: CGRect(x: Geo.center.x - Geo.rHub, y: Geo.center.y - Geo.rHub,
                               width: Geo.rHub * 2, height: Geo.rHub * 2))
    }
}

/// The black accent.
enum Ink {
    static let fill = LinearGradient(colors: [Color(white: 0.2), Color(white: 0.02)], startPoint: .top, endPoint: .bottom)
    static let rim = Color.white.opacity(0.16)
    /// Lit from the hub outward, like a polished black lens.
    static let petal = RadialGradient(colors: [Color(white: 0.2).opacity(0.94), Color(white: 0.03).opacity(0.96)],
                                      center: UnitPoint(x: Geo.center.x / Geo.size.width, y: Geo.center.y / Geo.size.height),
                                      startRadius: Geo.rIn, endRadius: Geo.rOut + 8)
    static let rimGradient = LinearGradient(colors: [.white.opacity(0.55), .white.opacity(0.1)], startPoint: .top, endPoint: .bottom)
}
