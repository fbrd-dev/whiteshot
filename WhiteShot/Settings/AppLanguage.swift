import AppKit

/// The language WhiteShot's menus and windows are shown in.
///
/// "System" is the default and leaves macOS in charge: it picks English or German from the user's system
/// language list (and English for anything else). An explicit choice is stored as the app's own
/// `AppleLanguages` override, which macOS reads when the app starts, so a change needs a restart.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system, en, de

    var id: String { rawValue }

    /// The languages WhiteShot is translated into.
    static let supported = ["en", "de"]

    /// Each language is named in itself, so it can be found whatever language the interface is in.
    var nativeName: String {
        switch self {
        case .system: return String(localized: "System Language")
        case .en: return "English"
        case .de: return "Deutsch"
        }
    }

    // MARK: Detecting the system language

    /// The user's languages as macOS has them, ignoring any override made for this app alone.
    static var systemLanguages: [String] {
        (CFPreferencesCopyValue("AppleLanguages" as CFString, kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesAnyHost) as? [String])
            ?? Locale.preferredLanguages
    }

    /// The supported language that best matches a list of preferred languages (English if none does).
    static func bestMatch(for preferred: [String]) -> AppLanguage {
        let match = Bundle.preferredLocalizations(from: supported, forPreferences: preferred).first ?? "en"
        return AppLanguage(rawValue: match) ?? .en
    }

    /// The language the interface would use if WhiteShot followed the system.
    static var detectedSystemLanguage: AppLanguage { bestMatch(for: systemLanguages) }

    /// What the menu shows for the "System" entry, naming the language it currently resolves to.
    static var systemEntryTitle: String {
        String(localized: "System Language (\(detectedSystemLanguage.nativeName))")
    }

    /// The concrete language a choice results in.
    func resolved(systemLanguages: [String] = AppLanguage.systemLanguages) -> AppLanguage {
        self == .system ? AppLanguage.bestMatch(for: systemLanguages) : self
    }

    /// The language this process is showing right now (it only changes when the app restarts).
    static var running: AppLanguage {
        AppLanguage(rawValue: Bundle.main.preferredLocalizations.first ?? "en") ?? .en
    }

    // MARK: Storing the choice

    static func stored(in defaults: UserDefaults = .standard) -> AppLanguage {
        AppLanguage(rawValue: defaults.string(forKey: Preferences.Key.language) ?? "") ?? .system
    }

    /// Remembers the choice and gives macOS the matching per-app override (or removes it for "System").
    static func store(_ choice: AppLanguage, in defaults: UserDefaults = .standard) {
        defaults.set(choice.rawValue, forKey: Preferences.Key.language)
        if choice == .system {
            defaults.removeObject(forKey: appleLanguagesKey)
        } else {
            defaults.set([choice.rawValue], forKey: appleLanguagesKey)
        }
    }

    static let appleLanguagesKey = "AppleLanguages"
}

/// Relaunches WhiteShot, used after the language was changed.
enum AppRestarter {
    /// Shell command that waits for the running copy to quit, then starts a fresh one.
    static func relaunchCommand(appPath: String) -> String {
        let quoted = "'" + appPath.replacingOccurrences(of: "'", with: "'\\''") + "'"
        return "sleep 1; /usr/bin/open -n \(quoted)"
    }

    /// Quits this copy and starts a new one. The new one is launched by a helper shell after a short wait,
    /// because a second copy that starts while this one is still running hands over to it and quits again.
    @MainActor
    static func relaunch() {
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = ["-c", relaunchCommand(appPath: Bundle.main.bundlePath)]
        try? helper.run()
        NSApp.terminate(nil)
    }

    /// Tells the user a restart is needed to see the new language, and offers to do it now.
    @MainActor
    static func offerRestart(for language: AppLanguage) {
        let alert = NSAlert()
        alert.messageText = String(localized: "Restart to change the language?")
        alert.informativeText = String(localized: "WhiteShot’s menus and windows will switch to \(language.nativeName) after it restarts.")
        alert.addButton(withTitle: String(localized: "Restart Now"))
        alert.addButton(withTitle: String(localized: "Later"))
        if alert.runModal() == .alertFirstButtonReturn { relaunch() }
    }
}
