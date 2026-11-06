import AppKit
import SwiftUI

/// The part of the editor you can pick up and drop into Finder, Mail, Slack or any other app. Dragging writes the picture, as
/// it looks now, to a file in the temporary folder and hands that file over, so every app that accepts files accepts it.
final class ImageDragSourceView: NSView, NSDraggingSource {
    /// Makes the file to drag and a preview to carry along; nil if that failed.
    var prepare: () -> (url: URL, preview: NSImage)? = { nil }
    private var mouseDownEvent: NSEvent?
    private var dragging = false

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
        dragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !dragging, let start = mouseDownEvent else { return }
        let a = start.locationInWindow, b = event.locationInWindow
        guard hypot(b.x - a.x, b.y - a.y) > 4 else { return }
        dragging = true
        guard let (url, preview) = prepare() else { NSSound.beep(); return }
        beginDrag(of: url, preview: preview, at: convert(b, from: nil), event: start)
    }

    /// Starts the drag session. Separate so tests can look at what is offered.
    @discardableResult
    func beginDrag(of url: URL, preview: NSImage, at point: NSPoint, event: NSEvent) -> NSDraggingSession {
        let item = NSDraggingItem(pasteboardWriter: url as NSURL)
        let size = Self.previewSize(for: preview.size, maxSide: 160)
        item.setDraggingFrame(NSRect(x: point.x - size.width / 2, y: point.y - size.height / 2, width: size.width, height: size.height), contents: preview)
        return beginDraggingSession(with: [item], event: event, source: self)
    }

    static func previewSize(for size: NSSize, maxSide: CGFloat) -> NSSize {
        guard size.width > 0, size.height > 0 else { return NSSize(width: maxSide, height: maxSide) }
        let factor = min(1, maxSide / max(size.width, size.height))
        return NSSize(width: size.width * factor, height: size.height * factor)
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .copy }
}

/// The draggable handle in the editor's status bar: an icon and a word, with the drag source laid over them.
struct ImageDragHandle: View {
    unowned let commands: EditorCommands

    var body: some View {
        Label("Drag image", systemImage: "hand.draw")
            .labelStyle(.titleAndIcon)
            .foregroundStyle(.secondary)
            .overlay { DragSourceRepresentable(commands: commands) }
            .help(String(localized: "Drag the picture into another app, such as Mail, Slack or the Finder"))
    }

    private struct DragSourceRepresentable: NSViewRepresentable {
        unowned let commands: EditorCommands

        func makeNSView(context: Context) -> ImageDragSourceView {
            let view = ImageDragSourceView()
            view.prepare = { [unowned commands] in commands.prepareDragFile() }
            return view
        }

        func updateNSView(_ view: ImageDragSourceView, context: Context) {}
    }
}
