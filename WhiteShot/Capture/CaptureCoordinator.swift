import AppKit

/// Drives every kind of capture: permission check, optional countdown, freeze, selection, delivery.
@MainActor
final class CaptureCoordinator {
    static let shared = CaptureCoordinator()

    private var overlay: CaptureOverlayController?
    private var busy = false

    private struct LastRegion: Codable {
        var displayID: UInt32
        var x: Double, y: Double, width: Double, height: Double
    }

    // MARK: Entry points

    func perform(_ action: HotkeyAction) {
        #if DEBUG
        if ActivationProbe.fakeCaptureRequested {
            // `WHITESHOT_DEBUG_PREACTIVATE=<seconds>`: like the real overlay, activate the app first and open the editor later.
            let wait = Double(ProcessInfo.processInfo.environment["WHITESHOT_DEBUG_PREACTIVATE"] ?? "") ?? 0
            if wait > 0 { NSApp.activate(ignoringOtherApps: true) }
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) {
                OutputPipeline.deliver(CaptureResult(image: SampleScreenshot.make(width: 640, height: 400), scale: 2))
            }
            return
        }
        #endif
        switch action {
        case .region: captureRegion()
        case .lastRegion: captureLastRegion()
        case .fullScreen: captureFullScreen()
        case .window: captureWindow()
        case .textGrab: grabText()
        }
    }

    func captureRegion() { startInteractive(.region) }
    /// Selects a region and copies the text and QR codes in it to the clipboard instead of delivering a screenshot.
    func grabText() { startInteractive(.region, purpose: .text) }
    func captureWindow() { startInteractive(.window) }

    func captureFullScreen() {
        startImmediate {
            let displays = try await ScreenGrabber.grabAllDisplays(includeCursor: Preferences.includeCursor)
            let mouse = NSEvent.mouseLocation
            let chosen = displays.first(where: { $0.screen.frame.contains(mouse) }) ?? displays.first
            guard let chosen else { throw GrabError.noDisplay }
            return CaptureResult(image: chosen.image, scale: chosen.scale)
        }
    }

    func captureAllDisplays() {
        startImmediate {
            let displays = try await ScreenGrabber.grabAllDisplays(includeCursor: Preferences.includeCursor)
            guard let stitched = ScreenGrabber.stitch(displays) else { throw GrabError.noDisplay }
            return CaptureResult(image: stitched.image, scale: stitched.scale)
        }
    }

    func captureLastRegion() {
        guard let data = UserDefaults.standard.data(forKey: Preferences.Key.lastRegion),
              let last = try? JSONDecoder().decode(LastRegion.self, from: data) else {
            Exporter.showError(String(localized: "There is no previous region yet. Capture a region first."))
            return
        }
        startImmediate {
            let rect = CGRect(x: last.x, y: last.y, width: last.width, height: last.height)
            let grabbed = try await ScreenGrabber.grabRegion(displayID: last.displayID, rect: rect, includeCursor: Preferences.includeCursor)
            return CaptureResult(image: grabbed.image, scale: grabbed.scale)
        }
    }

    func capture(windowID: CGWindowID) {
        startImmediate {
            let grabbed = try await ScreenGrabber.grabWindow(id: windowID, includeCursor: Preferences.includeCursor, includeShadow: Preferences.windowShadow)
            var image = grabbed.image
            // Transparent stays transparent (PNG, TIFF, HEIC); white or black is laid under the window, shadow and rounded corners.
            if let fill = Preferences.windowBackground.fill, let flat = ImageOps.flatten(image, on: fill) { image = flat }
            return CaptureResult(image: image, scale: grabbed.scale, title: grabbed.title)
        }
    }

    // MARK: Plumbing

    /// Captures that need no selection: wait out the delay, grab, deliver.
    private func startImmediate(_ grab: @escaping () async throws -> CaptureResult) {
        guard !busy, Permissions.ensureScreenRecording() else { return }
        busy = true
        Task { @MainActor [weak self] in
            defer { self?.busy = false }
            await self?.waitForDelay()
            do {
                let result = try await grab()
                OutputPipeline.deliver(result)
            } catch {
                Exporter.showError(error.localizedDescription)
            }
        }
    }

    private enum Purpose { case screenshot, text }

    private func startInteractive(_ mode: CaptureOverlayController.Mode, purpose: Purpose = .screenshot) {
        #if DEBUG
        let fakeOverlay = ActivationProbe.fakeOverlayRequested
        #else
        let fakeOverlay = false
        #endif
        guard !busy, fakeOverlay || Permissions.ensureScreenRecording() else { return }
        busy = true
        Task { @MainActor [weak self] in
            await self?.waitForDelay()
            let previous = NSWorkspace.shared.frontmostApplication
            do {
                // The freeze-frame: every display is captured before any overlay appears.
                let frozen: [FrozenDisplay]
                #if DEBUG
                // The synthetic overlay never reads the screen at all.
                frozen = fakeOverlay ? ActivationProbe.syntheticDisplays() : try await ScreenGrabber.grabAllDisplays(includeCursor: Preferences.includeCursor)
                #else
                frozen = try await ScreenGrabber.grabAllDisplays(includeCursor: Preferences.includeCursor)
                #endif
                let controller = CaptureOverlayController(frozen: frozen, mode: mode, windows: WindowList.onScreenWindows(), showLoupe: Preferences.showLoupe)
                self?.overlay = controller
                controller.begin { outcome in self?.finish(outcome, previous: previous, purpose: purpose) }
            } catch {
                self?.busy = false
                Exporter.showError(error.localizedDescription)
            }
        }
    }

    private func finish(_ outcome: CaptureOverlayController.Outcome, previous: NSRunningApplication?, purpose: Purpose) {
        overlay = nil
        switch outcome {
        case .cancelled:
            busy = false
            previous?.activate()
        case .region(let display, let rect):
            busy = false
            let scale = display.scale
            let pixels = CGRect(x: (rect.minX * scale).rounded(), y: (rect.minY * scale).rounded(),
                                width: (rect.width * scale).rounded(), height: (rect.height * scale).rounded())
            guard let cropped = ImageOps.crop(display.image, to: pixels) else { return }
            if purpose == .text {
                // Back to whatever the user was doing: a text grab has no window to show.
                previous?.activate()
                TextGrab.run(on: cropped)
                return
            }
            remember(display: display, rect: rect)
            // Cocoa screen coordinates grow upwards, the region's grow downwards from the top of the display.
            let source = CGRect(x: display.screen.frame.minX + rect.minX, y: display.screen.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
            var result = CaptureResult(image: cropped, scale: scale)
            result.sourceFrame = source
            OutputPipeline.deliver(result)
        case .window(let info):
            busy = false
            capture(windowID: info.id)
        }
    }

    private func remember(display: FrozenDisplay, rect: CGRect) {
        let last = LastRegion(displayID: display.displayID, x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
        if let data = try? JSONEncoder().encode(last) {
            UserDefaults.standard.set(data, forKey: Preferences.Key.lastRegion)
        }
    }

    private func waitForDelay() async {
        let seconds = Preferences.captureDelay
        if seconds > 0 {
            let hud = CountdownHUD()
            for remaining in stride(from: seconds, to: 0, by: -1) {
                hud.show(remaining)
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
            hud.close()
        }
        // Give the system a moment to drop the menu or HUD from the screen before it is captured.
        try? await Task.sleep(nanoseconds: 150_000_000)
    }
}

/// Large number in the middle of the screen while a capture delay counts down.
@MainActor
private final class CountdownHUD {
    private var panel: NSPanel?
    private let label = NSTextField(labelWithString: "")

    func show(_ value: Int) {
        if panel == nil {
            let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 120, height: 120), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.level = .statusBar
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hasShadow = true
            p.ignoresMouseEvents = true
            p.collectionBehavior = [.canJoinAllSpaces, .stationary]
            let effect = NSVisualEffectView(frame: p.contentRect(forFrameRect: p.frame))
            effect.material = .hudWindow
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.cornerRadius = 24
            label.font = .systemFont(ofSize: 64, weight: .semibold)
            label.alignment = .center
            label.frame = NSRect(x: 0, y: 24, width: 120, height: 76)
            effect.addSubview(label)
            p.contentView = effect
            if let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) ?? NSScreen.main {
                p.setFrameOrigin(NSPoint(x: screen.frame.midX - 60, y: screen.frame.midY - 60))
            }
            p.orderFrontRegardless()
            panel = p
        }
        label.stringValue = String(value)
    }

    func close() {
        panel?.orderOut(nil)
        panel = nil
    }
}
