import AppKit
import Carbon.HIToolbox

/// The two ready-made shortcut sets. `own` stays out of the way of macOS' built-in screenshot
/// shortcuts; `system` mirrors them so WhiteShot can stand in for them once those are switched off.
enum ShortcutScheme: String, CaseIterable, Identifiable {
    case own, system
    var id: String { rawValue }
}

enum HotkeyAction: String, CaseIterable, Identifiable, Codable {
    case region, lastRegion, fullScreen, window, textGrab
    var id: String { rawValue }

    var title: String {
        switch self {
        case .region: return String(localized: "Capture Region")
        case .lastRegion: return String(localized: "Capture Last Region")
        case .fullScreen: return String(localized: "Capture Full Screen")
        case .window: return String(localized: "Capture Window")
        case .textGrab: return String(localized: "Grab Text")
        }
    }

    /// Stable numeric id for the Carbon hot key registration.
    var carbonID: UInt32 {
        switch self {
        case .region: return 1
        case .lastRegion: return 2
        case .fullScreen: return 3
        case .window: return 4
        case .textGrab: return 5
        }
    }
}

struct Shortcut: Codable, Equatable, Hashable {
    var keyCode: UInt32
    /// Carbon modifier mask (`cmdKey`, `shiftKey`, `optionKey`, `controlKey`).
    var modifiers: UInt32

    init(keyCode: Int, modifiers: Int) {
        self.keyCode = UInt32(keyCode)
        self.modifiers = UInt32(modifiers)
    }

    init?(event: NSEvent) {
        let mods = Shortcut.carbonModifiers(from: event.modifierFlags)
        let isFunctionKey = Shortcut.functionKeyNames[Int(event.keyCode)] != nil
        // A bare letter would hijack normal typing everywhere, so require a modifier (except F-keys).
        guard mods != 0 || isFunctionKey else { return nil }
        self.init(keyCode: Int(event.keyCode), modifiers: Int(mods))
    }

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var mods: UInt32 = 0
        if flags.contains(.command) { mods |= UInt32(cmdKey) }
        if flags.contains(.shift) { mods |= UInt32(shiftKey) }
        if flags.contains(.option) { mods |= UInt32(optionKey) }
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        return mods
    }

    var displayString: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + Shortcut.keyName(for: keyCode)
    }

    private static let specialKeyNames: [Int: String] = [
        kVK_Return: "↩", kVK_Tab: "⇥", kVK_Space: "Space", kVK_Delete: "⌫", kVK_Escape: "⎋",
        kVK_LeftArrow: "←", kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
        kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟", kVK_ForwardDelete: "⌦",
    ]

    static let functionKeyNames: [Int: String] = [
        kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4", kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7",
        kVK_F8: "F8", kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12", kVK_F13: "F13",
        kVK_F14: "F14", kVK_F15: "F15", kVK_F16: "F16", kVK_F17: "F17", kVK_F18: "F18", kVK_F19: "F19", kVK_F20: "F20",
    ]

    static func keyName(for keyCode: UInt32) -> String {
        let code = Int(keyCode)
        if let name = specialKeyNames[code] ?? functionKeyNames[code] { return name }
        // Ask the active keyboard layout so the label matches what the key actually types.
        guard let source = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return "?" }
        let layout = unsafeBitCast(raw, to: CFData.self)
        let layoutPtr = unsafeBitCast(CFDataGetBytePtr(layout), to: UnsafePointer<UCKeyboardLayout>.self)
        var deadKeys: UInt32 = 0
        var chars = [UniChar](repeating: 0, count: 4)
        var length = 0
        let status = UCKeyTranslate(layoutPtr, UInt16(code), UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                                    OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, chars.count, &length, &chars)
        guard status == noErr, length > 0 else { return "?" }
        return String(utf16CodeUnits: chars, count: length).uppercased()
    }
}

/// One of the shortcuts an action can have. Slot 0 is the primary and starts out as the set's default;
/// slot 1 is the second shortcut and starts out empty. Both are active at the same time.
struct ShortcutSlot: Hashable {
    let action: HotkeyAction
    let index: Int
}

/// Resolves which shortcuts are active for each action, from the chosen set plus the user's own changes.
/// Each set ("WhiteShot's own" and "macOS style") remembers its own changes, so switching between the
/// sets never loses what was recorded in the other one.
enum ShortcutStore {
    static let didChange = Notification.Name("WhiteShotShortcutsDidChange")
    /// Primary and second shortcut.
    static let slotCount = 2

    /// Where preferences live. Tests point this at a scratch suite so they never touch the real ones.
    static var defaults: UserDefaults = .standard

    static var scheme: ShortcutScheme {
        get { ShortcutScheme(rawValue: defaults.string(forKey: Preferences.Key.shortcutScheme) ?? "") ?? .own }
        set {
            defaults.set(newValue.rawValue, forKey: Preferences.Key.shortcutScheme)
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }

    static func defaultShortcut(for action: HotkeyAction, scheme: ShortcutScheme) -> Shortcut {
        let mods: Int
        switch scheme {
        case .own: mods = controlKey | shiftKey
        case .system: mods = cmdKey | shiftKey
        }
        switch action {
        case .fullScreen: return Shortcut(keyCode: kVK_ANSI_3, modifiers: mods)
        case .region: return Shortcut(keyCode: kVK_ANSI_4, modifiers: mods)
        case .window: return Shortcut(keyCode: kVK_ANSI_5, modifiers: mods)
        case .lastRegion: return Shortcut(keyCode: kVK_ANSI_6, modifiers: mods)
        case .textGrab: return Shortcut(keyCode: kVK_ANSI_7, modifiers: mods)
        }
    }

    // MARK: Storage

    private static func slotKey(_ action: HotkeyAction, _ index: Int) -> String { "\(action.rawValue).\(index)" }

    private static func changes(for scheme: ShortcutScheme) -> [String: Shortcut] {
        guard let data = defaults.data(forKey: Preferences.Key.shortcutOverrides(for: scheme)),
              let decoded = try? JSONDecoder().decode([String: Shortcut].self, from: data) else { return [:] }
        return decoded
    }

    private static func setChanges(_ map: [String: Shortcut], for scheme: ShortcutScheme) {
        let key = Preferences.Key.shortcutOverrides(for: scheme)
        if map.isEmpty {
            defaults.removeObject(forKey: key)
        } else if let data = try? JSONEncoder().encode(map) {
            defaults.set(data, forKey: key)
        }
    }

    /// Versions up to 0.1 kept one flat list of changes for whichever set was active. Move it over.
    static func migrateLegacyOverrides() {
        guard let data = defaults.data(forKey: Preferences.Key.legacyShortcutOverrides) else { return }
        defaults.removeObject(forKey: Preferences.Key.legacyShortcutOverrides)
        guard let old = try? JSONDecoder().decode([String: Shortcut].self, from: data), !old.isEmpty else { return }
        var map = changes(for: scheme)
        for (action, shortcut) in old where map["\(action).0"] == nil { map["\(action).0"] = shortcut }
        setChanges(map, for: scheme)
    }

    // MARK: Reading

    /// The shortcut in `slot` for the active set, or nil if that slot is empty.
    static func shortcut(for action: HotkeyAction, slot: Int, scheme: ShortcutScheme? = nil) -> Shortcut? {
        let scheme = scheme ?? self.scheme
        if let custom = changes(for: scheme)[slotKey(action, slot)] { return custom }
        return slot == 0 ? defaultShortcut(for: action, scheme: scheme) : nil
    }

    /// The primary shortcut, the one shown in menus.
    static func shortcut(for action: HotkeyAction) -> Shortcut {
        shortcut(for: action, slot: 0) ?? defaultShortcut(for: action, scheme: scheme)
    }

    /// Every shortcut that currently triggers `action`.
    static func shortcuts(for action: HotkeyAction) -> [Shortcut] {
        (0..<slotCount).compactMap { shortcut(for: action, slot: $0) }
    }

    static func isCustomised(_ action: HotkeyAction, slot: Int) -> Bool {
        changes(for: scheme)[slotKey(action, slot)] != nil
    }

    /// The action already using `shortcut` in the active set, ignoring `slot` itself.
    static func owner(of shortcut: Shortcut, excluding slot: ShortcutSlot? = nil) -> HotkeyAction? {
        for action in HotkeyAction.allCases {
            for index in 0..<slotCount where ShortcutSlot(action: action, index: index) != slot {
                if self.shortcut(for: action, slot: index) == shortcut { return action }
            }
        }
        return nil
    }

    // MARK: Changing

    /// Records `shortcut` for the slot. `nil` restores the primary to its default, or empties the second.
    static func setShortcut(_ shortcut: Shortcut?, for action: HotkeyAction, slot: Int) {
        var map = changes(for: scheme)
        let key = slotKey(action, slot)
        if let shortcut, !(slot == 0 && shortcut == defaultShortcut(for: action, scheme: scheme)) {
            map[key] = shortcut
        } else {
            map.removeValue(forKey: key)
        }
        setChanges(map, for: scheme)
        NotificationCenter.default.post(name: didChange, object: nil)
    }
}

/// macOS' own screenshot shortcuts win over any app's, so tell the user when a chosen shortcut is shadowed.
enum SystemShortcutConflicts {
    /// Symbolic hot key ids and the combination each one uses by default.
    private static let systemScreenshots: [(id: String, shortcut: Shortcut)] = [
        ("28", Shortcut(keyCode: kVK_ANSI_3, modifiers: cmdKey | shiftKey)),
        ("29", Shortcut(keyCode: kVK_ANSI_3, modifiers: cmdKey | shiftKey | controlKey)),
        ("30", Shortcut(keyCode: kVK_ANSI_4, modifiers: cmdKey | shiftKey)),
        ("31", Shortcut(keyCode: kVK_ANSI_4, modifiers: cmdKey | shiftKey | controlKey)),
        ("184", Shortcut(keyCode: kVK_ANSI_5, modifiers: cmdKey | shiftKey)),
    ]

    /// Shortcuts WhiteShot uses that macOS' screenshot shortcuts currently intercept.
    static func shadowedSlots() -> [ShortcutSlot] {
        guard let all = CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, "com.apple.symbolichotkeys" as CFString) as? [String: Any]
        else { return [] }
        let enabled = systemScreenshots.filter { entry in
            guard let item = all[entry.id] as? [String: Any] else { return true }   // absent = system default (on)
            return (item["enabled"] as? Bool) ?? ((item["enabled"] as? Int) == 1)
        }.map(\.shortcut)
        return HotkeyAction.allCases.flatMap { action in
            (0..<ShortcutStore.slotCount).compactMap { index -> ShortcutSlot? in
                guard let shortcut = ShortcutStore.shortcut(for: action, slot: index), enabled.contains(shortcut) else { return nil }
                return ShortcutSlot(action: action, index: index)
            }
        }
    }
}
