import XCTest
@testable import WhiteShot

/// The version of the app is the git tag, and the update check compares release tags: nothing else holds a version number.
final class VersioningTests: XCTestCase {
    // MARK: Update check

    private func payload(tag: String, draft: Bool = false, prerelease: Bool = false) -> Data {
        Data("""
        {"url":"https://api.github.com/repos/fbrd-dev/whiteshot/releases/1","tag_name":"\(tag)","name":"WhiteShot",
         "draft":\(draft),"prerelease":\(prerelease),"html_url":"https://github.com/fbrd-dev/whiteshot/releases/tag/\(tag)",
         "body":"What is new","assets":[{"name":"WhiteShot-0.2.0.dmg"}]}
        """.utf8)
    }

    @MainActor
    func testANewerReleaseTagIsOffered() throws {
        let release = try XCTUnwrap(UpdateChecker.newerRelease(in: payload(tag: "v0.2.0"), than: "0.1.0"))
        XCTAssertEqual(release.tag_name, "v0.2.0")
        XCTAssertEqual(release.html_url.absoluteString, "https://github.com/fbrd-dev/whiteshot/releases/tag/v0.2.0")
        XCTAssertEqual(release.body, "What is new")
    }

    @MainActor
    func testTheSameOrAnOlderTagIsNot() throws {
        XCTAssertNil(try UpdateChecker.newerRelease(in: payload(tag: "v0.1.0"), than: "0.1.0"))
        XCTAssertNil(try UpdateChecker.newerRelease(in: payload(tag: "v0.1.0"), than: "0.2.0"))
    }

    @MainActor
    func testDraftsAndPrereleasesAreNeverOffered() throws {
        XCTAssertNil(try UpdateChecker.newerRelease(in: payload(tag: "v9.0.0", draft: true), than: "0.1.0"))
        XCTAssertNil(try UpdateChecker.newerRelease(in: payload(tag: "v9.0.0", prerelease: true), than: "0.1.0"))
    }

    @MainActor
    func testABuildWithoutATagIsOfferedEveryRelease() throws {
        XCTAssertNotNil(try UpdateChecker.newerRelease(in: payload(tag: "v0.1.0"), than: "0.0.0"), "a 0.0.0 build is a development build")
    }

    @MainActor
    func testTheAnswerMayLeaveOutTheOptionalFields() throws {
        let minimal = Data(#"{"tag_name":"v1.0.0","html_url":"https://github.com/fbrd-dev/whiteshot/releases/tag/v1.0.0"}"#.utf8)
        XCTAssertEqual(try UpdateChecker.newerRelease(in: minimal, than: "0.9.0")?.tag_name, "v1.0.0")
        XCTAssertThrowsError(try UpdateChecker.newerRelease(in: Data("{}".utf8), than: "0.9.0"), "not a release at all")
    }

    @MainActor
    func testTheRunningAppReportsAVersionNumber() {
        let version = UpdateChecker.currentVersion
        XCTAssertNotNil(version.range(of: #"^\d+(\.\d+)*$"#, options: .regularExpression), "“\(version)” is not a plain version number")
    }

    // MARK: Stamping the version from the tag

    /// A scratch git repository with a copy of the real stamping script in it, and a plist to stamp.
    private final class Scratch {
        let root: URL
        let plist: URL

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("whiteshot-version-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root.appendingPathComponent("scripts"), withIntermediateDirectories: true)
            let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("scripts/stamp_version.sh")
            try FileManager.default.copyItem(at: source, to: root.appendingPathComponent("scripts/stamp_version.sh"))
            plist = root.appendingPathComponent("Info.plist")
            let data = try PropertyListSerialization.data(fromPropertyList: ["CFBundleShortVersionString": "0.0.0", "CFBundleVersion": "0"], format: .xml, options: 0)
            try data.write(to: plist)
            try git("init", "-q")
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        @discardableResult
        func git(_ args: String...) throws -> String {
            try run("/usr/bin/git", ["-c", "user.name=Test", "-c", "user.email=test@example.com", "-c", "commit.gpgsign=false", "-c", "tag.gpgsign=false"] + args)
        }

        func commit() throws { try git("commit", "-q", "--allow-empty", "-m", "change") }

        @discardableResult
        func stamp() throws -> String { try run(root.appendingPathComponent("scripts/stamp_version.sh").path, [plist.path]) }

        func print() throws -> String { try run(root.appendingPathComponent("scripts/stamp_version.sh").path, ["--print"]) }

        var versions: (short: String?, build: String?) {
            let dict = (try? PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil)) as? [String: Any]
            return (dict?["CFBundleShortVersionString"] as? String, dict?["CFBundleVersion"] as? String)
        }

        private func run(_ path: String, _ args: [String]) throws -> String {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = args
            process.currentDirectoryURL = root
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            try process.run()
            let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            process.waitUntilExit()
            XCTAssertEqual(process.terminationStatus, 0, "\(path) \(args) failed: \(output)")
            return output
        }
    }

    func testTheTagBecomesTheVersion() throws {
        let repo = try Scratch()
        try repo.commit()
        try repo.git("tag", "v1.2.3")
        try repo.stamp()
        XCTAssertEqual(repo.versions.short, "1.2.3")
        XCTAssertEqual(repo.versions.build, "1.2.3")
    }

    func testWithoutATagThePlaceholderStays() throws {
        let repo = try Scratch()
        try repo.commit()
        let output = try repo.stamp()
        XCTAssertEqual(repo.versions.short, "0.0.0")
        XCTAssertTrue(output.contains("no version tag"), output)
    }

    func testTheNewestTagWinsAndCommitsAfterItDoNotChangeTheVersion() throws {
        let repo = try Scratch()
        try repo.commit()
        try repo.git("tag", "v1.2.3")
        try repo.commit()
        try repo.git("tag", "v1.3.0")
        try repo.commit()
        try repo.commit()
        try repo.stamp()
        XCTAssertEqual(repo.versions.short, "1.3.0")
    }

    func testPrintGivesTheVersionOrNothing() throws {
        let repo = try Scratch()
        try repo.commit()
        XCTAssertEqual(try repo.print().trimmingCharacters(in: .whitespacesAndNewlines), "", "no tag, nothing printed")
        try repo.git("tag", "v2.0.1")
        XCTAssertEqual(try repo.print().trimmingCharacters(in: .whitespacesAndNewlines), "2.0.1")
        XCTAssertEqual(repo.versions.short, "0.0.0", "printing never touches the plist")
    }

    func testTagsThatAreNotVersionsAreIgnored() throws {
        let repo = try Scratch()
        try repo.commit()
        try repo.git("tag", "nightly")
        try repo.git("tag", "release-candidate")
        try repo.stamp()
        XCTAssertEqual(repo.versions.short, "0.0.0")
        try repo.git("tag", "v0.4.0")
        try repo.stamp()
        XCTAssertEqual(repo.versions.short, "0.4.0")
    }
}
