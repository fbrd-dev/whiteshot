import AppKit
import ImageIO
import XCTest
@testable import WhiteShot

/// Fake recognised text with evenly spaced characters, so selection maths can be checked without Vision.
private func makeText(_ rows: [String], charWidth: CGFloat = 10, left: CGFloat = 100, top: CGFloat = 50, rowHeight: CGFloat = 40) -> RecognizedText {
    RecognizedText(lines: rows.enumerated().map { index, text in
        let rect = CGRect(x: left, y: top + CGFloat(index) * rowHeight, width: charWidth * CGFloat(text.count), height: 24)
        return RecognizedLine(text: text, rect: rect, edges: (0...text.count).map { left + charWidth * CGFloat($0) })
    })
}

final class TextSelectionLogicTests: XCTestCase {
    private let text = makeText(["Hello world", "Second line", "Third"])

    func testPositionOnTextFindsTheNearestGapOfTheLine() {
        // Characters are 10 wide starting at x = 100; 134 is closest to the gap after "Hel" (x = 130).
        XCTAssertEqual(text.position(at: CGPoint(x: 134, y: 60)), TextPosition(line: 0, offset: 3))
        XCTAssertEqual(text.position(at: CGPoint(x: 100, y: 62)), TextPosition(line: 0, offset: 0))
        XCTAssertEqual(text.position(at: CGPoint(x: 210, y: 62)), TextPosition(line: 0, offset: 11), "just past the end of the line")
        XCTAssertEqual(text.position(at: CGPoint(x: 150, y: 100)), TextPosition(line: 1, offset: 5))
    }

    func testPositionIsNilWhereThereIsNoText() {
        XCTAssertNil(text.position(at: CGPoint(x: 150, y: 300)), "far below the last line")
        XCTAssertNil(text.position(at: CGPoint(x: 600, y: 60)), "far to the right of the line")
        XCTAssertNil(text.position(at: CGPoint(x: 150, y: 82)), "the gap between two lines")
    }

    func testNearestPositionClampsOutsideTheTextWhileDragging() {
        XCTAssertEqual(text.nearestPosition(to: CGPoint(x: 400, y: 10)), TextPosition(line: 0, offset: 0), "above everything: the very start")
        XCTAssertEqual(text.nearestPosition(to: CGPoint(x: 0, y: 500)), TextPosition(line: 2, offset: 5), "below everything: the very end")
        XCTAssertEqual(text.nearestPosition(to: CGPoint(x: 300, y: 92)), TextPosition(line: 1, offset: 11), "beside a line: its end")
        XCTAssertNil(RecognizedText(lines: []).nearestPosition(to: .zero))
    }

    func testSelectedTextWithinOneLine() {
        let selection = TextSelection(anchor: TextPosition(line: 0, offset: 6), head: TextPosition(line: 0, offset: 11))
        XCTAssertEqual(text.text(in: selection), "world")
    }

    func testSelectedTextAcrossLinesJoinsThemWithLineBreaks() {
        let selection = TextSelection(anchor: TextPosition(line: 0, offset: 6), head: TextPosition(line: 2, offset: 3))
        XCTAssertEqual(text.text(in: selection), "world\nSecond line\nThi")
    }

    func testSelectionWorksBackwardsToo() {
        let selection = TextSelection(anchor: TextPosition(line: 1, offset: 6), head: TextPosition(line: 0, offset: 6))
        XCTAssertEqual(text.text(in: selection), "world\nSecond")
        XCTAssertEqual(selection.start, TextPosition(line: 0, offset: 6))
        XCTAssertEqual(selection.end, TextPosition(line: 1, offset: 6))
    }

    func testHighlightRectanglesFollowTheSelectedCharacters() {
        let selection = TextSelection(anchor: TextPosition(line: 0, offset: 6), head: TextPosition(line: 1, offset: 6))
        let rects = text.rects(for: selection)
        XCTAssertEqual(rects.count, 2)
        XCTAssertEqual(rects[0].minX, 160, accuracy: 0.01)
        XCTAssertEqual(rects[0].maxX, 210, accuracy: 0.01, "to the end of the first line")
        XCTAssertEqual(rects[1].minX, 100, accuracy: 0.01, "from the start of the second line")
        XCTAssertEqual(rects[1].maxX, 160, accuracy: 0.01)
        XCTAssertEqual(rects[0].minY, 50, accuracy: 0.01)
        XCTAssertEqual(rects[1].minY, 90, accuracy: 0.01)
    }

    func testWordAndLineSelection() {
        XCTAssertEqual(text.text(in: try! XCTUnwrap(text.wordSelection(at: CGPoint(x: 175, y: 60)))), "world")
        XCTAssertEqual(text.text(in: try! XCTUnwrap(text.wordSelection(at: CGPoint(x: 103, y: 60)))), "Hello")
        XCTAssertEqual(text.text(in: try! XCTUnwrap(text.lineSelection(at: CGPoint(x: 175, y: 100)))), "Second line")
        XCTAssertNil(text.wordSelection(at: CGPoint(x: 175, y: 300)))
    }

    func testSelectAllCoversEverything() throws {
        let all = try XCTUnwrap(text.fullRange)
        XCTAssertEqual(text.text(in: all), "Hello world\nSecond line\nThird")
        XCTAssertEqual(text.fullText, "Hello world\nSecond line\nThird")
    }

    func testLinesTouchingCensoredAreasAreRemoved() {
        let kept = text.removingLines(intersecting: [CGRect(x: 120, y: 85, width: 30, height: 10)])
        XCTAssertEqual(kept.lines.map(\.text), ["Hello world", "Third"], "the second line lies under the censoring box")
        XCTAssertEqual(text.removingLines(intersecting: []), text)
    }
}

final class CharacterEdgeTests: XCTestCase {
    private let line = CGRect(x: 100, y: 0, width: 400, height: 20)

    func testEdgesFollowWordBoxesAndSpacesTakeTheGaps() {
        let characters = Array("ab cd")
        let spans: [(min: CGFloat, max: CGFloat)?] = [(100, 160), (100, 160), nil, (200, 260), (200, 260)]
        let edges = TextRecognizer.edges(characters: characters, spans: spans, lineRect: line)
        XCTAssertEqual(edges.count, 6)
        XCTAssertEqual(edges[0], 100, accuracy: 0.01, "start of the first word")
        XCTAssertEqual(edges[2], 160, accuracy: 0.01, "end of the first word")
        XCTAssertEqual(edges[3], 200, accuracy: 0.01, "start of the second word: the space fills 160...200")
        XCTAssertEqual(edges[5], 260, accuracy: 0.01)
        XCTAssertEqual(edges, edges.sorted())
    }

    func testWiderLettersGetMoreRoomInsideAWord() {
        let edges = TextRecognizer.edges(characters: Array("mi"), spans: [(0, 100), (0, 100)], lineRect: line)
        let m = edges[1] - edges[0], i = edges[2] - edges[1]
        XCTAssertGreaterThan(m, i * 2, "an “m” is much wider than an “i” in proportional type")
        XCTAssertEqual(edges[2], 100, accuracy: 0.01)
    }

    func testLeadingAndTrailingSpacesStayInsideTheLine() {
        let edges = TextRecognizer.edges(characters: Array(" ab "), spans: [nil, (120, 160), (120, 160), nil], lineRect: line)
        XCTAssertEqual(edges.first!, 100, accuracy: 0.01)
        XCTAssertEqual(edges[1], 120, accuracy: 0.01)
        XCTAssertEqual(edges.last!, 500, accuracy: 0.01)
        XCTAssertEqual(edges, edges.sorted())
    }

    func testBackwardsBoxesFallBackToAnEvenSpread() {
        let edges = TextRecognizer.edges(characters: Array("ab cd"), spans: [(300, 360), (300, 360), nil, (100, 160), (100, 160)], lineRect: line)
        XCTAssertEqual(edges, (0...5).map { 100 + 400 * CGFloat($0) / 5 })
    }
}

/// Runs the real Vision framework on text drawn into a picture, and checks where the text is reported.
final class VisionRecognitionTests: XCTestCase {
    private let font = NSFont.systemFont(ofSize: 40)

    private func renderedImage() throws -> (image: CGImage, topLine: String) {
        let width = 1600, height = 500
        let ctx = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let graphics = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        NSColor.white.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.black]
        let top = "Invoice #2026-0142 for Contoso Ltd"
        (top as NSString).draw(at: NSPoint(x: 60, y: 60), withAttributes: attributes)
        ("Consulting package three" as NSString).draw(at: NSPoint(x: 60, y: 260), withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
        return (try XCTUnwrap(ctx.makeImage()), top)
    }

    func testFindsTheTextAndPutsItWhereItWasDrawn() async throws {
        let (image, top) = try renderedImage()
        let result = try await TextRecognizer.recognize(in: image)
        XCTAssertEqual(result.lines.count, 2, "two lines were drawn: \(result.lines.map(\.text))")

        let first = try XCTUnwrap(result.lines.first { $0.text.contains("Invoice") }, "found: \(result.lines.map(\.text))")
        XCTAssertTrue(first.text.contains("Contoso"))
        // Drawn at x = 60, y = 60 (top-left origin), in 40 pt type.
        XCTAssertEqual(first.rect.minX, 60, accuracy: 15)
        XCTAssertEqual(first.rect.midY, 60 + 24, accuracy: 25)
        XCTAssertEqual(first.rect.width, (top as NSString).size(withAttributes: [.font: font]).width, accuracy: 40)
        XCTAssertEqual(first.edges.count, first.text.count + 1)
        XCTAssertEqual(first.edges, first.edges.sorted())
        let second = try XCTUnwrap(result.lines.first { $0.text.contains("Consulting") })
        XCTAssertGreaterThan(second.rect.minY, first.rect.maxY, "the second line was drawn lower")
    }

    func testSelectingAWordSelectsTheWordDrawnUnderThePointer() async throws {
        let (image, top) = try renderedImage()
        let result = try await TextRecognizer.recognize(in: image)
        let line = try XCTUnwrap(result.lines.first { $0.text.contains("Contoso") })
        func width(_ s: String) -> CGFloat { (s as NSString).size(withAttributes: [.font: font]).width }
        let prefix = String(top.prefix(upTo: try XCTUnwrap(top.range(of: "Contoso")).lowerBound))
        let centre = CGPoint(x: 60 + width(prefix) + width("Contoso") / 2, y: line.rect.midY)
        let word = try XCTUnwrap(result.wordSelection(at: centre))
        XCTAssertEqual(result.text(in: word), "Contoso", "the point is in the middle of the drawn word “Contoso”")
        let rect = try XCTUnwrap(result.rects(for: word).first)
        XCTAssertEqual(rect.minX, 60 + width(prefix), accuracy: 14)
        XCTAssertEqual(rect.width, width("Contoso"), accuracy: 28)
    }

    func testAPictureWithoutTextGivesNoLines() async throws {
        let result = try await TextRecognizer.recognize(in: TestImage.solid(400, 300))
        XCTAssertTrue(result.isEmpty)
    }
}

@MainActor
final class TextModeModelTests: XCTestCase {
    override func setUp() { StyleDefaults.stash() }
    override func tearDown() { StyleDefaults.restore() }

    private func model() -> EditorModel { EditorModel(image: TestImage.solid(800, 600), scale: 1) }

    func testTurningItOnSelectsTheSelectToolAndLocksTheOthers() {
        let m = model()
        m.tool = .rectangle
        var box = m.makeAnnotation(.rectangle)
        box.rect = CGRect(x: 10, y: 10, width: 50, height: 50)
        m.add(box)
        XCTAssertFalse(m.selection.isEmpty)

        let generation = m.beginTextRecognition()
        XCTAssertNotNil(generation, "Vision has to run")
        XCTAssertEqual(m.tool, .select)
        XCTAssertTrue(m.selection.isEmpty)
        XCTAssertEqual(m.textMode, .recognizing)
        for tool in EditorTool.allCases {
            XCTAssertEqual(m.isToolEnabled(tool), tool == .select, "\(tool) while text recognition is on")
        }
        m.endTextRecognition()
        for tool in EditorTool.allCases { XCTAssertTrue(m.isToolEnabled(tool), "\(tool) after turning it off") }
    }

    func testResultOfAnAbandonedRunIsIgnored() throws {
        let m = model()
        let first = try XCTUnwrap(m.beginTextRecognition())
        m.endTextRecognition()
        m.finishTextRecognition(.success(makeText(["late"])), generation: first)
        XCTAssertNil(m.recognizedText)
        XCTAssertEqual(m.textMode, .off)

        let second = try XCTUnwrap(m.beginTextRecognition())
        m.finishTextRecognition(.success(makeText(["stale"])), generation: first)
        XCTAssertEqual(m.textMode, .recognizing, "a result from an earlier run must not complete this one")
        m.finishTextRecognition(.success(makeText(["fresh"])), generation: second)
        XCTAssertEqual(m.textMode, .active)
        XCTAssertEqual(m.recognizedText?.fullText, "fresh")
    }

    func testTextKnownForThePictureIsReusedWithoutRunningVisionAgain() throws {
        let m = model()
        let generation = try XCTUnwrap(m.beginTextRecognition())
        m.finishTextRecognition(.success(makeText(["Hello", "world"])), generation: generation)
        m.endTextRecognition()
        XCTAssertEqual(m.textMode, .off)
        XCTAssertEqual(m.recognizedTextForExport, "Hello\nworld", "still known after leaving the mode, for saving")
        XCTAssertNil(m.beginTextRecognition(), "no new run needed: the picture has not changed")
        XCTAssertEqual(m.textMode, .active)
        XCTAssertEqual(m.recognizedText?.lines.count, 2)
    }

    func testChangingThePictureThrowsTheTextAwayAndLeavesTheMode() throws {
        let m = model()
        let generation = try XCTUnwrap(m.beginTextRecognition())
        m.finishTextRecognition(.success(makeText(["Secret"])), generation: generation)
        m.textSelection = m.recognizedText?.fullRange
        XCTAssertEqual(m.selectedRecognizedText, "Secret")

        var box = m.makeAnnotation(.obfuscate)
        box.rect = CGRect(x: 90, y: 40, width: 100, height: 40)
        m.add(box)
        XCTAssertEqual(m.textMode, .off, "editing the picture ends text recognition")
        XCTAssertNil(m.recognizedText, "text found before the edit no longer describes the picture")
        XCTAssertNil(m.recognizedTextForExport)
        XCTAssertNil(m.selectedRecognizedText)
        XCTAssertTrue(m.isToolEnabled(.rectangle))
    }

    func testTextUnderCensoringIsNeverOffered() throws {
        let m = model()
        var box = m.makeAnnotation(.obfuscate)
        box.rect = CGRect(x: 90, y: 85, width: 200, height: 40)      // covers the second line of the sample
        m.add(box, select: false)
        let generation = try XCTUnwrap(m.beginTextRecognition())
        m.finishTextRecognition(.success(makeText(["Visible", "Hidden by the box", "Also visible"])), generation: generation)
        XCTAssertEqual(m.recognizedText?.lines.map(\.text), ["Visible", "Also visible"])
        XCTAssertFalse(m.recognizedTextForExport?.contains("Hidden") ?? false)
    }

    func testFailureIsReportedAndLeavesNoText() throws {
        struct Boom: LocalizedError { var errorDescription: String? { "boom" } }
        let m = model()
        let generation = try XCTUnwrap(m.beginTextRecognition())
        m.finishTextRecognition(.failure(Boom()), generation: generation)
        XCTAssertEqual(m.textMode, .active)
        XCTAssertEqual(m.recognitionError, "boom")
        XCTAssertTrue(m.recognizedText?.isEmpty ?? false)
        XCTAssertNil(m.recognizedTextForExport)
    }

    func testTextModeDoesNotMarkTheDocumentAsEdited() throws {
        let m = model()
        let generation = try XCTUnwrap(m.beginTextRecognition())
        m.finishTextRecognition(.success(makeText(["Hello"])), generation: generation)
        m.textSelection = m.recognizedText?.fullRange
        m.endTextRecognition()
        XCTAssertFalse(m.isDirty)
        XCTAssertFalse(m.canUndo)
    }
}

/// The canvas with text recognition on: dragging selects text, ⌘C copies it, the drawing tools stay locked.
@MainActor
final class TextModeCanvasTests: XCTestCase {
    private var window: NSWindow!
    private var canvas: CanvasView!
    private var model: EditorModel!
    private var pasteboard: NSPasteboard!

    override func setUp() async throws {
        StyleDefaults.stash()
        model = EditorModel(image: TestImage.solid(800, 600), scale: 1, displayName: "Test")
        canvas = CanvasView(model: model)
        pasteboard = NSPasteboard(name: NSPasteboard.Name("me.fbrd.whiteshot.tests.\(UUID().uuidString)"))
        canvas.textPasteboard = pasteboard
        window = NSWindow(contentRect: NSRect(x: -4000, y: 0, width: 1200, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 1200, height: 900))
        window.contentView = container
        container.addSubview(canvas)
        canvas.frame.origin = .zero
        model.zoom = 1
        canvas.syncFrameSize()
        model.onChange = { [weak self] in self?.canvas.modelChanged() }
        window.makeFirstResponder(canvas)

        let generation = try XCTUnwrap(model.beginTextRecognition())
        model.finishTextRecognition(.success(makeText(["Hello world", "Second line", "Third"])), generation: generation)
    }

    override func tearDown() async throws {
        model.onChange = nil
        pasteboard.releaseGlobally()
        window.close()
        StyleDefaults.restore()
    }

    private func viewPoint(_ imagePoint: CGPoint) -> NSPoint {
        let k = canvas.pointsPerPixel
        return canvas.convert(NSPoint(x: imagePoint.x * k, y: imagePoint.y * k), to: nil)
    }

    private func mouse(_ type: NSEvent.EventType, _ p: CGPoint, clicks: Int = 1, flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: viewPoint(p), modifierFlags: flags, timestamp: 0,
                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
    }

    private func drag(from a: CGPoint, to b: CGPoint) {
        canvas.mouseDown(with: mouse(.leftMouseDown, a))
        for i in 1...5 {
            let t = CGFloat(i) / 5
            canvas.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t)))
        }
        canvas.mouseUp(with: mouse(.leftMouseUp, b))
    }

    private func key(_ code: UInt16, _ chars: String = "") {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                     context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
        canvas.keyDown(with: event)
    }

    func testDraggingAcrossTextSelectsItAndCopyPutsItOnThePasteboard() {
        drag(from: CGPoint(x: 160, y: 62), to: CGPoint(x: 140, y: 102))      // "world" ... to "Seco" of the next line
        XCTAssertEqual(model.selectedRecognizedText, "world\nSeco")
        XCTAssertTrue(canvas.validateUserInterfaceItem(menuItem(#selector(CanvasView.copy(_:)))))
        canvas.copy(nil)
        XCTAssertEqual(pasteboard.string(forType: .string), "world\nSeco")
    }

    func testDraggingOutsideTheTextStillExtendsTheSelectionToTheNearestText() {
        drag(from: CGPoint(x: 100, y: 60), to: CGPoint(x: 700, y: 400))
        XCTAssertEqual(model.selectedRecognizedText, "Hello world\nSecond line\nThird")
    }

    func testDoubleClickSelectsAWordAndTripleClickALine() {
        canvas.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 175, y: 60), clicks: 2))
        canvas.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 175, y: 60), clicks: 2))
        XCTAssertEqual(model.selectedRecognizedText, "world")
        canvas.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 175, y: 100), clicks: 3))
        canvas.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 175, y: 100), clicks: 3))
        XCTAssertEqual(model.selectedRecognizedText, "Second line")
    }

    func testClickingBesideTheTextClearsTheSelection() {
        drag(from: CGPoint(x: 100, y: 60), to: CGPoint(x: 160, y: 60))
        XCTAssertNotNil(model.selectedRecognizedText)
        canvas.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 600, y: 500)))
        canvas.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 600, y: 500)))
        XCTAssertNil(model.selectedRecognizedText)
    }

    func testNothingDrawnOrMovedWhileTextRecognitionIsOn() {
        model.textSelection = nil
        drag(from: CGPoint(x: 400, y: 300), to: CGPoint(x: 600, y: 450))
        XCTAssertTrue(model.annotations.isEmpty, "no marquee, shape or other annotation")
        XCTAssertFalse(model.isDirty)
        XCTAssertFalse(model.canUndo)
    }

    func testToolShortcutsAreIgnored() {
        key(15, "r")                                                         // R: rectangle
        key(17, "t")                                                         // T: text
        key(8, "c")                                                          // C: crop
        XCTAssertEqual(model.tool, .select)
        XCTAssertEqual(model.textMode, .active)
    }

    func testSelectAllAndEscape() {
        canvas.selectAll(nil)
        XCTAssertEqual(model.selectedRecognizedText, "Hello world\nSecond line\nThird")
        key(53)                                                              // first Escape: drop the selection
        XCTAssertNil(model.textSelection)
        XCTAssertEqual(model.textMode, .active)
        key(53)                                                              // second Escape: leave text recognition
        XCTAssertEqual(model.textMode, .off)
    }

    func testEditCommandsThatChangeThePictureAreOff() {
        XCTAssertFalse(canvas.validateUserInterfaceItem(menuItem(#selector(CanvasView.delete(_:)))))
        XCTAssertFalse(canvas.validateUserInterfaceItem(menuItem(#selector(CanvasView.paste(_:)))))
        XCTAssertFalse(canvas.validateUserInterfaceItem(menuItem(#selector(CanvasView.duplicate(_:)))))
        XCTAssertFalse(canvas.validateUserInterfaceItem(menuItem(#selector(CanvasView.copy(_:)))), "nothing selected yet")
        XCTAssertTrue(canvas.validateUserInterfaceItem(menuItem(#selector(CanvasView.selectAll(_:)))))
    }

    func testCopyAllCopiesEverythingWithoutASelection() {
        canvas.copyRecognizedText(all: true)
        XCTAssertEqual(pasteboard.string(forType: .string), "Hello world\nSecond line\nThird")
    }

    private func menuItem(_ action: Selector) -> NSMenuItem { NSMenuItem(title: "", action: action, keyEquivalent: "") }
}

/// The editor window around it: the toolbar button and the menu commands that must be off.
@MainActor
final class TextModeWindowTests: XCTestCase {
    override func setUp() { StyleDefaults.stash() }
    override func tearDown() { StyleDefaults.restore() }

    func testRecognizeTextIsAnIslandOfItsOwnLeftOfTheOthers() throws {
        let controller = EditorWindowController(model: EditorModel(image: TestImage.solid(400, 300), scale: 1))
        let items = try XCTUnwrap(controller.window?.toolbar?.items).map(\.itemIdentifier.rawValue)
        let ocr = try XCTUnwrap(items.firstIndex(of: "whiteshot.recognizeText"))
        let save = try XCTUnwrap(items.firstIndex(of: "whiteshot.save"))
        XCTAssertLessThan(ocr, save, "left of Save, Copy and Share: \(items)")
        XCTAssertEqual(items[ocr + 1], NSToolbarItem.Identifier.space.rawValue, "a gap after it keeps it out of the island of the other three: \(items)")
        XCTAssertEqual(ocr, 0)
    }

    func testButtonFollowsTheMode() throws {
        let model = EditorModel(image: TestImage.solid(400, 300), scale: 1)
        let controller = EditorWindowController(model: model)
        XCTAssertEqual(controller.recognizeButtonIsOn, false)
        let generation = try XCTUnwrap(model.beginTextRecognition())
        XCTAssertEqual(controller.recognizeButtonIsOn, true, "on while recognising")
        model.finishTextRecognition(.success(makeText(["Hello"])), generation: generation)
        XCTAssertEqual(controller.recognizeButtonIsOn, true)
        model.endTextRecognition()
        XCTAssertEqual(controller.recognizeButtonIsOn, false)
    }

    func testPressingTheButtonRunsRecognitionOnTheRealPicture() async throws {
        // Real Vision on a picture without text: the mode must come up, then settle on "no text found".
        let model = EditorModel(image: TestImage.solid(400, 300), scale: 1)
        let controller = EditorWindowController(model: model)
        controller.toggleTextRecognition(nil)
        XCTAssertEqual(model.tool, .select)
        XCTAssertTrue(model.isTextMode)
        for _ in 0..<600 where model.textMode == .recognizing { try await Task.sleep(nanoseconds: 250_000_000) }
        XCTAssertEqual(model.textMode, .active)
        XCTAssertTrue(model.recognizedText?.isEmpty ?? false)
        XCTAssertNil(model.recognitionError)
        controller.toggleTextRecognition(nil)
        XCTAssertEqual(model.textMode, .off)
        XCTAssertEqual(controller.recognizeButtonIsOn, false)
    }

    func testMenuCommandsThatChangeThePictureAreOffWhileItIsOn() throws {
        let model = EditorModel(image: TestImage.solid(400, 300), scale: 1)
        let controller = EditorWindowController(model: model)
        func enabled(_ action: Selector) -> Bool { controller.validateMenuItem(NSMenuItem(title: "", action: action, keyEquivalent: "")) }

        var box = model.makeAnnotation(.rectangle)
        box.rect = CGRect(x: 10, y: 10, width: 50, height: 50)
        model.add(box)
        XCTAssertTrue(enabled(#selector(EditorWindowController.undo(_:))))
        XCTAssertTrue(enabled(#selector(EditorWindowController.rotateClockwise(_:))))

        let generation = try XCTUnwrap(model.beginTextRecognition())
        model.finishTextRecognition(.success(makeText(["Hello"])), generation: generation)
        for action in [#selector(EditorWindowController.undo(_:)), #selector(EditorWindowController.redo(_:)),
                       #selector(EditorWindowController.rotateClockwise(_:)), #selector(EditorWindowController.autoCropImage(_:)),
                       #selector(EditorWindowController.chooseCropTool(_:)), #selector(EditorWindowController.invertColors(_:)),
                       #selector(EditorWindowController.insertImageFromFile(_:))] {
            XCTAssertFalse(enabled(action), "\(action) must be off while text recognition is on")
        }
        XCTAssertEqual(controller.toolbarUndoRedoEnabled?.undo, false, "the Undo button is off too")

        let rectangle = NSMenuItem(title: "", action: #selector(EditorWindowController.chooseTool(_:)), keyEquivalent: "")
        rectangle.representedObject = EditorTool.rectangle.rawValue
        let select = NSMenuItem(title: "", action: #selector(EditorWindowController.chooseTool(_:)), keyEquivalent: "")
        select.representedObject = EditorTool.select.rawValue
        XCTAssertFalse(controller.validateMenuItem(rectangle))
        XCTAssertTrue(controller.validateMenuItem(select))

        controller.endTextRecognition()
        XCTAssertTrue(enabled(#selector(EditorWindowController.undo(_:))))
        XCTAssertTrue(controller.validateMenuItem(rectangle))
    }

    func testToolPaletteButtonsReportTheLockToo() {
        // The palette draws its buttons from `isToolEnabled`; spot-check the model answers it reads.
        let model = EditorModel(image: TestImage.solid(400, 300), scale: 1)
        XCTAssertTrue(EditorTool.allCases.allSatisfy(model.isToolEnabled))
        _ = model.beginTextRecognition()
        XCTAssertEqual(EditorTool.allCases.filter(model.isToolEnabled), [.select])
    }
}

/// Recognised text stored in saved files.
final class EmbeddedTextTests: XCTestCase {
    private let sample = "Invoice #2026-0142\nCustomer: Contoso Ltd — Café “Zürich” 日本語"

    func testTextRoundTripsInTheFormatsThatCarryIt() throws {
        let image = TestImage.solid(200, 100, (200, 220, 255))
        for format in [ImageFormat.png, .jpg, .tiff] {
            let data = try XCTUnwrap(ImageEncoder.data(for: image, format: format, scale: 2, text: sample), "\(format)")
            XCTAssertEqual(ImageEncoder.embeddedText(in: data), sample, "\(format)")
            let decoded = try XCTUnwrap(ImageEncoder.decode(data))
            XCTAssertEqual(decoded.image.width, 200, "the picture itself is untouched in \(format)")
            XCTAssertEqual(decoded.scale, 2, "the scale still survives next to the text in \(format)")
        }
    }

    func testNoTextMeansNoDescription() throws {
        for format in ImageFormat.allCases {
            let data = try XCTUnwrap(ImageEncoder.data(for: TestImage.solid(50, 50), format: format))
            XCTAssertNil(ImageEncoder.embeddedText(in: data), "\(format)")
            let empty = try XCTUnwrap(ImageEncoder.data(for: TestImage.solid(50, 50), format: format, text: ""))
            XCTAssertNil(ImageEncoder.embeddedText(in: empty), "\(format)")
        }
    }

    func testFormatsWithoutRoomForTextStillSave() throws {
        for format in [ImageFormat.gif, .bmp] {
            let data = try XCTUnwrap(ImageEncoder.data(for: TestImage.solid(50, 50), format: format, text: sample), "\(format)")
            XCTAssertNotNil(ImageEncoder.decode(data))
            XCTAssertNil(ImageEncoder.embeddedText(in: data))
        }
    }

    func testVeryLongTextIsCutAndStillSaves() throws {
        let long = String(repeating: "lorem ipsum dolor ", count: 5000)               // 90 000 characters
        for format in [ImageFormat.png, .jpg, .tiff] {
            let data = try XCTUnwrap(ImageEncoder.data(for: TestImage.solid(60, 60), format: format, text: long), "\(format)")
            let stored = try XCTUnwrap(ImageEncoder.embeddedText(in: data), "\(format)")
            XCTAssertEqual(stored.count, ImageEncoder.maxEmbeddedTextLength, "\(format)")
            XCTAssertNotNil(ImageEncoder.decode(data))
        }
    }

    func testSettingIsOnByDefaultAndPartOfReset() {
        XCTAssertEqual(Preferences.registeredDefaults[Preferences.Key.embedRecognizedText] as? Bool, true)
    }

    @MainActor
    func testSavingFromTheEditorStoresTheRecognisedTextOnlyWhenAllowedAndKnown() throws {
        StyleDefaults.stash()
        defer { StyleDefaults.restore() }
        let key = Preferences.Key.embedRecognizedText
        let previous = UserDefaults.standard.object(forKey: key)
        defer { if let previous { UserDefaults.standard.set(previous, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) } }

        let model = EditorModel(image: TestImage.solid(120, 80), scale: 1)
        let controller = EditorWindowController(model: model)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("whiteshot-ocr-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        func saved(_ name: String) throws -> String? {
            let url = folder.appendingPathComponent(name)
            XCTAssertTrue(controller.write(to: url, asProject: false, format: .png, quality: 0.9))
            return ImageEncoder.embeddedText(in: try Data(contentsOf: url))
        }

        UserDefaults.standard.set(true, forKey: key)
        XCTAssertNil(try saved("none.png"), "recognition has not been run on this picture")

        let generation = try XCTUnwrap(model.beginTextRecognition())
        model.finishTextRecognition(.success(makeText(["Hello", "world"])), generation: generation)
        model.endTextRecognition()
        XCTAssertEqual(try saved("with.png"), "Hello\nworld")

        UserDefaults.standard.set(false, forKey: key)
        XCTAssertNil(try saved("switchedOff.png"), "the setting turns it off")

        UserDefaults.standard.set(true, forKey: key)
        var box = model.makeAnnotation(.rectangle)
        box.rect = CGRect(x: 5, y: 5, width: 30, height: 30)
        model.add(box)
        XCTAssertNil(try saved("afterEdit.png"), "text found before an edit is not stored with the edited picture")
    }
}
