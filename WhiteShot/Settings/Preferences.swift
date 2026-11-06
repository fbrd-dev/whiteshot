import Foundation

/// Where a finished capture goes. Any combination can be enabled at once.
struct Destinations: OptionSet {
    let rawValue: Int
    static let editor = Destinations(rawValue: 1 << 0)
    static let clipboard = Destinations(rawValue: 1 << 1)
    static let saveFile = Destinations(rawValue: 1 << 2)
    static let saveAs = Destinations(rawValue: 1 << 3)
    static let print = Destinations(rawValue: 1 << 4)
    static let share = Destinations(rawValue: 1 << 5)
    static let email = Destinations(rawValue: 1 << 6)
    static let pin = Destinations(rawValue: 1 << 7)
}

/// What window captures put around the window.
enum WindowBackground: String, CaseIterable, Identifiable {
    case transparent, white, black
    var id: String { rawValue }

    var title: String {
        switch self {
        case .transparent: return String(localized: "Transparent")
        case .white: return String(localized: "White")
        case .black: return String(localized: "Black")
        }
    }

    /// The colour to lay under the capture, or nil to keep it transparent.
    var fill: RGBAColor? {
        switch self {
        case .transparent: return nil
        case .white: return .white
        case .black: return .black
        }
    }
}

/// Typed access to UserDefaults. SwiftUI views bind to the same keys with `@AppStorage`.
enum Preferences {
    enum Key {
        static let toEditor = "afterCapture.editor"
        static let toClipboard = "afterCapture.clipboard"
        static let toFile = "afterCapture.file"
        static let toSaveAs = "afterCapture.saveAs"
        static let toPrint = "afterCapture.print"
        static let toShare = "afterCapture.share"
        static let toEmail = "afterCapture.email"
        static let toPin = "afterCapture.pin"
        static let askEachTime = "afterCapture.askEachTime"

        static let outputFolder = "output.folder"
        static let filenamePattern = "output.filenamePattern"
        static let imageFormat = "output.format"
        static let jpegQuality = "output.jpegQuality"
        static let copyPathToClipboard = "output.copyPath"
        static let embedRecognizedText = "output.embedRecognizedText"
        static let filenameCounter = "output.counter"

        static let includeCursor = "capture.includeCursor"
        static let captureDelay = "capture.delay"
        static let playSound = "capture.playSound"
        static let showNotifications = "capture.notifications"
        static let showLoupe = "capture.loupe"
        static let windowShadow = "windowCapture.shadow"
        static let windowBackground = "windowCapture.background"
        static let textGrabText = "textGrab.text"
        static let textGrabCodes = "textGrab.codes"

        static let shortcutScheme = "shortcuts.scheme"
        /// Changes the user made to the shortcuts, kept separately for each shortcut set.
        static func shortcutOverrides(for scheme: ShortcutScheme) -> String { "shortcuts.overrides.\(scheme.rawValue)" }
        /// Before the sets kept their own changes there was a single list.
        static let legacyShortcutOverrides = "shortcuts.overrides"
        static let lastRegion = "capture.lastRegion"

        static let launchAtLogin = "general.launchAtLogin"
        static let language = "general.language"
        static let checkForUpdates = "general.checkForUpdates"
        static let lastUpdateCheck = "general.lastUpdateCheck"
        static let skippedVersion = "general.skippedVersion"
        static let hasSeenWelcome = "general.hasSeenWelcome"
    }

    static let defaultPattern = "SCR_${YYYY}-${MM}-${DD}_${hh}-${mm}-${ss}-${ms}"

    /// The default before it changed. Anyone still on it (never edited the field) moves to the new one.
    private static let previousDefaultPattern = "WhiteShot ${YYYY}-${MM}-${DD} ${hh}.${mm}.${ss}"

    /// Every setting's default value. Also the list of what "Reset" clears.
    static var registeredDefaults: [String: Any] {
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        return [
            Key.toEditor: true,
            Key.toClipboard: true,
            Key.toFile: true,
            Key.toSaveAs: false,
            Key.toPrint: false,
            Key.toShare: false,
            Key.toEmail: false,
            Key.toPin: false,
            Key.askEachTime: false,
            Key.outputFolder: pictures.appendingPathComponent("WhiteShot", isDirectory: true).path,
            Key.filenamePattern: defaultPattern,
            Key.imageFormat: ImageFormat.png.rawValue,
            Key.jpegQuality: 90,
            Key.copyPathToClipboard: false,
            Key.embedRecognizedText: true,
            Key.includeCursor: false,
            Key.captureDelay: 0,
            Key.playSound: true,
            Key.showNotifications: true,
            Key.showLoupe: true,
            Key.windowShadow: false,
            Key.windowBackground: WindowBackground.transparent.rawValue,
            Key.textGrabText: true,
            Key.textGrabCodes: true,
            Key.shortcutScheme: ShortcutScheme.own.rawValue,
            Key.launchAtLogin: false,
            Key.language: AppLanguage.system.rawValue,
            Key.checkForUpdates: true,
        ].merging(Dictionary(uniqueKeysWithValues: SensitiveKind.allCases.map { ($0.preferenceKey, $0.enabledByDefault as Any) })) { current, _ in current }
    }

    static func register() {
        if UserDefaults.standard.string(forKey: Key.filenamePattern) == previousDefaultPattern {
            UserDefaults.standard.removeObject(forKey: Key.filenamePattern)
        }
        UserDefaults.standard.register(defaults: registeredDefaults)
    }

    /// Puts every setting back to its default: the options above, recorded shortcuts and the colours,
    /// widths and fonts the editor remembers per tool. Deliberately kept: the running `${NUM}` file
    /// counter, the last captured region and the first-launch / permission flags, which are state
    /// rather than preferences (resetting them would re-show the welcome and restart numbering).
    static func resetToDefaults(in defaults: UserDefaults = .standard) {
        var keys = Set(registeredDefaults.keys)
        keys.formUnion(ShortcutScheme.allCases.map { Key.shortcutOverrides(for: $0) })
        keys.formUnion([Key.legacyShortcutOverrides, Key.skippedVersion, Key.lastUpdateCheck, "settings.selectedTab"])
        for key in keys { defaults.removeObject(forKey: key) }
        // The language choice also lives in the per-app override macOS reads at launch.
        defaults.removeObject(forKey: AppLanguage.appleLanguagesKey)
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix("toolStyle.") { defaults.removeObject(forKey: key) }
    }

    private static var defaults: UserDefaults { .standard }

    static var destinations: Destinations {
        get {
            var set: Destinations = []
            if defaults.bool(forKey: Key.toEditor) { set.insert(.editor) }
            if defaults.bool(forKey: Key.toClipboard) { set.insert(.clipboard) }
            if defaults.bool(forKey: Key.toFile) { set.insert(.saveFile) }
            if defaults.bool(forKey: Key.toSaveAs) { set.insert(.saveAs) }
            if defaults.bool(forKey: Key.toPrint) { set.insert(.print) }
            if defaults.bool(forKey: Key.toShare) { set.insert(.share) }
            if defaults.bool(forKey: Key.toEmail) { set.insert(.email) }
            if defaults.bool(forKey: Key.toPin) { set.insert(.pin) }
            return set
        }
        set {
            defaults.set(newValue.contains(.editor), forKey: Key.toEditor)
            defaults.set(newValue.contains(.clipboard), forKey: Key.toClipboard)
            defaults.set(newValue.contains(.saveFile), forKey: Key.toFile)
            defaults.set(newValue.contains(.saveAs), forKey: Key.toSaveAs)
            defaults.set(newValue.contains(.print), forKey: Key.toPrint)
            defaults.set(newValue.contains(.share), forKey: Key.toShare)
            defaults.set(newValue.contains(.email), forKey: Key.toEmail)
            defaults.set(newValue.contains(.pin), forKey: Key.toPin)
        }
    }

    static var askEachTime: Bool { defaults.bool(forKey: Key.askEachTime) }

    static var outputFolder: URL {
        URL(fileURLWithPath: defaults.string(forKey: Key.outputFolder) ?? NSHomeDirectory(), isDirectory: true)
    }

    static var filenamePattern: String {
        let pattern = defaults.string(forKey: Key.filenamePattern) ?? defaultPattern
        return pattern.trimmingCharacters(in: .whitespaces).isEmpty ? defaultPattern : pattern
    }

    static var imageFormat: ImageFormat {
        ImageFormat(rawValue: defaults.string(forKey: Key.imageFormat) ?? "") ?? .png
    }

    static var jpegQuality: Double { max(0.1, min(1, Double(defaults.integer(forKey: Key.jpegQuality)) / 100)) }
    static var copyPathToClipboard: Bool { defaults.bool(forKey: Key.copyPathToClipboard) }
    static var embedRecognizedText: Bool { defaults.bool(forKey: Key.embedRecognizedText) }
    static var includeCursor: Bool { defaults.bool(forKey: Key.includeCursor) }
    static var captureDelay: Int { max(0, defaults.integer(forKey: Key.captureDelay)) }
    static var playSound: Bool { defaults.bool(forKey: Key.playSound) }
    static var showNotifications: Bool { defaults.bool(forKey: Key.showNotifications) }
    static var showLoupe: Bool { defaults.bool(forKey: Key.showLoupe) }
    static var windowShadow: Bool { defaults.bool(forKey: Key.windowShadow) }
    static var windowBackground: WindowBackground {
        WindowBackground(rawValue: defaults.string(forKey: Key.windowBackground) ?? "") ?? .transparent
    }

    /// What a "grab text" capture copies. Both are on unless switched off.
    static var textGrabWantsText: Bool { defaults.object(forKey: Key.textGrabText) as? Bool ?? true }
    static var textGrabWantsCodes: Bool { defaults.object(forKey: Key.textGrabCodes) as? Bool ?? true }

    /// The kinds of sensitive text the editor points out. A kind never set falls back to its default.
    static func sensitiveKinds(in defaults: UserDefaults = .standard) -> Set<SensitiveKind> {
        Set(SensitiveKind.allCases.filter { defaults.object(forKey: $0.preferenceKey) as? Bool ?? $0.enabledByDefault })
    }

    /// Increments and returns the running number behind the `${NUM}` filename variable.
    static func nextFilenameNumber() -> Int {
        let next = defaults.integer(forKey: Key.filenameCounter) + 1
        defaults.set(next, forKey: Key.filenameCounter)
        return next
    }
}
