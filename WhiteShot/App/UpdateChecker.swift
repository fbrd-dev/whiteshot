import AppKit

/// Looks for a newer release on GitHub and tells the user. It never downloads or installs anything.
@MainActor
enum UpdateChecker {
    static let repository = "fbrd-dev/whiteshot"
    static var releasesPage: URL { URL(string: "https://github.com/\(repository)/releases")! }

    /// The part of GitHub's "latest release" answer that matters here.
    struct Release: Decodable {
        let tag_name: String
        let html_url: URL
        let body: String?
        let draft: Bool?
        let prerelease: Bool?
    }

    /// The version of the running app. It is the git tag the app was built from (see `scripts/stamp_version.sh`), nothing
    /// maintained by hand; "0.0.0" means a build made without a tag.
    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Dotted-number comparison that tolerates a leading "v" and trailing text such as "-beta".
    static func isNewer(_ remote: String, than local: String) -> Bool {
        func parts(_ version: String) -> [Int] {
            var v = version.trimmingCharacters(in: .whitespaces)
            if v.hasPrefix("v") || v.hasPrefix("V") { v.removeFirst() }
            let core = v.split(whereSeparator: { $0 == "-" || $0 == "+" }).first.map(String.init) ?? v
            return core.split(separator: ".").map { Int($0) ?? 0 }
        }
        let a = parts(remote), b = parts(local)
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// The release in GitHub's answer, if it is a published release whose tag is newer than `current`. The release tag is the
    /// version, so this compares the tag the latest release was made under with the tag this app was built from.
    static func newerRelease(in data: Data, than current: String) throws -> Release? {
        let release = try JSONDecoder().decode(Release.self, from: data)
        guard release.draft != true, release.prerelease != true else { return nil }
        return isNewer(release.tag_name, than: current) ? release : nil
    }

    /// Quiet check at launch: at most once a day, never in debug builds, silent unless something is new.
    static func checkAutomatically() {
        #if DEBUG
        return
        #else
        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: Preferences.Key.checkForUpdates) else { return }
        let last = defaults.object(forKey: Preferences.Key.lastUpdateCheck) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 24 * 3600 else { return }
        Task { await check(userInitiated: false) }
        #endif
    }

    static func checkNow() {
        Task { await check(userInitiated: true) }
    }

    private static func check(userInitiated: Bool) async {
        UserDefaults.standard.set(Date(), forKey: Preferences.Key.lastUpdateCheck)
        do {
            var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!)
            request.timeoutInterval = 10
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode == 404 {
                if userInitiated { informUpToDate() }
                return
            }
            guard let release = try newerRelease(in: data, than: currentVersion) else {
                if userInitiated { informUpToDate() }
                return
            }
            if !userInitiated, UserDefaults.standard.string(forKey: Preferences.Key.skippedVersion) == release.tag_name { return }
            offer(release)
        } catch {
            if userInitiated {
                Exporter.showError(String(localized: "WhiteShot could not check for updates: \(error.localizedDescription)"))
            }
        }
    }

    private static func informUpToDate() {
        let alert = NSAlert()
        alert.messageText = String(localized: "You’re up to date")
        alert.informativeText = String(localized: "WhiteShot \(currentVersion) is the newest version.")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private static func offer(_ release: Release) {
        let alert = NSAlert()
        alert.messageText = String(localized: "WhiteShot \(release.tag_name) is available")
        let notes = (release.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        alert.informativeText = String(localized: "You have version \(currentVersion).") + (notes.isEmpty ? "" : "\n\n" + String(notes.prefix(500)))
        alert.addButton(withTitle: String(localized: "Download"))
        alert.addButton(withTitle: String(localized: "Later"))
        alert.addButton(withTitle: String(localized: "Skip This Version"))
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn: NSWorkspace.shared.open(release.html_url)
        case .alertThirdButtonReturn: UserDefaults.standard.set(release.tag_name, forKey: Preferences.Key.skippedVersion)
        default: break
        }
    }
}
