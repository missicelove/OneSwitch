import CoreGraphics
import Foundation

/// The arrangement of one Mac's displays in global display coordinates (top-left origin, y grows
/// downward — the space of CGEvent.location and CGDisplayBounds). Pure value type, fully testable.
public struct ScreenGeometry: Equatable, Sendable {
    /// Display bounds; the main display (origin 0,0) first when present.
    public var displays: [CGRect]

    public init(displays: [CGRect]) {
        // Drop degenerate rects and duplicates (software-mirrored displays report identical bounds).
        var unique: [CGRect] = []
        for d in displays where d.width >= 1 && d.height >= 1
            && d.minX.isFinite && d.minY.isFinite && d.width.isFinite && d.height.isFinite && !unique.contains(d) {
            unique.append(d)
        }
        // Strict weak ordering (the old comparator returned true for both (a, b) and (b, a) when two rects
        // sat at the origin): main display (origin 0,0) first, then by position.
        self.displays = unique.sorted { a, b in
            let az = a.origin == .zero, bz = b.origin == .zero
            if az != bz { return az }
            return (a.minX, a.minY, a.width, a.height) < (b.minX, b.minY, b.width, b.height)
        }
    }

    public var isEmpty: Bool { displays.isEmpty }

    public var union: CGRect {
        displays.dropFirst().reduce(displays.first ?? .zero) { $0.union($1) }
    }

    public var mainDisplay: CGRect { displays.first ?? .zero }

    public var mainCenter: CGPoint { CGPoint(x: mainDisplay.midX.rounded(), y: mainDisplay.midY.rounded()) }

    /// The display containing `p` (half-open bounds).
    public func display(containing p: CGPoint) -> CGRect? {
        displays.first { p.x >= $0.minX && p.x < $0.maxX && p.y >= $0.minY && p.y < $0.maxY }
    }

    /// The closest point that lies on some display (cursor positions are clamped to maxX-1 / maxY-1).
    public func nearestPoint(to p: CGPoint) -> CGPoint {
        guard !displays.isEmpty else { return p }
        var best = p
        var bestDistance = Double.infinity
        for d in displays {
            let c = CGPoint(x: min(max(p.x, d.minX), d.maxX - 1), y: min(max(p.y, d.minY), d.maxY - 1))
            let dist = Double((c.x - p.x) * (c.x - p.x) + (c.y - p.y) * (c.y - p.y))
            if dist < bestDistance {
                bestDistance = dist
                best = c
            }
        }
        return best
    }

    /// True if at `p` (a point on a display) the given side of its display borders no other display,
    /// i.e. the cursor cannot continue past that edge locally.
    public func isOuterEdge(_ side: ScreenSide, at point: CGPoint) -> Bool {
        let p = nearestPoint(to: point)
        guard let d = display(containing: p) else { return false }
        for e in displays where e != d {
            switch side {
            case .right:
                if e.minX >= d.maxX - 1 && e.minY <= p.y && p.y < e.maxY { return false }
            case .left:
                if e.maxX <= d.minX + 1 && e.minY <= p.y && p.y < e.maxY { return false }
            case .top:
                if e.maxY <= d.minY + 1 && e.minX <= p.x && p.x < e.maxX { return false }
            case .bottom:
                if e.minY >= d.maxY - 1 && e.minX <= p.x && p.x < e.maxX { return false }
            }
        }
        return true
    }

    /// True when a cursor at `location` moving by (dx, dy) presses against the outer `side` edge.
    public func isPushing(_ side: ScreenSide, at location: CGPoint, dx: Double, dy: Double) -> Bool {
        let p = nearestPoint(to: location)
        guard let d = display(containing: p) else { return false }
        let atEdge: Bool
        switch side {
        case .right: atEdge = dx > 0 && p.x >= d.maxX - 1.5
        case .left: atEdge = dx < 0 && p.x <= d.minX + 0.5
        case .top: atEdge = dy < 0 && p.y <= d.minY + 0.5
        case .bottom: atEdge = dy > 0 && p.y >= d.maxY - 1.5
        }
        return atEdge && isOuterEdge(side, at: p)
    }

    /// Position along an edge as a fraction 0…1 of the whole desktop (y for left/right, x for top/bottom).
    public func fraction(along side: ScreenSide, at point: CGPoint) -> Double {
        let u = union
        let f: Double
        if side.isVerticalEdge {
            f = u.height > 1 ? Double((point.y - u.minY) / (u.height - 1)) : 0.5
        } else {
            f = u.width > 1 ? Double((point.x - u.minX) / (u.width - 1)) : 0.5
        }
        return min(max(f, 0), 1)
    }

    /// The point just inside the outer `side` edge at `fraction` along it — where a cursor arriving
    /// from the other Mac should appear.
    /// How far inside the edge an arriving cursor is placed. Right at the edge it lands in the resize zone
    /// of a window touching the screen edge and briefly turns into a ↔ cursor (felt as a hitch).
    public static let entryInset: CGFloat = 8

    public func entryPoint(on side: ScreenSide, fraction: Double) -> CGPoint {
        guard let first = displays.first else { return .zero }
        // A non-finite fraction used to propagate NaN into the lookups below and crash on a force unwrap.
        let f = fraction.isFinite ? min(max(fraction, 0), 1) : 0.5
        let u = union
        if side.isVerticalEdge {
            var y = (u.minY + CGFloat(f) * max(u.height - 1, 0)).rounded()
            var candidates = displays.filter { $0.minY <= y && y < $0.maxY }
            if candidates.isEmpty {
                let nearest = displays.min { distance($0.minY, $0.maxY - 1, y) < distance($1.minY, $1.maxY - 1, y) } ?? first
                y = min(max(y, nearest.minY), nearest.maxY - 1)
                candidates = displays.filter { $0.minY <= y && y < $0.maxY }
                if candidates.isEmpty { candidates = [nearest] }
            }
            if side == .left {
                let d = candidates.min { $0.minX < $1.minX } ?? first
                return CGPoint(x: d.minX + min(Self.entryInset, d.width / 4), y: y)
            } else {
                let d = candidates.max { $0.maxX < $1.maxX } ?? first
                return CGPoint(x: d.maxX - 1 - min(Self.entryInset, d.width / 4), y: y)
            }
        } else {
            var x = (u.minX + CGFloat(f) * max(u.width - 1, 0)).rounded()
            var candidates = displays.filter { $0.minX <= x && x < $0.maxX }
            if candidates.isEmpty {
                let nearest = displays.min { distance($0.minX, $0.maxX - 1, x) < distance($1.minX, $1.maxX - 1, x) } ?? first
                x = min(max(x, nearest.minX), nearest.maxX - 1)
                candidates = displays.filter { $0.minX <= x && x < $0.maxX }
                if candidates.isEmpty { candidates = [nearest] }
            }
            if side == .top {
                let d = candidates.min { $0.minY < $1.minY } ?? first
                return CGPoint(x: x, y: d.minY + min(Self.entryInset, d.height / 4))
            } else {
                let d = candidates.max { $0.maxY < $1.maxY } ?? first
                return CGPoint(x: x, y: d.maxY - 1 - min(Self.entryInset, d.height / 4))
            }
        }
    }

    /// True when `target` lies beyond `clamped` in the direction of `side` (the cursor wants to leave).
    public static func isBeyond(_ side: ScreenSide, target: CGPoint, clamped: CGPoint) -> Bool {
        switch side {
        case .left: return target.x < clamped.x - 0.5
        case .right: return target.x > clamped.x + 0.5
        case .top: return target.y < clamped.y - 0.5
        case .bottom: return target.y > clamped.y + 0.5
        }
    }

    private func distance(_ lo: CGFloat, _ hi: CGFloat, _ v: CGFloat) -> CGFloat {
        if v < lo { return lo - v }
        if v > hi { return v - hi }
        return 0
    }
}
