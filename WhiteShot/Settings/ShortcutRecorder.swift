import AppKit
import SwiftUI

/// A click-to-record field for a global shortcut.
struct ShortcutRecorder: NSViewRepresentable {
    /// Nil shows the placeholder: an empty slot waiting for the user to record something.
    let shortcut: Shortcut?
    var placeholder = String(localized: "Add…")
    let onChange: (Shortcut) -> Void

    func makeNSView(context: Context) -> RecorderView {
        let view = RecorderView()
        view.onChange = onChange
        view.placeholder = placeholder
        view.shortcut = shortcut
        return view
    }

    func updateNSView(_ view: RecorderView, context: Context) {
        view.onChange = onChange
        view.placeholder = placeholder
        view.shortcut = shortcut
    }

    final class RecorderView: NSView {
        var shortcut: Shortcut? { didSet { needsDisplay = true } }
        var placeholder = ""
        var onChange: ((Shortcut) -> Void)?
        private var recording = false { didSet { needsDisplay = true } }

        override var acceptsFirstResponder: Bool { true }
        override var intrinsicContentSize: NSSize { NSSize(width: 120, height: 24) }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

        override func mouseDown(with event: NSEvent) {
            recording = true
            window?.makeFirstResponder(self)
        }

        override func resignFirstResponder() -> Bool {
            recording = false
            return super.resignFirstResponder()
        }

        override func keyDown(with event: NSEvent) {
            guard recording else { super.keyDown(with: event); return }
            if event.keyCode == 53 {            // escape cancels
                recording = false
                window?.makeFirstResponder(nil)
                return
            }
            if let new = Shortcut(event: event) {
                recording = false
                onChange?(new)
                window?.makeFirstResponder(nil)
            } else {
                NSSound.beep()
            }
        }

        // Command-key combinations arrive here first; take them while recording.
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            guard recording else { return super.performKeyEquivalent(with: event) }
            keyDown(with: event)
            return true
        }

        override func draw(_ dirtyRect: NSRect) {
            let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
            let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
            (recording ? NSColor.controlAccentColor.withAlphaComponent(0.15) : NSColor.controlBackgroundColor).setFill()
            path.fill()
            (recording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
            path.lineWidth = recording ? 2 : 1
            path.stroke()
            let text = recording ? String(localized: "Type shortcut…") : (shortcut?.displayString ?? placeholder)
            let isPlaceholder = !recording && shortcut == nil
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13, weight: isPlaceholder ? .regular : .medium),
                .foregroundColor: (recording || isPlaceholder) ? NSColor.secondaryLabelColor : NSColor.labelColor,
            ]
            let size = (text as NSString).size(withAttributes: attributes)
            (text as NSString).draw(at: NSPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2), withAttributes: attributes)
        }

        override func accessibilityLabel() -> String? { String(localized: "Shortcut") }
        override func accessibilityValue() -> Any? { shortcut?.displayString ?? placeholder }
    }
}
