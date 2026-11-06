import AppKit
import CoreGraphics

/// Whole-image operations behind the Image menu. Pure functions on `CGImage`; geometry follows the
/// editor convention of pixels with the origin at the top-left.
enum ImageOps {
    private static func context(_ width: Int, _ height: Int, like image: CGImage) -> CGContext? {
        guard width > 0, height > 0 else { return nil }
        let ctx = Renderer.makeContext(width: width, height: height, colorSpace: ImageFilters.rgbColorSpace(for: image))
        ctx?.interpolationQuality = .high
        return ctx
    }

    static func crop(_ image: CGImage, to rect: CGRect) -> CGImage? {
        let bounds = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        let clipped = rect.integral.intersection(bounds)
        guard !clipped.isNull, clipped.width >= 1, clipped.height >= 1 else { return nil }
        // Redraw instead of `cropping(to:)` so the result does not keep the whole original alive.
        guard let ctx = context(Int(clipped.width), Int(clipped.height), like: image),
              let cropped = image.cropping(to: clipped) else { return nil }
        ctx.draw(cropped, in: CGRect(x: 0, y: 0, width: clipped.width, height: clipped.height))
        return ctx.makeImage()
    }

    static func rotate(_ image: CGImage, clockwise: Bool) -> CGImage? {
        let w = image.width, h = image.height
        guard let ctx = context(h, w, like: image) else { return nil }
        if clockwise {
            ctx.translateBy(x: 0, y: CGFloat(w))
            ctx.rotate(by: -.pi / 2)
        } else {
            ctx.translateBy(x: CGFloat(h), y: 0)
            ctx.rotate(by: .pi / 2)
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    static func flip(_ image: CGImage, horizontal: Bool) -> CGImage? {
        let w = image.width, h = image.height
        guard let ctx = context(w, h, like: image) else { return nil }
        if horizontal {
            ctx.translateBy(x: CGFloat(w), y: 0); ctx.scaleBy(x: -1, y: 1)
        } else {
            ctx.translateBy(x: 0, y: CGFloat(h)); ctx.scaleBy(x: 1, y: -1)
        }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    static func resize(_ image: CGImage, to size: CGSize) -> CGImage? {
        let w = max(1, Int(size.width.rounded())), h = max(1, Int(size.height.rounded()))
        guard let ctx = context(w, h, like: image) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// Adds a margin on each side, filled with `color` (use a clear colour for transparency).
    static func extendCanvas(_ image: CGImage, top: Int, left: Int, bottom: Int, right: Int, color: RGBAColor) -> CGImage? {
        let w = image.width + left + right, h = image.height + top + bottom
        guard let ctx = context(w, h, like: image) else { return nil }
        if color.isVisible {
            ctx.setFillColor(color.cgColor)
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        }
        // CG's origin is bottom-left, so the "bottom" margin is the y offset.
        ctx.draw(image, in: CGRect(x: left, y: bottom, width: image.width, height: image.height))
        return ctx.makeImage()
    }

    /// Smallest rectangle that drops the uniform border around the content, judged by the colour
    /// of the top-left pixel. Returns nil when the image is a single colour.
    static func autoCropRect(_ image: CGImage, tolerance: Int = 8) -> CGRect? {
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: ImageFilters.rgbColorSpace(for: image),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let raw = ctx.data else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let rowBytes = ctx.bytesPerRow
        let px = raw.bindMemory(to: UInt8.self, capacity: rowBytes * h)
        let ref = (Int(px[0]), Int(px[1]), Int(px[2]), Int(px[3]))

        func differs(_ x: Int, _ y: Int) -> Bool {
            let p = y * rowBytes + x * 4
            return abs(Int(px[p]) - ref.0) > tolerance || abs(Int(px[p + 1]) - ref.1) > tolerance
                || abs(Int(px[p + 2]) - ref.2) > tolerance || abs(Int(px[p + 3]) - ref.3) > tolerance
        }
        func rowHasContent(_ y: Int) -> Bool { (0..<w).contains { differs($0, y) } }
        func columnHasContent(_ x: Int, _ y0: Int, _ y1: Int) -> Bool { (y0...y1).contains { differs(x, $0) } }

        guard let top = (0..<h).first(where: rowHasContent),
              let bottom = (0..<h).reversed().first(where: rowHasContent),
              let left = (0..<w).first(where: { columnHasContent($0, top, bottom) }),
              let right = (0..<w).reversed().first(where: { columnHasContent($0, top, bottom) }) else { return nil }
        return CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1)
    }

    /// The smallest rectangle (pixels, top-left origin) holding every pixel whose alpha is at least `minAlpha`; nil if there is none.
    static func visibleBounds(of image: CGImage, minAlpha: UInt8 = 4) -> CGRect? {
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: ImageFilters.rgbColorSpace(for: image),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let raw = ctx.data else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let rowBytes = ctx.bytesPerRow
        let px = raw.bindMemory(to: UInt8.self, capacity: rowBytes * h)
        var minX = w, minY = h, maxX = -1, maxY = -1
        for y in 0..<h {
            let row = y * rowBytes
            for x in 0..<w where px[row + x * 4 + 3] >= minAlpha {
                if x < minX { minX = x }
                if x > maxX { maxX = x }
                if y < minY { minY = y }
                if y > maxY { maxY = y }
            }
        }
        return maxX < 0 ? nil : CGRect(x: minX, y: minY, width: maxX - minX + 1, height: maxY - minY + 1)
    }

    /// Cuts away the transparent border around a picture, keeping any faint shadow that is still visible.
    static func trimmingTransparentEdges(_ image: CGImage, minAlpha: UInt8 = 4) -> CGImage {
        guard let bounds = visibleBounds(of: image, minAlpha: minAlpha),
              bounds.size != CGSize(width: image.width, height: image.height) else { return image }
        return crop(image, to: bounds) ?? image
    }

    /// Composites over a solid colour. Needed before writing formats without an alpha channel,
    /// which would otherwise turn transparent areas black.
    static func flatten(_ image: CGImage, on color: RGBAColor = .white) -> CGImage? {
        guard let ctx = context(image.width, image.height, like: image) else { return nil }
        ctx.setFillColor(color.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage()
    }

    static func hasAlpha(_ image: CGImage) -> Bool {
        switch image.alphaInfo {
        case .none, .noneSkipFirst, .noneSkipLast: return false
        default: return true
        }
    }

    // MARK: - Effects

    struct EffectResult {
        var image: CGImage
        /// How far the original's top-left corner moved, so annotations can follow.
        var shift: CGPoint
    }

    static func border(_ image: CGImage, width: Int, color: RGBAColor) -> EffectResult? {
        guard let out = extendCanvas(image, top: width, left: width, bottom: width, right: width, color: color) else { return nil }
        return EffectResult(image: out, shift: CGPoint(x: width, y: width))
    }

    static func dropShadow(_ image: CGImage, offset: CGSize, blur: CGFloat, color: RGBAColor) -> EffectResult? {
        let margin = Int(ceil(blur * 1.6)) + 1
        let left = max(0, margin - Int(offset.width)), right = margin + max(0, Int(offset.width))
        let top = max(0, margin - Int(offset.height)), bottom = margin + max(0, Int(offset.height))
        let w = image.width + left + right, h = image.height + top + bottom
        guard let ctx = context(w, h, like: image) else { return nil }
        // Shadow offsets live in base space (y up), hence the negated height.
        ctx.setShadow(offset: CGSize(width: offset.width, height: -offset.height), blur: blur, color: color.cgColor)
        ctx.draw(image, in: CGRect(x: left, y: bottom, width: image.width, height: image.height))
        guard let out = ctx.makeImage() else { return nil }
        return EffectResult(image: out, shift: CGPoint(x: left, y: top))
    }

    struct TornEdgeOptions {
        var toothHeight: CGFloat = 8
        var horizontalToothRange: CGFloat = 12
        var top = true, right = true, bottom = true, left = true
        var shadow = true
    }

    static func tornEdge(_ image: CGImage, options: TornEdgeOptions, using generator: inout some RandomNumberGenerator) -> EffectResult? {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let tooth = max(1, options.toothHeight)
        let range = max(2, options.horizontalToothRange)
        let shadowBlur: CGFloat = options.shadow ? 6 : 0
        let margin = Int(ceil(tooth + shadowBlur * 1.6)) + 1
        let canvasW = image.width + margin * 2, canvasH = image.height + margin * 2
        guard let ctx = context(canvasW, canvasH, like: image) else { return nil }

        // Points are in top-left space inside the image, shifted by `margin` into the canvas.
        func jagged(from a: CGPoint, to b: CGPoint, torn: Bool, inward: CGPoint) -> [CGPoint] {
            guard torn else { return [b] }
            let length = a.distance(to: b)
            var result: [CGPoint] = []
            var travelled: CGFloat = 0
            let ux = (b.x - a.x) / length, uy = (b.y - a.y) / length
            while travelled < length {
                travelled = min(length, travelled + CGFloat.random(in: range * 0.4...range, using: &generator))
                let depth = travelled >= length ? 0 : CGFloat.random(in: 0...tooth, using: &generator)
                result.append(CGPoint(x: a.x + ux * travelled + inward.x * depth, y: a.y + uy * travelled + inward.y * depth))
            }
            return result
        }

        let corners = [CGPoint(x: 0, y: 0), CGPoint(x: w, y: 0), CGPoint(x: w, y: h), CGPoint(x: 0, y: h)]
        var outline: [CGPoint] = [corners[0]]
        outline += jagged(from: corners[0], to: corners[1], torn: options.top, inward: CGPoint(x: 0, y: 1))
        outline += jagged(from: corners[1], to: corners[2], torn: options.right, inward: CGPoint(x: -1, y: 0))
        outline += jagged(from: corners[2], to: corners[3], torn: options.bottom, inward: CGPoint(x: 0, y: -1))
        outline += jagged(from: corners[3], to: corners[0], torn: options.left, inward: CGPoint(x: 1, y: 0))

        let path = CGMutablePath()
        let m = CGFloat(margin)
        // Convert from top-left to CG's bottom-left space.
        func cg(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x + m, y: CGFloat(canvasH) - (p.y + m)) }
        path.move(to: cg(outline[0]))
        for p in outline.dropFirst() { path.addLine(to: cg(p)) }
        path.closeSubpath()

        ctx.saveGState()
        if options.shadow {
            ctx.setShadow(offset: CGSize(width: 2, height: -3), blur: shadowBlur, color: NSColor.black.withAlphaComponent(0.55).cgColor)
        }
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.addPath(path)
        ctx.clip()
        ctx.draw(image, in: CGRect(x: margin, y: margin, width: image.width, height: image.height))
        ctx.endTransparencyLayer()
        ctx.restoreGState()
        guard let out = ctx.makeImage() else { return nil }
        return EffectResult(image: out, shift: CGPoint(x: margin, y: margin))
    }
}

// MARK: - Moving annotations along with image operations

extension Annotation {
    /// Applies a point mapping to every coordinate of the annotation.
    mutating func mapGeometry(_ f: (CGPoint) -> CGPoint) {
        if kind != .line && kind != .arrow && kind != .freehand {
            rect = CGRect(from: f(CGPoint(x: rect.minX, y: rect.minY)), to: f(CGPoint(x: rect.maxX, y: rect.maxY)))
        }
        start = f(start)
        end = f(end)
        tail = f(tail)
        points = points.map(f)
    }
}
