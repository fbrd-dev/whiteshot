import AppKit
import CoreImage
import XCTest
@testable import WhiteShot

/// Lines of fake recognised text with evenly spaced characters (10 px each, left edge at x = 100).
private func lines(_ rows: [String], codes: [RecognizedCode] = []) -> RecognizedText {
    RecognizedText(lines: rows.enumerated().map { index, text in
        let rect = CGRect(x: 100, y: 50 + CGFloat(index) * 40, width: 10 * CGFloat(text.count), height: 24)
        return RecognizedLine(text: text, rect: rect, edges: (0...text.count).map { 100 + 10 * CGFloat($0) })
    }, codes: codes)
}

final class SensitiveDetectorTests: XCTestCase {
    private func found(_ text: String) -> [(SensitiveKind, String)] {
        SensitiveDetector.matches(in: lines([text])).map { ($0.kind, $0.text) }
    }

    func testFindsEachKind() {
        XCTAssertEqual(found("Mail alex.example+billing@contoso.example now").map(\.0), [.email])
        XCTAssertEqual(found("Mail alex.example+billing@contoso.example now").map(\.1), ["alex.example+billing@contoso.example"])
        XCTAssertEqual(found("IBAN DE89 3704 0044 0532 0130 00 ok").map(\.0), [.iban])
        XCTAssertEqual(found("IBAN DE89 3704 0044 0532 0130 00 ok").map(\.1), ["DE89 3704 0044 0532 0130 00"])
        XCTAssertEqual(found("Card 4111 1111 1111 1111").map(\.0), [.card])
        XCTAssertEqual(found("Call +49 30 1234567 today").map(\.1), ["+49 30 1234567"])
        XCTAssertEqual(found("Call +49 30 1234567 today").map(\.0), [.phone])
        XCTAssertEqual(found("Open https://contoso.example/a/b?c=1 please").map(\.0), [.url])
        XCTAssertEqual(found("Host 192.168.0.12 is down").map(\.0), [.ip])
        XCTAssertEqual(found("Host 192.168.0.12 is down").map(\.1), ["192.168.0.12"])
    }

    func testPlainNumbersAndDatesAreNotPhoneNumbers() {
        for text in ["Invoice #2026-0142", "04.11.2026", "2026-11-04", "Time 13:30:42", "04.11.2026 13:30", "€ 1170.00", "Order 123456789012",
                     "1 000 000", "Version 10.2.1", "Qty 12", "ZIP 10115 Berlin"] {
            XCTAssertTrue(found(text).filter { $0.0 == .phone }.isEmpty, "“\(text)” is not a phone number, found \(found(text))")
        }
    }

    func testNumberFormatsThatAreRealPhoneNumbers() {
        for text in ["+1 (415) 555-2671", "(030) 1234567", "0800 1234567", "0049 30 1234567", "415-555-2671"] {
            XCTAssertEqual(found(text).map(\.0), [.phone], "“\(text)” is a phone number")
        }
    }

    func testChecksumsKeepRandomNumbersOut() {
        XCTAssertTrue(found("Card 4111 1111 1111 1112").isEmpty, "fails the Luhn check")
        XCTAssertTrue(found("IBAN DE89 3704 0044 0532 0130 01").filter { $0.0 == .iban }.isEmpty, "fails the mod-97 check")
        XCTAssertTrue(SensitiveDetector.isValidIBAN("GB82 WEST 1234 5698 7654 32"))
        XCTAssertTrue(SensitiveDetector.isValidIBAN("de89370400440532013000"))
        XCTAssertFalse(SensitiveDetector.isValidIBAN("DE89 3704"))
        XCTAssertTrue(SensitiveDetector.isValidCardNumber("4111-1111-1111-1111"))
        XCTAssertTrue(SensitiveDetector.isValidCardNumber("5500 0000 0000 0004"))
        XCTAssertFalse(SensitiveDetector.isValidCardNumber("0000 0000 0000 0000"), "all the same digit is not a card")
        XCTAssertFalse(SensitiveDetector.isValidCardNumber("4111 1111"))
    }

    func testTheStrongestKindWinsWhereTheyOverlap() {
        let kinds = found("DE89 3704 0044 0532 0130 00").map(\.0)
        XCTAssertEqual(kinds, [.iban], "an IBAN is not also a card or phone number: \(kinds)")
        XCTAssertEqual(found("4111 1111 1111 1111").map(\.0), [.card], "a card number is not also a phone number")
        XCTAssertEqual(found("a@b.example").map(\.0), [.email], "an email is not also a URL or anything else")
    }

    func testSeveralMatchesInOneLineWithTheirPositions() {
        let result = SensitiveDetector.matches(in: lines(["Mail a@b.co or c@d.org"]))
        XCTAssertEqual(result.map(\.text), ["a@b.co", "c@d.org"])
        XCTAssertEqual(result[0].range, 5..<11)
        XCTAssertEqual(result[1].range, 15..<22)
    }

    func testTrailingPunctuationIsNotPartOfAnAddress() {
        XCTAssertEqual(found("see https://x.example/a.").map(\.1), ["https://x.example/a"])
        XCTAssertEqual(found("(https://x.example/a)").map(\.1), ["https://x.example/a"])
    }

    func testRectangleFollowsTheCharacters() throws {
        let recognized = lines(["Contact alex@example.com"])
        let match = try XCTUnwrap(SensitiveDetector.matches(in: recognized).first)
        let rect = SensitiveDetector.rect(of: match, in: recognized)
        XCTAssertEqual(rect.minX, 180, accuracy: 0.01)
        XCTAssertEqual(rect.maxX, 340, accuracy: 0.01)
        XCTAssertEqual(rect.minY, 50, accuracy: 0.01)
        XCTAssertEqual(rect.height, 24, accuracy: 0.01)
    }

    func testMatchesStayOnTheirOwnLines() {
        let result = SensitiveDetector.matches(in: lines(["nothing here", "write to a@b.co", "or 192.168.0.1"]))
        XCTAssertEqual(result.map(\.line), [1, 2])
    }

    func testWhichKindsAreOnIsASetting() throws {
        let suite = "me.fbrd.whiteshot.tests.kinds.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(Preferences.sensitiveKinds(in: defaults), [.email, .phone, .iban, .card], "web and IP addresses start off")
        defaults.set(false, forKey: SensitiveKind.email.preferenceKey)
        defaults.set(true, forKey: SensitiveKind.ip.preferenceKey)
        XCTAssertEqual(Preferences.sensitiveKinds(in: defaults), [.phone, .iban, .card, .ip])
        XCTAssertTrue(Preferences.registeredDefaults.keys.contains(SensitiveKind.url.preferenceKey), "so that Reset covers it")
    }
}

final class RecognizedTextEditingTests: XCTestCase {
    func testRemovingCharactersSplitsALineAroundTheCensoredPart() {
        let recognized = lines(["Contact: alex@example.com or call"])
        // Characters 9...25 are " alex@example.com " → x 190...350.
        let rest = recognized.removingCharacters(coveredBy: [CGRect(x: 192, y: 50, width: 156, height: 24)])
        XCTAssertEqual(rest.lines.map(\.text), ["Contact:", "or call"])
        XCTAssertEqual(rest.lines[0].rect.minX, 100, accuracy: 0.01)
        XCTAssertEqual(rest.lines[0].rect.maxX, 180, accuracy: 0.01)
        XCTAssertEqual(rest.lines[1].rect.minX, 360, accuracy: 0.01, "positions stay in picture coordinates")
        XCTAssertEqual(rest.lines[1].rect.maxX, 430, accuracy: 0.01)
        XCTAssertEqual(rest.lines[1].edges.count, rest.lines[1].text.count + 1)
        XCTAssertEqual(rest.lines[1].edges.first!, rest.lines[1].rect.minX, accuracy: 0.01)
    }

    func testRemovingCharactersKeepsUntouchedLinesAndDropsFullyCoveredOnes() {
        let recognized = lines(["keep me", "cover me", "keep me too"])
        let rest = recognized.removingCharacters(coveredBy: [CGRect(x: 90, y: 90, width: 200, height: 24)])
        XCTAssertEqual(rest.lines.map(\.text), ["keep me", "keep me too"])
        XCTAssertEqual(recognized.removingCharacters(coveredBy: []), recognized)
    }

    func testCodesUnderABoxAreRemovedToo() {
        let code = RecognizedCode(payload: "https://x.example", rect: CGRect(x: 400, y: 50, width: 80, height: 80), isQR: true)
        let recognized = lines(["text"], codes: [code])
        XCTAssertEqual(recognized.removingCharacters(coveredBy: [CGRect(x: 390, y: 40, width: 100, height: 100)]).codes, [])
        XCTAssertEqual(recognized.removingLines(intersecting: [CGRect(x: 390, y: 40, width: 100, height: 100)]).codes, [])
        XCTAssertEqual(recognized.removingCharacters(coveredBy: [CGRect(x: 100, y: 50, width: 10, height: 24)]).codes, [code])
    }

    func testOccurrencesIgnoreCaseAndFindEveryOne() {
        let recognized = lines(["Contoso and CONTOSO", "no match", "contoso.example/contoso"])
        let found = recognized.occurrences(of: "Contoso")
        XCTAssertEqual(found.count, 4)
        XCTAssertEqual(found[0].start, TextPosition(line: 0, offset: 0))
        XCTAssertEqual(found[1].start, TextPosition(line: 0, offset: 12))
        XCTAssertEqual(found[2].start, TextPosition(line: 2, offset: 0))
        XCTAssertEqual(found[3].end, TextPosition(line: 2, offset: 23))
    }

    func testOccurrencesNeedAtLeastTwoCharactersAndOneLine() {
        let recognized = lines(["a b a b", "ab"])
        XCTAssertTrue(recognized.occurrences(of: "a").isEmpty, "a single letter would match everywhere")
        XCTAssertTrue(recognized.occurrences(of: "ab\ncd").isEmpty)
        XCTAssertEqual(recognized.occurrences(of: "  ab  ").count, 1, "surrounding spaces are ignored")
    }

    func testCodeAddressesOpenOnlyForWebAndMail() {
        func code(_ payload: String) -> RecognizedCode { RecognizedCode(payload: payload, rect: .zero, isQR: true) }
        XCTAssertNotNil(code("https://contoso.example/pay").openableURL)
        XCTAssertNotNil(code(" http://contoso.example ").openableURL)
        XCTAssertNotNil(code("mailto:alex@example.com").openableURL)
        for payload in ["tel:+491234567", "file:///etc/hosts", "javascript:alert(1)", "slack://open", "WIFI:S:x;T:WPA;P:y;;", "just text", "ftp://x.example"] {
            XCTAssertNil(code(payload).openableURL, "“\(payload)” must not be opened from a code")
        }
    }

    func testClipboardStringJoinsTextAndCodes() {
        let code = RecognizedCode(payload: "https://x.example", rect: .zero, isQR: true)
        let recognized = lines(["Hello", "world"], codes: [code])
        XCTAssertEqual(TextRecognizer.clipboardString(from: recognized, text: true, codes: true), "Hello\nworld\nhttps://x.example")
        XCTAssertEqual(TextRecognizer.clipboardString(from: recognized, text: true, codes: false), "Hello\nworld")
        XCTAssertEqual(TextRecognizer.clipboardString(from: recognized, text: false, codes: true), "https://x.example")
        XCTAssertEqual(TextRecognizer.clipboardString(from: recognized, text: false, codes: false), "")
    }
}

@MainActor
final class CensorTextModelTests: XCTestCase {
    override func setUp() { StyleDefaults.stash() }
    override func tearDown() { StyleDefaults.restore() }

    /// A model in text mode with the given recognised text and suggestion kinds fixed (not the user's settings).
    private func model(_ recognized: RecognizedText, kinds: Set<SensitiveKind> = [.email, .phone, .iban, .card]) throws -> EditorModel {
        let m = EditorModel(image: TestImage.solid(800, 600), scale: 1)
        m.suggestionKindsProvider = { kinds }
        let generation = try XCTUnwrap(m.beginTextRecognition())
        m.finishTextRecognition(.success(recognized), generation: generation)
        return m
    }

    func testCensoringTheSelectionAddsABoxOverItAndStaysInTextMode() throws {
        let m = try model(lines(["Contact: alex@example.com", "Second line"]))
        m.textSelection = TextSelection(anchor: TextPosition(line: 0, offset: 9), head: TextPosition(line: 0, offset: 25))
        XCTAssertEqual(m.censorSelectedText(), 1)
        XCTAssertEqual(m.annotations.count, 1)
        let box = m.annotations[0]
        XCTAssertEqual(box.kind, .obfuscate)
        XCTAssertLessThanOrEqual(box.rect.minX, 190)
        XCTAssertGreaterThanOrEqual(box.rect.maxX, 350)
        XCTAssertLessThanOrEqual(box.rect.minY, 50)
        XCTAssertGreaterThanOrEqual(box.rect.maxY, 74)
        XCTAssertEqual(m.textMode, .active, "recognition stays on so the next piece of text can be censored too")
        XCTAssertNil(m.textSelection)
        XCTAssertTrue(m.isDirty)
        XCTAssertEqual(m.recognizedText?.lines.map(\.text), ["Contact:", "Second line"], "the text under the box is gone, the rest stays")
        XCTAssertFalse(m.recognizedTextForExport?.contains("alex") ?? false, "and so is it from what would be saved")
    }

    func testCensoringIsOneUndoStepThatLeavesTextMode() throws {
        let m = try model(lines(["a@b.example c@d.example"]))
        m.suggestionKinds = [.email]
        XCTAssertEqual(m.censorSuggestions(), 2)
        XCTAssertEqual(m.annotations.count, 2)
        m.endTextRecognition()
        m.undo()
        XCTAssertTrue(m.annotations.isEmpty, "both boxes go with one undo")
        XCTAssertFalse(m.canUndo)
        XCTAssertNil(m.recognizedText, "undoing changes the picture, so the old recognised text is dropped")
    }

    func testCensorBoxUsesTheCurrentCensorStyle() throws {
        let m = try model(lines(["secret"]))
        m.setCensorMode(.blackout)
        XCTAssertEqual(m.censorMode, .blackout)
        m.textSelection = m.recognizedText?.fullRange
        m.censorSelectedText()
        XCTAssertEqual(m.annotations.first?.style.obfuscateMode, .blackout)
    }

    func testCensorAllOccurrencesCoversEveryPlace() throws {
        let m = try model(lines(["Contoso Ltd", "unrelated", "visit contoso.example"]))
        m.textSelection = m.recognizedText?.occurrences(of: "Contoso").first
        XCTAssertEqual(m.occurrencesOfSelectedText, 2)
        XCTAssertEqual(m.censorAllOccurrencesOfSelectedText(), 2)
        XCTAssertEqual(m.annotations.count, 2)
        XCTAssertEqual(m.recognizedText?.lines.map(\.text), ["Ltd", "unrelated", "visit", "example"])
    }

    func testSuggestionsFollowTheKindsSwitchedOn() throws {
        let recognized = lines(["Mail a@b.example", "Call +49 30 1234567", "Host 192.168.0.12"])
        let m = try model(recognized, kinds: [.email, .phone])
        XCTAssertEqual(m.sensitiveMatches.map(\.kind), [.email, .phone, .ip], "all kinds are found")
        XCTAssertEqual(m.activeSuggestions.map(\.kind), [.email, .phone], "but only the switched-on ones are offered")
        m.toggleSuggestionKind(.phone)
        XCTAssertEqual(m.activeSuggestions.map(\.kind), [.email])
        m.toggleSuggestionKind(.ip)
        XCTAssertEqual(m.activeSuggestions.map(\.kind), [.email, .ip])
        XCTAssertEqual(m.censorSuggestions(), 2)
        XCTAssertEqual(m.annotations.count, 2)
        XCTAssertEqual(m.recognizedText?.lines.map(\.text), ["Mail", "Call +49 30 1234567", "Host"], "the phone number was left alone")
    }

    func testSuggestionsAreRefoundAfterCensoring() throws {
        let m = try model(lines(["a@b.example and c@d.example"]))
        m.suggestionKinds = [.email]
        m.textSelection = TextSelection(anchor: TextPosition(line: 0, offset: 0), head: TextPosition(line: 0, offset: 11))
        m.censorSelectedText()
        XCTAssertEqual(m.sensitiveMatches.map(\.text), ["c@d.example"], "only what is still uncovered is suggested")
    }

    func testNothingHappensWithoutASelectionOrOutsideTextMode() throws {
        let m = try model(lines(["hello"]))
        XCTAssertEqual(m.censorSelectedText(), 0)
        XCTAssertEqual(m.censorAllOccurrencesOfSelectedText(), 0)
        XCTAssertEqual(m.censorSuggestions(), 0)
        XCTAssertTrue(m.annotations.isEmpty)
        m.textSelection = m.recognizedText?.fullRange
        m.endTextRecognition()
        XCTAssertEqual(m.censorSelectedText(), 0, "the selection is gone and the mode is off")
    }

    func testSelectedCodeAndTheBarHeight() throws {
        let code = RecognizedCode(payload: "https://x.example", rect: CGRect(x: 400, y: 100, width: 60, height: 60), isQR: true)
        let m = try model(lines(["text"], codes: [code]))
        XCTAssertNil(m.selectedCode)
        m.selectedCodeIndex = 0
        XCTAssertEqual(m.selectedCode, code)
        XCTAssertEqual(propertyBarHeight(for: m), 76, "a second row for the text actions")
        m.endTextRecognition()
        XCTAssertEqual(propertyBarHeight(for: m), 42)
        let empty = EditorModel(image: TestImage.solid(100, 100), scale: 1)
        _ = empty.beginTextRecognition()
        XCTAssertEqual(propertyBarHeight(for: empty), 42, "while recognising there is only the status row")
    }
}

@MainActor
final class CensorTextCanvasTests: XCTestCase {
    private var window: NSWindow!
    private var canvas: CanvasView!
    private var model: EditorModel!
    private var pasteboard: NSPasteboard!
    private let code = RecognizedCode(payload: "https://contoso.example/pay", rect: CGRect(x: 400, y: 200, width: 80, height: 80), isQR: true)

    override func setUp() async throws {
        StyleDefaults.stash()
        model = EditorModel(image: TestImage.solid(800, 600), scale: 1, displayName: "Test")
        model.suggestionKindsProvider = { [.email] }
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
        model.finishTextRecognition(.success(lines(["Hello a@b.example", "Second line"], codes: [code])), generation: generation)
    }

    override func tearDown() async throws {
        model.onChange = nil
        pasteboard.releaseGlobally()
        window.close()
        StyleDefaults.restore()
    }

    private func viewPoint(_ p: CGPoint) -> NSPoint {
        let k = canvas.pointsPerPixel
        return canvas.convert(NSPoint(x: p.x * k, y: p.y * k), to: nil)
    }

    private func click(_ p: CGPoint) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: viewPoint(p), modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber,
                                           context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            type == .leftMouseDown ? canvas.mouseDown(with: event) : canvas.mouseUp(with: event)
        }
    }

    private func item(_ action: Selector) -> NSMenuItem { NSMenuItem(title: "", action: action, keyEquivalent: "") }

    func testClickingACodePicksItAndCopyPutsItsContentOnThePasteboard() {
        click(CGPoint(x: 440, y: 240))
        XCTAssertEqual(model.selectedCodeIndex, 0)
        XCTAssertEqual(model.selectedCode?.payload, "https://contoso.example/pay")
        XCTAssertTrue(canvas.validateUserInterfaceItem(item(#selector(CanvasView.copy(_:)))))
        canvas.copy(nil)
        XCTAssertEqual(pasteboard.string(forType: .string), "https://contoso.example/pay")
        click(CGPoint(x: 700, y: 500))
        XCTAssertNil(model.selectedCodeIndex, "a click elsewhere puts it down again")
    }

    func testPickingACodeClearsTheTextSelectionAndTheOtherWayAround() {
        model.textSelection = model.recognizedText?.fullRange
        click(CGPoint(x: 440, y: 240))
        XCTAssertNil(model.textSelection)
        click(CGPoint(x: 120, y: 60))                         // on "Hello"
        XCTAssertNil(model.selectedCodeIndex)
    }

    func testTheCensorCommandsFollowTheSelection() {
        let censor = item(#selector(CanvasView.censorSelection(_:)))
        let all = item(#selector(CanvasView.censorAllOccurrences(_:)))
        XCTAssertFalse(canvas.validateUserInterfaceItem(censor))
        XCTAssertFalse(canvas.validateUserInterfaceItem(all))
        model.textSelection = model.recognizedText?.occurrences(of: "Second").first
        XCTAssertTrue(canvas.validateUserInterfaceItem(censor))
        XCTAssertTrue(canvas.validateUserInterfaceItem(all))
        canvas.censorSelection(nil)
        XCTAssertEqual(model.annotations.count, 1)
        XCTAssertEqual(model.annotations.first?.kind, .obfuscate)
    }

    func testContextMenuOffersCensoring() throws {
        let event = NSEvent.mouseEvent(with: .rightMouseDown, location: viewPoint(CGPoint(x: 120, y: 60)), modifierFlags: [], timestamp: 0,
                                       windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        let menu = try XCTUnwrap(canvas.menu(for: event))
        let titles = menu.items.map(\.title)
        XCTAssertTrue(titles.contains("Copy"))
        XCTAssertTrue(titles.contains("Censor Selection"))
        XCTAssertTrue(titles.contains { $0.hasPrefix("Censor All") })
    }
}

/// Vision on a generated QR code.
final class QRRecognitionTests: XCTestCase {
    func testFindsAQRCodeAndItsContentWhereItIs() async throws {
        let filter = try XCTUnwrap(CIFilter(name: "CIQRCodeGenerator"))
        filter.setValue(Data("https://contoso.example/pay/2026-0142".utf8), forKey: "inputMessage")
        let qr = try XCTUnwrap(filter.outputImage).samplingNearest().transformed(by: CGAffineTransform(scaleX: 8, y: 8))
        let context = CIContext()
        let qrImage = try XCTUnwrap(context.createCGImage(qr, from: qr.extent))

        let width = 700, height = 500
        let canvas = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                             space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        canvas.setFillColor(CGColor(gray: 1, alpha: 1))
        canvas.fill(CGRect(x: 0, y: 0, width: width, height: height))
        // Drawn with its lower-left corner at (300, 100) in CG coordinates, i.e. top-left (300, 500 - 100 - side) in picture coordinates.
        let side = CGFloat(qrImage.width)
        canvas.draw(qrImage, in: CGRect(x: 300, y: 100, width: side, height: side))
        let image = try XCTUnwrap(canvas.makeImage())

        let result = try await TextRecognizer.recognize(in: image)
        let code = try XCTUnwrap(result.codes.first, "no code found")
        XCTAssertEqual(code.payload, "https://contoso.example/pay/2026-0142")
        XCTAssertTrue(code.isQR)
        XCTAssertEqual(code.rect.midX, 300 + side / 2, accuracy: 20)
        XCTAssertEqual(code.rect.midY, CGFloat(height) - 100 - side / 2, accuracy: 20)
        XCTAssertNotNil(code.openableURL)

        let onlyText = try await TextRecognizer.recognize(in: image, codes: false)
        XCTAssertTrue(onlyText.codes.isEmpty, "codes can be switched off")
        let onlyCodes = try await TextRecognizer.recognize(in: image, text: false)
        XCTAssertEqual(onlyCodes.codes.count, 1)
    }
}
