import AppKit
import ImageIO
import UniformTypeIdentifiers

enum AnnotationKind: String, Codable, CaseIterable {
    case rectangle, ellipse, line, arrow, freehand, text, bubble, step, obfuscate, highlight, image
}

/// A raster image placed on the canvas (pasted from the clipboard or inserted from a file).
/// Immutable and shared between copies of an annotation, so undo snapshots stay cheap.
final class EmbeddedImage: Codable, Equatable {
    let data: Data
    private var decoded: CGImage?

    init(data: Data) { self.data = data }

    convenience init?(cgImage: CGImage) {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, cgImage, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        self.init(data: output as Data)
    }

    var cgImage: CGImage? {
        if let decoded { return decoded }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        decoded = CGImageSourceCreateImageAtIndex(source, 0, nil)
        return decoded
    }

    required init(from decoder: Decoder) throws {
        data = try decoder.singleValueContainer().decode(Data.self)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(data)
    }

    static func == (lhs: EmbeddedImage, rhs: EmbeddedImage) -> Bool { lhs === rhs || lhs.data == rhs.data }
}

enum Handle: Hashable {
    case topLeft, top, topRight, right, bottomRight, bottom, bottomLeft, left
    case start, end, tail
}

/// One drawn object. A value type on purpose: undo snapshots are plain array copies and the whole
/// thing is trivially `Codable` for project files and copy/paste.
struct Annotation: Identifiable, Codable, Equatable {
    var id = UUID()
    var kind: AnnotationKind
    /// Creation order. Step labels derive their number from it.
    var serial = 0
    /// Box for every kind except line, arrow and freehand, which are defined by their points.
    var rect: CGRect = .zero
    var start: CGPoint = .zero
    var end: CGPoint = .zero
    var points: [CGPoint] = []
    var tail: CGPoint = .zero
    var text = ""
    var style: Style
    var image: EmbeddedImage?

    // MARK: - Geometry

    var bounds: CGRect {
        switch kind {
        case .line, .arrow:
            return CGRect(from: start, to: end)
        case .freehand:
            guard let first = points.first else { return .zero }
            var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
            for p in points {
                minX = min(minX, p.x); maxX = max(maxX, p.x)
                minY = min(minY, p.y); maxY = max(maxY, p.y)
            }
            return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        case .bubble:
            return rect.union(CGRect(x: tail.x, y: tail.y, width: 0, height: 0))
        default:
            return rect
        }
    }

    var isLinear: Bool { kind == .line || kind == .arrow }
    var hasText: Bool { kind == .text || kind == .bubble }

    /// False for a click that produced no usable shape (a stray tap with a drawing tool).
    var isMeaningful: Bool {
        switch kind {
        case .line, .arrow: return start.distance(to: end) >= 3
        case .freehand: return points.count >= 2 && (bounds.width >= 2 || bounds.height >= 2)
        case .text, .step, .image: return true
        default: return rect.width >= 3 && rect.height >= 3
        }
    }

    // MARK: - Handles

    func handles() -> [(Handle, CGPoint)] {
        if isLinear { return [(.start, start), (.end, end)] }
        let r = bounds
        let corners: [(Handle, CGPoint)] = [
            (.topLeft, CGPoint(x: r.minX, y: r.minY)),
            (.topRight, CGPoint(x: r.maxX, y: r.minY)),
            (.bottomRight, CGPoint(x: r.maxX, y: r.maxY)),
            (.bottomLeft, CGPoint(x: r.minX, y: r.maxY)),
        ]
        if kind == .step { return corners }
        let edges: [(Handle, CGPoint)] = [
            (.top, CGPoint(x: r.midX, y: r.minY)),
            (.right, CGPoint(x: r.maxX, y: r.midY)),
            (.bottom, CGPoint(x: r.midX, y: r.maxY)),
            (.left, CGPoint(x: r.minX, y: r.midY)),
        ]
        var all = corners + edges
        if kind == .bubble {
            // The bubble's box handles belong to `rect`, the tail has its own.
            all = [
                (.topLeft, CGPoint(x: rect.minX, y: rect.minY)),
                (.topRight, CGPoint(x: rect.maxX, y: rect.minY)),
                (.bottomRight, CGPoint(x: rect.maxX, y: rect.maxY)),
                (.bottomLeft, CGPoint(x: rect.minX, y: rect.maxY)),
                (.top, CGPoint(x: rect.midX, y: rect.minY)),
                (.right, CGPoint(x: rect.maxX, y: rect.midY)),
                (.bottom, CGPoint(x: rect.midX, y: rect.maxY)),
                (.left, CGPoint(x: rect.minX, y: rect.midY)),
                (.tail, tail),
            ]
        }
        return all
    }

    func handle(at point: CGPoint, tolerance: CGFloat) -> Handle? {
        // Later handles win ties, which keeps the tail grabbable when it sits on a corner.
        for (handle, location) in handles().reversed() where location.distance(to: point) <= tolerance {
            return handle
        }
        return nil
    }

    // MARK: - Hit testing

    func hitTest(_ p: CGPoint, tolerance t: CGFloat) -> Bool {
        let w = style.lineWidth / 2 + t
        switch kind {
        case .rectangle:
            if style.fillColor.isVisible { return rect.insetBy(dx: -t, dy: -t).contains(p) }
            return rect.insetBy(dx: -w, dy: -w).contains(p) && !rect.insetBy(dx: w, dy: w).contains(p)
        case .ellipse:
            let a = rect.width / 2, b = rect.height / 2
            guard a > 0, b > 0 else { return false }
            let nx = (p.x - rect.midX) / a, ny = (p.y - rect.midY) / b
            let d = hypot(nx, ny)
            let band = w / min(a, b)
            return style.fillColor.isVisible ? d <= 1 + band : abs(d - 1) <= band
        case .line, .arrow:
            return distance(from: p, toSegment: start, end) <= w + 2
        case .freehand:
            guard points.count > 1 else { return points.first.map { $0.distance(to: p) <= w } ?? false }
            for i in 1..<points.count where distance(from: p, toSegment: points[i - 1], points[i]) <= w + 2 { return true }
            return false
        case .bubble:
            return rect.insetBy(dx: -t, dy: -t).contains(p) || tail.distance(to: p) <= t + 6
        default:
            return rect.insetBy(dx: -t, dy: -t).contains(p)
        }
    }

    // MARK: - Mutation

    mutating func move(by d: CGPoint) {
        rect = rect.offsetBy(dx: d.x, dy: d.y)
        start = start + d
        end = end + d
        tail = tail + d
        if !points.isEmpty { points = points.map { $0 + d } }
    }

    /// Returns a copy of `self` with `handle` dragged to `p`. Always computed from the original
    /// geometry, so crossing over the opposite edge flips the shape instead of corrupting it.
    func resized(handle: Handle, to p: CGPoint, keepAspect: Bool = false) -> Annotation {
        var a = self
        switch handle {
        case .start:
            a.start = p
            if keepAspect { a.start = snapAngle(of: p, around: end) }
        case .end:
            a.end = p
            if keepAspect { a.end = snapAngle(of: p, around: start) }
        case .tail:
            a.tail = p
        default:
            let oldBounds = bounds
            var minX = oldBounds.minX, maxX = oldBounds.maxX, minY = oldBounds.minY, maxY = oldBounds.maxY
            if kind == .bubble { minX = rect.minX; maxX = rect.maxX; minY = rect.minY; maxY = rect.maxY }
            switch handle {
            case .topLeft: minX = p.x; minY = p.y
            case .top: minY = p.y
            case .topRight: maxX = p.x; minY = p.y
            case .right: maxX = p.x
            case .bottomRight: maxX = p.x; maxY = p.y
            case .bottom: maxY = p.y
            case .bottomLeft: minX = p.x; maxY = p.y
            case .left: minX = p.x
            default: break
            }
            var newRect = CGRect(from: CGPoint(x: minX, y: minY), to: CGPoint(x: maxX, y: maxY))
            if kind == .step || keepAspect {
                newRect = Self.squared(newRect, anchoredBy: handle, original: kind == .bubble ? rect : oldBounds, keepOriginalAspect: kind != .step)
            }
            if kind == .freehand {
                a.points = Self.map(points, from: oldBounds, to: newRect)
            } else {
                a.rect = newRect
            }
        }
        return a
    }

    /// Forces a resized rectangle to keep an aspect ratio (a square for step labels).
    private static func squared(_ r: CGRect, anchoredBy handle: Handle, original: CGRect, keepOriginalAspect: Bool) -> CGRect {
        let ratio = keepOriginalAspect && original.height > 0 ? original.width / original.height : 1
        var width = r.width, height = r.height
        if width / ratio > height { height = width / ratio } else { width = height * ratio }
        // Pin the corner opposite to the dragged handle.
        let x: CGFloat, y: CGFloat
        switch handle {
        case .topLeft: x = original.maxX - width; y = original.maxY - height
        case .topRight: x = original.minX; y = original.maxY - height
        case .bottomLeft: x = original.maxX - width; y = original.minY
        default: x = original.minX; y = original.minY
        }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    private static func map(_ points: [CGPoint], from old: CGRect, to new: CGRect) -> [CGPoint] {
        let ow = max(old.width, 0.0001), oh = max(old.height, 0.0001)
        return points.map { p in
            CGPoint(x: new.minX + (p.x - old.minX) / ow * new.width,
                    y: new.minY + (p.y - old.minY) / oh * new.height)
        }
    }

    /// Updates a shape that is being drawn with the mouse, from the press point to the current point.
    mutating func updateWhileCreating(from origin: CGPoint, to p: CGPoint, constrain: Bool, fromCenter: Bool) {
        switch kind {
        case .line, .arrow:
            start = origin
            end = constrain ? snapAngle(of: p, around: origin) : p
        case .freehand:
            if let last = points.last, last.distance(to: p) < 1.5 { return }
            points.append(p)
        default:
            var dx = p.x - origin.x, dy = p.y - origin.y
            if constrain {
                let side = max(abs(dx), abs(dy))
                dx = dx < 0 ? -side : side
                dy = dy < 0 ? -side : side
            }
            if fromCenter {
                rect = CGRect(x: origin.x - abs(dx), y: origin.y - abs(dy), width: abs(dx) * 2, height: abs(dy) * 2)
            } else {
                rect = CGRect(from: origin, to: CGPoint(x: origin.x + dx, y: origin.y + dy))
            }
            if kind == .bubble {
                tail = CGPoint(x: rect.minX + rect.width * 0.28, y: rect.maxY + max(rect.height * 0.4, 12))
            }
        }
    }

    func offset(by d: CGPoint) -> Annotation {
        var copy = self
        copy.move(by: d)
        return copy
    }
}
