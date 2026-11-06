import AppKit

/// Where a pinned screenshot goes and how big it is. Pure, so it can be tested without windows.
enum PinPlacement {
    /// The frame for a pin of `size` points. It goes exactly where the capture was taken from, if that is known and still on
    /// screen, otherwise to the middle of the screen, stepping aside for every pin already there. A picture bigger than
    /// 90% of the screen is shrunk to fit; `zoom` says by how much.
    static func frame(for size: NSSize, near source: NSRect?, in visible: NSRect, existing: Int) -> (frame: NSRect, zoom: CGFloat) {
        guard size.width > 0, size.height > 0 else { return (NSRect(origin: visible.origin, size: .zero), 1) }
        let zoom = min(1, 0.9 * visible.width / size.width, 0.9 * visible.height / size.height)
        let fitted = NSSize(width: (size.width * zoom).rounded(), height: (size.height * zoom).rounded())
        var origin: NSPoint
        if let source, zoom == 1, visible.intersects(source) {
            origin = source.origin
        } else {
            let step = CGFloat(existing % 8) * 26
            origin = NSPoint(x: visible.midX - fitted.width / 2 + step, y: visible.midY - fitted.height / 2 - step)
        }
        // Whole points: a window at a fractional position can end up a point taller or wider than its picture.
        origin.x = min(max(origin.x.rounded(), visible.minX.rounded(.up)), max(visible.minX, visible.maxX - fitted.width).rounded(.down))
        origin.y = min(max(origin.y.rounded(), visible.minY.rounded(.up)), max(visible.minY, visible.maxY - fitted.height).rounded(.down))
        return (NSRect(origin: origin, size: fitted), zoom)
    }
}

/// A borderless panel that floats above other windows and can take key presses without activating the app.
final class PinPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    override func performClose(_ sender: Any?) { close() }
}

/// A screenshot pinned on top of everything else, to look at while working in another app.
@MainActor
final class PinnedImageController: NSWindowController, NSWindowDelegate {
    private(set) static var pins: [PinnedImageController] = []

    let image: CGImage
    /// Pixels per point of the picture: 2 for a Retina capture, so the pin is as big on screen as what was captured.
    let imageScale: CGFloat
    let name: String
    private(set) var zoom: CGFloat
    private let pinView: PinView

    static let opacities: [CGFloat] = [1, 0.75, 0.5, 0.25]

    /// Pins `image`. `source` is where it was captured from, in screen coordinates, so the pin can appear in the same spot.
    @discardableResult
    static func pin(_ image: CGImage, scale: CGFloat, name: String, near source: NSRect? = nil) -> PinnedImageController {
        let size = NSSize(width: CGFloat(image.width) / max(scale, 1), height: CGFloat(image.height) / max(scale, 1))
        let screen = screenFor(source) ?? NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let placement = PinPlacement.frame(for: size, near: source, in: visible, existing: pins.count)
        let controller = PinnedImageController(image: image, scale: max(scale, 1), name: name, frame: placement.frame, zoom: placement.zoom)
        pins.append(controller)
        controller.window?.orderFrontRegardless()
        return controller
    }

    private static func screenFor(_ rect: NSRect?) -> NSScreen? {
        guard let rect else { return nil }
        return NSScreen.screens.first { $0.frame.intersects(rect) }
    }

    static func closeAll() {
        for pin in pins { pin.window?.close() }
    }

    private init(image: CGImage, scale: CGFloat, name: String, frame: NSRect, zoom: CGFloat) {
        self.image = image
        self.imageScale = scale
        self.name = name
        self.zoom = zoom
        self.pinView = PinView(image: image, scale: scale)
        let panel = PinPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.contentView = pinView
        super.init(window: panel)
        panel.delegate = self
        pinView.controller = self
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func windowWillClose(_ notification: Notification) {
        Self.pins.removeAll { $0 === self }
    }

    // MARK: Look

    var opacity: CGFloat { window?.alphaValue ?? 1 }

    func setOpacity(_ value: CGFloat) {
        window?.alphaValue = min(1, max(0.1, value))
    }

    /// Resizes the pin around its centre. 1 is the size of the original capture.
    func setZoom(_ value: CGFloat) {
        guard let window else { return }
        let newZoom = min(8, max(0.1, value))
        let base = NSSize(width: CGFloat(image.width) / imageScale, height: CGFloat(image.height) / imageScale)
        let size = NSSize(width: (base.width * newZoom).rounded(), height: (base.height * newZoom).rounded())
        let centre = NSPoint(x: window.frame.midX, y: window.frame.midY)
        zoom = newZoom
        window.setFrame(NSRect(x: (centre.x - size.width / 2).rounded(), y: (centre.y - size.height / 2).rounded(), width: size.width, height: size.height), display: true)
    }

    // MARK: Actions

    func dismiss() { window?.close() }

    func copyImage() { Exporter.copyToClipboard(image, scale: imageScale) }

    func saveImage() {
        if let url = Exporter.saveQuick(image, scale: imageScale, title: name, date: Date()) {
            Notifier.shared.post(title: String(localized: "Saved"), body: url.path, fileURL: url)
        }
    }

    func openInEditor() {
        EditorWindowController.present(CaptureResult(image: image, scale: imageScale), savedURL: nil)
        dismiss()
    }
}

/// The picture itself, a close button that appears under the pointer, and the context menu.
final class PinView: NSView {
    weak var controller: PinnedImageController?
    private let closeButton = NSButton()
    private var tracking: NSTrackingArea?

    init(image: CGImage, scale: CGFloat) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.contents = image
        layer?.contentsGravity = .resize
        layer?.contentsScale = scale
        layer?.magnificationFilter = .trilinear
        layer?.minificationFilter = .trilinear
        layer?.cornerRadius = 6
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        layer?.borderColor = NSColor.separatorColor.cgColor

        closeButton.isBordered = false
        closeButton.image = NSImage(systemSymbolName: "xmark.circle.fill", accessibilityDescription: String(localized: "Close"))?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(paletteColors: [.white, NSColor.black.withAlphaComponent(0.65)]))
        closeButton.imageScaling = .scaleProportionallyUpOrDown
        closeButton.target = self
        closeButton.action = #selector(closePin)
        closeButton.toolTip = String(localized: "Close")
        closeButton.alphaValue = 0
        addSubview(closeButton)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { true }

    override func layout() {
        super.layout()
        closeButton.frame = NSRect(x: 6, y: bounds.height - 26, width: 20, height: 20)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { closeButton.animator().alphaValue = 1 }
    override func mouseExited(with event: NSEvent) { closeButton.animator().alphaValue = 0 }

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { controller?.openInEditor() } else { super.mouseDown(with: event) }
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { controller?.dismiss() } else { super.keyDown(with: event) }       // Escape
    }

    override func magnify(with event: NSEvent) {
        guard let controller else { return }
        controller.setZoom(controller.zoom * (1 + event.magnification))
    }

    @objc private func closePin() { controller?.dismiss() }

    // MARK: Menu

    override func menu(for event: NSEvent) -> NSMenu? {
        guard let controller else { return nil }
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector, to target: NSMenu = menu, state: Bool = false) {
            let item = target.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
            if state { item.state = .on }
        }
        add(String(localized: "Open in Editor"), #selector(openInEditor))
        add(String(localized: "Copy Image"), #selector(copyImage))
        add(String(localized: "Save"), #selector(saveImage))
        menu.addItem(.separator())

        let opacityMenu = NSMenu()
        for value in PinnedImageController.opacities {
            let item = opacityMenu.addItem(withTitle: "\(Int(value * 100)) %", action: #selector(chooseOpacity(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = value
            item.state = abs(controller.opacity - value) < 0.01 ? .on : .off
        }
        let opacityItem = NSMenuItem(title: String(localized: "Opacity"), action: nil, keyEquivalent: "")
        opacityItem.submenu = opacityMenu
        menu.addItem(opacityItem)

        let sizeMenu = NSMenu()
        for value in [0.5, 1, 1.5, 2] as [CGFloat] {
            let item = sizeMenu.addItem(withTitle: "\(Int(value * 100)) %", action: #selector(chooseSize(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = value
            item.state = abs(controller.zoom - value) < 0.01 ? .on : .off
        }
        let sizeItem = NSMenuItem(title: String(localized: "Size"), action: nil, keyEquivalent: "")
        sizeItem.submenu = sizeMenu
        menu.addItem(sizeItem)

        menu.addItem(.separator())
        add(String(localized: "Close"), #selector(closePin))
        if PinnedImageController.pins.count > 1 { add(String(localized: "Close All Pins"), #selector(closeAllPins)) }
        return menu
    }

    @objc private func openInEditor() { controller?.openInEditor() }
    @objc private func copyImage() { controller?.copyImage() }
    @objc private func saveImage() { controller?.saveImage() }
    @objc private func closeAllPins() { PinnedImageController.closeAll() }
    @objc private func chooseOpacity(_ sender: NSMenuItem) { if let v = sender.representedObject as? CGFloat { controller?.setOpacity(v) } }
    @objc private func chooseSize(_ sender: NSMenuItem) { if let v = sender.representedObject as? CGFloat { controller?.setZoom(v) } }
}
