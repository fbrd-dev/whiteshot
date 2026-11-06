import CoreGraphics

extension CGRect {
    /// Rectangle spanning two arbitrary corner points, normalised to positive size.
    init(from a: CGPoint, to b: CGPoint) {
        self.init(x: min(a.x, b.x), y: min(a.y, b.y), width: abs(a.x - b.x), height: abs(a.y - b.y))
    }

    var center: CGPoint { CGPoint(x: midX, y: midY) }

    /// Same rectangle, but never extending outside `bounds`.
    func clamped(to bounds: CGRect) -> CGRect { intersection(bounds) }
}

extension CGPoint {
    func distance(to other: CGPoint) -> CGFloat { hypot(x - other.x, y - other.y) }

    func offset(dx: CGFloat, dy: CGFloat) -> CGPoint { CGPoint(x: x + dx, y: y + dy) }

    static func - (lhs: CGPoint, rhs: CGPoint) -> CGPoint { CGPoint(x: lhs.x - rhs.x, y: lhs.y - rhs.y) }
    static func + (lhs: CGPoint, rhs: CGPoint) -> CGPoint { CGPoint(x: lhs.x + rhs.x, y: lhs.y + rhs.y) }
}

/// Shortest distance from `p` to the segment `a`-`b`.
func distance(from p: CGPoint, toSegment a: CGPoint, _ b: CGPoint) -> CGFloat {
    let dx = b.x - a.x, dy = b.y - a.y
    let lengthSquared = dx * dx + dy * dy
    guard lengthSquared > 0 else { return p.distance(to: a) }
    let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / lengthSquared))
    return p.distance(to: CGPoint(x: a.x + t * dx, y: a.y + t * dy))
}

/// Snaps `point` to the nearest multiple of 45° around `origin` (used for Shift-drawing lines).
func snapAngle(of point: CGPoint, around origin: CGPoint) -> CGPoint {
    let dx = point.x - origin.x, dy = point.y - origin.y
    let length = hypot(dx, dy)
    guard length > 0 else { return point }
    let step = CGFloat.pi / 4
    let angle = (atan2(dy, dx) / step).rounded() * step
    return CGPoint(x: origin.x + cos(angle) * length, y: origin.y + sin(angle) * length)
}
