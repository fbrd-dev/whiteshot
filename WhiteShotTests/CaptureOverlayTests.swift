import AppKit
import XCTest
@testable import WhiteShot

/// Region selection logic, driven with synthetic events on an overlay that is never shown.
@MainActor
final class CaptureOverlayTests: XCTestCase {
    private var controller: CaptureOverlayController!
    private var view: CaptureOverlayView!
    private var window: NSWindow!
    private var outcome: CaptureOverlayController.Outcome?
    private var screen: NSScreen { NSScreen.main ?? NSScreen.screens[0] }

    override func setUp() async throws {
        let scale = screen.backingScaleFactor
        let image = TestImage.solid(64, 64)
        let frozen = FrozenDisplay(screen: screen, displayID: ScreenGrabber.displayID(of: screen) ?? 0, image: image, scale: scale)
        controller = CaptureOverlayController(frozen: [frozen], mode: .region, windows: [], showLoupe: false)
        controller.begin(present: false) { [unowned self] in self.outcome = $0 }
        window = controller.overlayWindows[0]
        view = controller.views[0]
        outcome = nil
    }

    private func mouse(_ type: NSEvent.EventType, _ p: CGPoint, flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: view.convert(p, to: nil), modifierFlags: flags, timestamp: 0,
                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }

    private func key(_ code: UInt16) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                         context: nil, characters: "", charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)!
    }

    private func drag(_ a: CGPoint, _ b: CGPoint, flags: NSEvent.ModifierFlags = []) {
        view.mouseDown(with: mouse(.leftMouseDown, a, flags: flags))
        view.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2), flags: flags))
        view.mouseDragged(with: mouse(.leftMouseDragged, b, flags: flags))
        view.mouseUp(with: mouse(.leftMouseUp, b, flags: flags))
    }

    private func region() -> (display: FrozenDisplay, rect: CGRect)? {
        if case .region(let d, let r)? = outcome { return (d, r) }
        return nil
    }

    func testDraggingSelectsARegionInTopLeftDisplayPoints() throws {
        let h = view.bounds.height
        drag(CGPoint(x: 100, y: h - 100), CGPoint(x: 300, y: h - 250))     // view coordinates have y up
        let result = try XCTUnwrap(region())
        XCTAssertEqual(result.rect.minX, 100, accuracy: 0.5)
        XCTAssertEqual(result.rect.minY, 100, accuracy: 0.5, "converted to a top-left origin")
        XCTAssertEqual(result.rect.width, 200, accuracy: 0.5)
        XCTAssertEqual(result.rect.height, 150, accuracy: 0.5)
    }

    func testDraggingUpwardsAndLeftwardsGivesTheSameRegion() throws {
        let h = view.bounds.height
        drag(CGPoint(x: 300, y: h - 250), CGPoint(x: 100, y: h - 100))
        let result = try XCTUnwrap(region())
        XCTAssertEqual(result.rect.width, 200, accuracy: 0.5)
        XCTAssertEqual(result.rect.height, 150, accuracy: 0.5)
    }

    func testTinyDragIsIgnoredAndOverlayStaysOpen() {
        drag(CGPoint(x: 100, y: 100), CGPoint(x: 101, y: 101))
        XCTAssertNil(outcome)
    }

    func testEscapeCancels() {
        view.keyDown(with: key(53))
        guard case .cancelled? = outcome else { return XCTFail("expected cancel, got \(String(describing: outcome))") }
    }

    func testRightClickCancels() {
        view.rightMouseDown(with: mouse(.rightMouseDown, CGPoint(x: 50, y: 50)))
        guard case .cancelled? = outcome else { return XCTFail("expected cancel") }
    }

    func testSpaceTogglesBetweenRegionAndWindowMode() {
        XCTAssertEqual(controller.mode, .region)
        view.keyDown(with: key(49))
        XCTAssertEqual(controller.mode, .window)
        view.keyDown(with: key(49))
        XCTAssertEqual(controller.mode, .region)
    }

    func testShiftMakesTheSelectionSquare() throws {
        let h = view.bounds.height
        drag(CGPoint(x: 100, y: h - 100), CGPoint(x: 400, y: h - 180), flags: .shift)
        let result = try XCTUnwrap(region())
        XCTAssertEqual(result.rect.width, result.rect.height, accuracy: 0.5)
    }

    func testOptionGrowsFromTheCentre() throws {
        let h = view.bounds.height
        drag(CGPoint(x: 400, y: h - 400), CGPoint(x: 500, y: h - 450), flags: .option)
        let result = try XCTUnwrap(region())
        XCTAssertEqual(result.rect.midX, 400, accuracy: 0.5)
        XCTAssertEqual(result.rect.width, 200, accuracy: 0.5)
        XCTAssertEqual(result.rect.height, 100, accuracy: 0.5)
    }

    func testSelectionIsClampedToTheScreen() throws {
        let h = view.bounds.height
        drag(CGPoint(x: 100, y: h - 100), CGPoint(x: view.bounds.width + 500, y: -500))
        let result = try XCTUnwrap(region())
        XCTAssertLessThanOrEqual(result.rect.maxX, view.bounds.width + 0.5)
        XCTAssertLessThanOrEqual(result.rect.maxY, h + 0.5)
    }

    /// Regression: the coordinator drops its controller inside the completion handler, while the
    /// overlay view is still returning from the mouse-up that finished the capture. That used to
    /// crash on a dangling unowned reference (found by driving the real app with the shortcut).
    func testControllerMayBeReleasedWhileTheFinishingEventUnwinds() throws {
        let frozen = FrozenDisplay(screen: screen, displayID: 0, image: TestImage.solid(64, 64), scale: screen.backingScaleFactor)
        var owner: CaptureOverlayController? = CaptureOverlayController(frozen: [frozen], mode: .region, windows: [], showLoupe: true)
        var delivered = false
        owner?.begin(present: false) { _ in delivered = true; owner = nil }
        let overlayWindow = try XCTUnwrap(owner?.overlayWindows.first)
        let overlayView = try XCTUnwrap(owner?.views.first)
        func event(_ type: NSEvent.EventType, _ p: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: overlayView.convert(p, to: nil), modifierFlags: [], timestamp: 0,
                               windowNumber: overlayWindow.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        overlayView.mouseDown(with: event(.leftMouseDown, CGPoint(x: 100, y: 300)))
        overlayView.mouseDragged(with: event(.leftMouseDragged, CGPoint(x: 300, y: 200)))
        overlayView.mouseUp(with: event(.leftMouseUp, CGPoint(x: 300, y: 200)))
        XCTAssertTrue(delivered)
        XCTAssertNil(owner)
    }

    func testFinishingTwiceDeliversOnlyOnce() {
        var count = 0
        controller.begin(present: false) { _ in count += 1 }
        controller.cancel()
        controller.cancel()
        XCTAssertEqual(count, 1)
    }
}
