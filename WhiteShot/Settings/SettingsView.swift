import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class SettingsWindowController: NSWindowController {
    static let shared = SettingsWindowController()

    private init() {
        let host = NSHostingController(rootView: SettingsView())
        let window = NSWindow(contentViewController: host)
        window.title = String(localized: "WhiteShot Settings")
        window.styleMask = [.titled, .closable, .miniaturizable]
        window.isReleasedWhenClosed = false
        window.tabbingMode = .disallowed
        super.init(window: window)
        window.center()
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            DispatchQueue.main.async { AppPolicy.update() }
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    func show() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        AppPolicy.update()
        // Don't open with the first text field focused and its contents selected.
        DispatchQueue.main.async { [weak self] in self?.window?.makeFirstResponder(nil) }
    }
}

struct SettingsView: View {
    /// Remembers the last tab, so Settings reopens where the user left it.
    @AppStorage("settings.selectedTab") private var tab = "general"

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag("general")
            CaptureSettings()
                .tabItem { Label("Capture", systemImage: "viewfinder") }
                .tag("capture")
            OutputSettings()
                .tabItem { Label("Output", systemImage: "folder") }
                .tag("output")
            TextSettings()
                .tabItem { Label("Text", systemImage: "text.viewfinder") }
                .tag("text")
            ShortcutSettings()
                .tabItem { Label("Shortcuts", systemImage: "keyboard") }
                .tag("shortcuts")
            AboutSettings()
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag("about")
        }
        .frame(width: 560, height: 660)
        .scenePadding()
    }
}

// MARK: - General

private struct GeneralSettings: View {
    @AppStorage(Preferences.Key.checkForUpdates) private var checkForUpdates = true
    @AppStorage(Preferences.Key.showNotifications) private var showNotifications = true
    @AppStorage(Preferences.Key.playSound) private var playSound = true
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var loginError: String?
    @State private var language = AppLanguage.stored()

    var body: some View {
        Form {
            Section {
                Picker("Language", selection: Binding(get: { language }, set: changeLanguage)) {
                    Text(AppLanguage.systemEntryTitle).tag(AppLanguage.system)
                    Divider()
                    Text(AppLanguage.en.nativeName).tag(AppLanguage.en)
                    Text(AppLanguage.de.nativeName).tag(AppLanguage.de)
                }
            } footer: {
                Text("By default WhiteShot uses your Mac’s language. Changing it takes effect after a restart.")
            }
            Section {
                Toggle("Launch WhiteShot at login", isOn: Binding(get: { launchAtLogin }, set: setLaunchAtLogin))
                if let loginError { Text(loginError).foregroundStyle(.red).font(.callout) }
            }
            Section("Feedback") {
                Toggle("Play a sound after capturing", isOn: $playSound)
                Toggle("Show a notification after saving or copying", isOn: $showNotifications)
            }
            Section("Updates") {
                Toggle("Check for new versions automatically", isOn: $checkForUpdates)
                Button("Check Now") { UpdateChecker.checkNow() }
                Text("WhiteShot only asks GitHub whether a newer release exists and never installs anything by itself.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section {
                Button("Reset All Settings…", role: .destructive, action: confirmReset)
            } footer: {
                Text("Restores every setting, your shortcuts and the colours and sizes the editor remembers to their defaults.")
            }
        }
        .formStyle(.grouped)
    }

    private func changeLanguage(_ choice: AppLanguage) {
        guard choice != language else { return }
        language = choice
        AppLanguage.store(choice)
        // Only worth a restart if the interface language would really differ from the one showing now.
        if choice.resolved() != AppLanguage.running { AppRestarter.offerRestart(for: choice.resolved()) }
    }

    private func confirmReset() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "Reset all settings to their defaults?")
        alert.informativeText = String(localized: "This restores WhiteShot’s settings, shortcuts and remembered editor styles. Your screenshots are not touched.")
        alert.addButton(withTitle: String(localized: "Reset"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let languageBefore = AppLanguage.running
        Preferences.resetToDefaults()
        language = .system
        // Launch at login lives in the system, not in our defaults.
        try? SMAppService.mainApp.unregister()
        launchAtLogin = SMAppService.mainApp.status == .enabled
        loginError = nil
        // Shortcut registrations and menus follow the stored values, so tell them to re-read.
        NotificationCenter.default.post(name: ShortcutStore.didChange, object: nil)
        // Back to "System" may mean a different interface language than the one showing now.
        let target = AppLanguage.system.resolved()
        if target != languageBefore { AppRestarter.offerRestart(for: target) }
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            launchAtLogin = enabled
            loginError = nil
        } catch {
            launchAtLogin = SMAppService.mainApp.status == .enabled
            loginError = error.localizedDescription
        }
    }
}

// MARK: - Capture

private struct CaptureSettings: View {
    @AppStorage(Preferences.Key.toEditor) private var toEditor = true
    @AppStorage(Preferences.Key.toClipboard) private var toClipboard = true
    @AppStorage(Preferences.Key.toFile) private var toFile = true
    @AppStorage(Preferences.Key.toSaveAs) private var toSaveAs = false
    @AppStorage(Preferences.Key.toPrint) private var toPrint = false
    @AppStorage(Preferences.Key.toShare) private var toShare = false
    @AppStorage(Preferences.Key.toEmail) private var toEmail = false
    @AppStorage(Preferences.Key.toPin) private var toPin = false
    @AppStorage(Preferences.Key.askEachTime) private var askEachTime = false
    @AppStorage(Preferences.Key.includeCursor) private var includeCursor = false
    @AppStorage(Preferences.Key.showLoupe) private var showLoupe = true
    @AppStorage(Preferences.Key.captureDelay) private var delay = 0
    @AppStorage(Preferences.Key.windowShadow) private var windowShadow = false
    @AppStorage(Preferences.Key.windowBackground) private var windowBackground = WindowBackground.transparent.rawValue

    var body: some View {
        Form {
            Section {
                Toggle("Ask where to send each screenshot", isOn: $askEachTime)
                Group {
                    Toggle("Open in the editor", isOn: $toEditor)
                    Toggle("Copy to the clipboard", isOn: $toClipboard)
                    Toggle("Save to the output folder", isOn: $toFile)
                    Toggle("Ask for a file name (Save As)", isOn: $toSaveAs)
                    Toggle("Print", isOn: $toPrint)
                    Toggle("Pin to the screen", isOn: $toPin)
                    Toggle("Share…", isOn: $toShare)
                    Toggle("Email", isOn: $toEmail)
                }
                .disabled(askEachTime)
            } header: {
                Text("After a capture")
            } footer: {
                Text("Pick any combination. With nothing selected the screenshot opens in the editor.")
            }
            Section("While capturing") {
                Toggle("Include the mouse pointer", isOn: $includeCursor)
                Toggle("Show a magnifier while selecting a region", isOn: $showLoupe)
                Stepper(value: $delay, in: 0...30) {
                    HStack {
                        Text("Delay before capturing")
                        Spacer()
                        Text(delay == 0 ? String(localized: "None") : String(localized: "\(delay) s")).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
            Section {
                Toggle("Include the window’s shadow", isOn: $windowShadow)
                Picker("Background", selection: $windowBackground) {
                    ForEach(WindowBackground.allCases) { Text($0.title).tag($0.rawValue) }
                }
            } header: {
                Text("Window capture")
            } footer: {
                Text("Transparent keeps the rounded corners and the shadow see-through in PNG, TIFF and HEIC files. JPEG and other formats without transparency show white instead.")
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Text

private struct TextSettings: View {
    @AppStorage(Preferences.Key.textGrabText) private var grabText = true
    @AppStorage(Preferences.Key.textGrabCodes) private var grabCodes = true
    @AppStorage(Preferences.Key.embedRecognizedText) private var embedText = true

    var body: some View {
        Form {
            Section {
                Toggle("Text", isOn: $grabText)
                Toggle("QR codes and barcodes", isOn: $grabCodes)
            } header: {
                Text("Grab Text")
            } footer: {
                Text("The Grab Text shortcut lets you select a region of the screen and copies what is in it to the clipboard. Choose what it picks up.")
            }
            Section {
                ForEach(SensitiveKind.allCases) { kind in
                    SensitiveKindToggle(kind: kind)
                }
            } header: {
                Text("Suggest censoring")
            } footer: {
                Text("When you use Recognize Text in the editor, text of these kinds is marked in orange and can be censored with one click. Nothing is ever censored automatically.")
            }
            Section {
                Toggle("Save recognized text with the image", isOn: $embedText)
            } footer: {
                Text("After you have used Recognize Text in the editor, PNG, JPEG, TIFF and HEIC files keep the text in their description. Text under censored areas is never included.")
            }
        }
        .formStyle(.grouped)
    }
}

private struct SensitiveKindToggle: View {
    let kind: SensitiveKind
    @AppStorage private var isOn: Bool

    init(kind: SensitiveKind) {
        self.kind = kind
        _isOn = AppStorage(wrappedValue: kind.enabledByDefault, kind.preferenceKey)
    }

    var body: some View {
        Toggle(isOn: $isOn) { Label(kind.title, systemImage: kind.symbol) }
    }
}

// MARK: - Output

private struct OutputSettings: View {
    @AppStorage(Preferences.Key.outputFolder) private var folder = ""
    @AppStorage(Preferences.Key.filenamePattern) private var pattern = Preferences.defaultPattern
    @AppStorage(Preferences.Key.imageFormat) private var format = ImageFormat.png.rawValue
    @AppStorage(Preferences.Key.jpegQuality) private var quality = 90
    @AppStorage(Preferences.Key.copyPathToClipboard) private var copyPath = false
    @State private var showVariables = false

    private var preview: String {
        let name = FilenamePattern.relativePath(pattern: pattern.isEmpty ? Preferences.defaultPattern : pattern,
                                                context: .init(date: Date(), title: "Safari", number: 1)).joined(separator: "/")
        return name + "." + (ImageFormat(rawValue: format) ?? .png).fileExtension
    }

    private var selectedFormat: ImageFormat { ImageFormat(rawValue: format) ?? .png }

    var body: some View {
        Form {
            Section("Save location") {
                HStack {
                    Image(systemName: "folder")
                    Text((folder as NSString).abbreviatingWithTildeInPath).lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Button("Choose…", action: chooseFolder)
                }
                LabeledContent("File name") {
                    TextField("", text: $pattern).textFieldStyle(.roundedBorder).frame(width: 280)
                }
                LabeledContent("Example") {
                    Text(preview).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                DisclosureGroup("Variables for the file name", isExpanded: $showVariables) {
                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 3) {
                        ForEach(FilenamePattern.variables, id: \.name) { variable in
                            GridRow {
                                Text("${\(variable.name)}").font(.system(.callout, design: .monospaced))
                                Text(variable.help).foregroundStyle(.secondary).font(.callout)
                            }
                        }
                    }
                    Text("A “/” in the pattern creates sub-folders.").font(.callout).foregroundStyle(.secondary).padding(.top, 4)
                }
            }
            Section("Image format") {
                Picker("Format", selection: $format) {
                    ForEach(ImageFormat.allCases) { Text($0.displayName).tag($0.rawValue) }
                }
                if selectedFormat.isLossy {
                    LabeledContent("Quality") {
                        HStack {
                            Slider(value: Binding(get: { Double(quality) }, set: { quality = Int($0) }), in: 10...100).frame(width: 180)
                            Text("\(quality)%").monospacedDigit().frame(width: 40, alignment: .trailing)
                        }
                    }
                }
                Toggle("Copy the file path to the clipboard after saving", isOn: $copyPath)
            }
        }
        .formStyle(.grouped)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = Preferences.outputFolder
        panel.prompt = String(localized: "Choose")
        if panel.runModal() == .OK, let url = panel.url { folder = url.path }
    }
}

// MARK: - Shortcuts

private struct ShortcutSettings: View {
    @State private var scheme = ShortcutStore.scheme
    @State private var tick = 0
    @State private var shadowed: [ShortcutSlot] = []
    @State private var taken: [ShortcutSlot] = []
    @State private var notice: String?

    var body: some View {
        Form {
            Section {
                Picker("Shortcut set", selection: Binding(get: { scheme }, set: { scheme = $0; ShortcutStore.scheme = $0; notice = nil })) {
                    Text("WhiteShot’s own (⌃⇧)").tag(ShortcutScheme.own)
                    Text("Like macOS screenshots (⌘⇧)").tag(ShortcutScheme.system)
                }
                .pickerStyle(.radioGroup)
            } footer: {
                VStack(alignment: .leading, spacing: 4) {
                    if scheme == .own {
                        Text("These don’t collide with macOS’ built-in screenshot shortcuts, so both can be used side by side.")
                    } else {
                        Text("To make these work, switch off macOS’ own screenshot shortcuts first. macOS gives its own shortcuts priority.")
                    }
                    Text("Each set remembers the shortcuts you record in it.")
                }
            }
            Section("Global shortcuts") {
                HStack(spacing: 6) {
                    Spacer()
                    Text("Shortcut").frame(width: 140)
                    Text("Second shortcut").frame(width: 140)
                }
                .font(.caption).foregroundStyle(.secondary)
                ForEach(HotkeyAction.allCases) { action in
                    HStack(spacing: 6) {
                        Text(action.title)
                        Spacer()
                        slotEditor(action, slot: 0)
                        slotEditor(action, slot: 1)
                    }
                }
                Text("Click a field, then press the combination you want. Both shortcuts of an action work at the same time.")
                    .font(.callout).foregroundStyle(.secondary)
                if let notice {
                    Label(notice, systemImage: "exclamationmark.circle").font(.callout).foregroundStyle(.orange)
                }
            }
            if !taken.isEmpty {
                Section {
                    Label {
                        Text("Another app already uses \(taken.compactMap { ShortcutStore.shortcut(for: $0.action, slot: $0.index)?.displayString }.joined(separator: ", ")). Pick a different combination.")
                    } icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                }
            }
            if !shadowed.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Label {
                            Text("macOS still uses \(shadowed.compactMap { ShortcutStore.shortcut(for: $0.action, slot: $0.index)?.displayString }.joined(separator: ", ")) for its own screenshots, so WhiteShot won’t receive it. Turn those off in System Settings › Keyboard › Keyboard Shortcuts › Screenshots.")
                        } icon: { Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange) }
                        Button("Open Keyboard Shortcuts…") {
                            if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") { NSWorkspace.shared.open(url) }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: refresh)
        .onReceive(NotificationCenter.default.publisher(for: ShortcutStore.didChange)) { _ in
            tick += 1
            scheme = ShortcutStore.scheme
            refresh()
        }
    }

    /// A recorder plus its Restore (primary) or Remove (second) button.
    private func slotEditor(_ action: HotkeyAction, slot: Int) -> some View {
        let current = ShortcutStore.shortcut(for: action, slot: slot)
        let canReset = ShortcutStore.isCustomised(action, slot: slot)
        return HStack(spacing: 2) {
            ShortcutRecorder(shortcut: current, placeholder: slot == 0 ? "—" : String(localized: "Add…")) { record($0, action, slot) }
                .frame(width: 112, height: 24)
                .id("\(action.rawValue)-\(slot)-\(tick)")
            Button {
                notice = nil
                ShortcutStore.setShortcut(nil, for: action, slot: slot)
            } label: { Image(systemName: slot == 0 ? "arrow.uturn.backward" : "xmark.circle") }
                .buttonStyle(.borderless)
                .help(slot == 0 ? String(localized: "Restore the default") : String(localized: "Remove this shortcut"))
                .opacity(canReset ? 1 : 0.25)
                .disabled(!canReset)
                .frame(width: 22)
        }
    }

    private func record(_ shortcut: Shortcut, _ action: HotkeyAction, _ slot: Int) {
        // The same combination on two actions (or twice on one) could only ever fire one of them.
        if let owner = ShortcutStore.owner(of: shortcut, excluding: ShortcutSlot(action: action, index: slot)) {
            notice = String(localized: "\(shortcut.displayString) is already used for “\(owner.title)”. Choose another combination.")
            tick += 1      // put the field back to what it showed
            return
        }
        notice = nil
        ShortcutStore.setShortcut(shortcut, for: action, slot: slot)
    }

    private func refresh() {
        shadowed = SystemShortcutConflicts.shadowedSlots()
        // Registration happens just after a change notification, so look again on the next turn.
        DispatchQueue.main.async {
            taken = HotkeyAction.allCases.flatMap { action in
                (0..<ShortcutStore.slotCount).compactMap { index -> ShortcutSlot? in
                    let slot = ShortcutSlot(action: action, index: index)
                    guard ShortcutStore.shortcut(for: action, slot: index) != nil, !HotKeyManager.shared.isRegistered(slot), !shadowed.contains(slot) else { return nil }
                    return slot
                }
            }
        }
    }
}

// MARK: - About

private struct AboutSettings: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 84, height: 84)
            Text("WhiteShot").font(.title.weight(.semibold))
            Text("Version \(UpdateChecker.currentVersion)").foregroundStyle(.secondary)
            Text("Screenshots and annotations for macOS, inspired by Greenshot.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            HStack {
                Link("GitHub", destination: URL(string: "https://github.com/\(UpdateChecker.repository)")!)
                Text("·").foregroundStyle(.secondary)
                Link("Report an Issue", destination: URL(string: "https://github.com/\(UpdateChecker.repository)/issues")!)
            }
            Text("Free software under the GNU General Public License, version 3.")
                .font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
