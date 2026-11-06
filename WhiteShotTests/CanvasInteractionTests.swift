import AppKit
import SwiftUI
import XCTest
@testable import WhiteShot

/// Drives the real CanvasView with synthetic mouse and key events.
@MainActor
final class CanvasInteractionTests: XCTestCase {
    private var window: NSWindow!
    private var canvas: CanvasView!
    private var model: EditorModel!

    override func setUp() async throws {
        StyleDefaults.stash()
        model = EditorModel(image: TestImage.solid(800, 600), scale: 1, displayName: "Test")
        canvas = CanvasView(model: model)
        window = NSWindow(contentRect: NSRect(x: -4000, y: 0, width: 1200, height: 900), styleMask: [.titled], backing: .buffered, defer: false)
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 1200, height: 900))
        window.contentView = container
        container.addSubview(canvas)
        canvas.frame.origin = .zero
        model.zoom = 1
        canvas.syncFrameSize()
        model.onChange = { [weak self] in self?.canvas.modelChanged() }
        window.makeFirstResponder(canvas)
    }

    override func tearDown() async throws {
        model.onChange = nil
        window.close()
        StyleDefaults.restore()
    }

    // MARK: Helpers

    private func viewPoint(_ imagePoint: CGPoint) -> NSPoint {
        let k = canvas.pointsPerPixel
        return canvas.convert(NSPoint(x: imagePoint.x * k, y: imagePoint.y * k), to: nil)
    }

    private func mouse(_ type: NSEvent.EventType, _ p: CGPoint, flags: NSEvent.ModifierFlags = [], clicks: Int = 1) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: viewPoint(p), modifierFlags: flags, timestamp: 0,
                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
    }

    private func drag(from a: CGPoint, to b: CGPoint, flags: NSEvent.ModifierFlags = []) {
        canvas.mouseDown(with: mouse(.leftMouseDown, a, flags: flags))
        let steps = 6
        for i in 1...steps {
            let t = CGFloat(i) / CGFloat(steps)
            canvas.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t), flags: flags))
        }
        canvas.mouseUp(with: mouse(.leftMouseUp, b, flags: flags))
    }

    private func click(_ p: CGPoint, clicks: Int = 1) {
        canvas.mouseDown(with: mouse(.leftMouseDown, p, clicks: clicks))
        canvas.mouseUp(with: mouse(.leftMouseUp, p, clicks: clicks))
    }

    private func key(_ code: UInt16, _ chars: String = "", flags: NSEvent.ModifierFlags = []) {
        let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
                                     windowNumber: window.windowNumber, context: nil, characters: chars,
                                     charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
        canvas.keyDown(with: event)
    }

    // MARK: Drawing

    func testDraggingWithRectangleToolCreatesAndSelectsAShape() {
        model.tool = .rectangle
        drag(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 300, y: 250))
        XCTAssertEqual(model.annotations.count, 1)
        let a = model.annotations[0]
        XCTAssertEqual(a.kind, .rectangle)
        XCTAssertEqual(a.rect.minX, 100, accuracy: 1)
        XCTAssertEqual(a.rect.width, 200, accuracy: 1)
        XCTAssertEqual(a.rect.height, 150, accuracy: 1)
        XCTAssertEqual(model.selection, [a.id])
        XCTAssertTrue(model.isDirty)
        model.undo()
        XCTAssertTrue(model.annotations.isEmpty)
    }

    func testStrayClickWithDrawingToolLeavesNothingAndKeepsDocumentClean() {
        model.tool = .rectangle
        click(CGPoint(x: 200, y: 200))
        XCTAssertTrue(model.annotations.isEmpty)
        XCTAssertFalse(model.isDirty)
        XCTAssertFalse(model.canUndo)
    }

    func testShiftConstrainsToASquare() {
        model.tool = .rectangle
        drag(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 300, y: 160), flags: .shift)
        XCTAssertEqual(model.annotations[0].rect.width, model.annotations[0].rect.height, accuracy: 1)
    }

    func testArrowAndFreehand() {
        model.tool = .arrow
        drag(from: CGPoint(x: 50, y: 50), to: CGPoint(x: 250, y: 150))
        XCTAssertEqual(model.annotations[0].kind, .arrow)
        XCTAssertEqual(model.annotations[0].end.x, 250, accuracy: 1)
        model.tool = .freehand
        drag(from: CGPoint(x: 300, y: 300), to: CGPoint(x: 500, y: 380))
        XCTAssertEqual(model.annotations[1].kind, .freehand)
        XCTAssertGreaterThan(model.annotations[1].points.count, 3)
    }

    func testStepToolPlacesNumberedLabelsInOrder() {
        model.tool = .step
        click(CGPoint(x: 100, y: 100))
        click(CGPoint(x: 200, y: 100))
        XCTAssertEqual(model.annotations.count, 2)
        let numbers = Renderer.stepNumbers(model.annotations)
        XCTAssertEqual(numbers[model.annotations[0].id], 1)
        XCTAssertEqual(numbers[model.annotations[1].id], 2)
        // Removing the first one renumbers the second.
        model.selection = [model.annotations[0].id]
        model.deleteSelection()
        XCTAssertEqual(Renderer.stepNumbers(model.annotations)[model.annotations[0].id], 1)
    }

    func testObfuscateToolProducesACensorRegion() {
        model.tool = .obfuscate
        drag(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 300, y: 140))
        XCTAssertEqual(model.annotations[0].kind, .obfuscate)
        XCTAssertEqual(model.annotations[0].style.obfuscateMode, .pixelate)
    }

    // MARK: Placing things quickly (shapes and numbers that "just disappear")

    /// Placing numbers quickly one after the other: each click must add a new number, however close the previous
    /// (still selected) one is.
    func testQuicklyPlacedNumbersAreAllKept() {
        model.tool = .step
        let spacing: CGFloat = 26   // closer than a step label's own width, like numbering neighbouring things
        for i in 0..<6 { click(CGPoint(x: 100 + CGFloat(i) * spacing, y: 100)) }
        XCTAssertEqual(model.annotations.count, 6, "every click must place a number; got \(model.annotations.count)")
        XCTAssertEqual(Set(model.annotations.map(\.id)).count, 6)
    }

    func testNumberPlacedRightNextToTheSelectedOneIsNotTakenForAResize() {
        model.tool = .step
        click(CGPoint(x: 200, y: 200))
        let first = model.annotations[0]
        // A click on the corner handle of the selected number: the user wants a *new* number there.
        let corner = first.handles()[0].1
        click(corner)
        XCTAssertEqual(model.annotations.count, 2)
        XCTAssertEqual(model.annotations[0].rect, first.rect, "the first number must not have been resized")
    }

    func testNewShapeStartedOnTheEdgeOfTheSelectedOneIsDrawnNotResized() {
        model.tool = .rectangle
        drag(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 200, y: 200))
        let first = model.annotations[0]
        // Draw the neighbouring box starting exactly at the previous box's corner (a handle of the selected shape).
        drag(from: CGPoint(x: 200, y: 200), to: CGPoint(x: 320, y: 300))
        XCTAssertEqual(model.annotations.count, 2, "the second box must be drawn")
        XCTAssertEqual(model.annotations[0].rect, first.rect, "and the first must be untouched")
    }

    /// A very fast flick can deliver mouse-down and mouse-up with no drag events between them.
    func testFastDragWithoutIntermediateEventsStillCreatesTheShape() {
        model.tool = .rectangle
        canvas.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 100, y: 100)))
        canvas.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 260, y: 190)))
        XCTAssertEqual(model.annotations.count, 1, "the shape must end where the mouse was released")
        XCTAssertEqual(model.annotations.first?.rect.width ?? 0, 160, accuracy: 1)
    }

    func testFastDragCreatesAnArrowEndingAtTheReleasePoint() {
        model.tool = .arrow
        canvas.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 50, y: 50)))
        canvas.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 300, y: 120)))
        XCTAssertEqual(model.annotations.count, 1)
        XCTAssertEqual(model.annotations.first?.end.x ?? 0, 300, accuracy: 1)
    }

    /// If a mouse-up is ever lost, the next mouse-down must not throw the unfinished shape away.
    func testALostMouseUpDoesNotLoseTheShapeBeingDrawn() {
        model.tool = .rectangle
        canvas.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 100, y: 100)))
        canvas.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 220, y: 180)))
        // (mouse-up never arrives)
        canvas.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 400, y: 300)))
        canvas.mouseDragged(with: mouse(.leftMouseDragged, CGPoint(x: 500, y: 380)))
        canvas.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 500, y: 380)))
        XCTAssertEqual(model.annotations.count, 2, "both shapes must survive")
        // And both are one undo step each.
        model.undo(); XCTAssertEqual(model.annotations.count, 1)
        model.undo(); XCTAssertEqual(model.annotations.count, 0)
    }

    func testDoubleClickWithADrawingToolStillPlacesTheNumber() {
        model.tool = .step
        click(CGPoint(x: 300, y: 300), clicks: 1)
        click(CGPoint(x: 400, y: 300), clicks: 2)     // a quick second click counts as a double-click
        XCTAssertEqual(model.annotations.count, 2)
    }

    // MARK: Selecting, moving, resizing

    private func addFilledRect(_ r: CGRect) -> Annotation {
        var a = model.makeAnnotation(.rectangle)
        a.rect = r
        a.style.fillColor = .blue
        model.add(a, select: false)
        return a
    }

    func testSelectToolMovesAnObjectAndUndoRestoresIt() {
        let a = addFilledRect(CGRect(x: 100, y: 100, width: 100, height: 100))
        model.tool = .select
        drag(from: CGPoint(x: 150, y: 150), to: CGPoint(x: 210, y: 190))
        let moved = model.annotation(withID: a.id)!
        XCTAssertEqual(moved.rect.minX, 160, accuracy: 1)
        XCTAssertEqual(moved.rect.minY, 140, accuracy: 1)
        model.undo()
        XCTAssertEqual(model.annotation(withID: a.id)!.rect.minX, 100, accuracy: 0.01)
    }

    func testDraggingAHandleResizes() {
        let a = addFilledRect(CGRect(x: 100, y: 100, width: 100, height: 100))
        model.tool = .select
        model.selection = [a.id]
        drag(from: CGPoint(x: 200, y: 200), to: CGPoint(x: 260, y: 240))
        let r = model.annotation(withID: a.id)!.rect
        XCTAssertEqual(r.width, 160, accuracy: 1)
        XCTAssertEqual(r.height, 140, accuracy: 1)
    }

    func testClickingEmptySpaceDeselectsAndMarqueeSelects() {
        let a = addFilledRect(CGRect(x: 100, y: 100, width: 50, height: 50))
        let b = addFilledRect(CGRect(x: 300, y: 100, width: 50, height: 50))
        model.tool = .select
        model.selection = [a.id]
        click(CGPoint(x: 600, y: 500))
        XCTAssertTrue(model.selection.isEmpty)
        drag(from: CGPoint(x: 50, y: 50), to: CGPoint(x: 400, y: 200))
        XCTAssertEqual(model.selection, [a.id, b.id])
    }

    func testShiftClickAddsToSelection() {
        let a = addFilledRect(CGRect(x: 100, y: 100, width: 50, height: 50))
        let b = addFilledRect(CGRect(x: 300, y: 100, width: 50, height: 50))
        model.tool = .select
        click(CGPoint(x: 120, y: 120))
        canvas.mouseDown(with: mouse(.leftMouseDown, CGPoint(x: 320, y: 120), flags: .shift))
        canvas.mouseUp(with: mouse(.leftMouseUp, CGPoint(x: 320, y: 120), flags: .shift))
        XCTAssertEqual(model.selection, [a.id, b.id])
    }

    func testUnfilledShapeDoesNotStealClicksOnItsInside() {
        var outline = model.makeAnnotation(.rectangle)
        outline.rect = CGRect(x: 100, y: 100, width: 300, height: 300)
        outline.style.fillColor = .clear
        model.add(outline, select: false)
        model.tool = .select
        click(CGPoint(x: 250, y: 250))
        XCTAssertTrue(model.selection.isEmpty)
        click(CGPoint(x: 100, y: 250))
        XCTAssertEqual(model.selection, [outline.id])
    }

    // MARK: Keyboard

    func testDeleteKeyRemovesSelection() {
        let a = addFilledRect(CGRect(x: 100, y: 100, width: 50, height: 50))
        model.selection = [a.id]
        key(51)
        XCTAssertTrue(model.annotations.isEmpty)
    }

    func testArrowKeysNudgeAndShiftNudgesByTen() {
        let a = addFilledRect(CGRect(x: 100, y: 100, width: 50, height: 50))
        model.selection = [a.id]
        key(124)
        XCTAssertEqual(model.annotation(withID: a.id)!.rect.minX, 101, accuracy: 0.01)
        key(125, flags: .shift)
        XCTAssertEqual(model.annotation(withID: a.id)!.rect.minY, 110, accuracy: 0.01)
    }

    func testLetterShortcutsSwitchTools() {
        key(15, "r"); XCTAssertEqual(model.tool, .rectangle)
        key(17, "t"); XCTAssertEqual(model.tool, .text)
        key(31, "o"); XCTAssertEqual(model.tool, .obfuscate)
        key(53); XCTAssertEqual(model.tool, .select)
    }

    // MARK: Text

    func testTextToolClickStartsEditingAndCommitsAsOneUndoStep() {
        model.tool = .text
        click(CGPoint(x: 120, y: 120))
        let id = try! XCTUnwrap(model.editingTextID)
        canvas.replaceEditingText(with: "Hello")
        canvas.endTextEditing(commit: true)
        XCTAssertNil(model.editingTextID)
        XCTAssertEqual(model.annotations.count, 1)
        XCTAssertEqual(model.annotations[0].text, "Hello")
        model.undo()
        XCTAssertTrue(model.annotations.isEmpty, "creating and typing is a single undo step")
        model.redo()
        XCTAssertEqual(model.annotations.first?.text, "Hello")
    }

    /// Regression: zooming while typing left the text field where it was at the old zoom.
    func testTextFieldFollowsTheBoxWhenZoomChanges() throws {
        var t = model.makeAnnotation(.text)
        t.rect = CGRect(x: 200, y: 100, width: 300, height: 60)
        t.text = "Zoom"
        model.add(t, select: false)
        canvas.beginTextEditing(id: t.id, isNew: false, before: nil)
        let before = try XCTUnwrap(canvas.editingTextFrame)
        model.zoom = 2
        canvas.syncFrameSize()
        let after = try XCTUnwrap(canvas.editingTextFrame)
        XCTAssertEqual(after.minX, before.minX * 2, accuracy: 1.5)
        XCTAssertEqual(after.minY, before.minY * 2, accuracy: 1.5)
        XCTAssertEqual(after.width, before.width * 2, accuracy: 2)
        canvas.endTextEditing(commit: false)
    }

    func testEmptyTextBoxIsDiscarded() {
        model.tool = .text
        click(CGPoint(x: 120, y: 120))
        canvas.endTextEditing(commit: true)
        XCTAssertTrue(model.annotations.isEmpty)
        XCTAssertFalse(model.isDirty)
    }

    func testDoubleClickEditsExistingText() {
        var t = model.makeAnnotation(.text)
        t.rect = CGRect(x: 100, y: 100, width: 200, height: 40)
        t.text = "Old"
        model.add(t, select: false)
        model.tool = .select
        click(CGPoint(x: 150, y: 120), clicks: 2)
        XCTAssertEqual(model.editingTextID, t.id)
        canvas.replaceEditingText(with: "New")
        canvas.endTextEditing(commit: true)
        XCTAssertEqual(model.annotation(withID: t.id)?.text, "New")
        model.undo()
        XCTAssertEqual(model.annotation(withID: t.id)?.text, "Old")
    }

    func testBubbleGetsATailAndStartsEditing() {
        model.tool = .bubble
        drag(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 300, y: 180))
        XCTAssertNotNil(model.editingTextID)
        let id = model.editingTextID!
        canvas.replaceEditingText(with: "Hi")
        canvas.endTextEditing(commit: true)
        let bubble = model.annotation(withID: id)!
        XCTAssertGreaterThan(bubble.tail.y, bubble.rect.maxY, "tail points below the box")
    }

    // MARK: Crop

    func testCropToolSelectsAreaAndReturnAppliesIt() {
        model.tool = .crop
        drag(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 400, y: 300))
        XCTAssertEqual(model.cropRect?.width ?? 0, 300, accuracy: 1)
        key(36)
        XCTAssertEqual(model.imageSize.width, 300, accuracy: 1)
        XCTAssertEqual(model.imageSize.height, 200, accuracy: 1)
        XCTAssertEqual(model.tool, .select)
        model.undo()
        XCTAssertEqual(model.imageSize, CGSize(width: 800, height: 600))
    }

    func testEscapeCancelsCrop() {
        model.tool = .crop
        drag(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 400, y: 300))
        key(53)
        XCTAssertNil(model.cropRect)
        XCTAssertEqual(model.imageSize, CGSize(width: 800, height: 600))
    }

    // MARK: Zoom

    func testZoomChangesViewSizeButNotCoordinates() {
        model.tool = .rectangle
        model.zoom = 2
        canvas.syncFrameSize()
        drag(from: CGPoint(x: 100, y: 100), to: CGPoint(x: 300, y: 250))
        XCTAssertEqual(model.annotations[0].rect.width, 200, accuracy: 1)
    }
}


/// The tool palette must never be cut off, whatever size the screenshot (and so the window) is.
/// History: first the palette's hosting view was shorter than its content, so Select and Crop got no clicks; later a
/// small screenshot opened a window shorter than the palette, which then overflowed into the status bar.
@MainActor
final class EditorChromeLayoutTests: XCTestCase {
    override func setUp() { StyleDefaults.stash() }
    override func tearDown() { StyleDefaults.restore() }

    private func controller(imageWidth: Int = 300, imageHeight: Int = 200) -> EditorWindowController {
        EditorWindowController(model: EditorModel(image: TestImage.solid(imageWidth, imageHeight), scale: 2))
    }

    /// The height the SwiftUI palette really takes, measured on an unconstrained copy.
    private func renderedHeight(_ density: PaletteDensity, model: EditorModel, controller: EditorWindowController) -> CGFloat {
        let probe = EditorModel(image: TestImage.solid(10, 10), scale: 1)
        probe.paletteDensity = density
        return NSHostingView(rootView: ToolPaletteView(model: probe, commands: controller)).fittingSize.height
    }

    func testComputedPaletteHeightsMatchTheRealRendering() {
        let c = controller()
        for density in [PaletteDensity.regular, .compact] {
            let real = renderedHeight(density, model: c.model, controller: c)
            XCTAssertEqual(ToolPaletteView.contentHeight(for: density), real, accuracy: 3, "\(density)")
        }
        XCTAssertLessThan(ToolPaletteView.contentHeight(for: .compact), ToolPaletteView.contentHeight(for: .regular))
        c.window?.close()
    }

    /// The guarantee: at the smallest window the user can make, the palette still fits whole.
    func testSmallestWindowStillShowsTheWholePalette() throws {
        let c = controller()
        let window = try XCTUnwrap(c.window)
        // AppKit applies the minimum when the user drags the window smaller; it is what limits that.
        XCTAssertGreaterThanOrEqual(window.contentMinSize.height, min(EditorWindowController.minimumContentHeight, (NSScreen.main?.visibleFrame.height ?? 900) * 0.88) - 0.5)

        window.setFrame(NSRect(x: -5000, y: 100, width: 1000, height: 760), display: false)
        window.setContentSize(NSSize(width: window.contentMinSize.width, height: window.contentMinSize.height))
        window.contentView?.layoutSubtreeIfNeeded()
        c.updatePaletteDensity()
        XCTAssertNotEqual(c.model.paletteDensity, .scrolling, "at the minimum size at least the compact palette must fit whole")
        // The palette lies completely inside the window, nothing hangs over the status bar.
        let palette = try XCTUnwrap(c.chromeViews.first { String(describing: type(of: $0)).contains("ToolPaletteView") })
        XCTAssertTrue(window.contentView!.bounds.contains(palette.frame))
        let needed = ToolPaletteView.contentHeight(for: c.model.paletteDensity) + 16
        XCTAssertLessThanOrEqual(needed, palette.frame.height + 0.5, "palette content needs \(needed) pt but its column is \(palette.frame.height) pt")
        c.window?.close()
    }

    func testPaletteDensityFollowsTheAvailableHeight() throws {
        let c = controller()
        let window = try XCTUnwrap(c.window)
        window.setFrame(NSRect(x: -5000, y: 100, width: 1000, height: 1000), display: false)
        window.setContentSize(NSSize(width: 900, height: EditorWindowController.comfortableContentHeight + 40))
        window.contentView?.layoutSubtreeIfNeeded(); c.updatePaletteDensity()
        XCTAssertEqual(c.model.paletteDensity, .regular, "a tall window has room for the regular palette")

        window.setContentSize(NSSize(width: 900, height: EditorWindowController.minimumContentHeight + 4))
        window.contentView?.layoutSubtreeIfNeeded(); c.updatePaletteDensity()
        XCTAssertEqual(c.model.paletteDensity, .compact, "a short window switches to the compact palette")
        c.window?.close()
    }

    func testSmallScreenshotsStillOpenTallEnoughForTheRegularPalette() throws {
        let c = controller(imageWidth: 200, imageHeight: 120)          // a tiny capture
        let window = try XCTUnwrap(c.window)
        window.contentView?.layoutSubtreeIfNeeded()
        let screenLimit = (NSScreen.main?.visibleFrame.height ?? 900) * 0.88
        XCTAssertGreaterThanOrEqual(window.contentLayoutRect.height + 0.5, min(EditorWindowController.comfortableContentHeight, screenLimit) - 1,
                                    "the window opened at \(window.contentLayoutRect.height) pt")
        XCTAssertEqual(c.model.paletteDensity, .regular)
        c.window?.close()
    }

    func testPaletteHostingViewSpansTheCanvasColumn() throws {
        let c = controller()
        let window = try XCTUnwrap(c.window)
        window.contentView?.layoutSubtreeIfNeeded()
        let palette = try XCTUnwrap(c.chromeViews.first { String(describing: type(of: $0)).contains("ToolPaletteView") })
        let canvasColumn = try XCTUnwrap(c.chromeViews.first { $0 is NSScrollView })
        XCTAssertEqual(palette.frame.minY, canvasColumn.frame.minY, accuracy: 1)
        XCTAssertEqual(palette.frame.height, canvasColumn.frame.height, accuracy: 1)
        XCTAssertTrue(window.contentView!.bounds.contains(palette.frame))
        c.window?.close()
    }
}

/// Regression: the toolbar's Redo button stayed enabled when there was nothing to redo.
@MainActor
final class UndoRedoToolbarTests: XCTestCase {
    override func setUp() { StyleDefaults.stash() }
    override func tearDown() { StyleDefaults.restore() }

    func testButtonsFollowWhatCanBeUndoneAndRedone() throws {
        let model = EditorModel(image: TestImage.solid(400, 300), scale: 1)
        let controller = EditorWindowController(model: model)
        let window = try XCTUnwrap(controller.window)
        window.setFrame(NSRect(x: -5000, y: 100, width: 1000, height: 760), display: false)

        func state() throws -> (undo: Bool, redo: Bool) { try XCTUnwrap(controller.toolbarUndoRedoEnabled) }
        var fresh = try state()
        XCTAssertFalse(fresh.undo, "nothing to undo in a new document")
        XCTAssertFalse(fresh.redo, "nothing to redo in a new document")

        var box = model.makeAnnotation(.rectangle)
        box.rect = CGRect(x: 10, y: 10, width: 50, height: 50)
        model.add(box)
        var afterEdit = try state()
        XCTAssertTrue(afterEdit.undo)
        XCTAssertFalse(afterEdit.redo, "a fresh edit leaves nothing to redo")

        model.undo()
        var afterUndo = try state()
        XCTAssertFalse(afterUndo.undo)
        XCTAssertTrue(afterUndo.redo)

        // The toolbar re-validates itself now and then; that must not flip the answer back.
        window.toolbar?.validateVisibleItems()
        afterUndo = try state()
        XCTAssertFalse(afterUndo.undo)
        XCTAssertTrue(afterUndo.redo)

        model.redo()
        afterEdit = try state()
        XCTAssertTrue(afterEdit.undo)
        XCTAssertFalse(afterEdit.redo, "redo is used up again")

        // A drag-style edit registers its undo step later; the buttons must still catch up.
        let before = model.snapshot()
        model.mutateLive { $0[0].move(by: CGPoint(x: 5, y: 5)) }
        model.commit(from: before, name: "Move")
        fresh = try state()
        XCTAssertTrue(fresh.undo)
        window.close()
    }
}
