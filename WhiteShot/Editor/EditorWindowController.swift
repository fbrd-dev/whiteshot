import AppKit
import SwiftUI

/// Keeps the picture centred when it is smaller than the visible area.
private final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposed: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposed)
        guard let document = documentView else { return rect }
        if document.frame.width < rect.width { rect.origin.x = (document.frame.width - rect.width) / 2 }
        if document.frame.height < rect.height { rect.origin.y = (document.frame.height - rect.height) / 2 }
        return rect
    }
}

private extension NSToolbarItem.Identifier {
    static let save = NSToolbarItem.Identifier("whiteshot.save")
    static let copyImage = NSToolbarItem.Identifier("whiteshot.copy")
    static let shareImage = NSToolbarItem.Identifier("whiteshot.share")
    static let recognizeText = NSToolbarItem.Identifier("whiteshot.recognizeText")
    static let undoItem = NSToolbarItem.Identifier("whiteshot.undo")
    static let redoItem = NSToolbarItem.Identifier("whiteshot.redo")
    static let zoomMenu = NSToolbarItem.Identifier("whiteshot.zoom")
}

/// One editor window per screenshot. Any number can be open at the same time.
@MainActor
final class EditorWindowController: NSWindowController, NSWindowDelegate, NSToolbarDelegate, NSToolbarItemValidation, NSMenuItemValidation,
                                     EditorCommands {
    private(set) static var controllers: [EditorWindowController] = []
    private static var cascadePoint = NSPoint.zero
    private static let zoomSteps: [CGFloat] = [0.1, 0.25, 0.33, 0.5, 0.67, 0.75, 1, 1.5, 2, 3, 4, 6, 8, 12, 16]

    let model: EditorModel
    private let canvas: CanvasView
    private let scrollView = NSScrollView()
    private var fitMode = false
    private var allowCloseWithoutPrompt = false
    private weak var shareButton: NSButton?
    private weak var recognizeButton: NSButton?
    private var recognitionTask: Task<Void, Never>?
    private var barHeight: NSLayoutConstraint?
    private var undoObservers: [NSObjectProtocol] = []

    // MARK: - Opening

    /// Opens a new editor for a fresh capture. `savedURL` is set when the capture was also written to disk.
    @discardableResult
    static func present(_ capture: CaptureResult, savedURL: URL?) -> EditorWindowController {
        let name = savedURL?.lastPathComponent
            ?? FilenamePattern.expand(Preferences.filenamePattern, context: .init(date: capture.date, title: capture.title, number: 1))
                .replacingOccurrences(of: "/", with: "-")
        let model = EditorModel(image: capture.image, scale: capture.scale, displayName: name)
        model.captureDate = capture.date
        model.fileURL = savedURL
        return show(model)
    }

    /// Opens an image file, or a `.whiteshot` project with its annotations still editable.
    @discardableResult
    static func open(fileURL url: URL) -> Bool {
        // Already open? Bring that window forward instead of duplicating it.
        if let existing = controllers.first(where: { $0.model.fileURL == url }) {
            existing.window?.makeKeyAndOrderFront(nil)
            return true
        }
        if url.pathExtension.lowercased() == ProjectFile.fileExtension {
            guard let data = try? Data(contentsOf: url), let project = ProjectFile.decode(data) else {
                Exporter.showError(String(localized: "“\(url.lastPathComponent)” is not a valid WhiteShot project."))
                return false
            }
            let model = EditorModel(image: project.image, scale: project.scale, displayName: url.lastPathComponent)
            model.loadAnnotations(project.annotations)
            model.fileURL = url
            show(model)
            return true
        }
        guard let decoded = ImageEncoder.decode(contentsOf: url) else {
            Exporter.showError(String(localized: "“\(url.lastPathComponent)” could not be opened as an image."))
            return false
        }
        // Not tied to the original: saving goes to the output folder instead of overwriting it.
        show(EditorModel(image: decoded.image, scale: decoded.scale, displayName: url.lastPathComponent))
        return true
    }

    @discardableResult
    static func openFromClipboard() -> Bool {
        guard let image = CanvasView.imageFromPasteboard(.general) else {
            Exporter.showError(String(localized: "There is no image on the clipboard."))
            return false
        }
        show(EditorModel(image: image, scale: 1, displayName: String(localized: "Clipboard")))
        return true
    }

    @discardableResult
    private static func show(_ model: EditorModel) -> EditorWindowController {
        let controller = EditorWindowController(model: model)
        controllers.append(controller)
        controller.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        controller.window?.makeKeyAndOrderFront(nil)
        AppPolicy.update()
        return controller
    }

    // MARK: - Setup

    init(model: EditorModel) {
        self.model = model
        self.canvas = CanvasView(model: model)

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable],
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        window.toolbarStyle = .unified
        window.titleVisibility = .visible
        super.init(window: window)

        window.delegate = self
        window.title = model.displayName
        buildLayout(in: window)
        buildToolbar(for: window)
        sizeWindowToFit(window)

        model.onChange = { [weak self] in self?.modelChanged() }
        // Keep the Undo / Redo buttons in step with what can actually be undone or redone.
        for name in [Notification.Name.NSUndoManagerDidCloseUndoGroup, .NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange] {
            undoObservers.append(NotificationCenter.default.addObserver(forName: name, object: model.undoManager, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.updateUndoRedoState() }
            })
        }
        canvas.onMagnify = { [weak self] factor, anchor in
            guard let self else { return }
            self.fitMode = false
            self.setZoom(self.model.zoom * factor, anchor: anchor)
        }
        updateTitle()
        updateUndoRedoState()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func buildLayout(in window: NSWindow) {
        let root = NSView()
        window.contentView = root

        scrollView.contentView = CenteringClipView()
        scrollView.documentView = canvas
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .underPageBackgroundColor
        scrollView.borderType = .noBorder
        scrollView.wantsLayer = true
        scrollView.layer?.cornerRadius = 10
        scrollView.layer?.masksToBounds = true
        scrollView.layer?.borderWidth = 0.5
        scrollView.layer?.borderColor = NSColor.separatorColor.cgColor
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let palette = NSHostingView(rootView: ToolPaletteView(model: model, commands: self))
        let bar = NSHostingView(rootView: PropertyBarView(model: model, commands: self))
        let status = NSHostingView(rootView: StatusBarView(model: model, commands: self))
        palette.translatesAutoresizingMaskIntoConstraints = false
        bar.translatesAutoresizingMaskIntoConstraints = false
        status.translatesAutoresizingMaskIntoConstraints = false
        // The palette's hosting view spans the whole column beside the canvas, and the SwiftUI content inside
        // adapts to that height (see PaletteDensity). Content that overflows its hosting view would still draw,
        // but the overflowing buttons would stop receiving clicks, so it must never be taller than the column.
        palette.sizingOptions = []
        bar.sizingOptions = []
        status.sizingOptions = []
        palette.setContentHuggingPriority(.required, for: .horizontal)

        root.addSubview(scrollView)
        root.addSubview(palette)
        root.addSubview(bar)
        root.addSubview(status)

        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: root.topAnchor, constant: 6),
            bar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            bar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            bar.heightAnchor.constraint(equalToConstant: 42).withStored(in: &barHeight),

            status.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            status.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            status.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            status.heightAnchor.constraint(equalToConstant: 26),

            palette.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            palette.widthAnchor.constraint(equalToConstant: 64),
            palette.topAnchor.constraint(equalTo: scrollView.topAnchor),
            palette.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),

            scrollView.topAnchor.constraint(equalTo: bar.bottomAnchor, constant: 4),
            scrollView.leadingAnchor.constraint(equalTo: palette.trailingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10),
            scrollView.bottomAnchor.constraint(equalTo: status.topAnchor),
        ])
    }

    // Space above and below the canvas column, and the margin kept around the palette.
    private static let chromeAbove: CGFloat = 6 + 42 + 4
    private static let chromeBelow: CGFloat = 26
    private static let paletteMargin: CGFloat = 16

    /// Smallest window height at which even the compact palette fits whole.
    static var minimumContentHeight: CGFloat {
        ToolPaletteView.contentHeight(for: .compact) + paletteMargin + chromeAbove + chromeBelow
    }

    /// Window height at which the regular palette fits whole; small screenshots open at least this tall.
    static var comfortableContentHeight: CGFloat {
        ToolPaletteView.contentHeight(for: .regular) + paletteMargin + chromeAbove + chromeBelow
    }

    /// Picks the palette density from the height of the column it sits in.
    func updatePaletteDensity() {
        let available = scrollView.frame.height
        guard available > 0 else { return }
        let density: PaletteDensity
        if available >= ToolPaletteView.contentHeight(for: .regular) + Self.paletteMargin { density = .regular }
        else if available >= ToolPaletteView.contentHeight(for: .compact) + Self.paletteMargin { density = .compact }
        else { density = .scrolling }
        if model.paletteDensity != density { model.paletteDensity = density }
    }

    private func sizeWindowToFit(_ window: NSWindow) {
        let screen = NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let backing = screen?.backingScaleFactor ?? 2
        let chrome = NSSize(width: 64 + 10 + 24, height: Self.chromeAbove + Self.chromeBelow + 6 + 24)
        let natural = NSSize(width: model.imageSize.width / backing + chrome.width, height: model.imageSize.height / backing + chrome.height)
        let maxSize = NSSize(width: visible.width * 0.9, height: visible.height * 0.88)
        // Never smaller than the palette needs, so a small screenshot does not cut the tool palette off.
        window.contentMinSize = NSSize(width: 760, height: min(Self.minimumContentHeight, maxSize.height))
        let wantedHeight = max(natural.height, Self.comfortableContentHeight)
        let size = NSSize(width: max(window.contentMinSize.width, min(natural.width, maxSize.width)),
                          height: max(window.contentMinSize.height, min(wantedHeight, maxSize.height)))
        window.setContentSize(size)
        window.center()

        if Self.cascadePoint == .zero {
            Self.cascadePoint = NSPoint(x: window.frame.minX, y: window.frame.maxY)
        } else {
            Self.cascadePoint = window.cascadeTopLeft(from: Self.cascadePoint)
        }

        window.layoutIfNeeded()
        updatePaletteDensity()
        model.zoom = 1
        canvas.syncFrameSize()
        if natural.width > maxSize.width || natural.height > maxSize.height { zoomToFit() }
    }

    // MARK: - Toolbar

    private func buildToolbar(for window: NSWindow) {
        let toolbar = NSToolbar(identifier: "WhiteShotEditorToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [.recognizeText, .space, .save, .copyImage, .shareImage, .flexibleSpace, .undoItem, .redoItem, .zoomMenu]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        func symbol(_ name: String, _ label: String) -> NSImage? {
            NSImage(systemSymbolName: name, accessibilityDescription: label)
        }
        switch identifier {
        case .save:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = String(localized: "Save")
            item.toolTip = String(localized: "Save (⌘S)")
            item.image = symbol("square.and.arrow.down", item.label)
            item.target = self
            item.action = #selector(saveDocument(_:))
            return item
        case .copyImage:
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = String(localized: "Copy")
            item.toolTip = String(localized: "Copy Image to Clipboard (⇧⌘C)")
            item.image = symbol("doc.on.doc", item.label)
            item.target = self
            item.action = #selector(copyImage(_:))
            return item
        case .recognizeText:
            // A plain button too, so it can show that text recognition is on.
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = String(localized: "Recognize Text")
            item.toolTip = String(localized: "Recognize Text (⇧⌘T)")
            let button = NSButton(image: symbol("text.viewfinder", item.label) ?? NSImage(), target: self, action: #selector(toggleTextRecognition(_:)))
            button.bezelStyle = .texturedRounded
            button.setButtonType(.pushOnPushOff)
            button.toolTip = item.toolTip
            recognizeButton = button
            item.view = button
            return item
        case .shareImage:
            // A plain button instead of NSSharingServicePickerToolbarItem: that item asks its delegate for
            // the shared items whenever the toolbar validates (e.g. each time the window becomes key),
            // which would flatten and re-encode the image over and over and interrupt text editing.
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = String(localized: "Share")
            item.toolTip = String(localized: "Share…")
            let button = NSButton(image: symbol("square.and.arrow.up", item.label) ?? NSImage(), target: self, action: #selector(shareDocument(_:)))
            button.bezelStyle = .texturedRounded
            button.toolTip = item.toolTip
            shareButton = button
            item.view = button
            return item
        case .undoItem, .redoItem:
            // Two ordinary items, validated by `validateToolbarItem`, so the toolbar itself greys them out.
            let isUndo = identifier == .undoItem
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = isUndo ? String(localized: "Undo") : String(localized: "Redo")
            item.toolTip = isUndo ? String(localized: "Undo (⌘Z)") : String(localized: "Redo (⇧⌘Z)")
            item.image = symbol(isUndo ? "arrow.uturn.backward" : "arrow.uturn.forward", item.label)
            item.target = self
            item.action = isUndo ? #selector(undo(_:)) : #selector(redo(_:))
            return item
        case .zoomMenu:
            let item = NSMenuToolbarItem(itemIdentifier: identifier)
            item.label = String(localized: "Zoom")
            item.toolTip = String(localized: "Zoom")
            item.image = symbol("plus.magnifyingglass", item.label)
            let menu = NSMenu()
            menu.addItem(withTitle: String(localized: "Zoom In"), action: #selector(zoomInAction(_:)), keyEquivalent: "").target = self
            menu.addItem(withTitle: String(localized: "Zoom Out"), action: #selector(zoomOutAction(_:)), keyEquivalent: "").target = self
            menu.addItem(withTitle: String(localized: "Actual Size"), action: #selector(actualSizeAction(_:)), keyEquivalent: "").target = self
            menu.addItem(withTitle: String(localized: "Fit to Window"), action: #selector(fitAction(_:)), keyEquivalent: "").target = self
            item.menu = menu
            item.showsIndicator = false
            return item
        default:
            return nil
        }
    }

    // MARK: - Model changes

    /// Asks the toolbar to re-check Undo and Redo right away (it also does so after user events).
    private func updateUndoRedoState() {
        window?.toolbar?.validateVisibleItems()
    }

    /// Undo / Redo availability as the toolbar shows it (exposed for tests).
    var toolbarUndoRedoEnabled: (undo: Bool, redo: Bool)? {
        guard let items = window?.toolbar?.items,
              let undo = items.first(where: { $0.itemIdentifier == .undoItem }),
              let redo = items.first(where: { $0.itemIdentifier == .redoItem }) else { return nil }
        return (undo.isEnabled, redo.isEnabled)
    }

    func validateToolbarItem(_ item: NSToolbarItem) -> Bool {
        switch item.itemIdentifier {
        case .undoItem: return model.undoManager.canUndo && !model.isTextMode
        case .redoItem: return model.undoManager.canRedo && !model.isTextMode
        default: return true
        }
    }

    private func modelChanged() {
        updateUndoRedoState()
        canvas.modelChanged()
        updateTitle()
        updateRecognizeButton()
        updateBarHeight()
        // Leaving text recognition (or changing the picture) while Vision is still working abandons that run.
        if model.textMode != .recognizing, recognitionTask != nil { recognitionTask?.cancel(); recognitionTask = nil }
    }

    /// The property bar grows a second row while text recognition has something to offer.
    private func updateBarHeight() {
        let wanted = propertyBarHeight(for: model)
        if barHeight?.constant != wanted { barHeight?.constant = wanted }
    }

    private func updateRecognizeButton() {
        guard let button = recognizeButton else { return }
        let on = model.isTextMode
        if (button.state == .on) != on { button.state = on ? .on : .off }
        button.contentTintColor = on ? .controlAccentColor : nil
    }

    /// Whether the Recognize Text button shows as switched on (exposed for tests).
    var recognizeButtonIsOn: Bool? { recognizeButton.map { $0.state == .on } }

    private func updateTitle() {
        guard let window else { return }
        window.title = model.fileURL?.lastPathComponent ?? model.displayName
        window.representedURL = model.fileURL
        window.isDocumentEdited = model.isDirty
    }

    // MARK: - EditorCommands

    func selectTool(_ tool: EditorTool) {
        canvas.selectTool(tool)
        window?.makeFirstResponder(canvas)
    }

    // MARK: - Text recognition

    /// Turns text recognition on or off. On: the Select tool is chosen, the other tools are locked, and Vision reads the
    /// picture as it looks right now (censored areas included as censored). Off: the overlay goes away.
    @objc func toggleTextRecognition(_ sender: Any?) {
        if model.isTextMode {
            model.endTextRecognition()
        } else {
            canvas.endTextEditing(commit: true)
            if let generation = model.beginTextRecognition() {
                let image = model.flattenedImage()
                recognitionTask = Task { [weak self] in
                    let result: Result<RecognizedText, Error>
                    do { result = .success(try await TextRecognizer.recognize(in: image)) } catch { result = .failure(error) }
                    guard !Task.isCancelled else { return }
                    self?.model.finishTextRecognition(result, generation: generation)
                }
            }
        }
        updateRecognizeButton()
        window?.invalidateCursorRects(for: canvas)
        window?.makeFirstResponder(canvas)
    }

    func endTextRecognition() {
        model.endTextRecognition()
        window?.makeFirstResponder(canvas)
    }

    func copyAllRecognizedText() { canvas.copyRecognizedText(all: true) }

    func pinImage() {
        canvas.endTextEditing(commit: true)
        PinnedImageController.pin(model.flattenedImage(), scale: model.scale, name: baseName)
    }

    @objc func pinDocument(_ sender: Any?) { pinImage() }

    func prepareDragFile() -> (url: URL, preview: NSImage)? {
        canvas.endTextEditing(commit: true)
        let image = model.flattenedImage()
        guard let url = Exporter.writeDragFile(image, scale: model.scale, name: baseName, text: textToSave) else { return nil }
        return (url, ImageEncoder.nsImage(for: image, scale: model.scale))
    }
    func copyRecognizedSelection() { canvas.copyRecognizedText() }

    /// Opens the picked code's address in the browser or mail app. Only web and mail links can be opened this way.
    func openSelectedCode() {
        if let url = model.selectedCode?.openableURL { NSWorkspace.shared.open(url) }
    }

    /// Test hook: the canvas that shows the text.
    var canvasForTesting: CanvasView { canvas }

    func applyCrop() {
        guard let rect = model.cropRect, rect.width >= 1, rect.height >= 1 else { return }
        model.crop(to: rect)
        model.tool = .select
        window?.invalidateCursorRects(for: canvas)
        window?.makeFirstResponder(canvas)
        if fitMode { zoomToFit() }
    }

    func cancelCrop() {
        model.cropRect = nil
        model.tool = .select
        window?.invalidateCursorRects(for: canvas)
        model.refresh()
    }

    // MARK: - Zoom

    func setZoom(_ requested: CGFloat, anchor: NSPoint? = nil) {
        let zoom = min(16, max(0.05, requested))
        let clip = scrollView.contentView
        let before = canvas.pointsPerPixel
        let anchorInCanvas = anchor ?? canvas.convert(NSPoint(x: clip.bounds.midX, y: clip.bounds.midY), from: clip)
        let imagePoint = CGPoint(x: anchorInCanvas.x / before, y: anchorInCanvas.y / before)
        let offset = CGPoint(x: anchorInCanvas.x - clip.bounds.minX, y: anchorInCanvas.y - clip.bounds.minY)

        model.zoom = zoom
        canvas.syncFrameSize()
        let after = canvas.pointsPerPixel
        // `scroll(to:)` does not apply the clip view's constraint, which is what keeps a small picture centred.
        let wanted = NSRect(x: imagePoint.x * after - offset.x, y: imagePoint.y * after - offset.y, width: clip.bounds.width, height: clip.bounds.height)
        clip.scroll(to: clip.constrainBoundsRect(wanted).origin)
        scrollView.reflectScrolledClipView(clip)
        canvas.needsDisplay = true
    }

    func zoomIn() {
        fitMode = false
        setZoom(Self.zoomSteps.first(where: { $0 > model.zoom + 0.001 }) ?? 16)
    }

    func zoomOut() {
        fitMode = false
        setZoom(Self.zoomSteps.last(where: { $0 < model.zoom - 0.001 }) ?? 0.1)
    }

    func zoomToActualSize() {
        fitMode = false
        setZoom(1)
    }

    func zoomToFit() {
        fitMode = true
        let available = scrollView.contentSize
        guard available.width > 0, available.height > 0 else { return }
        let backing = window?.backingScaleFactor ?? 2
        let fitWidth = (available.width - 24) * backing / model.imageSize.width
        let fitHeight = (available.height - 24) * backing / model.imageSize.height
        setZoom(min(1, fitWidth, fitHeight))
    }

    func windowDidResize(_ notification: Notification) {
        updatePaletteDensity()
        if fitMode { zoomToFit() }
    }

    @objc private func zoomInAction(_ sender: Any?) { zoomIn() }
    @objc private func zoomOutAction(_ sender: Any?) { zoomOut() }
    @objc private func actualSizeAction(_ sender: Any?) { zoomToActualSize() }
    @objc private func fitAction(_ sender: Any?) { zoomToFit() }

    // MARK: - File actions (reached from the menu through the responder chain)

    /// Hosting views of the SwiftUI chrome, exposed for layout tests.
    var chromeViews: [NSView] { window?.contentView?.subviews ?? [] }

    private var baseName: String { (model.displayName as NSString).deletingPathExtension }

    @objc func saveDocument(_ sender: Any?) {
        canvas.endTextEditing(commit: true)
        if let url = model.fileURL {
            if write(to: url, asProject: url.pathExtension.lowercased() == ProjectFile.fileExtension, format: nil, quality: Preferences.jpegQuality) {
                didSave(url)
            }
        } else if let url = Exporter.saveQuick(model.flattenedImage(), scale: model.scale, title: "", date: model.captureDate, text: textToSave) {
            model.fileURL = url
            didSave(url)
        }
    }

    @objc func saveDocumentAs(_ sender: Any?) {
        canvas.endTextEditing(commit: true)
        guard let window else { return }
        Exporter.runSavePanel(suggestedName: baseName + "." + Preferences.imageFormat.fileExtension, allowProject: true, from: window) { [weak self] choice in
            guard let self, let choice else { return }
            let isProject = choice.format == nil
            if self.write(to: choice.url, asProject: isProject, format: choice.format, quality: choice.quality) {
                self.model.fileURL = choice.url
                self.didSave(choice.url)
            }
        }
    }

    /// Recognised text that goes into a saved image: only if the user has run Recognize Text on this very picture.
    private var textToSave: String? { Preferences.embedRecognizedText ? model.recognizedTextForExport : nil }

    func write(to url: URL, asProject: Bool, format: ImageFormat?, quality: Double) -> Bool {
        let data: Data?
        if asProject {
            data = ProjectFile.encode(image: model.baseImage, scale: model.scale, annotations: model.annotations)
        } else {
            let resolved = format ?? ImageFormat(fileExtension: url.pathExtension) ?? Preferences.imageFormat
            data = ImageEncoder.data(for: model.flattenedImage(), format: resolved, quality: quality, scale: model.scale, text: textToSave)
        }
        guard let data else {
            Exporter.showError(String(localized: "The image could not be encoded."))
            return false
        }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            Exporter.showError(String(localized: "Could not save to \(url.path): \(error.localizedDescription)"))
            return false
        }
    }

    private func didSave(_ url: URL) {
        model.displayName = url.lastPathComponent
        model.markClean()
        updateTitle()
        if Preferences.copyPathToClipboard { Exporter.copyPath(url) }
        Notifier.shared.post(title: String(localized: "Saved"), body: url.path, fileURL: url)
    }

    @objc func copyImage(_ sender: Any?) {
        canvas.endTextEditing(commit: true)
        Exporter.copyToClipboard(model.flattenedImage(), scale: model.scale)
        model.markClean()
        updateTitle()
        Notifier.shared.post(title: String(localized: "Copied"), body: String(localized: "The image is on the clipboard."))
    }

    @objc func copyImagePath(_ sender: Any?) {
        if let url = model.fileURL { Exporter.copyPath(url) }
    }

    @objc func revealInFinder(_ sender: Any?) {
        if let url = model.fileURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
    }

    @objc func printDocument(_ sender: Any?) {
        canvas.endTextEditing(commit: true)
        Exporter.printImage(model.flattenedImage(), scale: model.scale, from: window)
    }

    @objc func shareDocument(_ sender: Any?) {
        canvas.endTextEditing(commit: true)
        Exporter.share(model.flattenedImage(), scale: model.scale, name: baseName, relativeTo: shareButton ?? window?.contentView)
    }

    @objc func emailDocument(_ sender: Any?) {
        canvas.endTextEditing(commit: true)
        Exporter.email(model.flattenedImage(), scale: model.scale, name: baseName)
    }

    // MARK: - Edit actions

    @objc func undo(_ sender: Any?) {
        canvas.endTextEditing(commit: true)
        model.undo()
    }

    @objc func redo(_ sender: Any?) {
        canvas.endTextEditing(commit: true)
        model.redo()
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { model.undoManager }

    // MARK: - Image menu

    @objc func chooseCropTool(_ sender: Any?) { selectTool(.crop) }
    @objc func autoCropImage(_ sender: Any?) { model.autoCrop(); if fitMode { zoomToFit() } }
    @objc func rotateClockwise(_ sender: Any?) { model.rotate(clockwise: true); if fitMode { zoomToFit() } }
    @objc func rotateCounterClockwise(_ sender: Any?) { model.rotate(clockwise: false); if fitMode { zoomToFit() } }
    @objc func flipHorizontal(_ sender: Any?) { model.flip(horizontal: true) }
    @objc func flipVertical(_ sender: Any?) { model.flip(horizontal: false) }
    @objc func resizeImage(_ sender: Any?) { if let window { EffectSheets.resize(model: model, window: window) } }
    @objc func changeCanvasSize(_ sender: Any?) { if let window { EffectSheets.canvasSize(model: model, window: window) } }
    @objc func addDropShadow(_ sender: Any?) { if let window { EffectSheets.dropShadow(model: model, window: window) } }
    @objc func addBorder(_ sender: Any?) { if let window { EffectSheets.border(model: model, window: window) } }
    @objc func addTornEdge(_ sender: Any?) { if let window { EffectSheets.tornEdge(model: model, window: window) } }
    @objc func adjustColors(_ sender: Any?) { if let window { EffectSheets.adjustColors(model: model, window: window) } }
    @objc func convertToGrayscale(_ sender: Any?) { model.applyFilter(String(localized: "Grayscale")) { ImageFilters.grayscale($0) } }
    @objc func invertColors(_ sender: Any?) { model.applyFilter(String(localized: "Invert Colors")) { ImageFilters.invert($0) } }

    @objc func insertImageFromFile(_ sender: Any?) {
        guard let window else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let decoded = ImageEncoder.decode(contentsOf: url) else { return }
            self?.canvas.insertImage(decoded.image, at: nil)
        }
    }

    @objc func zoomInMenu(_ sender: Any?) { zoomIn() }
    @objc func zoomOutMenu(_ sender: Any?) { zoomOut() }
    @objc func zoomActualMenu(_ sender: Any?) { zoomToActualSize() }
    @objc func zoomFitMenu(_ sender: Any?) { zoomToFit() }

    @objc func chooseTool(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let tool = EditorTool(rawValue: raw) { selectTool(tool) }
    }

    /// Commands that change the picture or its undo history; they are off while text recognition is on.
    private static let lockedInTextMode: Set<Selector> = [
        #selector(EditorWindowController.undo(_:)), #selector(EditorWindowController.redo(_:)),
        #selector(EditorWindowController.chooseCropTool(_:)), #selector(EditorWindowController.autoCropImage(_:)),
        #selector(EditorWindowController.rotateClockwise(_:)), #selector(EditorWindowController.rotateCounterClockwise(_:)),
        #selector(EditorWindowController.flipHorizontal(_:)), #selector(EditorWindowController.flipVertical(_:)),
        #selector(EditorWindowController.resizeImage(_:)), #selector(EditorWindowController.changeCanvasSize(_:)),
        #selector(EditorWindowController.addDropShadow(_:)), #selector(EditorWindowController.addBorder(_:)),
        #selector(EditorWindowController.addTornEdge(_:)), #selector(EditorWindowController.adjustColors(_:)),
        #selector(EditorWindowController.convertToGrayscale(_:)), #selector(EditorWindowController.invertColors(_:)),
        #selector(EditorWindowController.insertImageFromFile(_:)),
    ]

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        if model.isTextMode, let action = item.action, Self.lockedInTextMode.contains(action) { return false }
        switch item.action {
        case #selector(toggleTextRecognition(_:)):
            item.state = model.isTextMode ? .on : .off
            return true
        case #selector(undo(_:)):
            item.title = model.undoManager.canUndo ? model.undoManager.undoMenuItemTitle : String(localized: "Undo")
            return model.undoManager.canUndo
        case #selector(redo(_:)):
            item.title = model.undoManager.canRedo ? model.undoManager.redoMenuItemTitle : String(localized: "Redo")
            return model.undoManager.canRedo
        case #selector(copyImagePath(_:)), #selector(revealInFinder(_:)):
            return model.fileURL != nil
        case #selector(chooseTool(_:)):
            if let raw = item.representedObject as? String {
                item.state = model.tool.rawValue == raw ? .on : .off
                if let tool = EditorTool(rawValue: raw) { return model.isToolEnabled(tool) }
            }
            return true
        default:
            return true
        }
    }

    #if DEBUG
    /// Development aid: puts the first annotation of `kind` into in-place text editing, as a double-click would.
    func debugBeginTextEditing(of kind: AnnotationKind) {
        guard let match = model.annotations.first(where: { $0.kind == kind }) else { return }
        canvas.beginTextEditing(id: match.id, isNew: false, before: nil)
    }
    #endif

    // MARK: - Closing

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        canvas.endTextEditing(commit: true)
        guard model.isDirty, !allowCloseWithoutPrompt else { return true }
        let alert = NSAlert()
        alert.messageText = String(localized: "Do you want to save the changes to “\(model.displayName)”?")
        alert.informativeText = String(localized: "Your changes will be lost if you don’t save them.")
        alert.addButton(withTitle: String(localized: "Save"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.addButton(withTitle: String(localized: "Don’t Save"))
        alert.beginSheetModal(for: sender) { [weak self] response in
            guard let self else { return }
            switch response {
            case .alertFirstButtonReturn:
                self.saveDocument(nil)
                if !self.model.isDirty { self.closeNow() }
            case .alertThirdButtonReturn:
                self.closeNow()
            default:
                break
            }
        }
        return false
    }

    private func closeNow() {
        allowCloseWithoutPrompt = true
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        recognitionTask?.cancel()
        recognitionTask = nil
        undoObservers.forEach(NotificationCenter.default.removeObserver)
        undoObservers.removeAll()
        model.onChange = nil
        canvas.onMagnify = nil
        Self.controllers.removeAll { $0 === self }
        DispatchQueue.main.async { AppPolicy.update() }
    }
}

private extension NSLayoutConstraint {
    /// Keeps a reference to the constraint while handing it back, so it can go straight into `activate`.
    func withStored(in slot: inout NSLayoutConstraint?) -> NSLayoutConstraint {
        slot = self
        return self
    }
}

/// Shows the Dock icon and menu bar while a real window is open, and hides them again afterwards,
/// so WhiteShot behaves like a menu-bar utility in between.
@MainActor
enum AppPolicy {
    static func update() {
        let hasWindow = NSApp.windows.contains { $0.isVisible && $0.styleMask.contains(.titled) && !($0 is NSPanel) }
        let wanted: NSApplication.ActivationPolicy = hasWindow ? .regular : .accessory
        if NSApp.activationPolicy() != wanted {
            NSApp.setActivationPolicy(wanted)
            if wanted == .regular { MenuBarHandover.activate() }
        }
    }
}

/// Gets the menu bar for the app once it has turned from a menu-bar utility into a regular app.
///
/// A menu-bar-only app does not own the menu bar, even while it is the active app. The capture overlay activates WhiteShot
/// while it is still one, so by the time the editor opens the app is already active and activating it again does nothing:
/// the menus (File, Edit, …) exist but have no place in the menu bar, and the menu bar still belongs to the previous app,
/// until something else activates WhiteShot afresh (opening Settings from the status item did). So the active app is handed
/// to the Dock for a moment and taken back, which is a real change of the front app, made while WhiteShot is a regular app.
@MainActor
private final class MenuBarHandover {
    private static var current: MenuBarHandover?
    private var observer: NSObjectProtocol?

    static func activate() {
        guard NSApp.isActive, current == nil,
              let dock = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first else {
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let handover = MenuBarHandover()
        current = handover
        handover.observer = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { note in
            let activated = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            if activated?.bundleIdentifier == "com.apple.dock" { MainActor.assumeIsolated { handover.takeBack() } }
        }
        dock.activate()
        // If the Dock never reports back, do not leave the app inactive.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { handover.takeBack() }
    }

    private func takeBack() {
        guard Self.current === self else { return }
        Self.current = nil
        if let observer { NSWorkspace.shared.notificationCenter.removeObserver(observer) }
        observer = nil
        NSApp.activate(ignoringOtherApps: true)
    }
}
