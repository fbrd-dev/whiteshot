import AppKit
import UniformTypeIdentifiers

/// Everything that can be done with a finished image: write it to disk, copy it, print it, share it.
/// Used both by the post-capture pipeline and by the editor's toolbar and menus.
@MainActor
enum Exporter {
    // MARK: Saving

    /// Saves into the configured folder using the filename pattern, without asking. Returns the file written.
    @discardableResult
    static func saveQuick(_ image: CGImage, scale: CGFloat, title: String = "", date: Date = Date(), over existing: URL? = nil, text: String? = nil) -> URL? {
        let format = Preferences.imageFormat
        let url: URL
        if let existing, ImageFormat(fileExtension: existing.pathExtension) != nil {
            url = existing
        } else {
            let context = FilenamePattern.Context(date: date, title: title, number: patternUsesNumber ? Preferences.nextFilenameNumber() : 1)
            let parts = FilenamePattern.relativePath(pattern: Preferences.filenamePattern, context: context)
            url = FilenamePattern.uniqueURL(in: Preferences.outputFolder, components: parts, fileExtension: format.fileExtension)
        }
        let fileFormat = ImageFormat(fileExtension: url.pathExtension) ?? format
        guard let data = ImageEncoder.data(for: image, format: fileFormat, quality: Preferences.jpegQuality, scale: scale, text: text) else {
            showError(String(localized: "The image could not be encoded."))
            return nil
        }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            showError(String(localized: "Could not save to \(url.path): \(error.localizedDescription)"))
            return nil
        }
    }

    // MARK: Dragging out of the editor

    /// Where the files made for dragging a picture out of an editor live: the temporary folder, tidied at launch.
    static var dragDirectory: URL { FileManager.default.temporaryDirectory.appendingPathComponent("WhiteShot Drag", isDirectory: true) }

    /// Writes `image` in the preferred format to its own folder inside `dragDirectory` and returns the file.
    static func writeDragFile(_ image: CGImage, scale: CGFloat, name: String, text: String? = nil) -> URL? {
        let format = Preferences.imageFormat
        guard let data = ImageEncoder.data(for: image, format: format, quality: Preferences.jpegQuality, scale: scale, text: text) else { return nil }
        let safe = name.replacingOccurrences(of: "/", with: "-").trimmingCharacters(in: .whitespaces)
        let folder = dragDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let url = folder.appendingPathComponent((safe.isEmpty ? "Screenshot" : safe) + "." + format.fileExtension)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    /// Removes drag files older than `age` seconds; other apps may still be reading a recent one.
    static func cleanUpDragFiles(olderThan age: TimeInterval = 24 * 3600) {
        let manager = FileManager.default
        guard let items = try? manager.contentsOfDirectory(at: dragDirectory, includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        for item in items {
            let modified = (try? item.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            if Date().timeIntervalSince(modified) > age { try? manager.removeItem(at: item) }
        }
    }

    private static var patternUsesNumber: Bool { Preferences.filenamePattern.contains("${NUM}") }

    struct SaveChoice {
        var url: URL
        /// Nil when the user chose the editable WhiteShot project format.
        var format: ImageFormat?
        var quality: Double
    }

    /// Shows a Save panel with a format picker. `allowProject` adds the editable `.whiteshot` format.
    static func runSavePanel(suggestedName: String, directory: URL? = nil, allowProject: Bool, from window: NSWindow?, completion: @escaping (SaveChoice?) -> Void) {
        let panel = NSSavePanel()
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.nameFieldStringValue = suggestedName
        panel.directoryURL = directory ?? Preferences.outputFolder
        let accessory = SavePanelAccessory(panel: panel, allowProject: allowProject, initial: Preferences.imageFormat)
        panel.accessoryView = accessory

        let finish: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { completion(nil); return }
            completion(SaveChoice(url: url, format: accessory.selectedFormat, quality: accessory.quality))
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: finish) } else { finish(panel.runModal()) }
    }

    // MARK: Clipboard

    static func copyToClipboard(_ image: CGImage, scale: CGFloat) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        if let png = ImageEncoder.data(for: image, format: .png, scale: scale) {
            pasteboard.setData(png, forType: .png)
        }
        // TIFF as well: some older apps only understand it.
        if let tiff = NSBitmapImageRep(cgImage: image).tiffRepresentation {
            pasteboard.setData(tiff, forType: .tiff)
        }
    }

    static func copyPath(_ url: URL) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(url.path, forType: .string)
    }

    // MARK: Printing

    static func printImage(_ image: CGImage, scale: CGFloat, from window: NSWindow?) {
        let nsImage = ImageEncoder.nsImage(for: image, scale: scale)
        let view = NSImageView(frame: NSRect(origin: .zero, size: nsImage.size))
        view.image = nsImage
        view.imageScaling = .scaleProportionallyUpOrDown
        let info = (NSPrintInfo.shared.copy() as? NSPrintInfo) ?? NSPrintInfo.shared
        info.isHorizontallyCentered = true
        info.isVerticallyCentered = true
        info.horizontalPagination = .fit
        info.verticalPagination = .fit
        let operation = NSPrintOperation(view: view, printInfo: info)
        operation.showsPrintPanel = true
        if let window {
            operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
        } else {
            operation.run()
        }
    }

    // MARK: Sharing

    /// Writes the image to a temporary PNG so sharing targets get a real, well-named file.
    static func temporaryFile(for image: CGImage, scale: CGFloat, name: String) -> URL? {
        guard let data = ImageEncoder.data(for: image, format: .png, scale: scale) else { return nil }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("WhiteShot", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safe = FilenamePattern.sanitize(component: name)
        let url = dir.appendingPathComponent(safe.isEmpty ? "WhiteShot" : safe).appendingPathExtension("png")
        do { try data.write(to: url, options: .atomic); return url } catch { return nil }
    }

    /// Shows the system Share sheet. Without an anchor view a tiny invisible window is placed at the mouse.
    static func share(_ image: CGImage, scale: CGFloat, name: String, relativeTo view: NSView?) {
        guard let file = temporaryFile(for: image, scale: scale, name: name) else { return }
        let picker = NSSharingServicePicker(items: [file])
        if let view {
            picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
            return
        }
        let anchor = NSPanel(contentRect: NSRect(origin: NSEvent.mouseLocation, size: NSSize(width: 1, height: 1)),
                             styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        anchor.backgroundColor = .clear
        anchor.isOpaque = false
        anchor.hasShadow = false
        anchor.level = .floating
        anchor.orderFrontRegardless()
        if let content = anchor.contentView {
            picker.show(relativeTo: content.bounds, of: content, preferredEdge: .minY)
        }
        // Keep the anchor alive while the share sheet is up.
        DispatchQueue.main.asyncAfter(deadline: .now() + 120) { anchor.orderOut(nil) }
    }

    static func email(_ image: CGImage, scale: CGFloat, name: String) {
        guard let file = temporaryFile(for: image, scale: scale, name: name) else { return }
        guard let service = NSSharingService(named: .composeEmail), service.canPerform(withItems: [file]) else {
            showError(String(localized: "No email app is set up on this Mac."))
            return
        }
        service.perform(withItems: [file])
    }

    // MARK: Feedback

    static func playCaptureSound() {
        let base = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/system/"
        for name in ["Screen Capture.aif", "Shutter.aif"] {
            if let sound = NSSound(contentsOfFile: base + name, byReference: true) { sound.play(); return }
        }
    }

    static func showError(_ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "WhiteShot")
        alert.informativeText = message
        alert.runModal()
    }
}

/// Format popup (and JPEG quality) shown under the file name in the Save panel.
@MainActor
final class SavePanelAccessory: NSView {
    private weak var panel: NSSavePanel?
    private let popup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let slider = NSSlider(value: 90, minValue: 10, maxValue: 100, target: nil, action: nil)
    private let qualityLabel = NSTextField(labelWithString: String(localized: "Quality"))
    private let formats: [ImageFormat]
    private let allowProject: Bool

    init(panel: NSSavePanel, allowProject: Bool, initial: ImageFormat) {
        self.panel = panel
        self.allowProject = allowProject
        self.formats = ImageFormat.allCases
        super.init(frame: NSRect(x: 0, y: 0, width: 360, height: 64))

        for format in formats { popup.addItem(withTitle: format.displayName) }
        if allowProject { popup.addItem(withTitle: String(localized: "WhiteShot Project (editable)")) }
        popup.selectItem(at: formats.firstIndex(of: initial) ?? 0)
        popup.target = self
        popup.action = #selector(formatChanged)
        slider.doubleValue = Double(UserDefaults.standard.integer(forKey: Preferences.Key.jpegQuality))

        let formatLabel = NSTextField(labelWithString: String(localized: "Format"))
        let top = NSStackView(views: [formatLabel, popup])
        let bottom = NSStackView(views: [qualityLabel, slider])
        for stack in [top, bottom] { stack.orientation = .horizontal; stack.spacing = 8 }
        slider.widthAnchor.constraint(greaterThanOrEqualToConstant: 160).isActive = true
        let column = NSStackView(views: [top, bottom])
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 8
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.centerXAnchor.constraint(equalTo: centerXAnchor),
            column.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        formatChanged()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    /// Nil means the editable project format.
    var selectedFormat: ImageFormat? {
        let index = popup.indexOfSelectedItem
        return index < formats.count ? formats[index] : nil
    }

    var quality: Double { slider.doubleValue / 100 }

    @objc private func formatChanged() {
        let format = selectedFormat
        let type = format?.utType ?? UTType("me.fbrd.whiteshot.project") ?? UTType(filenameExtension: ProjectFile.fileExtension) ?? .data
        panel?.allowedContentTypes = [type]
        let lossy = format?.isLossy ?? false
        slider.isHidden = !lossy
        qualityLabel.isHidden = !lossy
        // Keep the typed name but swap the extension to match the chosen format.
        if let panel {
            let base = (panel.nameFieldStringValue as NSString).deletingPathExtension
            let ext = format?.fileExtension ?? ProjectFile.fileExtension
            panel.nameFieldStringValue = base + "." + ext
        }
    }
}
