import AppKit

/// "Grab Text": select a region of the screen, and whatever text or QR codes are in it go to the clipboard. No editor, no file.
@MainActor
enum TextGrab {
    private static var task: Task<Void, Never>?

    /// Reads `image` and copies the result. Shows a small message while it works and when it is done.
    /// `pasteboard` and `completion` are for tests and the debug harness; normally the text goes to the general pasteboard.
    static func run(on image: CGImage, pasteboard: NSPasteboard? = nil, completion: ((String?) -> Void)? = nil) {
        task?.cancel()
        #if DEBUG
        // The synthetic overlay of the debug harness must never touch the real clipboard.
        let target = pasteboard ?? (ActivationProbe.fakeOverlayRequested ? NSPasteboard(name: NSPasteboard.Name("me.fbrd.whiteshot.debug.grab")) : .general)
        #else
        let target = pasteboard ?? .general
        #endif
        let wantText = Preferences.textGrabWantsText
        let wantCodes = Preferences.textGrabWantsCodes
        guard wantText || wantCodes else {
            GrabHUD.shared.show(String(localized: "Turn on text or QR codes in Settings › Text"), symbol: "exclamationmark.circle", dismissAfter: 2.5)
            completion?(nil)
            return
        }
        GrabHUD.shared.show(String(localized: "Recognizing text…"), symbol: "text.viewfinder", busy: true)
        task = Task { @MainActor in
            do {
                let result = try await TextRecognizer.recognize(in: image, text: wantText, codes: wantCodes)
                guard !Task.isCancelled else { return }
                let string = TextRecognizer.clipboardString(from: result, text: wantText, codes: wantCodes)
                guard !string.isEmpty else {
                    GrabHUD.shared.show(String(localized: "No text found"), symbol: "text.viewfinder", dismissAfter: 1.8)
                    completion?(nil)
                    return
                }
                copy(string, to: target)
                completion?(string)
                #if DEBUG
                if ActivationProbe.fakeOverlayRequested { print("GRAB e2e: \(string.replacingOccurrences(of: "\n", with: " | "))"); fflush(stdout) }
                #endif
                if Preferences.playSound { Exporter.playCaptureSound() }
                GrabHUD.shared.show(summary(of: result, text: wantText, codes: wantCodes, string: string), symbol: "doc.on.clipboard", dismissAfter: 1.8)
            } catch {
                guard !Task.isCancelled else { return }
                GrabHUD.shared.show(String(localized: "Text recognition failed"), symbol: "exclamationmark.triangle", dismissAfter: 2.5)
                completion?(nil)
            }
        }
    }

    static func copy(_ string: String, to pasteboard: NSPasteboard = .general) {
        pasteboard.clearContents()
        pasteboard.setString(string, forType: .string)
    }

    /// What the confirmation says was copied.
    static func summary(of result: RecognizedText, text: Bool, codes: Bool, string: String) -> String {
        let hasText = text && !result.lines.isEmpty
        let hasCodes = codes && !result.codes.isEmpty
        if hasText && hasCodes { return String(localized: "Copied text and QR code") }
        if hasCodes { return result.codes.count == 1 ? String(localized: "Copied QR code content") : String(localized: "Copied \(result.codes.count) codes") }
        return String(localized: "Copied \(string.count) characters")
    }
}

/// A small, click-through message in the middle of the screen: the feedback for a text grab, which has no window of its own.
@MainActor
final class GrabHUD {
    static let shared = GrabHUD()

    private var panel: NSPanel?
    private let label = NSTextField(labelWithString: "")
    private let icon = NSImageView()
    private let spinner = NSProgressIndicator()
    private var dismissal: DispatchWorkItem?

    func show(_ message: String, symbol: String, busy: Bool = false, dismissAfter seconds: TimeInterval? = nil) {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        label.stringValue = message
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.isHidden = busy
        spinner.isHidden = !busy
        busy ? spinner.startAnimation(nil) : spinner.stopAnimation(nil)
        label.sizeToFit()
        let width = max(180, label.frame.width + 70)
        let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main
        let frame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        panel.setFrame(NSRect(x: frame.midX - width / 2, y: frame.minY + frame.height * 0.3, width: width, height: 54), display: true)
        layout(in: panel)
        panel.orderFrontRegardless()
        dismissal?.cancel()
        if let seconds {
            let work = DispatchWorkItem { [weak self] in self?.panel?.orderOut(nil) }
            dismissal = work
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
        }
    }

    func hide() {
        dismissal?.cancel()
        panel?.orderOut(nil)
    }

    /// The message window, for tests and the debug harness.
    var windowForTesting: NSWindow? { panel }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 220, height: 54), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        let effect = NSVisualEffectView()
        effect.material = .hudWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 16
        effect.layer?.masksToBounds = true
        label.font = .systemFont(ofSize: 14, weight: .medium)
        label.textColor = .labelColor
        icon.contentTintColor = .secondaryLabelColor
        icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 18, weight: .regular)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        for view in [icon, spinner, label] { effect.addSubview(view) }
        panel.contentView = effect
        return panel
    }

    private func layout(in panel: NSPanel) {
        let height = panel.frame.height
        icon.frame = NSRect(x: 16, y: (height - 24) / 2, width: 24, height: 24)
        spinner.frame = NSRect(x: 19, y: (height - 18) / 2, width: 18, height: 18)
        label.frame = NSRect(x: 48, y: (height - label.frame.height) / 2, width: panel.frame.width - 60, height: label.frame.height)
    }
}
