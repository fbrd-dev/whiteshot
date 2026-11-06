import XCTest
@testable import WhiteShot

final class FilenamePatternTests: XCTestCase {
    private var context: FilenamePattern.Context {
        var c = DateComponents(); c.year = 2026; c.month = 3; c.day = 7; c.hour = 9; c.minute = 5; c.second = 2
        return FilenamePattern.Context(date: Calendar(identifier: .gregorian).date(from: c)!, title: "Safari", number: 42)
    }

    func testVariablesAreCaseSensitive() {
        XCTAssertEqual(FilenamePattern.expand("${YYYY}-${MM}-${DD} ${hh}.${mm}.${ss}", context: context), "2026-03-07 09.05.02")
        XCTAssertEqual(FilenamePattern.expand("${YY}", context: context), "26")
    }

    func testMillisecondsAreThreeDigitsAndDistinguishRapidCaptures() {
        var c = DateComponents(); c.year = 2026; c.month = 3; c.day = 7; c.hour = 9; c.minute = 5; c.second = 2; c.nanosecond = 7_000_000
        let early = Calendar(identifier: .gregorian).date(from: c)!
        c.nanosecond = 345_000_000
        let late = Calendar(identifier: .gregorian).date(from: c)!
        XCTAssertEqual(FilenamePattern.expand("${ss}-${ms}", context: .init(date: early)), "02-007")
        XCTAssertEqual(FilenamePattern.expand("${ss}-${ms}", context: .init(date: late)), "02-345")
        XCTAssertNotEqual(FilenamePattern.expand(Preferences.defaultPattern, context: .init(date: early)),
                          FilenamePattern.expand(Preferences.defaultPattern, context: .init(date: late)))
    }

    func testDefaultPatternProducesTheDocumentedName() {
        var c = DateComponents(); c.year = 2026; c.month = 11; c.day = 3; c.hour = 9; c.minute = 41; c.second = 7; c.nanosecond = 42_000_000
        let date = Calendar(identifier: .gregorian).date(from: c)!
        XCTAssertEqual(Preferences.defaultPattern, "SCR_${YYYY}-${MM}-${DD}_${hh}-${mm}-${ss}-${ms}")
        XCTAssertEqual(FilenamePattern.relativePath(pattern: Preferences.defaultPattern, context: .init(date: date)),
                       ["SCR_2026-11-03_09-41-07-042"])
    }

    func testTitleAndNumber() {
        XCTAssertEqual(FilenamePattern.expand("${title}_${NUM}", context: context), "Safari_000042")
    }

    func testUnknownVariablesStayAsTyped() {
        XCTAssertEqual(FilenamePattern.expand("${nope}", context: context), "${nope}")
    }

    func testSanitizeRemovesSeparatorsAndLeadingDots() {
        XCTAssertEqual(FilenamePattern.sanitize(component: "a/b:c"), "a-b-c")
        XCTAssertEqual(FilenamePattern.sanitize(component: "..hidden"), "hidden")
    }

    func testSlashInPatternMakesSubfolders() {
        let parts = FilenamePattern.relativePath(pattern: "${YYYY}/${MM}/shot", context: context)
        XCTAssertEqual(parts, ["2026", "03", "shot"])
    }

    func testPathTraversalIsDropped() {
        let parts = FilenamePattern.relativePath(pattern: "../../etc/passwd", context: context)
        XCTAssertFalse(parts.contains(".."))
    }

    func testEmptyPatternFallsBack() {
        XCTAssertEqual(FilenamePattern.relativePath(pattern: "", context: context), ["WhiteShot"])
    }

    func testUniqueURLNeverOverwrites() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = FilenamePattern.uniqueURL(in: dir, components: ["shot"], fileExtension: "png")
        try Data().write(to: first)
        let second = FilenamePattern.uniqueURL(in: dir, components: ["shot"], fileExtension: "png")
        XCTAssertNotEqual(first, second)
        XCTAssertEqual(second.lastPathComponent, "shot 2.png")
    }
}
