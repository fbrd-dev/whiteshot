import AppKit
import XCTest
@testable import WhiteShot

final class PinPlacementTests: XCTestCase {
    private let visible = NSRect(x: 0, y: 0, width: 1440, height: 860)

    func testAppearsWhereItWasCapturedFrom() {
        let source = NSRect(x: 300, y: 200, width: 400, height: 250)
        let placed = PinPlacement.frame(for: NSSize(width: 400, height: 250), near: source, in: visible, existing: 0)
        XCTAssertEqual(placed.frame, source)
        XCTAssertEqual(placed.zoom, 1)
    }

    func testStaysOnScreenWhenTheSourceSticksOut() {
        let source = NSRect(x: 1300, y: -50, width: 400, height: 250)
        let placed = PinPlacement.frame(for: NSSize(width: 400, height: 250), near: source, in: visible, existing: 0)
        XCTAssertEqual(placed.frame.maxX, 1440, accuracy: 0.5)
        XCTAssertEqual(placed.frame.minY, 0, accuracy: 0.5)
    }

    func testWithoutASourceItGoesToTheMiddleAndStepsAside() {
        let first = PinPlacement.frame(for: NSSize(width: 400, height: 200), near: nil, in: visible, existing: 0).frame
        XCTAssertEqual(first.midX, 720, accuracy: 1)
        XCTAssertEqual(first.midY, 430, accuracy: 1)
        let second = PinPlacement.frame(for: NSSize(width: 400, height: 200), near: nil, in: visible, existing: 1).frame
        XCTAssertGreaterThan(second.minX, first.minX, "the next pin does not cover the first exactly")
        XCTAssertLessThan(second.minY, first.minY)
    }

    func testAHugePictureIsShrunkToFitTheScreen() {
        let placed = PinPlacement.frame(for: NSSize(width: 4000, height: 2000), near: NSRect(x: 0, y: 0, width: 4000, height: 2000), in: visible, existing: 0)
        XCTAssertLessThan(placed.zoom, 1)
        XCTAssertLessThanOrEqual(placed.frame.width, 0.9 * visible.width + 1)
        XCTAssertLessThanOrEqual(placed.frame.height, 0.9 * visible.height + 1)
        XCTAssertEqual(placed.frame.width / placed.frame.height, 2, accuracy: 0.02, "the proportions are kept")
        XCTAssertTrue(visible.contains(placed.frame))
    }

    func testTheFrameIsOnWholePointsSoTheWindowMatchesThePicture() {
        let odd = NSRect(x: 0, y: 0, width: 1511, height: 861)           // a visible frame with odd sizes
        for existing in 0..<4 {
            let frame = PinPlacement.frame(for: NSSize(width: 400, height: 300), near: nil, in: odd, existing: existing).frame
            XCTAssertEqual(frame.origin.x, frame.origin.x.rounded())
            XCTAssertEqual(frame.origin.y, frame.origin.y.rounded())
            XCTAssertEqual(frame.size, NSSize(width: 400, height: 300))
        }
    }

    func testAnEmptyPictureDoesNotCrash() {
        XCTAssertEqual(PinPlacement.frame(for: .zero, near: nil, in: visible, existing: 0).frame.size, .zero)
    }
}

@MainActor
final class PinnedImageControllerTests: XCTestCase {
    override func tearDown() { PinnedImageController.closeAll() }

    private func pin(scale: CGFloat = 2, near: NSRect? = nil) -> PinnedImageController {
        PinnedImageController.pin(TestImage.solid(400, 300, (200, 80, 80)), scale: scale, name: "Test", near: near)
    }

    func testItFloatsAboveOtherWindowsWithoutTakingOverTheApp() throws {
        let pin = pin()
        let panel = try XCTUnwrap(pin.window as? NSPanel)
        XCTAssertEqual(panel.level, .floating)
        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel), "clicking a pin must not pull WhiteShot to the front")
        XCTAssertFalse(panel.styleMask.contains(.titled), "so it does not turn WhiteShot into a regular app with a Dock icon")
        XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        XCTAssertTrue(panel.canBecomeKey, "so Escape works")
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertTrue(panel.isMovableByWindowBackground)
        XCTAssertFalse(panel.hidesOnDeactivate)
        XCTAssertTrue(PinnedImageController.pins.contains { $0 === pin })
    }

    func testItIsAsBigAsTheCaptureWasOnScreen() throws {
        let retina = pin(scale: 2, near: NSRect(x: 100, y: 100, width: 200, height: 150))
        XCTAssertEqual(try XCTUnwrap(retina.window).frame.size, NSSize(width: 200, height: 150))
        XCTAssertEqual(try XCTUnwrap(retina.window).frame.origin.x, 100, accuracy: 1, "right where it was captured")
        let plain = pin(scale: 1)
        XCTAssertEqual(try XCTUnwrap(plain.window).frame.size, NSSize(width: 400, height: 300))
    }

    func testOpacityIsKeptInRange() throws {
        let pin = pin()
        pin.setOpacity(0.5)
        XCTAssertEqual(try XCTUnwrap(pin.window).alphaValue, 0.5, accuracy: 0.001)
        pin.setOpacity(0)
        XCTAssertEqual(pin.opacity, 0.1, accuracy: 0.001, "never fully invisible, or it could not be found again")
        pin.setOpacity(3)
        XCTAssertEqual(pin.opacity, 1, accuracy: 0.001)
    }

    func testResizingKeepsTheCentre() throws {
        let pin = pin(scale: 2, near: NSRect(x: 300, y: 300, width: 200, height: 150))
        let window = try XCTUnwrap(pin.window)
        let centre = NSPoint(x: window.frame.midX, y: window.frame.midY)
        pin.setZoom(2)
        XCTAssertEqual(window.frame.size, NSSize(width: 400, height: 300))
        XCTAssertEqual(window.frame.midX, centre.x, accuracy: 1)
        XCTAssertEqual(window.frame.midY, centre.y, accuracy: 1)
        pin.setZoom(100)
        XCTAssertEqual(pin.zoom, 8, "limited")
        pin.setZoom(0)
        XCTAssertEqual(pin.zoom, 0.1, "limited")
    }

    func testClosingRemovesItFromThePins() {
        let a = pin(), b = pin()
        XCTAssertEqual(PinnedImageController.pins.count, 2)
        a.dismiss()
        XCTAssertEqual(PinnedImageController.pins.count, 1)
        XCTAssertTrue(PinnedImageController.pins.first === b)
        PinnedImageController.closeAll()
        XCTAssertTrue(PinnedImageController.pins.isEmpty)
    }

    func testEscapeClosesAPin() throws {
        let pin = pin()
        let view = try XCTUnwrap(pin.window?.contentView as? PinView)
        let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                      characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)!
        view.keyDown(with: escape)
        XCTAssertTrue(PinnedImageController.pins.isEmpty)
    }

    func testContextMenuOffersTheActionsAndShowsTheCurrentChoices() throws {
        let first = pin(), second = pin()
        first.setOpacity(0.5)
        let view = try XCTUnwrap(first.window?.contentView as? PinView)
        let event = NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                       eventNumber: 0, clickCount: 1, pressure: 1)!
        let menu = try XCTUnwrap(view.menu(for: event))
        let titles = menu.items.map(\.title)
        for expected in ["Open in Editor", "Copy Image", "Save", "Opacity", "Size", "Close", "Close All Pins"] {
            XCTAssertTrue(titles.contains(expected), "missing “\(expected)” in \(titles)")
        }
        let opacity = try XCTUnwrap(menu.item(withTitle: "Opacity")?.submenu)
        XCTAssertEqual(opacity.items.filter { $0.state == .on }.map(\.title), ["50 %"])
        _ = second
    }
}

final class WindowCaptureImageTests: XCTestCase {
    /// An image with a transparent border and an opaque block inside it, plus a faint shadow below.
    private func imageWithBorder() -> CGImage {
        let ctx = CGContext(data: nil, width: 100, height: 80, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 0.1))
        ctx.fill(CGRect(x: 18, y: 8, width: 64, height: 40))          // faint, bottom part in CG coordinates
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 20, y: 20, width: 60, height: 40))
        return ctx.makeImage()!
    }

    func testVisibleBoundsIncludeTheFaintShadowButNotTheEmptyBorder() throws {
        let image = imageWithBorder()
        let all = try XCTUnwrap(ImageOps.visibleBounds(of: image, minAlpha: 4))
        // CG y is up: the faint area spans y 8...48 from the bottom, the opaque block 20...60 → top-left y 20...72.
        XCTAssertEqual(all.minX, 18); XCTAssertEqual(all.width, 64)
        XCTAssertEqual(all.minY, 80 - 60); XCTAssertEqual(all.maxY, 80 - 8)
        let opaque = try XCTUnwrap(ImageOps.visibleBounds(of: image, minAlpha: 250))
        XCTAssertEqual(opaque, CGRect(x: 20, y: 20, width: 60, height: 40))
    }

    func testTrimmingCutsTheTransparentEdge() {
        let trimmed = ImageOps.trimmingTransparentEdges(imageWithBorder())
        XCTAssertEqual(trimmed.width, 64)
        XCTAssertEqual(trimmed.height, 52)
        XCTAssertEqual(TestImage.pixel(trimmed, 32, 10).a, 255, "the opaque block is still there")
    }

    func testAnEmptyOrAlreadyTightImageIsLeftAlone() {
        let solid = TestImage.solid(30, 20)
        XCTAssertEqual(ImageOps.trimmingTransparentEdges(solid).width, 30)
        let clear = CGContext(data: nil, width: 10, height: 10, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
        XCTAssertNil(ImageOps.visibleBounds(of: clear))
        XCTAssertEqual(ImageOps.trimmingTransparentEdges(clear).width, 10)
    }

    func testBackgroundChoices() {
        XCTAssertNil(WindowBackground.transparent.fill)
        XCTAssertEqual(WindowBackground.white.fill, .white)
        XCTAssertEqual(WindowBackground.black.fill, .black)
        let flat = ImageOps.flatten(imageWithBorder(), on: WindowBackground.black.fill!)
        XCTAssertEqual(TestImage.pixel(try! XCTUnwrap(flat), 2, 2).a, 255, "nothing transparent is left")
        XCTAssertEqual(TestImage.pixel(try! XCTUnwrap(flat), 2, 2).r, 0)
    }

    func testDefaultsKeepTheOldBehaviour() {
        XCTAssertEqual(Preferences.registeredDefaults[Preferences.Key.windowShadow] as? Bool, false)
        XCTAssertEqual(Preferences.registeredDefaults[Preferences.Key.windowBackground] as? String, "transparent")
        XCTAssertEqual(Preferences.registeredDefaults[Preferences.Key.toPin] as? Bool, false)
        XCTAssertEqual(Preferences.registeredDefaults[Preferences.Key.textGrabText] as? Bool, true)
        XCTAssertEqual(Preferences.registeredDefaults[Preferences.Key.textGrabCodes] as? Bool, true)
        XCTAssertEqual(Destinations.pin.rawValue, 1 << 7)
        XCTAssertFalse(Destinations([.editor, .clipboard]).contains(.pin))
    }
}

@MainActor
final class DragOutTests: XCTestCase {
    override func setUp() { StyleDefaults.stash() }
    override func tearDown() { StyleDefaults.restore() }

    func testPreviewIsScaledDownButNeverUp() {
        XCTAssertEqual(ImageDragSourceView.previewSize(for: NSSize(width: 800, height: 400), maxSide: 160), NSSize(width: 160, height: 80))
        XCTAssertEqual(ImageDragSourceView.previewSize(for: NSSize(width: 100, height: 50), maxSide: 160), NSSize(width: 100, height: 50))
        XCTAssertEqual(ImageDragSourceView.previewSize(for: .zero, maxSide: 160), NSSize(width: 160, height: 160))
    }

    func testDragFileHoldsThePictureWithItsNameAndText() throws {
        let image = TestImage.solid(120, 80, (10, 120, 200))
        let url = try XCTUnwrap(Exporter.writeDragFile(image, scale: 2, name: "My / Screenshot", text: "Hello\nworld"))
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        XCTAssertTrue(url.path.hasPrefix(Exporter.dragDirectory.path))
        XCTAssertEqual(url.deletingPathExtension().lastPathComponent, "My - Screenshot", "a slash in the name is not a folder")
        XCTAssertEqual(url.pathExtension, Preferences.imageFormat.fileExtension)
        let data = try Data(contentsOf: url)
        let decoded = try XCTUnwrap(ImageEncoder.decode(data))
        XCTAssertEqual(decoded.image.width, 120)
        XCTAssertEqual(decoded.scale, 2)
        if Preferences.imageFormat != .gif && Preferences.imageFormat != .bmp {
            XCTAssertEqual(ImageEncoder.embeddedText(in: data), "Hello\nworld")
        }
        let other = try XCTUnwrap(Exporter.writeDragFile(image, scale: 2, name: "My / Screenshot"))
        defer { try? FileManager.default.removeItem(at: other.deletingLastPathComponent()) }
        XCTAssertNotEqual(url.deletingLastPathComponent(), other.deletingLastPathComponent(), "each drag has its own folder, so names never collide")
    }

    func testOldDragFilesAreTidiedAwayRecentOnesStay() throws {
        let image = TestImage.solid(20, 20)
        let old = try XCTUnwrap(Exporter.writeDragFile(image, scale: 1, name: "old")).deletingLastPathComponent()
        let recent = try XCTUnwrap(Exporter.writeDragFile(image, scale: 1, name: "recent")).deletingLastPathComponent()
        defer { try? FileManager.default.removeItem(at: old); try? FileManager.default.removeItem(at: recent) }
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-3 * 24 * 3600)], ofItemAtPath: old.path)
        Exporter.cleanUpDragFiles()
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: recent.path))
    }

    func testEditorMakesTheDragFileFromWhatYouSee() throws {
        let model = EditorModel(image: TestImage.solid(300, 200, (255, 255, 255)), scale: 2, displayName: "Draft.png")
        let controller = EditorWindowController(model: model)
        var box = model.makeAnnotation(.rectangle)
        box.rect = CGRect(x: 10, y: 10, width: 100, height: 80)
        box.style.fillColor = RGBAColor(r: 1, g: 0, b: 0, a: 1)
        model.add(box)
        let prepared = try XCTUnwrap(controller.prepareDragFile())
        defer { try? FileManager.default.removeItem(at: prepared.url.deletingLastPathComponent()) }
        XCTAssertEqual(prepared.url.deletingPathExtension().lastPathComponent, "Draft")
        let decoded = try XCTUnwrap(ImageEncoder.decode(contentsOf: prepared.url))
        // Allowing for a lossy format if that is what the user's settings say.
        XCTAssertGreaterThan(TestImage.pixel(decoded.image, 50, 50).r, 235)
        XCTAssertLessThan(TestImage.pixel(decoded.image, 50, 50).g, 30, "the annotation is in the dragged picture")
        XCTAssertEqual(prepared.preview.size.width, 150, accuracy: 0.5, "the preview has the picture's size in points")
    }

    func testTheStatusBarOffersPinAndDrag() throws {
        // The handle and the pin button are SwiftUI; check that the commands behind them exist on the controller.
        let controller = EditorWindowController(model: EditorModel(image: TestImage.solid(200, 100), scale: 1))
        controller.pinImage()
        XCTAssertEqual(PinnedImageController.pins.count, 1)
        PinnedImageController.closeAll()
    }
}

@MainActor
final class TextGrabTests: XCTestCase {
    func testConfirmationSaysWhatWasCopied() {
        let code = RecognizedCode(payload: "https://x.example", rect: .zero, isQR: true)
        func line(_ text: String) -> RecognizedLine { RecognizedLine(text: text, rect: .zero, edges: Array(repeating: 0, count: text.count + 1)) }
        let both = RecognizedText(lines: [line("Hello")], codes: [code])
        XCTAssertEqual(TextGrab.summary(of: both, text: true, codes: true, string: "x"), "Copied text and QR code")
        XCTAssertEqual(TextGrab.summary(of: both, text: false, codes: true, string: "x"), "Copied QR code content")
        XCTAssertEqual(TextGrab.summary(of: both, text: true, codes: false, string: "Hello"), "Copied 5 characters")
        XCTAssertEqual(TextGrab.summary(of: RecognizedText(lines: [], codes: [code, code]), text: true, codes: true, string: "x"), "Copied 2 codes")
    }

    func testCopyGoesToTheGivenPasteboard() {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("me.fbrd.whiteshot.tests.grab.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        TextGrab.copy("line one\nline two", to: pasteboard)
        XCTAssertEqual(pasteboard.string(forType: .string), "line one\nline two")
    }

    func testTheShortcutIsAnActionWithItsOwnDefaults() {
        XCTAssertTrue(HotkeyAction.allCases.contains(.textGrab))
        XCTAssertEqual(HotkeyAction.textGrab.carbonID, 5)
        XCTAssertFalse(HotkeyAction.textGrab.title.isEmpty)
        let own = ShortcutStore.defaultShortcut(for: .textGrab, scheme: .own)
        let system = ShortcutStore.defaultShortcut(for: .textGrab, scheme: .system)
        XCTAssertEqual(own.displayString, "⌃⇧7")
        XCTAssertEqual(system.displayString, "⇧⌘7")
        for scheme in ShortcutScheme.allCases {
            let all = HotkeyAction.allCases.map { ShortcutStore.defaultShortcut(for: $0, scheme: scheme) }
            XCTAssertEqual(Set(all).count, all.count, "no two actions share a default in \(scheme)")
        }
    }
}
