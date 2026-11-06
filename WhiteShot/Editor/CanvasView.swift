import AppKit

/// Text view that hands Escape back to the canvas so editing can end without a click.
private final class InPlaceTextView: NSTextView {
    var onCancel: (() -> Void)?
    var onCommit: (() -> Void)?

    override func cancelOperation(_ sender: Any?) { onCancel?() }

    override func keyDown(with event: NSEvent) {
        // Command-Return finishes editing; plain Return inserts a line break.
        if event.keyCode == 36, event.modifierFlags.contains(.command) { onCommit?(); return }
        super.keyDown(with: event)
    }
}

/// The drawing surface. Coordinates inside the model are image pixels with the origin at the
/// top-left; this view is flipped to match and scales by `pointsPerPixel` for zoom.
final class CanvasView: NSView, NSTextViewDelegate, NSUserInterfaceValidations {
    unowned let model: EditorModel
    var onMagnify: ((CGFloat, NSPoint) -> Void)?
    var onRequestImageInsert: (() -> Void)?
    /// Where copied recognised text goes. The general pasteboard; tests use a private one.
    var textPasteboard: NSPasteboard = .general

    private enum Drag {
        case creating(id: UUID, origin: CGPoint, before: EditorModel.Snapshot, wasDirty: Bool)
        case moving(start: CGPoint, originals: [UUID: Annotation], before: EditorModel.Snapshot)
        case resizing(handle: Handle, original: Annotation, before: EditorModel.Snapshot)
        case marquee(origin: CGPoint, base: Set<UUID>)
        case newCrop(origin: CGPoint)
        case cropMove(start: CGPoint, original: CGRect)
        case cropResize(handle: Handle, original: CGRect)
        case selectingText(anchor: TextPosition)
    }

    private var drag: Drag?
    private var marquee: CGRect?
    private var textView: InPlaceTextView?
    private var textBefore: EditorModel.Snapshot?
    private var textIsNew = false
    private var textWasDirty = false
    private var trackingArea: NSTrackingArea?

    static let annotationPasteboardType = NSPasteboard.PasteboardType("me.fbrd.whiteshot.annotations")

    init(model: EditorModel) {
        self.model = model
        super.init(frame: .zero)
        registerForDraggedTypes([.fileURL, .png, .tiff])
        syncFrameSize()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var undoManager: UndoManager? { model.undoManager }

    // MARK: - Geometry

    private var backingScale: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }

    /// View points per image pixel. Zoom 1 shows one image pixel per screen pixel.
    var pointsPerPixel: CGFloat { model.zoom / backingScale }

    func syncFrameSize() {
        let k = pointsPerPixel
        let size = NSSize(width: ceil(model.imageSize.width * k), height: ceil(model.imageSize.height * k))
        if frame.size != size {
            setFrameSize(size)
            // A zoom change moves and rescales the live text field along with everything else.
            updateTextViewFrame()
        }
    }

    /// Frame of the in-place text field while editing, in canvas coordinates (exposed for tests).
    var editingTextFrame: NSRect? { textView?.frame }

    func imagePoint(from event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        let k = pointsPerPixel
        return CGPoint(x: p.x / k, y: p.y / k)
    }

    func viewRect(for imageRect: CGRect) -> CGRect {
        let k = pointsPerPixel
        return CGRect(x: imageRect.minX * k, y: imageRect.minY * k, width: imageRect.width * k, height: imageRect.height * k)
    }

    /// Called whenever the model reports a change.
    func modelChanged() {
        syncFrameSize()
        updateTextViewFrame()
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncFrameSize()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let k = pointsPerPixel

        // The picture itself. Nearest-neighbour when magnified so pixels stay crisp.
        ctx.saveGState()
        ctx.interpolationQuality = model.zoom >= 2 ? .none : .high
        ctx.translateBy(x: 0, y: bounds.height)
        ctx.scaleBy(x: 1, y: -1)
        ctx.draw(model.composite(), in: CGRect(origin: .zero, size: bounds.size))
        ctx.restoreGState()

        // Editing chrome, drawn in image units so geometry lines up exactly.
        ctx.saveGState()
        ctx.scaleBy(x: k, y: k)
        if model.isTextMode {
            drawRecognizedText(ctx, k: k)
        } else {
            drawSelection(ctx, k: k)
            if let marquee { drawMarquee(marquee, ctx, k: k) }
        }
        ctx.restoreGState()

        if model.tool == .crop, let crop = model.cropRect { drawCropOverlay(crop, ctx, k: k) }
    }

    private func drawSelection(_ ctx: CGContext, k: CGFloat) {
        let accent = NSColor.controlAccentColor.cgColor
        let selected = model.selectedAnnotations
        for a in selected {
            if !a.isLinear {
                ctx.setStrokeColor(accent)
                ctx.setLineWidth(1 / k)
                ctx.setLineDash(phase: 0, lengths: [4 / k, 3 / k])
                ctx.stroke(a.bounds.insetBy(dx: -2 / k, dy: -2 / k))
                ctx.setLineDash(phase: 0, lengths: [])
            }
        }
        guard selected.count == 1, let only = selected.first, model.editingTextID == nil else { return }
        let size = 8 / k
        for (_, point) in only.handles() {
            let r = CGRect(x: point.x - size / 2, y: point.y - size / 2, width: size, height: size)
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fillEllipse(in: r)
            ctx.setStrokeColor(accent)
            ctx.setLineWidth(1.5 / k)
            ctx.strokeEllipse(in: r)
        }
    }

    /// Text recognition: a faint box on every line Vision found, and the selection on top of it.
    private func drawRecognizedText(_ ctx: CGContext, k: CGFloat) {
        guard let text = model.recognizedText else { return }
        let accent = NSColor.controlAccentColor
        let radius = 2 / k
        for line in text.lines {
            let rect = line.rect.insetBy(dx: -1 / k, dy: -1 / k)
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.setFillColor(accent.withAlphaComponent(0.10).cgColor)
            ctx.setStrokeColor(accent.withAlphaComponent(0.45).cgColor)
            ctx.setLineWidth(1 / k)
            ctx.drawPath(using: .fillStroke)
        }
        // What looks sensitive, in orange, so it stands out from the ordinary recognised lines.
        let orange = NSColor.systemOrange
        for match in model.activeSuggestions where text.lines.indices.contains(match.line) {
            let rect = SensitiveDetector.rect(of: match, in: text).insetBy(dx: -1.5 / k, dy: -2 / k)
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            ctx.setFillColor(orange.withAlphaComponent(0.30).cgColor)
            ctx.setStrokeColor(orange.cgColor)
            ctx.setLineWidth(1.5 / k)
            ctx.drawPath(using: .fillStroke)
        }
        if let selection = model.textSelection, !selection.isEmpty {
            ctx.setFillColor(accent.withAlphaComponent(0.38).cgColor)
            for rect in text.rects(for: selection) {
                ctx.addPath(CGPath(roundedRect: rect.insetBy(dx: 0, dy: -1 / k), cornerWidth: radius, cornerHeight: radius, transform: nil))
                ctx.fillPath()
            }
        }
        // QR codes and barcodes: an outline, filled when picked.
        for (index, code) in text.codes.enumerated() {
            let rect = code.rect.insetBy(dx: -3 / k, dy: -3 / k)
            ctx.addPath(CGPath(roundedRect: rect, cornerWidth: 4 / k, cornerHeight: 4 / k, transform: nil))
            ctx.setFillColor(accent.withAlphaComponent(index == model.selectedCodeIndex ? 0.35 : 0.12).cgColor)
            ctx.setStrokeColor(accent.cgColor)
            ctx.setLineWidth(2.5 / k)
            ctx.drawPath(using: .fillStroke)
        }
    }

    private func drawMarquee(_ rect: CGRect, _ ctx: CGContext, k: CGFloat) {
        let accent = NSColor.controlAccentColor
        ctx.setFillColor(accent.withAlphaComponent(0.12).cgColor)
        ctx.fill(rect)
        ctx.setStrokeColor(accent.cgColor)
        ctx.setLineWidth(1 / k)
        ctx.stroke(rect)
    }

    private func drawCropOverlay(_ crop: CGRect, _ ctx: CGContext, k: CGFloat) {
        let view = viewRect(for: crop)
        ctx.saveGState()
        ctx.addRect(bounds)
        ctx.addRect(view)
        ctx.clip(using: .evenOdd)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.55).cgColor)
        ctx.fill(bounds)
        ctx.restoreGState()

        ctx.setStrokeColor(NSColor.white.cgColor)
        ctx.setLineWidth(1)
        ctx.stroke(view)
        // Rule-of-thirds guides.
        ctx.setStrokeColor(NSColor.white.withAlphaComponent(0.35).cgColor)
        for i in 1...2 {
            let x = view.minX + view.width * CGFloat(i) / 3, y = view.minY + view.height * CGFloat(i) / 3
            ctx.move(to: CGPoint(x: x, y: view.minY)); ctx.addLine(to: CGPoint(x: x, y: view.maxY))
            ctx.move(to: CGPoint(x: view.minX, y: y)); ctx.addLine(to: CGPoint(x: view.maxX, y: y))
        }
        ctx.strokePath()

        for (_, p) in cropHandles(for: crop) {
            let r = CGRect(x: p.x * k - 5, y: p.y * k - 5, width: 10, height: 10)
            ctx.setFillColor(NSColor.white.cgColor)
            ctx.fill(r)
            ctx.setStrokeColor(NSColor.controlAccentColor.cgColor)
            ctx.setLineWidth(1.5)
            ctx.stroke(r)
        }

        let label = "\(Int(crop.width)) × \(Int(crop.height))" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.white,
        ]
        let size = label.size(withAttributes: attributes)
        let pill = CGRect(x: view.midX - size.width / 2 - 6, y: max(2, view.minY - size.height - 10), width: size.width + 12, height: size.height + 4)
        ctx.setFillColor(NSColor.black.withAlphaComponent(0.7).cgColor)
        ctx.addPath(CGPath(roundedRect: pill, cornerWidth: 5, cornerHeight: 5, transform: nil))
        ctx.fillPath()
        label.draw(at: CGPoint(x: pill.minX + 6, y: pill.minY + 2), withAttributes: attributes)
    }

    private func cropHandles(for r: CGRect) -> [(Handle, CGPoint)] {
        [(.topLeft, CGPoint(x: r.minX, y: r.minY)), (.top, CGPoint(x: r.midX, y: r.minY)),
         (.topRight, CGPoint(x: r.maxX, y: r.minY)), (.right, CGPoint(x: r.maxX, y: r.midY)),
         (.bottomRight, CGPoint(x: r.maxX, y: r.maxY)), (.bottom, CGPoint(x: r.midX, y: r.maxY)),
         (.bottomLeft, CGPoint(x: r.minX, y: r.maxY)), (.left, CGPoint(x: r.minX, y: r.midY))]
    }

    // MARK: - Cursor

    override func resetCursorRects() {
        if model.isTextMode {
            // The text cursor over recognised text, the plain arrow everywhere else.
            for line in model.recognizedText?.lines ?? [] {
                addCursorRect(viewRect(for: line.rect).intersection(bounds), cursor: .iBeam)
            }
            for code in model.recognizedText?.codes ?? [] {
                addCursorRect(viewRect(for: code.rect).intersection(bounds), cursor: .pointingHand)
            }
            return
        }
        let cursor: NSCursor
        switch model.tool {
        case .select: cursor = .arrow
        case .text: cursor = .iBeam
        default: cursor = .crosshair
        }
        addCursorRect(bounds, cursor: cursor)
    }

    override func mouseMoved(with event: NSEvent) {
        model.pointerLocation = imagePoint(from: event)
    }

    override func mouseExited(with event: NSEvent) {
        model.pointerLocation = nil
    }

    // MARK: - Mouse

    private var hitTolerance: CGFloat { 5 / pointsPerPixel }
    private var handleTolerance: CGFloat { 8 / pointsPerPixel }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        endTextEditing(commit: true)
        // If the previous mouse-up never arrived, close that gesture first instead of silently dropping it.
        if drag != nil { completeDrag() }
        let p = imagePoint(from: event)
        let additive = event.modifierFlags.contains(.shift)

        if model.isTextMode { beginTextSelection(at: p, event: event); return }
        if model.tool == .crop { beginCrop(at: p); return }

        // Handles only work with the Select tool. With a drawing tool active every press starts a new shape:
        // the previous shape is still selected, and its handles (a step label's cover everything around it)
        // used to swallow presses meant for the next shape or number placed right beside it.
        if model.tool == .select, model.selection.count == 1, let only = model.selectedAnnotations.first,
           let handle = only.handle(at: p, tolerance: handleTolerance) {
            drag = .resizing(handle: handle, original: only, before: model.snapshot())
            return
        }

        if let kind = model.tool.kind {
            if kind == .text, let existing = model.annotations.last(where: { $0.kind == .text && $0.hitTest(p, tolerance: hitTolerance) }) {
                model.selection = [existing.id]
                beginTextEditing(id: existing.id, isNew: false, before: nil)
                return
            }
            beginCreating(kind, at: p, event: event)
            return
        }

        // Select tool.
        if let hit = model.annotations.last(where: { $0.hitTest(p, tolerance: hitTolerance) }) {
            if additive {
                if model.selection.contains(hit.id) { model.selection.remove(hit.id) } else { model.selection.insert(hit.id) }
            } else if !model.selection.contains(hit.id) {
                model.selection = [hit.id]
            }
            if event.clickCount == 2, hit.hasText {
                beginTextEditing(id: hit.id, isNew: false, before: nil)
                return
            }
            let originals = Dictionary(uniqueKeysWithValues: model.selectedAnnotations.map { ($0.id, $0) })
            drag = .moving(start: p, originals: originals, before: model.snapshot())
        } else {
            let base = additive ? model.selection : []
            model.selection = base
            drag = .marquee(origin: p, base: base)
        }
        model.refresh()
    }

    override func mouseDragged(with event: NSEvent) {
        let p = imagePoint(from: event)
        model.pointerLocation = p
        applyDrag(to: p, flags: event.modifierFlags)
    }

    /// Updates whatever the current gesture is manipulating so that it ends at `p`.
    private func applyDrag(to p: CGPoint, flags: NSEvent.ModifierFlags) {
        let shift = flags.contains(.shift)
        let option = flags.contains(.option)
        switch drag {
        case .creating(let id, let origin, _, _):
            model.mutateLive { list in
                guard let i = list.firstIndex(where: { $0.id == id }) else { return }
                list[i].updateWhileCreating(from: origin, to: p, constrain: shift, fromCenter: option)
            }
        case .moving(let start, let originals, _):
            let delta = CGPoint(x: p.x - start.x, y: p.y - start.y)
            model.mutateLive { list in
                for i in list.indices {
                    if let original = originals[list[i].id] { list[i] = original.offset(by: delta) }
                }
            }
        case .resizing(let handle, let original, _):
            model.mutateLive { list in
                guard let i = list.firstIndex(where: { $0.id == original.id }) else { return }
                list[i] = original.resized(handle: handle, to: p, keepAspect: shift)
            }
        case .marquee(let origin, let base):
            let rect = CGRect(from: origin, to: p)
            // A plain click is not a rubber band: it must not select whatever happens to lie under the point.
            guard rect.width >= 3 || rect.height >= 3 else { return }
            marquee = rect
            model.selection = base.union(model.annotations.filter { $0.bounds.intersects(rect) }.map(\.id))
            model.refresh()
        case .selectingText(let anchor):
            if let position = model.recognizedText?.nearestPosition(to: p) {
                model.textSelection = TextSelection(anchor: anchor, head: position)
                model.refresh()
            }
        case .newCrop(let origin):
            var rect = CGRect(from: origin, to: p).intersection(model.imageBounds)
            if shift { let side = min(rect.width, rect.height); rect.size = CGSize(width: side, height: side) }
            model.cropRect = rect
            model.refresh()
        case .cropMove(let start, let original):
            var moved = original.offsetBy(dx: p.x - start.x, dy: p.y - start.y)
            moved.origin.x = min(max(0, moved.origin.x), model.imageSize.width - moved.width)
            moved.origin.y = min(max(0, moved.origin.y), model.imageSize.height - moved.height)
            model.cropRect = moved
            model.refresh()
        case .cropResize(let handle, let original):
            let clampedPoint = CGPoint(x: min(max(0, p.x), model.imageSize.width), y: min(max(0, p.y), model.imageSize.height))
            var dummy = Annotation(kind: .rectangle, style: Style())
            dummy.rect = original
            model.cropRect = dummy.resized(handle: handle, to: clampedPoint, keepAspect: shift).rect
            model.refresh()
        case nil:
            break
        }
    }

    override func mouseUp(with event: NSEvent) {
        // A quick flick can deliver the press and the release with no drag events in between, or the last drag
        // event can lie short of the release point: end the gesture exactly where the button was released.
        if drag != nil { applyDrag(to: imagePoint(from: event), flags: event.modifierFlags) }
        completeDrag()
    }

    /// Finishes the current gesture: commits its undo step, or discards a shape that came out empty.
    private func completeDrag() {
        defer { drag = nil; marquee = nil; needsDisplay = true }
        switch drag {
        case .creating(let id, _, let before, let wasDirty):
            finishCreating(id: id, before: before, wasDirty: wasDirty)
        case .moving(_, _, let before):
            model.commit(from: before, name: String(localized: "Move"))
        case .resizing(_, _, let before):
            model.commit(from: before, name: String(localized: "Resize"))
        case .newCrop:
            if let crop = model.cropRect, crop.width < 4 || crop.height < 4 { model.cropRect = nil }
            model.refresh()
        default:
            break
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard !model.isTextMode else { super.rightMouseDown(with: event); return }
        let p = imagePoint(from: event)
        if let hit = model.annotations.last(where: { $0.hitTest(p, tolerance: hitTolerance) }), !model.selection.contains(hit.id) {
            model.selection = [hit.id]
            model.refresh()
        }
        super.rightMouseDown(with: event)
    }

    // MARK: Selecting recognised text

    private func beginTextSelection(at p: CGPoint, event: NSEvent) {
        guard let text = model.recognizedText else { return }          // still recognising
        // A QR code or barcode under the pointer is picked instead of starting a text selection.
        let slack = 4 / pointsPerPixel
        if let index = text.codes.firstIndex(where: { $0.rect.insetBy(dx: -slack, dy: -slack).contains(p) }) {
            model.textSelection = nil
            model.selectedCodeIndex = index
            model.refresh()
            return
        }
        if model.selectedCodeIndex != nil { model.selectedCodeIndex = nil }
        switch event.clickCount {
        case 2:
            model.textSelection = text.wordSelection(at: p)
        case 3...:
            model.textSelection = text.lineSelection(at: p)
        default:
            guard let position = text.position(at: p) else {
                model.textSelection = nil                               // a click beside the text clears the selection
                model.refresh()
                return
            }
            let anchor = event.modifierFlags.contains(.shift) ? (model.textSelection?.anchor ?? position) : position
            model.textSelection = TextSelection(anchor: anchor, head: position)
            drag = .selectingText(anchor: anchor)
        }
        model.refresh()
    }

    /// Copies the selected recognised text (or the picked code), or all the text when `all` is set.
    func copyRecognizedText(all: Bool = false) {
        guard let text = all ? model.recognizedTextForExport : (model.selectedRecognizedText ?? model.selectedCode?.payload) else { return }
        textPasteboard.clearContents()
        textPasteboard.setString(text, forType: .string)
    }

    // MARK: Creating shapes

    private func beginCreating(_ kind: AnnotationKind, at p: CGPoint, event: NSEvent) {
        let before = model.snapshot()
        let wasDirty = model.isDirty
        var annotation = model.makeAnnotation(kind)
        switch kind {
        case .step:
            let diameter = max(16, annotation.style.fontSize * 2.2)
            annotation.rect = CGRect(x: p.x - diameter / 2, y: p.y - diameter / 2, width: diameter, height: diameter)
        case .freehand:
            annotation.points = [p]
        case .text:
            annotation.rect = CGRect(origin: p, size: .zero)
        default:
            annotation.updateWhileCreating(from: p, to: p, constrain: false, fromCenter: false)
        }
        model.mutateLive { $0.append(annotation) }
        model.selection = [annotation.id]
        drag = .creating(id: annotation.id, origin: p, before: before, wasDirty: wasDirty)
    }

    private func finishCreating(id: UUID, before: EditorModel.Snapshot, wasDirty: Bool) {
        guard var a = model.annotation(withID: id) else { return }

        if a.kind == .text {
            // A plain click makes a default-sized box; a drag keeps the box the user drew.
            let k = model.scale
            if a.rect.width < 12 {
                a.rect = CGRect(x: a.rect.minX, y: a.rect.minY, width: 220 * k, height: 0)
            }
            a.rect.size.height = max(a.rect.height, TextLayout.requiredHeight(for: "", style: a.style, width: a.rect.width))
            replace(a)
            beginTextEditing(id: id, isNew: true, before: before, wasDirty: wasDirty)
            return
        }

        guard a.isMeaningful else {
            model.mutateLive { $0.removeAll { $0.id == id } }
            model.selection = []
            if !wasDirty { model.markClean() }
            return
        }
        if a.kind == .bubble {
            replace(a)
            beginTextEditing(id: id, isNew: true, before: before, wasDirty: wasDirty)
            return
        }
        model.commit(from: before, name: String(localized: "Add"))
        model.refresh()
    }

    private func replace(_ a: Annotation) {
        model.mutateLive { list in
            if let i = list.firstIndex(where: { $0.id == a.id }) { list[i] = a }
        }
    }

    // MARK: Crop

    private func beginCrop(at p: CGPoint) {
        if let crop = model.cropRect {
            for (handle, point) in cropHandles(for: crop) where point.distance(to: p) <= handleTolerance {
                drag = .cropResize(handle: handle, original: crop)
                return
            }
            if crop.contains(p) {
                drag = .cropMove(start: p, original: crop)
                return
            }
        }
        model.cropRect = CGRect(origin: p, size: .zero)
        drag = .newCrop(origin: p)
    }

    // MARK: - In-place text editing

    func beginTextEditing(id: UUID, isNew: Bool, before: EditorModel.Snapshot?, wasDirty: Bool? = nil) {
        endTextEditing(commit: true)
        guard let a = model.annotation(withID: id), a.hasText else { return }
        model.selection = [id]
        model.editingTextID = id
        textBefore = before ?? model.snapshot()
        textIsNew = isNew
        textWasDirty = wasDirty ?? model.isDirty

        let tv = InPlaceTextView(frame: .zero)
        tv.drawsBackground = false
        tv.isRichText = false
        tv.allowsUndo = false
        tv.importsGraphics = false
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.textContainerInset = .zero
        tv.textContainer?.lineFragmentPadding = 0
        tv.isVerticallyResizable = false
        tv.isHorizontallyResizable = false
        tv.delegate = self
        tv.onCancel = { [weak self] in self?.endTextEditing(commit: true); self?.window?.makeFirstResponder(self) }
        tv.onCommit = tv.onCancel
        textView = tv
        applyTextAttributes(a)
        tv.string = a.text
        addSubview(tv)
        updateTextViewFrame()
        window?.makeFirstResponder(tv)
        tv.selectAll(nil)
        model.refresh()
    }

    private func applyTextAttributes(_ a: Annotation) {
        guard let tv = textView else { return }
        // Image-pixel font size: the view's bounds are scaled instead (see updateTextViewFrame), so the
        // text wraps exactly as the renderer will draw it at any zoom.
        let attributes = a.style.textAttributes()
        tv.typingAttributes = attributes
        tv.insertionPointColor = a.style.textColor.nsColor
        tv.defaultParagraphStyle = attributes[.paragraphStyle] as? NSParagraphStyle
        if let storage = tv.textStorage, storage.length > 0 {
            storage.setAttributes(attributes, range: NSRange(location: 0, length: storage.length))
        }
    }

    private func updateTextViewFrame() {
        guard let tv = textView, let id = model.editingTextID, let a = model.annotation(withID: id) else { return }
        applyTextAttributes(a)
        let pad = TextLayout.padding(for: a.style)
        let inner = a.rect.insetBy(dx: pad, dy: pad)
        guard inner.width > 1, inner.height > 1 else { return }
        // Frame in view points, bounds in image pixels: AppKit scales the text for display.
        tv.frame = viewRect(for: inner)
        tv.setBoundsSize(inner.size)
        // Vertical alignment inside the box, to match what the renderer will draw.
        if let layout = tv.layoutManager, let container = tv.textContainer {
            layout.ensureLayout(for: container)
            let used = layout.usedRect(for: container).height
            var inset: CGFloat = 0
            switch a.style.verticalAlign {
            case .top: inset = 0
            case .middle: inset = max(0, (inner.height - used) / 2)
            case .bottom: inset = max(0, inner.height - used)
            }
            tv.textContainerInset = NSSize(width: 0, height: inset)
        }
    }

    /// Replaces the text being edited, exactly as typing would. Lets tests drive text editing without key events.
    func replaceEditingText(with text: String) {
        guard let tv = textView, let id = model.editingTextID else { return }
        tv.string = text
        model.setText(text, for: id)
    }

    func textDidChange(_ notification: Notification) {
        guard let tv = textView, let id = model.editingTextID else { return }
        model.setText(tv.string, for: id)
    }

    func endTextEditing(commit: Bool) {
        guard let tv = textView, let id = model.editingTextID else { return }
        let text = tv.string
        let before = textBefore
        let isNew = textIsNew
        let wasDirty = textWasDirty
        tv.removeFromSuperview()
        textView = nil
        textBefore = nil
        model.editingTextID = nil

        let isEmpty = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let kind = model.annotation(withID: id)?.kind
        if isEmpty, isNew || kind == .text {
            // An empty text box is invisible clutter: drop it. For a brand-new one nothing was ever undoable.
            model.mutateLive { $0.removeAll { $0.id == id } }
            model.selection = []
            if isNew, let before, !wasDirty, model.annotations == before.annotations { model.markClean() }
            else if !isNew, let before { model.commit(from: before, name: String(localized: "Delete")) }
        } else if commit, let before {
            model.commit(from: before, name: isNew ? String(localized: "Add") : String(localized: "Edit Text"))
        }
        model.refresh()
        if window?.firstResponder === tv || window?.firstResponder == nil { window?.makeFirstResponder(self) }
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        false
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .control, .option])
        guard mods.isEmpty else { super.keyDown(with: event); return }
        let shift = event.modifierFlags.contains(.shift)
        let step: CGFloat = shift ? 10 : 1

        switch event.keyCode {
        case 51, 117:                       // delete, forward delete
            model.deleteSelection()
        case 53:                            // escape
            if model.isTextMode {
                if model.textSelection != nil { model.textSelection = nil; model.refresh() } else { model.endTextRecognition() }
            } else if model.tool == .crop {
                model.cropRect = nil; model.tool = .select; model.refresh()
            } else if !model.selection.isEmpty {
                model.selection = []; model.refresh()
            } else if model.tool != .select {
                model.tool = .select
            }
        case 36, 76:                        // return
            if model.tool == .crop, let crop = model.cropRect, crop.width >= 1, crop.height >= 1 {
                model.crop(to: crop)
                model.tool = .select
            } else if model.selection.count == 1, let a = model.selectedAnnotations.first, a.hasText {
                beginTextEditing(id: a.id, isNew: false, before: nil)
            }
        case 123: model.nudgeSelection(dx: -step, dy: 0)
        case 124: model.nudgeSelection(dx: step, dy: 0)
        case 125: model.nudgeSelection(dx: 0, dy: step)
        case 126: model.nudgeSelection(dx: 0, dy: -step)
        default:
            if let key = event.charactersIgnoringModifiers?.uppercased(),
               let tool = EditorTool.allCases.first(where: { $0.shortcut == key }) {
                selectTool(tool)
            } else {
                super.keyDown(with: event)
            }
        }
    }

    func selectTool(_ tool: EditorTool) {
        guard model.isToolEnabled(tool) else { return }
        endTextEditing(commit: true)
        if tool != .crop { model.cropRect = nil }
        model.tool = tool
        // Switching away from a drawing tool keeps the selection; switching to one starts fresh.
        if tool != .select && tool != .crop { model.selection = [] }
        window?.invalidateCursorRects(for: self)
        model.refresh()
    }

    // MARK: - Edit commands (reached through the responder chain)

    @objc override func selectAll(_ sender: Any?) {
        if model.isTextMode {
            model.textSelection = model.recognizedText?.fullRange
            model.refresh()
        } else {
            model.selectAll()
        }
    }
    @objc func delete(_ sender: Any?) { model.deleteSelection() }
    @objc func duplicate(_ sender: Any?) { model.duplicateSelection() }
    @objc func bringToFront(_ sender: Any?) { model.arrangeSelection(.front) }
    @objc func sendToBack(_ sender: Any?) { model.arrangeSelection(.back) }
    @objc func bringForward(_ sender: Any?) { model.arrangeSelection(.forward) }
    @objc func sendBackward(_ sender: Any?) { model.arrangeSelection(.backward) }

    @objc func copy(_ sender: Any?) {
        if model.isTextMode { copyRecognizedText(); return }
        let selected = model.selectedAnnotations
        guard !selected.isEmpty, let data = try? JSONEncoder().encode(selected) else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setData(data, forType: Self.annotationPasteboardType)
    }

    @objc func censorSelection(_ sender: Any?) { model.censorSelectedText() }
    @objc func censorAllOccurrences(_ sender: Any?) { model.censorAllOccurrencesOfSelectedText() }

    @objc func cut(_ sender: Any?) {
        copy(sender)
        model.deleteSelection()
    }

    @objc func paste(_ sender: Any?) {
        let pasteboard = NSPasteboard.general
        if let data = pasteboard.data(forType: Self.annotationPasteboardType),
           var pasted = try? JSONDecoder().decode([Annotation].self, from: data), !pasted.isEmpty {
            let offset = CGPoint(x: 12 * model.scale, y: 12 * model.scale)
            for i in pasted.indices {
                pasted[i].id = UUID()
                pasted[i].serial = model.nextAnnotationSerial()
                pasted[i].move(by: offset)
            }
            model.edit(String(localized: "Paste")) { $0.append(contentsOf: pasted) }
            model.selection = Set(pasted.map(\.id))
            model.refresh()
        } else if let image = Self.imageFromPasteboard(pasteboard) {
            insertImage(image, at: nil)
        }
    }

    static func imageFromPasteboard(_ pasteboard: NSPasteboard) -> CGImage? {
        if let data = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff),
           let decoded = ImageEncoder.decode(data) { return decoded.image }
        return nil
    }

    /// Adds an image as a movable object, centred at `center` (or the middle of the visible area).
    func insertImage(_ image: CGImage, at center: CGPoint?) {
        guard let embedded = EmbeddedImage(cgImage: image) else { return }
        var a = Annotation(kind: .image, serial: model.nextAnnotationSerial(), style: Style())
        var size = CGSize(width: image.width, height: image.height)
        // Keep an oversized paste inside the canvas.
        let limit = model.imageSize
        let fit = min(1, limit.width / size.width, limit.height / size.height)
        size = CGSize(width: size.width * fit, height: size.height * fit)
        let c = center ?? CGPoint(x: model.imageSize.width / 2, y: model.imageSize.height / 2)
        a.rect = CGRect(x: c.x - size.width / 2, y: c.y - size.height / 2, width: size.width, height: size.height)
        a.image = embedded
        model.add(a)
        model.tool = .select
    }

    func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        if model.isTextMode {
            // The picture is read-only while text recognition is on: only copying and selecting text make sense.
            switch item.action {
            case #selector(copy(_:)): return model.selectedRecognizedText != nil || model.selectedCode != nil
            case #selector(selectAll(_:)): return !(model.recognizedText?.isEmpty ?? true)
            case #selector(censorSelection(_:)): return model.selectedRecognizedText != nil
            case #selector(censorAllOccurrences(_:)): return model.occurrencesOfSelectedText > 0
            default: return false
            }
        }
        switch item.action {
        case #selector(copy(_:)), #selector(cut(_:)), #selector(delete(_:)), #selector(duplicate(_:)),
             #selector(bringToFront(_:)), #selector(sendToBack(_:)), #selector(bringForward(_:)), #selector(sendBackward(_:)):
            return !model.selection.isEmpty
        case #selector(paste(_:)):
            let types = NSPasteboard.general.types ?? []
            return types.contains(Self.annotationPasteboardType) || types.contains(.png) || types.contains(.tiff)
        case #selector(selectAll(_:)):
            return !model.annotations.isEmpty
        default:
            return true
        }
    }

    // MARK: - Context menu

    override func menu(for event: NSEvent) -> NSMenu? {
        if model.isTextMode {
            let menu = NSMenu()
            menu.addItem(withTitle: String(localized: "Copy"), action: #selector(copy(_:)), keyEquivalent: "").target = self
            menu.addItem(withTitle: String(localized: "Select All"), action: #selector(selectAll(_:)), keyEquivalent: "").target = self
            menu.addItem(.separator())
            menu.addItem(withTitle: String(localized: "Censor Selection"), action: #selector(censorSelection(_:)), keyEquivalent: "").target = self
            let count = model.occurrencesOfSelectedText
            menu.addItem(withTitle: count > 1 ? String(localized: "Censor All \(count) Occurrences") : String(localized: "Censor All Occurrences"),
                         action: #selector(censorAllOccurrences(_:)), keyEquivalent: "").target = self
            return menu
        }
        guard !model.selection.isEmpty else { return nil }
        let menu = NSMenu()
        menu.addItem(withTitle: String(localized: "Duplicate"), action: #selector(duplicate(_:)), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Bring to Front"), action: #selector(bringToFront(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: String(localized: "Bring Forward"), action: #selector(bringForward(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: String(localized: "Send Backward"), action: #selector(sendBackward(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: String(localized: "Send to Back"), action: #selector(sendToBack(_:)), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Cut"), action: #selector(cut(_:)), keyEquivalent: "").target = self
        menu.addItem(withTitle: String(localized: "Copy"), action: #selector(copy(_:)), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: String(localized: "Delete"), action: #selector(delete(_:)), keyEquivalent: "").target = self
        return menu
    }

    // MARK: - Zoom gestures

    override func magnify(with event: NSEvent) {
        onMagnify?(1 + event.magnification, convert(event.locationInWindow, from: nil))
    }

    override func scrollWheel(with event: NSEvent) {
        if event.modifierFlags.contains(.command) {
            let delta = event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 0.01 : 0.05)
            onMagnify?(1 + delta, convert(event.locationInWindow, from: nil))
        } else {
            super.scrollWheel(with: event)
        }
    }

    // MARK: - Drag and drop of images

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        !model.isTextMode && Self.imageFromDrag(sender) != nil ? .copy : []
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let image = Self.imageFromDrag(sender) else { return false }
        let p = convert(sender.draggingLocation, from: nil)
        let k = pointsPerPixel
        insertImage(image, at: CGPoint(x: p.x / k, y: p.y / k))
        return true
    }

    private static func imageFromDrag(_ sender: NSDraggingInfo) -> CGImage? {
        let pasteboard = sender.draggingPasteboard
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           let url = urls.first, let decoded = ImageEncoder.decode(contentsOf: url) {
            return decoded.image
        }
        return imageFromPasteboard(pasteboard)
    }
}
