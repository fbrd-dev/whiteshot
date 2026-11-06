import AppKit
import UniformTypeIdentifiers

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusController: StatusItemController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // When hosting unit tests, don't install a status item, hot keys or the welcome alert.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil { return }

        Preferences.register()
        ShortcutStore.migrateLegacyOverrides()

        // Two copies would fight over the global shortcuts, so hand over to the one already running.
        if let bundleID = Bundle.main.bundleIdentifier {
            let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).filter { $0 != .current }
            if !others.isEmpty {
                others.first?.activate()
                NSApp.terminate(nil)
                return
            }
        }

        #if DEBUG
        if DebugHarness.runIfRequested() { return }
        #endif

        #if DEBUG
        // Mimics a launch from Xcode or the Finder, where the app starts out active before it turns into a menu-bar app.
        if ProcessInfo.processInfo.environment["WHITESHOT_DEBUG_ACTIVATE_AT_LAUNCH"] != nil { NSApp.activate(ignoringOtherApps: true) }
        #endif
        NSApp.setActivationPolicy(.accessory)
        NSApp.mainMenu = MainMenu.build()
        #if DEBUG
        ActivationProbe.start()
        #endif
        statusController = StatusItemController()
        Notifier.shared.configure()
        if Preferences.showNotifications { Notifier.shared.requestAuthorizationIfNeeded() }

        Exporter.cleanUpDragFiles()
        HotKeyManager.shared.onAction = { CaptureCoordinator.shared.perform($0) }
        HotKeyManager.shared.start()

        showWelcomeIfNeeded()
        UpdateChecker.checkAutomatically()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Launching the app again (Dock, Spotlight) from the menu bar state opens Settings.
        if !flag { SettingsWindowController.shared.show() }
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { EditorWindowController.open(fileURL: url) }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let unsaved = EditorWindowController.controllers.filter { $0.model.isDirty }
        guard !unsaved.isEmpty else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = unsaved.count == 1
            ? String(localized: "One screenshot has unsaved changes")
            : String(localized: "\(unsaved.count) screenshots have unsaved changes")
        alert.informativeText = String(localized: "If you quit now, those changes are lost.")
        alert.addButton(withTitle: String(localized: "Quit Anyway"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    // MARK: First run

    private func showWelcomeIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: Preferences.Key.hasSeenWelcome) else { return }
        UserDefaults.standard.set(true, forKey: Preferences.Key.hasSeenWelcome)
        let region = ShortcutStore.shortcut(for: .region).displayString
        let alert = NSAlert()
        alert.messageText = String(localized: "Welcome to WhiteShot")
        alert.informativeText = String(localized: "WhiteShot lives in your menu bar. Press \(region) to capture a region of the screen.\n\nmacOS will now ask for permission to record your screen. WhiteShot needs it to take screenshots, and nothing ever leaves your Mac.")
        alert.addButton(withTitle: String(localized: "Continue"))
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
        UserDefaults.standard.set(true, forKey: "permissions.askedScreenCapture")
        _ = CGRequestScreenCaptureAccess()
    }

    // MARK: Menu actions

    @objc func showSettings(_ sender: Any?) { SettingsWindowController.shared.show() }
    @objc func checkForUpdates(_ sender: Any?) { UpdateChecker.checkNow() }

    @objc func showAbout(_ sender: Any?) {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: NSAttributedString(string: "Free software under the GNU General Public License, version 3.\ngithub.com/\(UpdateChecker.repository)",
                                         attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]),
        ])
    }

    @objc func openImage(_ sender: Any?) {
        let panel = NSOpenPanel()
        var types: [UTType] = [.image]
        if let project = UTType("me.fbrd.whiteshot.project") ?? UTType(filenameExtension: ProjectFile.fileExtension) { types.append(project) }
        panel.allowedContentTypes = types
        panel.allowsMultipleSelection = true
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK {
            for url in panel.urls { EditorWindowController.open(fileURL: url) }
        }
    }

    @objc func openFromClipboard(_ sender: Any?) { EditorWindowController.openFromClipboard() }

    @objc func captureFromMenu(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let action = HotkeyAction(rawValue: raw) else { return }
        CaptureCoordinator.shared.perform(action)
    }

    @objc func captureAllDisplays(_ sender: Any?) { CaptureCoordinator.shared.captureAllDisplays() }

    @objc func openProjectPage(_ sender: Any?) {
        NSWorkspace.shared.open(URL(string: "https://github.com/\(UpdateChecker.repository)")!)
    }

    @objc func openIssuesPage(_ sender: Any?) {
        NSWorkspace.shared.open(URL(string: "https://github.com/\(UpdateChecker.repository)/issues")!)
    }
}
