import AppKit

/// Sends a finished capture to wherever the user wants it: any combination of the editor, the
/// clipboard, a file, a Save As dialog, the printer, the Share sheet and email.
@MainActor
enum OutputPipeline {
    static func deliver(_ result: CaptureResult) {
        if Preferences.playSound { Exporter.playCaptureSound() }
        if Preferences.askEachTime {
            askWhereToSend(result)
        } else {
            run(result, to: Preferences.destinations)
        }
    }

    static func run(_ result: CaptureResult, to requested: Destinations) {
        // A capture must never vanish silently: with nothing selected, open it in the editor.
        let destinations = requested.isEmpty ? [.editor] : requested
        var savedURL: URL?

        if destinations.contains(.saveFile) {
            savedURL = Exporter.saveQuick(result.image, scale: result.scale, title: result.title, date: result.date)
            if let url = savedURL {
                Notifier.shared.post(title: String(localized: "Screenshot saved"), body: url.path, fileURL: url)
            }
        }

        if destinations.contains(.clipboard) {
            Exporter.copyToClipboard(result.image, scale: result.scale)
            if !destinations.contains(.saveFile) {
                Notifier.shared.post(title: String(localized: "Screenshot copied"), body: String(localized: "The image is on the clipboard."))
            }
        } else if Preferences.copyPathToClipboard, let url = savedURL {
            Exporter.copyPath(url)
        }

        if destinations.contains(.editor) {
            EditorWindowController.present(result, savedURL: savedURL)
        }

        if destinations.contains(.saveAs) {
            let name = FilenamePattern.expand(Preferences.filenamePattern, context: .init(date: result.date, title: result.title, number: 1))
                .replacingOccurrences(of: "/", with: "-")
            Exporter.runSavePanel(suggestedName: name + "." + Preferences.imageFormat.fileExtension, allowProject: false, from: nil) { choice in
                guard let choice, let data = ImageEncoder.data(for: result.image, format: choice.format ?? .png, quality: choice.quality, scale: result.scale) else { return }
                do {
                    try data.write(to: choice.url, options: .atomic)
                    Notifier.shared.post(title: String(localized: "Screenshot saved"), body: choice.url.path, fileURL: choice.url)
                } catch {
                    Exporter.showError(String(localized: "Could not save to \(choice.url.path): \(error.localizedDescription)"))
                }
            }
        }

        if destinations.contains(.pin) {
            PinnedImageController.pin(result.image, scale: result.scale, name: shareName(result), near: result.sourceFrame)
        }

        if destinations.contains(.print) { Exporter.printImage(result.image, scale: result.scale, from: nil) }
        if destinations.contains(.share) { Exporter.share(result.image, scale: result.scale, name: shareName(result), relativeTo: nil) }
        if destinations.contains(.email) { Exporter.email(result.image, scale: result.scale, name: shareName(result)) }
    }

    private static func shareName(_ result: CaptureResult) -> String {
        FilenamePattern.expand(Preferences.filenamePattern, context: .init(date: result.date, title: result.title, number: 1))
            .replacingOccurrences(of: "/", with: "-")
    }

    // MARK: Ask every time

    private final class ChoiceItem: NSMenuItem {
        var handler: (() -> Void)?
        @objc func fire() { handler?() }
    }

    private static func askWhereToSend(_ result: CaptureResult) {
        let menu = NSMenu()
        func add(_ title: String, _ symbol: String, _ destinations: Destinations) {
            let item = ChoiceItem(title: title, action: #selector(ChoiceItem.fire), keyEquivalent: "")
            item.target = item
            item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)
            item.handler = { run(result, to: destinations) }
            menu.addItem(item)
        }
        add(String(localized: "Open in Editor"), "pencil.and.scribble", .editor)
        add(String(localized: "Copy to Clipboard"), "doc.on.doc", .clipboard)
        add(String(localized: "Pin to Screen"), "pin", .pin)
        add(String(localized: "Save"), "square.and.arrow.down", .saveFile)
        add(String(localized: "Save As…"), "square.and.arrow.down.on.square", .saveAs)
        menu.addItem(.separator())
        add(String(localized: "Share…"), "square.and.arrow.up", .share)
        add(String(localized: "Email"), "envelope", .email)
        add(String(localized: "Print…"), "printer", .print)
        menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
    }
}
