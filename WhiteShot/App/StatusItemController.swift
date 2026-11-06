import AppKit
import Carbon.HIToolbox

/// The menu bar icon and its menu. The menu is rebuilt each time it opens, so shortcuts,
/// checkmarks and the window list are always current.
@MainActor
final class StatusItemController: NSObject, NSMenuDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
    private let menu = NSMenu()
    private let windowsMenu = NSMenu()
    private var windowsForMenu: [WindowInfo] = []

    override init() {
        super.init()
        statusItem.button?.image = MenuBarIcon.make()
        statusItem.button?.toolTip = "WhiteShot"
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
    }

    // MARK: Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === self.menu else { return }
        menu.removeAllItems()

        addCapture(.region, symbol: "viewfinder", to: menu)
        addCapture(.lastRegion, symbol: "arrow.counterclockwise", to: menu)
        addCapture(.fullScreen, symbol: "display", to: menu)
        addCapture(.textGrab, symbol: "text.viewfinder", to: menu)

        let allDisplays = item(String(localized: "Capture All Displays"), #selector(captureAllDisplays))
        allDisplays.image = symbol("rectangle.on.rectangle")
        allDisplays.isHidden = NSScreen.screens.count < 2
        menu.addItem(allDisplays)

        let windowItem = NSMenuItem(title: String(localized: "Capture Window"), action: nil, keyEquivalent: "")
        windowItem.image = symbol("macwindow")
        windowItem.submenu = windowsMenu
        windowsMenu.delegate = self
        applyShortcut(.window, to: windowItem)
        menu.addItem(windowItem)
        rebuildWindowsMenu()

        menu.addItem(.separator())
        let after = NSMenuItem(title: String(localized: "After Capture"), action: nil, keyEquivalent: "")
        after.submenu = afterCaptureMenu()
        menu.addItem(after)

        menu.addItem(.separator())
        if !PinnedImageController.pins.isEmpty {
            menu.addItem(item(String(localized: "Close All Pins"), #selector(closeAllPins)))
        }
        menu.addItem(item(String(localized: "Open Image…"), #selector(AppDelegate.openImage(_:)), target: NSApp.delegate))
        menu.addItem(item(String(localized: "Open from Clipboard"), #selector(AppDelegate.openFromClipboard(_:)), target: NSApp.delegate))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Settings…"), #selector(AppDelegate.showSettings(_:)), key: ",", target: NSApp.delegate))
        menu.addItem(item(String(localized: "Check for Updates…"), #selector(AppDelegate.checkForUpdates(_:)), target: NSApp.delegate))
        menu.addItem(item(String(localized: "About WhiteShot"), #selector(AppDelegate.showAbout(_:)), target: NSApp.delegate))
        menu.addItem(.separator())
        menu.addItem(item(String(localized: "Quit WhiteShot"), #selector(NSApplication.terminate(_:)), key: "q", target: NSApp))
    }

    func menuWillOpen(_ menu: NSMenu) {
        if menu === windowsMenu { rebuildWindowsMenu() }
    }

    private func rebuildWindowsMenu() {
        windowsMenu.removeAllItems()
        let pick = item(String(localized: "Choose by Clicking"), #selector(captureWindowByClicking))
        pick.image = symbol("cursorarrow.click")
        windowsMenu.addItem(pick)
        windowsMenu.addItem(.separator())
        windowsForMenu = WindowList.onScreenWindows()
        if windowsForMenu.isEmpty {
            let none = NSMenuItem(title: String(localized: "No Windows"), action: nil, keyEquivalent: "")
            none.isEnabled = false
            windowsMenu.addItem(none)
        }
        for (index, info) in windowsForMenu.prefix(25).enumerated() {
            let title = info.menuTitle.count > 60 ? String(info.menuTitle.prefix(58)) + "…" : info.menuTitle
            let entry = item(title, #selector(captureListedWindow(_:)))
            entry.tag = index
            windowsMenu.addItem(entry)
        }
    }

    private func afterCaptureMenu() -> NSMenu {
        let submenu = NSMenu()
        let current = Preferences.destinations
        let choices: [(String, Destinations)] = [
            (String(localized: "Open in Editor"), .editor),
            (String(localized: "Copy to Clipboard"), .clipboard),
            (String(localized: "Pin to Screen"), .pin),
            (String(localized: "Save to File"), .saveFile),
            (String(localized: "Save As…"), .saveAs),
            (String(localized: "Print"), .print),
            (String(localized: "Share"), .share),
            (String(localized: "Email"), .email),
        ]
        for (title, destination) in choices {
            let entry = item(title, #selector(toggleDestination(_:)))
            entry.tag = destination.rawValue
            entry.state = current.contains(destination) && !Preferences.askEachTime ? .on : .off
            entry.isEnabled = !Preferences.askEachTime
            submenu.addItem(entry)
        }
        submenu.addItem(.separator())
        let ask = item(String(localized: "Ask Each Time"), #selector(toggleAskEachTime))
        ask.state = Preferences.askEachTime ? .on : .off
        submenu.addItem(ask)
        return submenu
    }

    // MARK: Helpers

    private func symbol(_ name: String) -> NSImage? { NSImage(systemSymbolName: name, accessibilityDescription: nil) }

    private func item(_ title: String, _ action: Selector, key: String = "", target: AnyObject? = nil) -> NSMenuItem {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
        entry.target = target ?? self
        return entry
    }

    private func addCapture(_ action: HotkeyAction, symbol name: String, to menu: NSMenu) {
        let entry = item(action.title, #selector(runAction(_:)))
        entry.representedObject = action.rawValue
        entry.image = symbol(name)
        applyShortcut(action, to: entry)
        menu.addItem(entry)
    }

    /// Shows the active shortcut next to the item. It only displays the combination; the global hot key does the work.
    private func applyShortcut(_ action: HotkeyAction, to entry: NSMenuItem) {
        let shortcut = ShortcutStore.shortcut(for: action)
        let key = Shortcut.keyName(for: shortcut.keyCode)
        guard key.count == 1 else { return }
        entry.keyEquivalent = key.lowercased()
        var mask: NSEvent.ModifierFlags = []
        if shortcut.modifiers & UInt32(controlKey) != 0 { mask.insert(.control) }
        if shortcut.modifiers & UInt32(optionKey) != 0 { mask.insert(.option) }
        if shortcut.modifiers & UInt32(shiftKey) != 0 { mask.insert(.shift) }
        if shortcut.modifiers & UInt32(cmdKey) != 0 { mask.insert(.command) }
        entry.keyEquivalentModifierMask = mask
    }

    // MARK: Actions

    @objc private func runAction(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let action = HotkeyAction(rawValue: raw) else { return }
        CaptureCoordinator.shared.perform(action)
    }

    @objc private func closeAllPins() { PinnedImageController.closeAll() }
    @objc private func captureAllDisplays() { CaptureCoordinator.shared.captureAllDisplays() }
    @objc private func captureWindowByClicking() { CaptureCoordinator.shared.captureWindow() }

    @objc private func captureListedWindow(_ sender: NSMenuItem) {
        guard sender.tag >= 0, sender.tag < windowsForMenu.count else { return }
        CaptureCoordinator.shared.capture(windowID: windowsForMenu[sender.tag].id)
    }

    @objc private func toggleDestination(_ sender: NSMenuItem) {
        var set = Preferences.destinations
        let destination = Destinations(rawValue: sender.tag)
        if set.contains(destination) { set.remove(destination) } else { set.insert(destination) }
        Preferences.destinations = set
    }

    @objc private func toggleAskEachTime() {
        UserDefaults.standard.set(!Preferences.askEachTime, forKey: Preferences.Key.askEachTime)
    }
}

enum MenuBarIcon {
    /// Four corner brackets around a dot: a viewfinder that reads clearly at menu bar size.
    static func make() -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let inset: CGFloat = 2.5, arm: CGFloat = 5
            let path = NSBezierPath()
            path.lineWidth = 1.6
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            let minX = rect.minX + inset, maxX = rect.maxX - inset, minY = rect.minY + inset, maxY = rect.maxY - inset
            for (cx, cy, dx, dy) in [(minX, minY, 1.0, 1.0), (maxX, minY, -1.0, 1.0), (minX, maxY, 1.0, -1.0), (maxX, maxY, -1.0, -1.0)] {
                path.move(to: NSPoint(x: cx + dx * arm, y: cy))
                path.line(to: NSPoint(x: cx, y: cy))
                path.line(to: NSPoint(x: cx, y: cy + dy * arm))
            }
            NSColor.black.setStroke()
            path.stroke()
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: rect.midX - 2, y: rect.midY - 2, width: 4, height: 4)).fill()
            return true
        }
        image.isTemplate = true
        return image
    }
}
