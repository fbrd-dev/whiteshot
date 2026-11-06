import XCTest
@testable import WhiteShot

final class AppLogicTests: XCTestCase {
    @MainActor
    func testVersionComparison() {
        XCTAssertTrue(UpdateChecker.isNewer("v0.2.0", than: "0.1.0"))
        XCTAssertTrue(UpdateChecker.isNewer("1.0", than: "0.9.9"))
        XCTAssertTrue(UpdateChecker.isNewer("0.10.0", than: "0.9.0"), "numeric, not alphabetical")
        XCTAssertFalse(UpdateChecker.isNewer("0.1.0", than: "0.1.0"))
        XCTAssertFalse(UpdateChecker.isNewer("0.1", than: "0.1.0"))
        XCTAssertFalse(UpdateChecker.isNewer("v0.0.9", than: "0.1.0"))
        XCTAssertTrue(UpdateChecker.isNewer("v1.2.0-beta", than: "1.1.0"))
    }

    func testOwnShortcutsAvoidTheSystemOnes() {
        for action in HotkeyAction.allCases {
            let own = ShortcutStore.defaultShortcut(for: action, scheme: .own)
            let system = ShortcutStore.defaultShortcut(for: action, scheme: .system)
            XCTAssertNotEqual(own, system)
            XCTAssertTrue(own.displayString.hasPrefix("⌃⇧"), own.displayString)
            XCTAssertTrue(system.displayString.hasPrefix("⇧⌘"), system.displayString)
        }
    }

    func testShortcutDisplayStrings() {
        XCTAssertEqual(ShortcutStore.defaultShortcut(for: .region, scheme: .own).displayString, "⌃⇧4")
        XCTAssertEqual(ShortcutStore.defaultShortcut(for: .fullScreen, scheme: .system).displayString, "⇧⌘3")
    }

    func testAllActionsHaveDistinctShortcutsAndIDs() {
        for scheme in ShortcutScheme.allCases {
            let shortcuts = HotkeyAction.allCases.map { ShortcutStore.defaultShortcut(for: $0, scheme: scheme) }
            XCTAssertEqual(Set(shortcuts).count, shortcuts.count)
        }
        XCTAssertEqual(Set(HotkeyAction.allCases.map(\.carbonID)).count, HotkeyAction.allCases.count)
    }

    // MARK: Defaults and reset

    func testSaveToFileIsOnByDefaultAlongsideEditorAndClipboard() {
        let defaults = Preferences.registeredDefaults
        XCTAssertEqual(defaults[Preferences.Key.toFile] as? Bool, true)
        XCTAssertEqual(defaults[Preferences.Key.toEditor] as? Bool, true)
        XCTAssertEqual(defaults[Preferences.Key.toClipboard] as? Bool, true)
        XCTAssertEqual(defaults[Preferences.Key.toPrint] as? Bool, false)
    }

    private func scratchDefaults() -> (UserDefaults, () -> Void) {
        let name = "whiteshot.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        return (defaults, { defaults.removePersistentDomain(forName: name) })
    }

    func testResetRestoresDefaultsButKeepsStateLikeTheFileCounter() {
        let (d, cleanup) = scratchDefaults()
        defer { cleanup() }
        d.register(defaults: Preferences.registeredDefaults)
        d.set(7, forKey: Preferences.Key.captureDelay)
        d.set(false, forKey: Preferences.Key.toFile)
        d.set("system", forKey: Preferences.Key.shortcutScheme)
        d.set(Data("override".utf8), forKey: Preferences.Key.shortcutOverrides(for: .own))
        d.set(Data("style".utf8), forKey: "toolStyle.arrow")
        d.set("/tmp/elsewhere", forKey: Preferences.Key.outputFolder)
        // State that must survive a reset:
        d.set(5, forKey: Preferences.Key.filenameCounter)
        d.set(true, forKey: Preferences.Key.hasSeenWelcome)
        d.set(Data("region".utf8), forKey: Preferences.Key.lastRegion)

        Preferences.resetToDefaults(in: d)

        XCTAssertEqual(d.integer(forKey: Preferences.Key.captureDelay), 0)
        XCTAssertTrue(d.bool(forKey: Preferences.Key.toFile), "back to the new default")
        XCTAssertEqual(d.string(forKey: Preferences.Key.shortcutScheme), "own")
        XCTAssertNil(d.data(forKey: Preferences.Key.shortcutOverrides(for: .own)))
        XCTAssertNil(d.data(forKey: "toolStyle.arrow"))
        XCTAssertEqual(d.string(forKey: Preferences.Key.outputFolder), Preferences.registeredDefaults[Preferences.Key.outputFolder] as? String)
        XCTAssertEqual(d.integer(forKey: Preferences.Key.filenameCounter), 5)
        XCTAssertTrue(d.bool(forKey: Preferences.Key.hasSeenWelcome))
        XCTAssertNotNil(d.data(forKey: Preferences.Key.lastRegion))
    }

    /// Guards against forgetting a new setting: anything that has a registered default is reset.
    /// (Checks what the suite itself stores: registered defaults and the system-wide domain also show through `object(forKey:)`.)
    func testEveryRegisteredSettingIsCleared() {
        let name = "whiteshot.tests.\(UUID().uuidString)"
        let d = UserDefaults(suiteName: name)!
        defer { d.removePersistentDomain(forName: name) }
        for key in Preferences.registeredDefaults.keys { d.set("changed", forKey: key) }
        Preferences.resetToDefaults(in: d)
        let stored = d.persistentDomain(forName: name) ?? [:]
        for key in Preferences.registeredDefaults.keys {
            XCTAssertNil(stored[key], "\(key) was not reset")
        }
    }
}

final class AppLanguageTests: XCTestCase {
    private var suiteName = ""
    private var d: UserDefaults!

    override func setUp() {
        suiteName = "whiteshot.tests.\(UUID().uuidString)"
        d = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() { d.removePersistentDomain(forName: suiteName) }

    /// What this suite itself has stored for the per-app language override. (`array(forKey:)` would also
    /// return the system-wide AppleLanguages from the global domain.)
    private var storedOverride: [String]? { d.persistentDomain(forName: suiteName)?[AppLanguage.appleLanguagesKey] as? [String] }

    func testSystemLanguageIsDetectedFromThePreferredList() {
        XCTAssertEqual(AppLanguage.bestMatch(for: ["de-DE", "en-US"]), .de)
        XCTAssertEqual(AppLanguage.bestMatch(for: ["en-GB", "de"]), .en)
        XCTAssertEqual(AppLanguage.bestMatch(for: ["de-AT"]), .de, "regional German is still German")
        XCTAssertEqual(AppLanguage.bestMatch(for: ["fr-FR", "de-DE"]), .de, "falls through to the first supported language")
    }

    func testAnUnsupportedSystemLanguageFallsBackToEnglish() {
        XCTAssertEqual(AppLanguage.bestMatch(for: ["fr-FR"]), .en)
        XCTAssertEqual(AppLanguage.bestMatch(for: ["ja-JP", "es-ES"]), .en)
        XCTAssertEqual(AppLanguage.bestMatch(for: []), .en)
    }

    func testSystemChoiceFollowsTheSystemAndExplicitChoicesDoNot() {
        XCTAssertEqual(AppLanguage.system.resolved(systemLanguages: ["de-DE"]), .de)
        XCTAssertEqual(AppLanguage.system.resolved(systemLanguages: ["fr"]), .en)
        XCTAssertEqual(AppLanguage.en.resolved(systemLanguages: ["de-DE"]), .en)
        XCTAssertEqual(AppLanguage.de.resolved(systemLanguages: ["en-US"]), .de)
    }

    func testDefaultIsSystemLanguage() {
        d.register(defaults: Preferences.registeredDefaults)
        XCTAssertEqual(AppLanguage.stored(in: d), .system)
        XCTAssertNil(storedOverride, "no per-app override while following the system")
    }

    func testChoosingALanguageSetsTheOverrideAndSystemRemovesIt() {
        AppLanguage.store(.de, in: d)
        XCTAssertEqual(AppLanguage.stored(in: d), .de)
        XCTAssertEqual(storedOverride, ["de"])
        AppLanguage.store(.en, in: d)
        XCTAssertEqual(storedOverride, ["en"])
        AppLanguage.store(.system, in: d)
        XCTAssertEqual(AppLanguage.stored(in: d), .system)
        XCTAssertNil(storedOverride, "back to following macOS")
    }

    func testResetGoesBackToTheSystemLanguage() {
        AppLanguage.store(.de, in: d)
        Preferences.resetToDefaults(in: d)
        XCTAssertEqual(AppLanguage.stored(in: d), .system)
        XCTAssertNil(storedOverride)
    }

    func testRelaunchCommandQuotesPathsSafely() {
        XCTAssertEqual(AppRestarter.relaunchCommand(appPath: "/Applications/WhiteShot.app"), "sleep 1; /usr/bin/open -n '/Applications/WhiteShot.app'")
        let nasty = AppRestarter.relaunchCommand(appPath: "/tmp/it's a; rm -rf x/WhiteShot.app")
        XCTAssertTrue(nasty.contains("'/tmp/it'\\''s a; rm -rf x/WhiteShot.app'"), nasty)
    }

    func testBothLanguagesHaveNamesInThemselves() {
        XCTAssertEqual(AppLanguage.en.nativeName, "English")
        XCTAssertEqual(AppLanguage.de.nativeName, "Deutsch")
        XCTAssertEqual(AppLanguage.allCases.count, 3)
    }
}
