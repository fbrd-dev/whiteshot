import AppKit

/// The menu bar shown while an editor window is open. Most actions have no fixed target, so they
/// travel the responder chain to the canvas or the active editor window.
@MainActor
enum MainMenu {
    static func build() -> NSMenu {
        let main = NSMenu()
        main.addItem(submenu(appMenu()))
        main.addItem(submenu(fileMenu()))
        main.addItem(submenu(editMenu()))
        main.addItem(submenu(captureMenu()))
        main.addItem(submenu(imageMenu()))
        main.addItem(submenu(toolsMenu()))
        main.addItem(submenu(viewMenu()))
        let windowMenu = windowMenu()
        main.addItem(submenu(windowMenu))
        NSApp.windowsMenu = windowMenu
        let help = helpMenu()
        main.addItem(submenu(help))
        NSApp.helpMenu = help
        return main
    }

    private static func submenu(_ menu: NSMenu) -> NSMenuItem {
        let item = NSMenuItem(title: menu.title, action: nil, keyEquivalent: "")
        item.submenu = menu
        return item
    }

    @discardableResult
    private static func add(_ menu: NSMenu, _ title: String, _ action: Selector?, _ key: String = "",
                            _ modifiers: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = key.isEmpty ? [] : modifiers
        item.target = target
        menu.addItem(item)
        return item
    }

    private static var app: AnyObject? { NSApp.delegate }

    private static func appMenu() -> NSMenu {
        let menu = NSMenu(title: "WhiteShot")
        add(menu, String(localized: "About WhiteShot"), #selector(AppDelegate.showAbout(_:)), target: app)
        add(menu, String(localized: "Check for Updates…"), #selector(AppDelegate.checkForUpdates(_:)), target: app)
        menu.addItem(.separator())
        add(menu, String(localized: "Settings…"), #selector(AppDelegate.showSettings(_:)), ",", target: app)
        menu.addItem(.separator())
        let services = NSMenuItem(title: String(localized: "Services"), action: nil, keyEquivalent: "")
        let servicesMenu = NSMenu(title: "Services")
        services.submenu = servicesMenu
        NSApp.servicesMenu = servicesMenu
        menu.addItem(services)
        menu.addItem(.separator())
        add(menu, String(localized: "Hide WhiteShot"), #selector(NSApplication.hide(_:)), "h", target: NSApp)
        add(menu, String(localized: "Hide Others"), #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option], target: NSApp)
        add(menu, String(localized: "Show All"), #selector(NSApplication.unhideAllApplications(_:)), target: NSApp)
        menu.addItem(.separator())
        add(menu, String(localized: "Quit WhiteShot"), #selector(NSApplication.terminate(_:)), "q", target: NSApp)
        return menu
    }

    private static func fileMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "File"))
        add(menu, String(localized: "Open Image…"), #selector(AppDelegate.openImage(_:)), "o", target: app)
        add(menu, String(localized: "Open from Clipboard"), #selector(AppDelegate.openFromClipboard(_:)), "v", [.command, .option], target: app)
        menu.addItem(.separator())
        add(menu, String(localized: "Save"), #selector(EditorWindowController.saveDocument(_:)), "s")
        add(menu, String(localized: "Save As…"), #selector(EditorWindowController.saveDocumentAs(_:)), "s", [.command, .shift])
        menu.addItem(.separator())
        add(menu, String(localized: "Copy Image to Clipboard"), #selector(EditorWindowController.copyImage(_:)), "c", [.command, .shift])
        add(menu, String(localized: "Copy File Path"), #selector(EditorWindowController.copyImagePath(_:)))
        add(menu, String(localized: "Show in Finder"), #selector(EditorWindowController.revealInFinder(_:)))
        menu.addItem(.separator())
        add(menu, String(localized: "Pin to Screen"), #selector(EditorWindowController.pinDocument(_:)), "p", [.command, .shift])
        add(menu, String(localized: "Share…"), #selector(EditorWindowController.shareDocument(_:)))
        add(menu, String(localized: "Email…"), #selector(EditorWindowController.emailDocument(_:)))
        add(menu, String(localized: "Print…"), #selector(EditorWindowController.printDocument(_:)), "p")
        menu.addItem(.separator())
        add(menu, String(localized: "Close"), #selector(NSWindow.performClose(_:)), "w")
        return menu
    }

    private static func editMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "Edit"))
        add(menu, String(localized: "Undo"), #selector(EditorWindowController.undo(_:)), "z")
        add(menu, String(localized: "Redo"), #selector(EditorWindowController.redo(_:)), "z", [.command, .shift])
        menu.addItem(.separator())
        add(menu, String(localized: "Cut"), #selector(NSText.cut(_:)), "x")
        add(menu, String(localized: "Copy"), #selector(NSText.copy(_:)), "c")
        add(menu, String(localized: "Paste"), #selector(NSText.paste(_:)), "v")
        add(menu, String(localized: "Duplicate"), #selector(CanvasView.duplicate(_:)), "d")
        add(menu, String(localized: "Delete"), #selector(CanvasView.delete(_:)))
        add(menu, String(localized: "Select All"), #selector(NSText.selectAll(_:)), "a")
        menu.addItem(.separator())
        add(menu, String(localized: "Insert Image from File…"), #selector(EditorWindowController.insertImageFromFile(_:)))
        menu.addItem(.separator())
        let arrange = NSMenu(title: String(localized: "Arrange"))
        add(arrange, String(localized: "Bring to Front"), #selector(CanvasView.bringToFront(_:)), "]", [.command, .shift])
        add(arrange, String(localized: "Bring Forward"), #selector(CanvasView.bringForward(_:)), "]")
        add(arrange, String(localized: "Send Backward"), #selector(CanvasView.sendBackward(_:)), "[")
        add(arrange, String(localized: "Send to Back"), #selector(CanvasView.sendToBack(_:)), "[", [.command, .shift])
        let arrangeItem = NSMenuItem(title: arrange.title, action: nil, keyEquivalent: "")
        arrangeItem.submenu = arrange
        menu.addItem(arrangeItem)
        return menu
    }

    private static func captureMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "Capture"))
        for action in HotkeyAction.allCases {
            let item = add(menu, action.title, #selector(AppDelegate.captureFromMenu(_:)), target: app)
            item.representedObject = action.rawValue
        }
        add(menu, String(localized: "Capture All Displays"), #selector(AppDelegate.captureAllDisplays(_:)), target: app)
        return menu
    }

    private static func imageMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "Image"))
        add(menu, String(localized: "Crop"), #selector(EditorWindowController.chooseCropTool(_:)), "k")
        add(menu, String(localized: "Auto-Crop"), #selector(EditorWindowController.autoCropImage(_:)))
        menu.addItem(.separator())
        add(menu, String(localized: "Rotate Right"), #selector(EditorWindowController.rotateClockwise(_:)), "r")
        add(menu, String(localized: "Rotate Left"), #selector(EditorWindowController.rotateCounterClockwise(_:)), "l")
        add(menu, String(localized: "Flip Horizontal"), #selector(EditorWindowController.flipHorizontal(_:)))
        add(menu, String(localized: "Flip Vertical"), #selector(EditorWindowController.flipVertical(_:)))
        menu.addItem(.separator())
        add(menu, String(localized: "Resize…"), #selector(EditorWindowController.resizeImage(_:)), "r", [.command, .option])
        add(menu, String(localized: "Canvas Size…"), #selector(EditorWindowController.changeCanvasSize(_:)))
        menu.addItem(.separator())
        add(menu, String(localized: "Drop Shadow…"), #selector(EditorWindowController.addDropShadow(_:)))
        add(menu, String(localized: "Border…"), #selector(EditorWindowController.addBorder(_:)))
        add(menu, String(localized: "Torn Edge…"), #selector(EditorWindowController.addTornEdge(_:)))
        menu.addItem(.separator())
        add(menu, String(localized: "Adjust Colors…"), #selector(EditorWindowController.adjustColors(_:)))
        add(menu, String(localized: "Grayscale"), #selector(EditorWindowController.convertToGrayscale(_:)))
        add(menu, String(localized: "Invert Colors"), #selector(EditorWindowController.invertColors(_:)))
        return menu
    }

    private static func toolsMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "Tools"))
        for tool in EditorTool.allCases {
            let item = add(menu, "\(tool.title)    \(tool.shortcut)", #selector(EditorWindowController.chooseTool(_:)))
            item.representedObject = tool.rawValue
            item.image = NSImage(systemSymbolName: tool.symbol, accessibilityDescription: nil)
        }
        menu.addItem(.separator())
        let recognize = add(menu, String(localized: "Recognize Text"), #selector(EditorWindowController.toggleTextRecognition(_:)), "t", [.command, .shift])
        recognize.image = NSImage(systemSymbolName: "text.viewfinder", accessibilityDescription: nil)
        return menu
    }

    private static func viewMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "View"))
        add(menu, String(localized: "Zoom In"), #selector(EditorWindowController.zoomInMenu(_:)), "+")
        add(menu, String(localized: "Zoom Out"), #selector(EditorWindowController.zoomOutMenu(_:)), "-")
        add(menu, String(localized: "Actual Size"), #selector(EditorWindowController.zoomActualMenu(_:)), "1")
        add(menu, String(localized: "Fit to Window"), #selector(EditorWindowController.zoomFitMenu(_:)), "0")
        menu.addItem(.separator())
        add(menu, String(localized: "Enter Full Screen"), #selector(NSWindow.toggleFullScreen(_:)), "f", [.command, .control])
        return menu
    }

    private static func windowMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "Window"))
        add(menu, String(localized: "Minimize"), #selector(NSWindow.performMiniaturize(_:)), "m")
        add(menu, String(localized: "Zoom"), #selector(NSWindow.performZoom(_:)))
        menu.addItem(.separator())
        add(menu, String(localized: "Bring All to Front"), #selector(NSApplication.arrangeInFront(_:)), target: NSApp)
        return menu
    }

    private static func helpMenu() -> NSMenu {
        let menu = NSMenu(title: String(localized: "Help"))
        add(menu, String(localized: "WhiteShot on GitHub"), #selector(AppDelegate.openProjectPage(_:)), target: app)
        add(menu, String(localized: "Report an Issue"), #selector(AppDelegate.openIssuesPage(_:)), target: app)
        return menu
    }
}
