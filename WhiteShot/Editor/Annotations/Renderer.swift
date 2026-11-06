import AppKit

/// Text measuring and drawing shared by text boxes, speech bubbles and step labels.
enum TextLayout {
    static func padding(for style: Style) -> CGFloat { max(2, style.fontSize * 0.25) }

    static func attributed(_ text: String, style: Style) -> NSAttributedString {
        NSAttributedString(string: text, attributes: style.textAttributes())
    }

    /// Height the text needs inside a box that is `width` wide, padding included.
    static func requiredHeight(for text: String, style: Style, width: CGFloat) -> CGFloat {
        let pad = padding(for: style)
        let sample = text.isEmpty ? "Ag" : text
        let size = attributed(sample, style: style).boundingRect(
            with: CGSize(width: max(1, width - pad * 2), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading])
        return ceil(size.height) + pad * 2
    }

    /// Draws into a context whose y axis already points down.
    static func draw(_ text: String, in rect: CGRect, style: Style, context ctx: CGContext) {
        guard !text.isEmpty else { return }
        let pad = padding(for: style)
        let inner = rect.insetBy(dx: pad, dy: pad)
        guard inner.width > 1, inner.height > 1 else { return }
        let string = attributed(text, style: style)
        let options: NSString.DrawingOptions = [.usesLineFragmentOrigin, .usesFontLeading]
        let needed = ceil(string.boundingRect(with: CGSize(width: inner.width, height: .greatestFiniteMagnitude), options: options).height)
        var y = inner.minY
        switch style.verticalAlign {
        case .top: break
        case .middle: y += (inner.height - needed) / 2
        case .bottom: y += inner.height - needed
        }
        ctx.saveGState()
        ctx.clip(to: rect)
        let graphics = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        string.draw(with: CGRect(x: inner.minX, y: y, width: inner.width, height: needed), options: options)
        NSGraphicsContext.restoreGraphicsState()
        ctx.restoreGState()
    }
}

/// Flattens a base image and its annotations into a single bitmap. This is the single source of
/// truth for what the canvas shows and what gets exported, so the two can never disagree.
enum Renderer {
    struct Options {
        /// Capture scale (2 on Retina). Only used for scale-dependent decoration such as shadows.
        var scale: CGFloat = 1
        /// An annotation whose text is currently being edited in a live text view; skip its text.
        var hiddenTextID: UUID?
    }

    static func makeContext(width: Int, height: Int, colorSpace: CGColorSpace) -> CGContext? {
        CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                  bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
    }

    static func render(base: CGImage, annotations: [Annotation], options: Options = Options()) -> CGImage? {
        let w = base.width, h = base.height
        guard let ctx = makeContext(width: w, height: h, colorSpace: ImageFilters.rgbColorSpace(for: base)) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(base, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard !annotations.isEmpty else { return ctx.makeImage() }

        // From here on the y axis points down, matching the editor's coordinate system.
        ctx.translateBy(x: 0, y: CGFloat(h))
        ctx.scaleBy(x: 1, y: -1)
        let numbers = stepNumbers(annotations)
        for annotation in annotations {
            draw(annotation, in: ctx, imageSize: CGSize(width: w, height: h), stepNumber: numbers[annotation.id], options: options)
        }
        return ctx.makeImage()
    }

    /// Step labels are numbered by creation order, so deleting one renumbers the rest.
    static func stepNumbers(_ annotations: [Annotation]) -> [UUID: Int] {
        var result: [UUID: Int] = [:]
        let steps = annotations.filter { $0.kind == .step }.sorted { $0.serial < $1.serial }
        for (index, step) in steps.enumerated() { result[step.id] = step.style.stepStart + index }
        return result
    }

    // MARK: - Drawing

    private static func draw(_ a: Annotation, in ctx: CGContext, imageSize: CGSize, stepNumber: Int?, options: Options) {
        let style = a.style
        switch a.kind {
        case .rectangle:
            withShadow(style, options, ctx) {
                if style.fillColor.isVisible { ctx.setFillColor(style.fillColor.cgColor); ctx.fill(a.rect) }
                if style.strokeColor.isVisible, style.lineWidth > 0 {
                    ctx.setStrokeColor(style.strokeColor.cgColor); ctx.setLineWidth(style.lineWidth)
                    ctx.setLineJoin(.miter)
                    ctx.stroke(a.rect)
                }
            }
        case .ellipse:
            withShadow(style, options, ctx) {
                if style.fillColor.isVisible { ctx.setFillColor(style.fillColor.cgColor); ctx.fillEllipse(in: a.rect) }
                if style.strokeColor.isVisible, style.lineWidth > 0 {
                    ctx.setStrokeColor(style.strokeColor.cgColor); ctx.setLineWidth(style.lineWidth)
                    ctx.strokeEllipse(in: a.rect)
                }
            }
        case .line, .arrow:
            withShadow(style, options, ctx) { drawLine(a, ctx) }
        case .freehand:
            withShadow(style, options, ctx) { drawFreehand(a, ctx) }
        case .text:
            withShadow(style, options, ctx) {
                if style.fillColor.isVisible { ctx.setFillColor(style.fillColor.cgColor); ctx.fill(a.rect) }
                if style.strokeColor.isVisible, style.lineWidth > 0 {
                    ctx.setStrokeColor(style.strokeColor.cgColor); ctx.setLineWidth(style.lineWidth); ctx.stroke(a.rect)
                }
                if a.id != options.hiddenTextID { TextLayout.draw(a.text, in: a.rect, style: style, context: ctx) }
            }
        case .bubble:
            let path = bubblePath(a)
            withShadow(style, options, ctx) {
                ctx.addPath(path)
                ctx.setFillColor(style.fillColor.cgColor)
                ctx.fillPath()
                if style.strokeColor.isVisible, style.lineWidth > 0 {
                    ctx.addPath(path)
                    ctx.setStrokeColor(style.strokeColor.cgColor); ctx.setLineWidth(style.lineWidth); ctx.setLineJoin(.round)
                    ctx.strokePath()
                }
            }
            if a.id != options.hiddenTextID { TextLayout.draw(a.text, in: a.rect, style: style, context: ctx) }
        case .step:
            drawStep(a, number: stepNumber ?? style.stepStart, ctx, options)
        case .obfuscate:
            drawObfuscate(a, ctx, imageSize: imageSize)
        case .highlight:
            drawHighlight(a, ctx, imageSize: imageSize)
        case .image:
            if let image = a.image?.cgImage { drawFlipped(image, in: a.rect, ctx) }
        }
    }

    /// Draws a CGImage into `rect` of a context whose y axis points down.
    static func drawFlipped(_ image: CGImage, in rect: CGRect, _ ctx: CGContext) {
        ctx.saveGState()
        ctx.translateBy(x: rect.minX, y: rect.maxY)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: rect.width, height: rect.height))
        ctx.restoreGState()
    }

    private static func withShadow(_ style: Style, _ options: Options, _ ctx: CGContext, _ body: () -> Void) {
        guard style.shadow else { body(); return }
        let s = max(1, options.scale)
        ctx.saveGState()
        // The offset is in the context's base space, which is y-up, so a negative height is "down".
        ctx.setShadow(offset: CGSize(width: 3 * s, height: -3 * s), blur: 5 * s, color: NSColor.black.withAlphaComponent(0.5).cgColor)
        ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        body()
        ctx.endTransparencyLayer()
        ctx.restoreGState()
    }

    // MARK: Lines

    static func arrowHeadLength(lineWidth: CGFloat) -> CGFloat { lineWidth * 3.2 + 8 }

    private static func drawLine(_ a: Annotation, _ ctx: CGContext) {
        let style = a.style
        guard style.strokeColor.isVisible, style.lineWidth > 0 else { return }
        var from = a.start, to = a.end
        let length = from.distance(to: to)
        guard length > 0 else { return }
        var heads: [(tip: CGPoint, from: CGPoint)] = []
        if a.kind == .arrow {
            let headLength = min(arrowHeadLength(lineWidth: style.lineWidth), length * 0.6)
            let ux = (to.x - from.x) / length, uy = (to.y - from.y) / length
            if style.arrowHeads == .end || style.arrowHeads == .both {
                heads.append((a.end, CGPoint(x: a.end.x - ux * headLength, y: a.end.y - uy * headLength)))
                to = CGPoint(x: a.end.x - ux * headLength * 0.8, y: a.end.y - uy * headLength * 0.8)
            }
            if style.arrowHeads == .start || style.arrowHeads == .both {
                heads.append((a.start, CGPoint(x: a.start.x + ux * headLength, y: a.start.y + uy * headLength)))
                from = CGPoint(x: a.start.x + ux * headLength * 0.8, y: a.start.y + uy * headLength * 0.8)
            }
        }
        ctx.setStrokeColor(style.strokeColor.cgColor)
        ctx.setFillColor(style.strokeColor.cgColor)
        ctx.setLineWidth(style.lineWidth)
        ctx.setLineCap(.round)
        ctx.move(to: from)
        ctx.addLine(to: to)
        ctx.strokePath()

        for head in heads {
            let angle = atan2(head.tip.y - head.from.y, head.tip.x - head.from.x)
            let spread = CGFloat.pi / 7.5
            let side = head.tip.distance(to: head.from) / cos(spread)
            let p1 = CGPoint(x: head.tip.x - cos(angle - spread) * side, y: head.tip.y - sin(angle - spread) * side)
            let p2 = CGPoint(x: head.tip.x - cos(angle + spread) * side, y: head.tip.y - sin(angle + spread) * side)
            ctx.move(to: head.tip)
            ctx.addLine(to: p1)
            ctx.addLine(to: p2)
            ctx.closePath()
            ctx.setLineJoin(.round)
            ctx.setLineWidth(max(1, style.lineWidth * 0.4))
            ctx.drawPath(using: .fillStroke)
        }
    }

    private static func drawFreehand(_ a: Annotation, _ ctx: CGContext) {
        let style = a.style
        guard style.strokeColor.isVisible, style.lineWidth > 0, let first = a.points.first else { return }
        ctx.setStrokeColor(style.strokeColor.cgColor)
        ctx.setLineWidth(style.lineWidth)
        ctx.setLineCap(.round)
        ctx.setLineJoin(.round)
        if a.points.count == 1 {
            ctx.setFillColor(style.strokeColor.cgColor)
            ctx.fillEllipse(in: CGRect(x: first.x - style.lineWidth / 2, y: first.y - style.lineWidth / 2, width: style.lineWidth, height: style.lineWidth))
            return
        }
        // Quadratic curves through the midpoints smooth out the jitter of a mouse stroke.
        ctx.move(to: first)
        for i in 1..<a.points.count {
            let p = a.points[i], prev = a.points[i - 1]
            let mid = CGPoint(x: (p.x + prev.x) / 2, y: (p.y + prev.y) / 2)
            ctx.addQuadCurve(to: mid, control: prev)
        }
        ctx.addLine(to: a.points[a.points.count - 1])
        ctx.strokePath()
    }

    // MARK: Bubble and step label

    static func bubblePath(_ a: Annotation) -> CGPath {
        let r = a.rect
        let radius = min(r.width, r.height) * 0.18
        let body = CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
        guard r.width > 4, r.height > 4, !r.insetBy(dx: -0.5, dy: -0.5).contains(a.tail) else { return body }

        // The tail leaves from the box edge nearest to its tip.
        let baseWidth = min(min(r.width, r.height) * 0.45, 40)
        let tip = a.tail
        let leftGap = r.minX - tip.x, rightGap = tip.x - r.maxX, topGap = r.minY - tip.y, bottomGap = tip.y - r.maxY
        let farthest = max(leftGap, rightGap, topGap, bottomGap)
        var b1: CGPoint, b2: CGPoint
        if farthest == bottomGap || farthest == topGap {
            let cx = min(max(tip.x, r.minX + radius + baseWidth / 2), r.maxX - radius - baseWidth / 2)
            let y = farthest == bottomGap ? r.maxY - 0.5 : r.minY + 0.5
            b1 = CGPoint(x: cx - baseWidth / 2, y: y); b2 = CGPoint(x: cx + baseWidth / 2, y: y)
        } else {
            let cy = min(max(tip.y, r.minY + radius + baseWidth / 2), r.maxY - radius - baseWidth / 2)
            let x = farthest == rightGap ? r.maxX - 0.5 : r.minX + 0.5
            b1 = CGPoint(x: x, y: cy - baseWidth / 2); b2 = CGPoint(x: x, y: cy + baseWidth / 2)
        }
        let triangle = CGMutablePath()
        triangle.move(to: b1)
        triangle.addLine(to: tip)
        triangle.addLine(to: b2)
        triangle.closeSubpath()
        return body.union(triangle)
    }

    private static func drawStep(_ a: Annotation, number: Int, _ ctx: CGContext, _ options: Options) {
        let style = a.style
        withShadow(style, options, ctx) {
            if style.fillColor.isVisible { ctx.setFillColor(style.fillColor.cgColor); ctx.fillEllipse(in: a.rect) }
            if style.strokeColor.isVisible, style.lineWidth > 0 {
                ctx.setStrokeColor(style.strokeColor.cgColor); ctx.setLineWidth(style.lineWidth)
                ctx.strokeEllipse(in: a.rect.insetBy(dx: style.lineWidth / 2, dy: style.lineWidth / 2))
            }
        }
        var textStyle = style
        textStyle.fontSize = a.rect.height * 0.5
        textStyle.textAlign = .center
        textStyle.verticalAlign = .middle
        textStyle.bold = true
        // Zero padding so the digits stay centred in small circles.
        let inner = a.rect
        let string = NSAttributedString(string: String(number), attributes: textStyle.textAttributes())
        let size = string.size()
        ctx.saveGState()
        let graphics = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        string.draw(at: CGPoint(x: inner.midX - size.width / 2, y: inner.midY - size.height / 2))
        NSGraphicsContext.restoreGraphicsState()
        ctx.restoreGState()
    }

    // MARK: Filters

    /// Region of the already-rendered picture (everything below this annotation) as its own image.
    private static func snapshot(of region: CGRect, _ ctx: CGContext, imageSize: CGSize) -> (image: CGImage, rect: CGRect)? {
        let bounds = CGRect(origin: .zero, size: imageSize)
        let clipped = region.integral.intersection(bounds)
        guard !clipped.isNull, clipped.width >= 1, clipped.height >= 1, let whole = ctx.makeImage(),
              let cropped = whole.cropping(to: clipped) else { return nil }
        return (cropped, clipped)
    }

    private static func drawObfuscate(_ a: Annotation, _ ctx: CGContext, imageSize: CGSize) {
        let style = a.style
        switch style.obfuscateMode {
        case .blackout:
            ctx.setFillColor((style.fillColor.isVisible ? style.fillColor : .black).with(alpha: 1).cgColor)
            ctx.fill(a.rect)
        case .pixelate, .blur:
            guard let (image, region) = snapshot(of: a.rect, ctx, imageSize: imageSize) else { return }
            let result = style.obfuscateMode == .pixelate
                ? ImageFilters.pixelate(image, blockSize: Int(style.pixelSize.rounded()))
                : ImageFilters.blur(image, radius: Double(style.blurRadius))
            if let result { drawFlipped(result, in: region, ctx) }
        }
    }

    private static func drawHighlight(_ a: Annotation, _ ctx: CGContext, imageSize: CGSize) {
        let style = a.style
        switch style.highlightMode {
        case .text:
            // Multiply keeps dark text readable, like a real marker pen.
            ctx.saveGState()
            ctx.setBlendMode(.multiply)
            ctx.setFillColor(style.highlightColor.cgColor)
            ctx.fill(a.rect)
            ctx.restoreGState()
        case .area:
            ctx.saveGState()
            ctx.addRect(CGRect(origin: .zero, size: imageSize))
            ctx.addRect(a.rect)
            ctx.clip(using: .evenOdd)
            ctx.setFillColor(NSColor.black.withAlphaComponent(style.dim).cgColor)
            ctx.fill(CGRect(origin: .zero, size: imageSize))
            ctx.restoreGState()
        case .grayscale:
            guard let (image, region) = snapshot(of: a.rect, ctx, imageSize: imageSize),
                  let gray = ImageFilters.grayscale(image) else { return }
            drawFlipped(gray, in: region, ctx)
        case .magnify:
            let factor = max(1.1, style.magnification)
            let source = CGRect(x: a.rect.midX - a.rect.width / factor / 2, y: a.rect.midY - a.rect.height / factor / 2,
                                width: a.rect.width / factor, height: a.rect.height / factor)
            guard let (image, _) = snapshot(of: source, ctx, imageSize: imageSize) else { return }
            ctx.saveGState()
            ctx.clip(to: a.rect)
            ctx.interpolationQuality = .high
            drawFlipped(image, in: a.rect, ctx)
            ctx.restoreGState()
            if style.strokeColor.isVisible, style.lineWidth > 0 {
                ctx.setStrokeColor(style.strokeColor.cgColor)
                ctx.setLineWidth(style.lineWidth)
                ctx.stroke(a.rect)
            }
        }
    }
}
