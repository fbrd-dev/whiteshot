import Carbon.HIToolbox
import XCTest
@testable import WhiteShot

/// Shortcut storage runs against a scratch defaults suite, never the real preferences.
final class ShortcutStoreTests: XCTestCase {
    private var suiteName = ""
    private var original: UserDefaults!

    override func setUp() {
        original = ShortcutStore.defaults
        suiteName = "whiteshot.tests.\(UUID().uuidString)"
        ShortcutStore.defaults = UserDefaults(suiteName: suiteName)!
    }

    override func tearDown() {
        ShortcutStore.defaults.removePersistentDomain(forName: suiteName)
        ShortcutStore.defaults = original
    }

    private let f13 = Shortcut(keyCode: kVK_F13, modifiers: 0)
    private let custom = Shortcut(keyCode: kVK_ANSI_8, modifiers: cmdKey | optionKey)

    func testSecondShortcutStartsEmptyAndPrimaryStartsAtTheDefault() {
        for action in HotkeyAction.allCases {
            XCTAssertNil(ShortcutStore.shortcut(for: action, slot: 1), "second slot is empty until the user adds one")
            XCTAssertEqual(ShortcutStore.shortcut(for: action, slot: 0), ShortcutStore.defaultShortcut(for: action, scheme: .own))
            XCTAssertEqual(ShortcutStore.shortcuts(for: action).count, 1)
        }
    }

    func testBothShortcutsAreActiveTogether() {
        ShortcutStore.setShortcut(f13, for: .region, slot: 1)
        XCTAssertEqual(ShortcutStore.shortcuts(for: .region), [ShortcutStore.defaultShortcut(for: .region, scheme: .own), f13])
        // The primary is untouched, so the menu still shows it.
        XCTAssertEqual(ShortcutStore.shortcut(for: .region), ShortcutStore.defaultShortcut(for: .region, scheme: .own))
    }

    func testSecondShortcutCanBeRemovedAgain() {
        ShortcutStore.setShortcut(f13, for: .window, slot: 1)
        XCTAssertTrue(ShortcutStore.isCustomised(.window, slot: 1))
        ShortcutStore.setShortcut(nil, for: .window, slot: 1)
        XCTAssertNil(ShortcutStore.shortcut(for: .window, slot: 1))
        XCTAssertFalse(ShortcutStore.isCustomised(.window, slot: 1))
    }

    func testRestoringThePrimaryBringsBackTheDefaultAndRecordingTheDefaultStoresNothing() {
        ShortcutStore.setShortcut(custom, for: .region, slot: 0)
        XCTAssertEqual(ShortcutStore.shortcut(for: .region), custom)
        ShortcutStore.setShortcut(nil, for: .region, slot: 0)
        XCTAssertEqual(ShortcutStore.shortcut(for: .region), ShortcutStore.defaultShortcut(for: .region, scheme: .own))
        ShortcutStore.setShortcut(ShortcutStore.defaultShortcut(for: .region, scheme: .own), for: .region, slot: 0)
        XCTAssertFalse(ShortcutStore.isCustomised(.region, slot: 0))
    }

    /// Regression: switching between WhiteShot's own and the macOS-style set used to throw the recorded shortcuts away.
    func testEachSetKeepsItsOwnShortcutsWhenSwitching() {
        ShortcutStore.scheme = .own
        ShortcutStore.setShortcut(custom, for: .region, slot: 0)
        ShortcutStore.setShortcut(f13, for: .region, slot: 1)

        ShortcutStore.scheme = .system
        XCTAssertEqual(ShortcutStore.shortcut(for: .region), ShortcutStore.defaultShortcut(for: .region, scheme: .system),
                       "the other set starts from its own defaults")
        XCTAssertNil(ShortcutStore.shortcut(for: .region, slot: 1))
        let systemCustom = Shortcut(keyCode: kVK_ANSI_9, modifiers: controlKey)
        ShortcutStore.setShortcut(systemCustom, for: .window, slot: 0)

        ShortcutStore.scheme = .own
        XCTAssertEqual(ShortcutStore.shortcut(for: .region), custom, "own set's shortcut survived")
        XCTAssertEqual(ShortcutStore.shortcut(for: .region, slot: 1), f13, "own set's second shortcut survived")
        ShortcutStore.scheme = .system
        XCTAssertEqual(ShortcutStore.shortcut(for: .window), systemCustom, "and so did the system set's")
    }

    func testConflictsAreFoundAcrossActionsAndSlots() {
        ShortcutStore.setShortcut(f13, for: .region, slot: 1)
        XCTAssertEqual(ShortcutStore.owner(of: f13), .region)
        XCTAssertNil(ShortcutStore.owner(of: f13, excluding: ShortcutSlot(action: .region, index: 1)), "a slot may keep its own shortcut")
        XCTAssertEqual(ShortcutStore.owner(of: ShortcutStore.defaultShortcut(for: .window, scheme: .own)), .window)
        XCTAssertNil(ShortcutStore.owner(of: custom))
    }

    func testOldSingleListOfChangesMovesToTheActiveSet() throws {
        let legacy = try JSONEncoder().encode(["region": custom])
        ShortcutStore.defaults.set(legacy, forKey: Preferences.Key.legacyShortcutOverrides)
        ShortcutStore.migrateLegacyOverrides()
        XCTAssertEqual(ShortcutStore.shortcut(for: .region), custom)
        XCTAssertNil(ShortcutStore.defaults.data(forKey: Preferences.Key.legacyShortcutOverrides), "the old key is gone")
        ShortcutStore.scheme = .system
        XCTAssertNotEqual(ShortcutStore.shortcut(for: .region), custom, "it belonged to the set that was active")
    }

    func testHotKeyIDsAreDistinctPerSlot() {
        var seen = Set<UInt32>()
        for action in HotkeyAction.allCases {
            for index in 0..<ShortcutStore.slotCount {
                XCTAssertTrue(seen.insert(action.carbonID * 10 + UInt32(index)).inserted)
                XCTAssertEqual((action.carbonID * 10 + UInt32(index)) / 10, action.carbonID)
            }
        }
    }
}

final class ColorCodeTests: XCTestCase {
    func testHexRoundTrip() throws {
        let c = try XCTUnwrap(RGBAColor(hex: "#E8352F"))
        XCTAssertEqual(c.rgb255.r, 0xE8)
        XCTAssertEqual(c.rgb255.g, 0x35)
        XCTAssertEqual(c.rgb255.b, 0x2F)
        XCTAssertEqual(c.hexString, "E8352F")
        XCTAssertEqual(c.a, 1)
    }

    func testHexAcceptsWithoutHashLowercaseAndShortForm() throws {
        XCTAssertEqual(RGBAColor(hex: "e8352f")?.hexString, "E8352F")
        XCTAssertEqual(RGBAColor(hex: "  #fa0 ")?.hexString, "FFAA00")
        XCTAssertEqual(RGBAColor(hex: "000")?.hexString, "000000")
    }

    func testHexWithAlphaDigits() throws {
        let c = try XCTUnwrap(RGBAColor(hex: "#11223380"))
        XCTAssertEqual(c.hexString, "112233")
        XCTAssertEqual(c.a, 128.0 / 255, accuracy: 0.001)
    }

    func testInvalidHexIsRejected() {
        for bad in ["", "#", "12", "12345", "#GGGGGG", "#12345G", "1234567", "#1234567890", "red"] {
            XCTAssertNil(RGBAColor(hex: bad), bad)
        }
    }

    func testChannelsClampAndRound() {
        XCTAssertEqual(RGBAColor(red: 300, green: -5, blue: 128).rgb255 .r, 255)
        XCTAssertEqual(RGBAColor(red: 300, green: -5, blue: 128).rgb255.g, 0)
        XCTAssertEqual(RGBAColor(red: 0, green: 0, blue: 128).hexString, "000080")
    }

    func testTypingAHexCodeKeepsOpacityOrRevivesNone() throws {
        let half = RGBAColor.red.with(alpha: 0.5)
        XCTAssertEqual(half.applying(hex: "#00FF00")?.a ?? 0, 0.5, accuracy: 0.001, "keeps the current opacity")
        XCTAssertEqual(half.applying(hex: "#00FF00")?.hexString, "00FF00")
        XCTAssertEqual(RGBAColor.clear.applying(hex: "#00FF00")?.a, 1, "typing a colour into None makes it visible")
        XCTAssertEqual(half.applying(hex: "#00FF0040")?.a ?? 0, 64.0 / 255, accuracy: 0.001, "explicit alpha digits win")
        XCTAssertNil(half.applying(hex: "nonsense"))
    }

    func testEditingOneChannelKeepsTheOthersAndRevivesNone() {
        let c = RGBAColor(red: 10, green: 20, blue: 30, alpha: 0.7).replacing(green: 200)
        XCTAssertEqual(c.rgb255.r, 10)
        XCTAssertEqual(c.rgb255.g, 200)
        XCTAssertEqual(c.rgb255.b, 30)
        XCTAssertEqual(c.a, 0.7, accuracy: 0.001)
        XCTAssertEqual(RGBAColor.clear.replacing(red: 255).a, 1)
    }

    func testRealColourDisplaysItsCodeAfterAScreenPick() {
        // What the eyedropper hands back is an NSColor in the display's space; its code must be shown in sRGB.
        let picked = RGBAColor(NSColor(srgbRed: 0.5, green: 0.25, blue: 1, alpha: 1))
        XCTAssertEqual(picked.hexString, "8040FF")
    }
}
