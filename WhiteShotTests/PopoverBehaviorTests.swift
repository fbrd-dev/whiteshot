import AppKit
import SwiftUI
import XCTest
@testable import WhiteShot

/// Drives the colour popover's host (`PopoverAnchor`) with synthetic clicks across two windows.
@MainActor
final class PopoverBehaviorTests: XCTestCase {
    /// Lets SwiftUI flip the popover on and off from the test.
    final class Switch: ObservableObject { @Published var on = false }

    struct Probe: View {
        @ObservedObject var model: Switch
        var body: some View {
            Color.clear.frame(width: 200, height: 100)
                .background(PopoverAnchor(isPresented: Binding(get: { model.on }, set: { model.on = $0 })) {
                    Text("popover content").frame(width: 120, height: 60)
                })
        }
    }

    private var windowA: NSWindow!
    private var windowB: NSWindow!
    private let flip = Switch()

    override func setUp() async throws {
        // B sits at the left, A overlaps its right part and is in front.
        windowB = makeWindow(x: -4000, y: 300, title: "B")
        windowA = makeWindow(x: -3800, y: 300, title: "A", hosting: Probe(model: flip))
        windowB.orderFront(nil)
        windowA.orderFront(nil)
        windowA.makeKey()
        spin(0.2)
    }

    override func tearDown() async throws {
        closePopovers()
        windowA.close(); windowB.close()
    }

    private func makeWindow(x: CGFloat, y: CGFloat, title: String, hosting: (some View)? = nil as EmptyView?) -> NSWindow {
        let window = NSWindow(contentRect: NSRect(x: x, y: y, width: 400, height: 300), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = title
        window.isReleasedWhenClosed = false
        if let hosting { window.contentView = NSHostingView(rootView: hosting) }
        return window
    }

    private func spin(_ seconds: TimeInterval) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }

    private var popoverWindows: [NSWindow] {
        NSApp.windows.filter { $0.isVisible && String(describing: type(of: $0)).contains("Popover") }
    }

    private func closePopovers() { flip.on = false; spin(0.2) }

    /// A full click (down then up) delivered through the application's event queue, like a real one.
    private func click(in window: NSWindow, at point: NSPoint) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            // sendEvent runs local event monitors; postEvent would only queue it, and nothing here drains that queue.
            NSApp.sendEvent(event)
            spin(0.1)
        }
        spin(0.4)
    }

    private func frontToBack() -> [String] {
        NSApp.orderedWindows.filter { $0 === windowA || $0 === windowB }.map(\.title)
    }

    private func openPopover() {
        flip.on = true
        spin(0.5)
    }

    func testPopoverOpens() {
        openPopover()
        XCTAssertEqual(popoverWindows.count, 1, "the popover is on screen")
    }

    /// Regression: the popover stayed open when the user clicked the canvas of the window it belongs to.
    func testClickingElsewhereInTheSameWindowClosesThePopover() {
        openPopover()
        XCTAssertEqual(popoverWindows.count, 1)
        // Well away from the anchor (the anchor is the 200x100 box at the top-left of the content).
        click(in: windowA, at: NSPoint(x: 300, y: 40))
        XCTAssertEqual(popoverWindows.count, 0, "popover should close on a click in its own window")
    }

    /// Why this matters: an open popover kept its parent window in front of the app's other windows, so a click
    /// on another window did not bring it forward (verified with real clicks; see DebugHarness `--debug-twowindows`).
    func testClickingTheOtherWindowClosesThePopoverSoItCannotKeepItsParentInFront() {
        openPopover()
        click(in: windowB, at: NSPoint(x: 60, y: 150))
        XCTAssertEqual(popoverWindows.count, 0)
    }

    func testEscapeClosesThePopover() {
        openPopover()
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                     windowNumber: windowA.windowNumber, context: nil, characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}",
                                     isARepeat: false, keyCode: 53)!
        NSApp.sendEvent(event)
        spin(0.4)
        XCTAssertEqual(popoverWindows.count, 0)
    }

    func testClickingTheSwatchItselfTogglesInsteadOfClosingAndReopening() {
        openPopover()
        // The anchor fills the 200x100 Color.clear at the top-left of window A's content (AppKit y is up).
        let content = windowA.contentView!
        let inside = NSPoint(x: 100, y: content.bounds.height - 50)
        click(in: windowA, at: inside)
        // The click itself must not dismiss it from the monitor; the swatch's own button does that in the app.
        XCTAssertEqual(popoverWindows.count, 1, "the monitor leaves clicks on the anchor to the swatch's own toggle")
    }

    func testClickingInsideThePopoverKeepsItOpen() {
        openPopover()
        let popoverWindow = popoverWindows[0]
        click(in: popoverWindow, at: NSPoint(x: popoverWindow.frame.width / 2, y: popoverWindow.frame.height / 2))
        XCTAssertEqual(popoverWindows.count, 1, "interacting with the popover itself must not dismiss it")
    }
}
