import XCTest
@testable import WhiteShot

final class RendererTests: XCTestCase {
    private func rect(_ r: CGRect, fill: RGBAColor, stroke: RGBAColor = .clear) -> Annotation {
        var s = Style(); s.fillColor = fill; s.strokeColor = stroke; s.lineWidth = 0
        var a = Annotation(kind: .rectangle, style: s)
        a.rect = r
        return a
    }

    func testFilledRectangleIsDrawnAtTheRightPlace() throws {
        let base = TestImage.solid(100, 80)
        let out = try XCTUnwrap(Renderer.render(base: base, annotations: [rect(CGRect(x: 10, y: 20, width: 30, height: 10), fill: .blue)]))
        // y is measured from the top: row 25 is inside, row 5 is not.
        XCTAssertEqual(TestImage.pixel(out, 20, 25).b, 255)
        XCTAssertLessThan(TestImage.pixel(out, 20, 25).r, 10)
        XCTAssertEqual(TestImage.pixel(out, 20, 5).r, 255)
        XCTAssertEqual(TestImage.pixel(out, 20, 5).g, 255)
        XCTAssertEqual(TestImage.pixel(out, 60, 25).r, 255)
    }

    func testPixelateRemovesDetail() throws {
        let base = TestImage.stripes(64, 64)
        var style = Style(); style.obfuscateMode = .pixelate; style.pixelSize = 16
        var a = Annotation(kind: .obfuscate, style: style)
        a.rect = CGRect(x: 0, y: 0, width: 64, height: 64)
        let out = try XCTUnwrap(Renderer.render(base: base, annotations: [a]))
        // Within one 16px block every pixel is the same average grey: the stripes are gone.
        let first = TestImage.pixel(out, 1, 1)
        for x in 0..<16 { XCTAssertEqual(TestImage.pixel(out, x, 3).r, first.r, accuracy: 1) }
        XCTAssertGreaterThan(first.r, 100)
        XCTAssertLessThan(first.r, 160)
    }

    func testBlurSmoothsHardEdges() throws {
        let base = TestImage.stripes(64, 64)
        var style = Style(); style.obfuscateMode = .blur; style.blurRadius = 6
        var a = Annotation(kind: .obfuscate, style: style)
        a.rect = CGRect(x: 0, y: 0, width: 64, height: 64)
        let out = try XCTUnwrap(Renderer.render(base: base, annotations: [a]))
        let values = (8..<56).map { TestImage.pixel(out, $0, 32).r }
        XCTAssertLessThan((values.max() ?? 0) - (values.min() ?? 0), 80, "stripes should be mostly averaged out")
    }

    func testBlackoutIsOpaqueAndLeavesNothingOfTheOriginal() throws {
        let base = TestImage.stripes(40, 40)
        var style = Style(); style.obfuscateMode = .blackout; style.fillColor = .black
        var a = Annotation(kind: .obfuscate, style: style)
        a.rect = CGRect(x: 10, y: 10, width: 20, height: 20)
        let out = try XCTUnwrap(Renderer.render(base: base, annotations: [a]))
        for x in 10..<30 { XCTAssertEqual(TestImage.pixel(out, x, 20).r, 0) }
    }

    func testFilterSeesAnnotationsBelowIt() throws {
        // A red box drawn first and then blacked out: the final pixel must be black, not red.
        let base = TestImage.solid(50, 50)
        let box = rect(CGRect(x: 0, y: 0, width: 50, height: 50), fill: .red)
        var style = Style(); style.obfuscateMode = .blackout; style.fillColor = .black
        var blackout = Annotation(kind: .obfuscate, style: style)
        blackout.rect = CGRect(x: 10, y: 10, width: 20, height: 20)
        let out = try XCTUnwrap(Renderer.render(base: base, annotations: [box, blackout]))
        XCTAssertEqual(TestImage.pixel(out, 15, 15).r, 0)
        XCTAssertGreaterThan(TestImage.pixel(out, 40, 40).r, 200)
    }

    func testTextHighlightKeepsDarkTextVisible() throws {
        let base = TestImage.make(width: 40, height: 20) { x, _ in x < 20 ? (0, 0, 0) : (255, 255, 255) }
        var style = Style(); style.highlightMode = .text; style.highlightColor = .yellow
        var a = Annotation(kind: .highlight, style: style)
        a.rect = CGRect(x: 0, y: 0, width: 40, height: 20)
        let out = try XCTUnwrap(Renderer.render(base: base, annotations: [a]))
        XCTAssertLessThan(TestImage.pixel(out, 5, 5).r, 30, "black stays black under multiply")
        XCTAssertLessThan(TestImage.pixel(out, 30, 5).b, 60, "white turns yellow")
    }

    func testStepLabelsRenumberWhenOneIsRemoved() {
        var s = Style(); s.stepStart = 1
        let a = Annotation(kind: .step, serial: 1, style: s)
        let b = Annotation(kind: .step, serial: 2, style: s)
        let c = Annotation(kind: .step, serial: 3, style: s)
        XCTAssertEqual(Renderer.stepNumbers([a, b, c])[c.id], 3)
        XCTAssertEqual(Renderer.stepNumbers([a, c])[c.id], 2)
    }

    func testShadowAddsPixelsOutsideTheShape() throws {
        let base = TestImage.solid(80, 80)
        var s = Style(); s.fillColor = .red; s.strokeColor = .clear; s.lineWidth = 0; s.shadow = true
        var a = Annotation(kind: .rectangle, style: s)
        a.rect = CGRect(x: 20, y: 20, width: 20, height: 20)
        let out = try XCTUnwrap(Renderer.render(base: base, annotations: [a]))
        // Shadow falls down and to the right of the box.
        XCTAssertLessThan(TestImage.pixel(out, 42, 42).g, 250)
        XCTAssertEqual(TestImage.pixel(out, 10, 10).g, 255)
    }
}
