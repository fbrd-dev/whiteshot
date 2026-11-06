import AppKit
import QuartzCore

final class CaptureOverlayWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Runs the freeze-frame selection: one borderless window per display shows a frozen screenshot of
/// that display, and the user picks a region (or a window) on it.
@MainActor
final class CaptureOverlayController {
    enum Mode { case region, window }

    enum Outcome {
        case cancelled
        /// `rect` is in display points with the origin at the top-left.
        case region(FrozenDisplay, rect: CGRect)
        case window(WindowInfo)
    }

    private(set) var mode: Mode
    let windowList: [WindowInfo]
    let showLoupe: Bool
    private(set) var overlayWindows: [CaptureOverlayWindow] = []
    private(set) var views: [CaptureOverlayView] = []
    private var completion: ((Outcome) -> Void)?
    private var finished = false
    private(set) var hoveredWindow: WindowInfo?

    /// `frame` overrides the window size; only development and tests use it, to avoid covering the whole screen.
    init(frozen: [FrozenDisplay], mode: Mode, windows: [WindowInfo], showLoupe: Bool, frame: NSRect? = nil) {
        self.mode = mode
        self.windowList = windows
        self.showLoupe = showLoupe
        for display in frozen {
            let windowFrame = frame ?? display.screen.frame
            let window = CaptureOverlayWindow(contentRect: windowFrame, styleMask: .borderless, backing: .buffered, defer: false, screen: display.screen)
            window.setFrame(windowFrame, display: false)
            window.level = .screenSaver
            window.isOpaque = false
            window.backgroundColor = .clear
            window.hasShadow = false
            window.isReleasedWhenClosed = false
            window.acceptsMouseMovedEvents = true
            window.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
            let view = CaptureOverlayView(frozen: display, controller: self)
            view.frame = NSRect(origin: .zero, size: windowFrame.size)
            window.contentView = view
            overlayWindows.append(window)
            views.append(view)
        }
    }

    /// `present: false` wires up the completion without putting windows on screen (used by tests).
    func begin(present: Bool = true, completion: @escaping (Outcome) -> Void) {
        self.completion = completion
        guard present else { return }
        NSApp.activate(ignoringOtherApps: true)
        let mouse = NSEvent.mouseLocation
        for window in overlayWindows { window.orderFrontRegardless() }
        let active = overlayWindows.first(where: { $0.frame.contains(mouse) }) ?? overlayWindows.first
        active?.makeKeyAndOrderFront(nil)
        if let view = active?.contentView { active?.makeFirstResponder(view) }
        refreshHover()
        for view in views { view.refresh() }
    }

    func toggleMode() {
        mode = mode == .region ? .window : .region
        hoveredWindow = nil
        refreshHover()
        for view in views { view.resetSelection(); view.refresh() }
    }

    func cancel() { finish(.cancelled) }

    func finish(_ outcome: Outcome) {
        guard !finished else { return }
        finished = true
        for window in overlayWindows { window.orderOut(nil) }
        overlayWindows.removeAll()
        views.removeAll()
        NSCursor.arrow.set()
        let done = completion
        completion = nil
        done?(outcome)
    }

    // MARK: Window mode

    /// Cocoa's global mouse position converted to the CG space that window frames use (top-left origin).
    private var cgMouse: CGPoint {
        let mouse = NSEvent.mouseLocation
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGPoint(x: mouse.x, y: primaryHeight - mouse.y)
    }

    func refreshHover() {
        guard mode == .window else { hoveredWindow = nil; for view in views { view.refresh() }; return }
        let point = cgMouse
        hoveredWindow = windowList.first(where: { $0.frame.contains(point) })
        for view in views { view.refresh() }
    }

    func hoveredWindowFrame(on screen: NSScreen) -> CGRect? {
        guard let info = hoveredWindow else { return nil }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        let cocoa = CGRect(x: info.frame.minX, y: primaryHeight - info.frame.maxY, width: info.frame.width, height: info.frame.height)
        let local = cocoa.offsetBy(dx: -screen.frame.minX, dy: -screen.frame.minY)
        let clipped = local.intersection(CGRect(origin: .zero, size: screen.frame.size))
        return clipped.isNull ? nil : clipped
    }

    func activate(window: NSWindow?) {
        guard let window, window.isVisible, !window.isKeyWindow else { return }
        window.makeKeyAndOrderFront(nil)
        if let view = window.contentView { window.makeFirstResponder(view) }
    }
}

final class CaptureOverlayView: NSView {
    private let frozen: FrozenDisplay
    /// Weak on purpose: finishing a capture lets the coordinator release the controller while this
    /// view is still unwinding the mouse event that finished it.
    private weak var controller: CaptureOverlayController?

    private let imageLayer = CALayer()
    private let dimLayer = CAShapeLayer()
    private let highlightLayer = CAShapeLayer()
    private let selectionLayer = CAShapeLayer()
    private let crosshairLayer = CAShapeLayer()
    private let labelBackground = CALayer()
    private let labelLayer = CATextLayer()
    private let loupeLayer = CALayer()
    private let loupeBorder = CAShapeLayer()
    private let loupeCross = CAShapeLayer()

    private var anchor: CGPoint?
    private var current: CGPoint = .zero
    private var mouse: CGPoint?
    private var spaceHeld = false
    private var lastPoint: CGPoint = .zero
    private var selection: CGRect?
    private var trackingArea: NSTrackingArea?

    private static let loupePixels = 25
    private static let loupeZoom: CGFloat = 5

    init(frozen: FrozenDisplay, controller: CaptureOverlayController) {
        self.frozen = frozen
        self.controller = controller
        super.init(frame: .zero)
        wantsLayer = true
        guard let root = layer else { return }
        root.backgroundColor = NSColor.black.cgColor

        imageLayer.contents = frozen.image
        imageLayer.contentsGravity = .resize
        imageLayer.contentsScale = frozen.scale
        imageLayer.magnificationFilter = .nearest
        root.addSublayer(imageLayer)

        dimLayer.fillColor = NSColor.black.withAlphaComponent(0.38).cgColor
        dimLayer.fillRule = .evenOdd
        root.addSublayer(dimLayer)

        highlightLayer.fillColor = NSColor.controlAccentColor.withAlphaComponent(0.22).cgColor
        highlightLayer.strokeColor = NSColor.controlAccentColor.cgColor
        highlightLayer.lineWidth = 3
        root.addSublayer(highlightLayer)

        selectionLayer.fillColor = nil
        selectionLayer.strokeColor = NSColor.white.cgColor
        selectionLayer.lineWidth = 1
        selectionLayer.shadowColor = NSColor.black.cgColor
        selectionLayer.shadowOpacity = 0.6
        selectionLayer.shadowRadius = 2
        selectionLayer.shadowOffset = .zero
        root.addSublayer(selectionLayer)

        crosshairLayer.strokeColor = NSColor.white.withAlphaComponent(0.55).cgColor
        crosshairLayer.lineWidth = 0.5
        crosshairLayer.shadowColor = NSColor.black.cgColor
        crosshairLayer.shadowOpacity = 0.5
        crosshairLayer.shadowRadius = 0.5
        crosshairLayer.shadowOffset = .zero
        root.addSublayer(crosshairLayer)

        labelBackground.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
        labelBackground.cornerRadius = 6
        root.addSublayer(labelBackground)
        labelLayer.fontSize = 12
        labelLayer.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        labelLayer.foregroundColor = NSColor.white.cgColor
        labelLayer.alignmentMode = .center
        labelLayer.contentsScale = frozen.scale
        root.addSublayer(labelLayer)

        let loupeSize = CGFloat(Self.loupePixels) * Self.loupeZoom
        loupeLayer.bounds = CGRect(x: 0, y: 0, width: loupeSize, height: loupeSize)
        loupeLayer.cornerRadius = 10
        loupeLayer.masksToBounds = true
        loupeLayer.magnificationFilter = .nearest
        loupeLayer.minificationFilter = .nearest
        loupeLayer.contentsGravity = .resize
        loupeBorder.fillColor = nil
        loupeBorder.strokeColor = NSColor.white.cgColor
        loupeBorder.lineWidth = 2
        loupeBorder.shadowColor = NSColor.black.cgColor
        loupeBorder.shadowOpacity = 0.5
        loupeBorder.shadowRadius = 3
        loupeBorder.shadowOffset = .zero
        loupeCross.fillColor = nil
        loupeCross.strokeColor = NSColor.systemRed.cgColor
        loupeCross.lineWidth = 1
        root.addSublayer(loupeLayer)
        root.addSublayer(loupeBorder)
        root.addSublayer(loupeCross)
        loupeLayer.isHidden = true
        loupeBorder.isHidden = true
        loupeCross.isHidden = true
        labelBackground.isHidden = true
        labelLayer.isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        imageLayer.frame = bounds
        CATransaction.commit()
        refresh()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        trackingArea = area
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    func resetSelection() {
        anchor = nil
        selection = nil
    }

    // MARK: Mouse

    private func point(from event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        return CGPoint(x: min(max(0, p.x), bounds.width), y: min(max(0, p.y), bounds.height))
    }

    override func mouseEntered(with event: NSEvent) {
        controller?.activate(window: window)
        mouse = point(from: event)
        refresh()
    }

    override func mouseMoved(with event: NSEvent) {
        mouse = point(from: event)
        controller?.refreshHover()
        refresh()
    }

    override func mouseDown(with event: NSEvent) {
        if controller?.mode == .window { return }
        let p = point(from: event)
        anchor = p
        current = p
        lastPoint = p
        selection = nil
        refresh()
    }

    override func mouseDragged(with event: NSEvent) {
        guard controller?.mode == .region, anchor != nil else { return }
        let p = point(from: event)
        mouse = p
        if spaceHeld, let a = anchor {
            // Space moves the whole selection instead of resizing it.
            var dx = p.x - lastPoint.x, dy = p.y - lastPoint.y
            let rect = CGRect(from: a, to: current)
            dx = min(max(-rect.minX, dx), bounds.width - rect.maxX)
            dy = min(max(-rect.minY, dy), bounds.height - rect.maxY)
            anchor = CGPoint(x: a.x + dx, y: a.y + dy)
            current = CGPoint(x: current.x + dx, y: current.y + dy)
        } else {
            current = p
        }
        lastPoint = p
        recomputeSelection(modifiers: event.modifierFlags)
        refresh()
    }

    override func flagsChanged(with event: NSEvent) {
        guard anchor != nil, controller?.mode == .region else { return }
        recomputeSelection(modifiers: event.modifierFlags)
        refresh()
    }

    private func recomputeSelection(modifiers: NSEvent.ModifierFlags) {
        guard let a = anchor else { return }
        var end = current
        if modifiers.contains(.shift) {
            // Square selection, growing toward the pointer.
            let side = max(abs(end.x - a.x), abs(end.y - a.y))
            end = CGPoint(x: a.x + (end.x < a.x ? -side : side), y: a.y + (end.y < a.y ? -side : side))
        }
        if modifiers.contains(.option) {
            // Grow from the centre outward.
            let dx = abs(end.x - a.x), dy = abs(end.y - a.y)
            selection = CGRect(x: a.x - dx, y: a.y - dy, width: dx * 2, height: dy * 2).intersection(bounds)
        } else {
            selection = CGRect(from: a, to: end).intersection(bounds)
        }
    }

    override func mouseUp(with event: NSEvent) {
        guard let controller else { return }
        switch controller.mode {
        case .window:
            if let info = controller.hoveredWindow { controller.finish(.window(info)) }
        case .region:
            defer { anchor = nil; refresh() }
            guard let s = selection, s.width >= 4, s.height >= 4 else { selection = nil; return }
            let topLeft = CGRect(x: s.minX, y: bounds.height - s.maxY, width: s.width, height: s.height)
            controller.finish(.region(frozen, rect: topLeft))
        }
    }

    override func rightMouseDown(with event: NSEvent) { controller?.cancel() }

    // MARK: Keyboard

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53:    // escape
            controller?.cancel()
        case 49:    // space
            if anchor == nil { controller?.toggleMode() } else { spaceHeld = true }
        default:
            break
        }
    }

    override func keyUp(with event: NSEvent) {
        if event.keyCode == 49 { spaceHeld = false }
    }

    // MARK: Drawing

    func refresh() {
        guard layer != nil, bounds.width > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        // Nothing to draw once the capture is over and the controller is gone.
        guard let controller else { return }
        let windowMode = controller.mode == .window
        let hover = windowMode ? controller.hoveredWindowFrame(on: frozen.screen) : nil
        let hole = selection ?? hover

        let dim = CGMutablePath()
        dim.addRect(bounds)
        if let hole { dim.addRect(hole) }
        dimLayer.frame = bounds
        dimLayer.path = dim

        highlightLayer.frame = bounds
        highlightLayer.path = hover.map { CGPath(rect: $0, transform: nil) }
        highlightLayer.isHidden = hover == nil

        selectionLayer.frame = bounds
        selectionLayer.path = selection.map { CGPath(rect: $0.insetBy(dx: -0.5, dy: -0.5), transform: nil) }
        selectionLayer.isHidden = selection == nil

        // Thin guide lines through the pointer while nothing is being dragged.
        let showCrosshair = !windowMode && selection == nil && mouse != nil
        crosshairLayer.frame = bounds
        if showCrosshair, let m = mouse {
            let path = CGMutablePath()
            path.move(to: CGPoint(x: 0, y: m.y)); path.addLine(to: CGPoint(x: bounds.width, y: m.y))
            path.move(to: CGPoint(x: m.x, y: 0)); path.addLine(to: CGPoint(x: m.x, y: bounds.height))
            crosshairLayer.path = path
        }
        crosshairLayer.isHidden = !showCrosshair

        updateLabel(selection: selection, hover: hover)
        updateLoupe()
    }

    private func updateLabel(selection: CGRect?, hover: CGRect?) {
        guard let rect = selection ?? hover else {
            labelLayer.isHidden = true
            labelBackground.isHidden = true
            return
        }
        labelLayer.string = "\(Int(rect.width.rounded())) × \(Int(rect.height.rounded()))"
        let size = CGSize(width: 86, height: 20)
        var origin = CGPoint(x: rect.midX - size.width / 2, y: rect.minY - size.height - 8)
        if origin.y < 4 { origin.y = min(bounds.height - size.height - 4, rect.maxY + 8) }
        origin.x = min(max(4, origin.x), bounds.width - size.width - 4)
        labelBackground.frame = CGRect(origin: origin, size: size)
        labelLayer.frame = CGRect(x: origin.x, y: origin.y + 2, width: size.width, height: size.height - 2)
        labelLayer.isHidden = false
        labelBackground.isHidden = false
    }

    private func updateLoupe() {
        let visible = (controller?.showLoupe ?? false) && controller?.mode == .region && mouse != nil
        loupeLayer.isHidden = !visible
        loupeBorder.isHidden = !visible
        loupeCross.isHidden = !visible
        guard visible, let m = mouse else { return }

        // Pixel under the pointer, in the frozen image (origin top-left).
        let scale = frozen.scale
        let px = Int((m.x * scale).rounded(.down)), py = Int(((bounds.height - m.y) * scale).rounded(.down))
        let half = Self.loupePixels / 2
        let region = CGRect(x: px - half, y: py - half, width: Self.loupePixels, height: Self.loupePixels)
        let imageBounds = CGRect(x: 0, y: 0, width: frozen.image.width, height: frozen.image.height)
        if region.intersection(imageBounds) == region, let crop = frozen.image.cropping(to: region) {
            loupeLayer.contents = crop
        }

        let size = loupeLayer.bounds.size
        var origin = CGPoint(x: m.x + 22, y: m.y - size.height - 22)
        if origin.x + size.width > bounds.width - 4 { origin.x = m.x - size.width - 22 }
        if origin.y < 4 { origin.y = m.y + 22 }
        loupeLayer.frame = CGRect(origin: origin, size: size)
        loupeBorder.path = CGPath(roundedRect: loupeLayer.frame, cornerWidth: 10, cornerHeight: 10, transform: nil)
        let cell = Self.loupeZoom
        loupeCross.path = CGPath(rect: CGRect(x: loupeLayer.frame.midX - cell / 2, y: loupeLayer.frame.midY - cell / 2, width: cell, height: cell), transform: nil)
    }
}
