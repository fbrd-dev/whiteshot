import XCTest
@testable import WhiteShot

final class EditorModelTests: XCTestCase {
    override func setUp() { super.setUp(); StyleDefaults.stash() }
    override func tearDown() { StyleDefaults.restore(); super.tearDown() }

    private func model(_ w: Int = 100, _ h: Int = 60) -> EditorModel {
        EditorModel(image: TestImage.solid(w, h), scale: 1, displayName: "Test")
    }

    private func box(in model: EditorModel, _ r: CGRect) -> Annotation {
        var a = model.makeAnnotation(.rectangle)
        a.rect = r
        return a
    }

    func testUndoAndRedoAnAddedShape() {
        let m = model()
        m.add(box(in: m, CGRect(x: 5, y: 5, width: 20, height: 20)))
        XCTAssertEqual(m.annotations.count, 1)
        m.undo()
        XCTAssertEqual(m.annotations.count, 0)
        m.redo()
        XCTAssertEqual(m.annotations.count, 1)
    }

    func testDeleteIsUndoable() {
        let m = model()
        m.add(box(in: m, CGRect(x: 5, y: 5, width: 20, height: 20)))
        m.deleteSelection()
        XCTAssertTrue(m.annotations.isEmpty)
        m.undo()
        XCTAssertEqual(m.annotations.count, 1)
    }

    func testCropShiftsAnnotationsAndShrinksImage() {
        let m = model(100, 60)
        m.add(box(in: m, CGRect(x: 40, y: 20, width: 10, height: 10)))
        m.crop(to: CGRect(x: 30, y: 10, width: 50, height: 40))
        XCTAssertEqual(m.imageSize, CGSize(width: 50, height: 40))
        XCTAssertEqual(m.annotations[0].rect.origin, CGPoint(x: 10, y: 10))
        m.undo()
        XCTAssertEqual(m.imageSize, CGSize(width: 100, height: 60))
        XCTAssertEqual(m.annotations[0].rect.origin, CGPoint(x: 40, y: 20))
    }

    func testRotateClockwiseMovesTheAnnotationWithThePixels() throws {
        // A marker in the top-left corner must end up in the top-right after a clockwise turn.
        let base = TestImage.make(width: 100, height: 60) { x, y in (x < 10 && y < 10) ? (255, 0, 0) : (255, 255, 255) }
        let m = EditorModel(image: base, scale: 1)
        var a = m.makeAnnotation(.rectangle)
        a.rect = CGRect(x: 0, y: 0, width: 10, height: 10)
        m.add(a)
        m.rotate(clockwise: true)
        XCTAssertEqual(m.imageSize, CGSize(width: 60, height: 100))
        XCTAssertEqual(TestImage.pixel(m.baseImage, 55, 5).r, 255)
        XCTAssertEqual(TestImage.pixel(m.baseImage, 55, 5).g, 0)
        XCTAssertEqual(m.annotations[0].rect.minX, 50, accuracy: 0.001)
        XCTAssertEqual(m.annotations[0].rect.minY, 0, accuracy: 0.001)
    }

    func testRotateCounterClockwiseMovesTheAnnotationWithThePixels() {
        let base = TestImage.make(width: 100, height: 60) { x, y in (x < 10 && y < 10) ? (255, 0, 0) : (255, 255, 255) }
        let m = EditorModel(image: base, scale: 1)
        var a = m.makeAnnotation(.rectangle)
        a.rect = CGRect(x: 0, y: 0, width: 10, height: 10)
        m.add(a)
        m.rotate(clockwise: false)
        XCTAssertEqual(TestImage.pixel(m.baseImage, 5, 95).g, 0)
        XCTAssertEqual(m.annotations[0].rect.minX, 0, accuracy: 0.001)
        XCTAssertEqual(m.annotations[0].rect.minY, 90, accuracy: 0.001)
    }

    func testResizeScalesAnnotations() {
        let m = model(100, 60)
        m.add(box(in: m, CGRect(x: 10, y: 10, width: 20, height: 20)))
        m.resize(to: CGSize(width: 50, height: 30))
        XCTAssertEqual(m.annotations[0].rect.width, 10, accuracy: 0.001)
        XCTAssertEqual(m.imageSize, CGSize(width: 50, height: 30))
    }

    func testStyleChangeUpdatesSelectionAndRemembersDefault() {
        let m = model()
        m.add(box(in: m, CGRect(x: 5, y: 5, width: 20, height: 20)))
        m.updateStyle { $0.strokeColor = .blue }
        XCTAssertEqual(m.annotations[0].style.strokeColor, .blue)
        XCTAssertEqual(m.style(for: .rectangle).strokeColor, .blue)
    }

    func testSliderLikeChangesCollapseIntoOneUndoStep() {
        let m = model()
        m.add(box(in: m, CGRect(x: 5, y: 5, width: 20, height: 20)))
        let original = m.annotations[0].style.lineWidth
        for width in stride(from: 4.0, through: 12.0, by: 1.0) { m.updateStyle(coalesceKey: "w") { $0.lineWidth = CGFloat(width) } }
        XCTAssertEqual(m.annotations[0].style.lineWidth, 12)
        m.undo()
        XCTAssertEqual(m.annotations[0].style.lineWidth, original)
    }

    func testArrangeBringsToFront() {
        let m = model()
        let a = box(in: m, CGRect(x: 0, y: 0, width: 10, height: 10))
        let b = box(in: m, CGRect(x: 20, y: 0, width: 10, height: 10))
        m.add(a); m.add(b)
        m.selection = [a.id]
        m.arrangeSelection(.front)
        XCTAssertEqual(m.annotations.last?.id, a.id)
        m.arrangeSelection(.back)
        XCTAssertEqual(m.annotations.first?.id, a.id)
    }

    func testDuplicateCreatesIndependentCopy() {
        let m = model()
        m.add(box(in: m, CGRect(x: 0, y: 0, width: 10, height: 10)))
        m.duplicateSelection()
        XCTAssertEqual(m.annotations.count, 2)
        XCTAssertNotEqual(m.annotations[0].id, m.annotations[1].id)
        XCTAssertNotEqual(m.annotations[0].rect.origin, m.annotations[1].rect.origin)
    }

    func testAutoCropRemovesUniformBorder() {
        let base = TestImage.make(width: 60, height: 40) { x, y in (x >= 10 && x < 40 && y >= 5 && y < 25) ? (0, 0, 0) : (255, 255, 255) }
        let m = EditorModel(image: base, scale: 1)
        m.autoCrop()
        XCTAssertEqual(m.imageSize, CGSize(width: 30, height: 20))
    }

    /// The editor must not make a second full-size bitmap while nothing is drawn.
    func testNothingDrawnMeansNoSecondCopyOfTheImage() {
        let m = model(200, 100)
        XCTAssertTrue(m.composite() === m.baseImage, "the canvas shows the base image itself")
        XCTAssertTrue(m.flattenedImage() === m.baseImage, "and saving or copying uses it directly")

        m.add(box(in: m, CGRect(x: 10, y: 10, width: 50, height: 30)))
        XCTAssertFalse(m.composite() === m.baseImage, "with an annotation it must be a real render")
        XCTAssertFalse(m.flattenedImage() === m.baseImage)

        m.undo()
        XCTAssertTrue(m.composite() === m.baseImage, "back to sharing the base after the last annotation is gone")
        m.redo()
        XCTAssertFalse(m.composite() === m.baseImage, "and a render again after redo")
    }

    func testSharedBaseStillExportsCorrectly() throws {
        // The image handed to the encoder is the untouched base: it must encode like any other.
        let m = EditorModel(image: TestImage.solid(30, 20, (10, 200, 30)), scale: 2)
        let data = try XCTUnwrap(ImageEncoder.data(for: m.flattenedImage(), format: .png, scale: m.scale))
        let decoded = try XCTUnwrap(ImageEncoder.decode(data))
        XCTAssertEqual(decoded.image.width, 30)
        XCTAssertEqual(TestImage.pixel(decoded.image, 5, 5).g, 200)
    }

    func testFlattenedImageIncludesAnnotationsButBaseDoesNot() {
        let m = model(40, 40)
        var a = m.makeAnnotation(.rectangle)
        a.rect = CGRect(x: 0, y: 0, width: 40, height: 40)
        a.style.fillColor = .black
        m.add(a)
        XCTAssertEqual(TestImage.pixel(m.flattenedImage(), 20, 20).r, 0)
        XCTAssertEqual(TestImage.pixel(m.baseImage, 20, 20).r, 255)
    }
}

final class AnnotationGeometryTests: XCTestCase {
    private func rectangle(filled: Bool) -> Annotation {
        var s = Style(); s.fillColor = filled ? .red : .clear; s.lineWidth = 2
        var a = Annotation(kind: .rectangle, style: s)
        a.rect = CGRect(x: 10, y: 10, width: 100, height: 60)
        return a
    }

    func testUnfilledRectangleOnlyHitsNearItsOutline() {
        let a = rectangle(filled: false)
        XCTAssertTrue(a.hitTest(CGPoint(x: 10, y: 40), tolerance: 4))
        XCTAssertFalse(a.hitTest(CGPoint(x: 60, y: 40), tolerance: 4), "the empty inside must not steal clicks")
    }

    func testFilledRectangleHitsInside() {
        XCTAssertTrue(rectangle(filled: true).hitTest(CGPoint(x: 60, y: 40), tolerance: 4))
    }

    func testResizingPastTheOppositeEdgeFlipsInsteadOfBreaking() {
        let a = rectangle(filled: true)
        let flipped = a.resized(handle: .right, to: CGPoint(x: -20, y: 40))
        XCTAssertEqual(flipped.rect.minX, -20, accuracy: 0.001)
        XCTAssertEqual(flipped.rect.maxX, 10, accuracy: 0.001)
        XCTAssertGreaterThan(flipped.rect.width, 0)
    }

    func testStepLabelStaysSquare() {
        var a = Annotation(kind: .step, style: Style())
        a.rect = CGRect(x: 0, y: 0, width: 30, height: 30)
        let resized = a.resized(handle: .bottomRight, to: CGPoint(x: 80, y: 50))
        XCTAssertEqual(resized.rect.width, resized.rect.height, accuracy: 0.001)
    }

    func testLineEndpointHandles() {
        var a = Annotation(kind: .line, style: Style())
        a.start = CGPoint(x: 0, y: 0); a.end = CGPoint(x: 50, y: 50)
        XCTAssertEqual(a.handle(at: CGPoint(x: 49, y: 51), tolerance: 6), .end)
        XCTAssertNil(a.handle(at: CGPoint(x: 25, y: 25), tolerance: 6))
    }

    func testFreehandResizeScalesPoints() {
        var a = Annotation(kind: .freehand, style: Style())
        a.points = [CGPoint(x: 0, y: 0), CGPoint(x: 50, y: 25), CGPoint(x: 100, y: 50)]
        let resized = a.resized(handle: .bottomRight, to: CGPoint(x: 200, y: 100))
        XCTAssertEqual(resized.points[1].x, 100, accuracy: 0.001)
        XCTAssertEqual(resized.points[2].y, 100, accuracy: 0.001)
    }

    func testShiftSnapsLineToFortyFiveDegrees() {
        let snapped = snapAngle(of: CGPoint(x: 100, y: 12), around: .zero)
        XCTAssertEqual(snapped.y, 0, accuracy: 0.001)
        let diagonal = snapAngle(of: CGPoint(x: 100, y: 90), around: .zero)
        XCTAssertEqual(diagonal.x, diagonal.y, accuracy: 0.001)
    }

    func testTinyClickIsNotMeaningful() {
        var a = Annotation(kind: .rectangle, style: Style())
        a.rect = CGRect(x: 0, y: 0, width: 1, height: 1)
        XCTAssertFalse(a.isMeaningful)
    }
}

final class FileFormatTests: XCTestCase {
    func testProjectFileRoundTripKeepsAnnotationsEditable() throws {
        let base = TestImage.solid(30, 20)
        var a = Annotation(kind: .text, serial: 3, style: Style())
        a.rect = CGRect(x: 1, y: 2, width: 20, height: 10)
        a.text = "Hello"
        let data = try XCTUnwrap(ProjectFile.encode(image: base, scale: 2, annotations: [a]))
        let decoded = try XCTUnwrap(ProjectFile.decode(data))
        XCTAssertEqual(decoded.annotations, [a])
        XCTAssertEqual(decoded.image.width, 30)
        XCTAssertEqual(decoded.scale, 2)
    }

    func testGarbageIsRejected() {
        XCTAssertNil(ProjectFile.decode(Data("not a project".utf8)))
        XCTAssertNil(ProjectFile.decode(Data()))
    }

    func testEmbeddedImageSurvivesCoding() throws {
        let embedded = try XCTUnwrap(EmbeddedImage(cgImage: TestImage.solid(8, 8, (10, 20, 30))))
        var a = Annotation(kind: .image, style: Style())
        a.image = embedded
        let copy = try JSONDecoder().decode(Annotation.self, from: JSONEncoder().encode(a))
        XCTAssertEqual(copy.image?.cgImage?.width, 8)
    }

    func testEncodersProduceReadableFilesWithScale() throws {
        let image = TestImage.solid(20, 10, (200, 30, 30))
        for format in [ImageFormat.png, .jpg, .gif, .tiff, .bmp] {
            let data = try XCTUnwrap(ImageEncoder.data(for: image, format: format, quality: 0.9, scale: 2), "\(format)")
            let decoded = try XCTUnwrap(ImageEncoder.decode(data), "\(format)")
            XCTAssertEqual(decoded.image.width, 20, "\(format)")
        }
        let png = try XCTUnwrap(ImageEncoder.data(for: image, format: .png, scale: 2))
        XCTAssertEqual(ImageEncoder.decode(png)?.scale, 2)
    }

    func testTransparentImageBecomesWhiteNotBlackInJPEG() throws {
        let clear = try XCTUnwrap(Renderer.makeContext(width: 10, height: 10, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)?.makeImage())
        let data = try XCTUnwrap(ImageEncoder.data(for: clear, format: .jpg, quality: 1))
        let decoded = try XCTUnwrap(ImageEncoder.decode(data))
        XCTAssertGreaterThan(TestImage.pixel(decoded.image, 5, 5).r, 240)
    }
}

final class ImageOpsTests: XCTestCase {
    func testDropShadowGrowsCanvasAndReportsShift() throws {
        let result = try XCTUnwrap(ImageOps.dropShadow(TestImage.solid(40, 30), offset: CGSize(width: 4, height: 4), blur: 6, color: .black))
        XCTAssertGreaterThan(result.image.width, 40)
        XCTAssertGreaterThan(result.shift.x, 0)
        // The original lands exactly at `shift`: its top-left pixel is opaque white there.
        let p = TestImage.pixel(result.image, Int(result.shift.x) + 1, Int(result.shift.y) + 1)
        XCTAssertEqual(p.r, 255)
        XCTAssertEqual(p.a, 255)
    }

    func testBorderAddsColouredFrame() throws {
        let result = try XCTUnwrap(ImageOps.border(TestImage.solid(10, 10), width: 3, color: .red))
        XCTAssertEqual(result.image.width, 16)
        XCTAssertGreaterThan(TestImage.pixel(result.image, 1, 1).r, 200)
        XCTAssertLessThan(TestImage.pixel(result.image, 1, 1).g, 80)
    }

    func testTornEdgeKeepsCentreAndCutsCorners() throws {
        var rng = SystemRandomNumberGenerator()
        var options = ImageOps.TornEdgeOptions()
        options.shadow = false
        let result = try XCTUnwrap(ImageOps.tornEdge(TestImage.solid(120, 80, (0, 0, 0)), options: options, using: &rng))
        let cx = Int(result.shift.x) + 60, cy = Int(result.shift.y) + 40
        XCTAssertEqual(TestImage.pixel(result.image, cx, cy).a, 255)
        XCTAssertEqual(TestImage.pixel(result.image, 0, 0).a, 0, "margin outside the torn edge is transparent")
    }

    func testAdjustColorsBrightens() throws {
        let out = try XCTUnwrap(ImageFiltersTestHelper.brighten(TestImage.solid(8, 8, (100, 100, 100))))
        XCTAssertGreaterThan(TestImage.pixel(out, 4, 4).r, 130)
    }

    func testInvert() throws {
        let out = try XCTUnwrap(ImageFilters.invert(TestImage.solid(8, 8, (10, 20, 30))))
        let p = TestImage.pixel(out, 4, 4)
        XCTAssertEqual(p.r, 245, accuracy: 3)
        XCTAssertEqual(p.b, 225, accuracy: 3)
    }
}

enum ImageFiltersTestHelper {
    static func brighten(_ image: CGImage) -> CGImage? {
        ImageFilters.adjustColors(image, brightness: 0.2, contrast: 1, gamma: 1)
    }
}
