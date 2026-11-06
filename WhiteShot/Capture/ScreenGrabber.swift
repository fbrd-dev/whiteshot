import AppKit
import ScreenCaptureKit

/// One display, captured at native resolution.
struct FrozenDisplay {
    let screen: NSScreen
    let displayID: CGDirectDisplayID
    let image: CGImage
    /// Pixels per point (2 on Retina).
    let scale: CGFloat
}

enum GrabError: LocalizedError {
    case noDisplay
    case windowGone

    var errorDescription: String? {
        switch self {
        case .noDisplay: return String(localized: "No display could be captured.")
        case .windowGone: return String(localized: "That window is no longer available.")
        }
    }
}

/// Thin layer over ScreenCaptureKit's one-shot screenshot API.
enum ScreenGrabber {
    static func displayID(of screen: NSScreen) -> CGDirectDisplayID? {
        screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }

    /// Captures every connected display at once, so a freeze-frame overlay can cover all of them.
    static func grabAllDisplays(includeCursor: Bool) async throws -> [FrozenDisplay] {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let targets: [(NSScreen, SCDisplay)] = await MainActor.run {
            NSScreen.screens.compactMap { screen in
                guard let id = displayID(of: screen), let display = content.displays.first(where: { $0.displayID == id }) else { return nil }
                return (screen, display)
            }
        }
        guard !targets.isEmpty else { throw GrabError.noDisplay }

        var frozen: [FrozenDisplay] = []
        try await withThrowingTaskGroup(of: FrozenDisplay.self) { group in
            for (screen, display) in targets {
                group.addTask {
                    let filter = SCContentFilter(display: display, excludingWindows: [])
                    let scale = CGFloat(filter.pointPixelScale)
                    let config = SCStreamConfiguration()
                    config.width = Int((filter.contentRect.width * scale).rounded())
                    config.height = Int((filter.contentRect.height * scale).rounded())
                    config.showsCursor = includeCursor
                    config.pixelFormat = kCVPixelFormatType_32BGRA
                    let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
                    return FrozenDisplay(screen: screen, displayID: display.displayID, image: image, scale: scale)
                }
            }
            for try await item in group { frozen.append(item) }
        }
        return frozen
    }

    /// Captures a rectangle of one display directly, without a freeze-frame (used for "last region").
    /// `rect` is in display points with the origin at the top-left.
    static func grabRegion(displayID: CGDirectDisplayID, rect: CGRect, includeCursor: Bool) async throws -> (image: CGImage, scale: CGFloat) {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first else { throw GrabError.noDisplay }
        let filter = SCContentFilter(display: display, excludingWindows: [])
        let scale = CGFloat(filter.pointPixelScale)
        let bounds = CGRect(x: 0, y: 0, width: filter.contentRect.width, height: filter.contentRect.height)
        let clipped = rect.intersection(bounds)
        guard !clipped.isNull, clipped.width >= 1, clipped.height >= 1 else { throw GrabError.noDisplay }
        let config = SCStreamConfiguration()
        config.sourceRect = clipped
        config.width = Int((clipped.width * scale).rounded())
        config.height = Int((clipped.height * scale).rounded())
        config.showsCursor = includeCursor
        config.pixelFormat = kCVPixelFormatType_32BGRA
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        return (image, scale)
    }

    /// Captures one window by itself, even if other windows overlap it. Rounded corners stay transparent. With `includeShadow` the
    /// window's shadow comes along, trimmed to what is actually visible, like the Mac's own window screenshots.
    static func grabWindow(id: CGWindowID, includeCursor: Bool, includeShadow: Bool = false) async throws -> (image: CGImage, scale: CGFloat, title: String) {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let window = content.windows.first(where: { $0.windowID == id }) else { throw GrabError.windowGone }
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let scale = CGFloat(filter.pointPixelScale)
        let config = SCStreamConfiguration()
        // Asked for exactly the window's size, a capture with shadow squeezes the shadow into it and shrinks the window. Asked
        // for more, the window keeps its size and the shadow fits around it; the empty margin is trimmed afterwards.
        let padding: CGFloat = includeShadow ? shadowPadding : 0
        config.width = Int(((filter.contentRect.width + 2 * padding) * scale).rounded())
        config.height = Int(((filter.contentRect.height + 2 * padding) * scale).rounded())
        config.showsCursor = includeCursor
        config.ignoreShadowsSingleWindow = !includeShadow
        config.pixelFormat = kCVPixelFormatType_32BGRA
        var image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        if includeShadow { image = ImageOps.trimmingTransparentEdges(image) }
        let title = [window.owningApplication?.applicationName, window.title].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " – ")
        return (image, scale, title)
    }

    /// Room asked for around a window so its whole shadow fits (macOS shadows reach about 25 points at most).
    static let shadowPadding: CGFloat = 64

    /// Joins several displays into one picture laid out like the desktop, at the highest scale among them.
    static func stitch(_ displays: [FrozenDisplay]) -> (image: CGImage, scale: CGFloat)? {
        guard let first = displays.first else { return nil }
        if displays.count == 1 { return (first.image, first.scale) }
        let scale = displays.map(\.scale).max() ?? 1
        let union = displays.map { $0.screen.frame }.reduce(displays[0].screen.frame) { $0.union($1) }
        let width = Int((union.width * scale).rounded()), height = Int((union.height * scale).rounded())
        guard let ctx = Renderer.makeContext(width: width, height: height, colorSpace: ImageFilters.rgbColorSpace(for: first.image)) else { return nil }
        ctx.interpolationQuality = .high
        for display in displays {
            let f = display.screen.frame
            // Cocoa screen frames are bottom-left based, like the CG context.
            ctx.draw(display.image, in: CGRect(x: (f.minX - union.minX) * scale, y: (f.minY - union.minY) * scale,
                                               width: f.width * scale, height: f.height * scale))
        }
        guard let image = ctx.makeImage() else { return nil }
        return (image, scale)
    }
}

/// On-screen windows, front to back, in CG global coordinates (origin top-left of the primary display).
struct WindowInfo {
    let id: CGWindowID
    let frame: CGRect
    let title: String
    let ownerName: String

    var menuTitle: String {
        title.isEmpty ? ownerName : "\(ownerName) – \(title)"
    }
}

enum WindowList {
    static func onScreenWindows() -> [WindowInfo] {
        guard let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return raw.compactMap { entry in
            guard let layer = entry[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid = entry[kCGWindowOwnerPID as String] as? Int32, pid != ownPID,
                  let id = entry[kCGWindowNumber as String] as? CGWindowID,
                  let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
                  let frame = CGRect(dictionaryRepresentation: boundsDict),
                  frame.width >= 32, frame.height >= 32 else { return nil }
            if let alpha = entry[kCGWindowAlpha as String] as? Double, alpha < 0.05 { return nil }
            return WindowInfo(id: id, frame: frame,
                              title: entry[kCGWindowName as String] as? String ?? "",
                              ownerName: entry[kCGWindowOwnerName as String] as? String ?? "")
        }
    }
}

enum Permissions {
    private static let askedKey = "permissions.askedScreenCapture"

    /// True if screen recording is allowed. The first call triggers the system prompt; later calls
    /// show an explanation with a shortcut to the right System Settings pane.
    @MainActor
    static func ensureScreenRecording() -> Bool {
        if CGPreflightScreenCaptureAccess() { return true }
        if !UserDefaults.standard.bool(forKey: askedKey) {
            UserDefaults.standard.set(true, forKey: askedKey)
            _ = CGRequestScreenCaptureAccess()
            return false
        }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = String(localized: "WhiteShot needs permission to record your screen")
        alert.informativeText = String(localized: "Open System Settings › Privacy & Security › Screen & System Audio Recording, switch WhiteShot on, then quit and reopen WhiteShot. macOS only applies this permission to apps that start afterwards.")
        alert.addButton(withTitle: String(localized: "Open System Settings"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
        return false
    }
}
