#if DEBUG
import AppKit
import ScreenCaptureKit
import Darwin
import SwiftUI

/// Development aid, compiled into Debug builds only.
///
///     WhiteShot --debug-editor-shot out.png [--dark] [--tool rectangle] [--select text]
///
/// opens an editor window off-screen on synthetic content, renders it to a PNG and exits. It never
/// touches the screen contents, the real screenshots folder or the capture permission.
@MainActor
enum DebugHarness {
    static func runIfRequested() -> Bool {
        let args = CommandLine.arguments
        if args.contains("--debug-drag-test") {
            // An editor and a drop target, both WhiteShot's own windows, to drag between with a real mouse.
            NSApp.setActivationPolicy(.accessory)
            Task { @MainActor in
                await DragTest.run()
                exit(0)
            }
            return true
        }
        if args.contains("--debug-textgrab") {
            // Runs the text-grab pipeline on the synthetic sample into a private pasteboard (never the real clipboard).
            NSApp.setActivationPolicy(.accessory)
            Preferences.register()
            Task { @MainActor in
                let pasteboard = NSPasteboard(name: NSPasteboard.Name("me.fbrd.whiteshot.debug.grab"))
                var finished = false
                TextGrab.run(on: SampleScreenshot.make(width: 1280, height: 800), pasteboard: pasteboard) { string in
                    print("GRAB result: \(string.map { "\($0.split(separator: "\n").count) lines" } ?? "nothing")")
                    print("GRAB pasteboard: \((pasteboard.string(forType: .string) ?? "").replacingOccurrences(of: "\n", with: " | "))")
                    finished = true
                }
                for _ in 0..<160 where !finished { try? await Task.sleep(nanoseconds: 250_000_000) }
                if args.contains("--hud") {
                    if let window = GrabHUD.shared.windowForTesting { print("WINDOW \(window.windowNumber)"); fflush(stdout); try? await Task.sleep(nanoseconds: 6_000_000_000) }
                }
                pasteboard.releaseGlobally()
                exit(0)
            }
            return true
        }
        if args.contains("--debug-pin") {
            // Pins a synthetic picture so the pin window can be looked at.
            NSApp.setActivationPolicy(.accessory)
            Task { @MainActor in
                let image = SampleScreenshot.make(width: 560, height: 360)
                let pin = PinnedImageController.pin(image, scale: 2, name: "Sample", near: NSRect(x: 120, y: 260, width: 560, height: 360))
                if args.contains("--half") { pin.setOpacity(0.5) }
                guard let window = pin.window else { exit(1) }
                print("WINDOW \(window.windowNumber)")
                fflush(stdout)
                try? await Task.sleep(nanoseconds: 9_000_000_000)
                exit(0)
            }
            return true
        }
        if args.contains("--debug-window-shadow-test") {
            NSApp.setActivationPolicy(.accessory)
            Task { @MainActor in
                await WindowShadowTest.run()
                exit(0)
            }
            return true
        }
        if args.contains("--debug-relaunch-test") {
            NSApp.setActivationPolicy(.accessory)
            Task { @MainActor in
                print("PID \(ProcessInfo.processInfo.processIdentifier)"); fflush(stdout)
                try? await Task.sleep(nanoseconds: 800_000_000)
                AppRestarter.relaunch()
            }
            return true
        }
        if args.contains("--debug-memory-test") {
            NSApp.setActivationPolicy(.accessory)
            Task { @MainActor in
                await runMemoryTest(withEdits: !args.contains("--plain"))
                exit(0)
            }
            return true
        }
        if args.contains("--debug-twowindows") {
            NSApp.setActivationPolicy(.accessory)
            Task { @MainActor in
                await runTwoWindows()
                exit(0)
            }
            return true
        }
        if args.contains("--debug-hotkey-test") {
            // Registers the shortcuts from the preferences and just prints which action fires. No overlay, no capture.
            NSApp.setActivationPolicy(.accessory)
            Preferences.register()
            ShortcutStore.migrateLegacyOverrides()
            HotKeyManager.shared.onAction = { print("FIRED \($0.rawValue)"); fflush(stdout) }
            HotKeyManager.shared.start()
            for action in HotkeyAction.allCases {
                for index in 0..<ShortcutStore.slotCount {
                    let slot = ShortcutSlot(action: action, index: index)
                    if let shortcut = ShortcutStore.shortcut(for: action, slot: index) {
                        print("SLOT \(action.rawValue).\(index) \(shortcut.displayString) registered=\(HotKeyManager.shared.isRegistered(slot))")
                    }
                }
            }
            print("READY"); fflush(stdout)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                exit(0)
            }
            return true
        }
        if args.contains("--debug-color-popover") {
            NSApp.setActivationPolicy(.accessory)
            if args.contains("--dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
            let kind = args.contains("--none") ? RGBAColor.clear : (args.contains("--half") ? RGBAColor.blue.with(alpha: 0.5) : RGBAColor.red)
            Task { @MainActor in
                await showColorPopover(color: kind)
                exit(0)
            }
            return true
        }
        if args.contains("--debug-settings-shot") {
            NSApp.setActivationPolicy(.accessory)
            if let i = args.firstIndex(of: "--tab"), i + 1 < args.count { UserDefaults.standard.set(args[i + 1], forKey: "settings.selectedTab") }
            Task { @MainActor in
                Preferences.register()
                SettingsWindowController.shared.show()
                guard let window = SettingsWindowController.shared.window else { exit(1) }
                window.setFrameOrigin(NSPoint(x: 80, y: 220))
                window.orderFrontRegardless()
                print("WINDOW \(window.windowNumber)")
                fflush(stdout)
                try? await Task.sleep(nanoseconds: 9_000_000_000)
                exit(0)
            }
            return true
        }
        if args.contains("--debug-overlay-shot") {
            NSApp.setActivationPolicy(.accessory)
            Task { @MainActor in
                await renderOverlay(windowMode: args.contains("--window-mode"))
                exit(0)
            }
            return true
        }
        if args.contains("--debug-capture-selftest") {
            NSApp.setActivationPolicy(.accessory)
            Task { @MainActor in
                await CaptureSelfTest.run()
                exit(0)
            }
            return true
        }
        guard let flag = args.firstIndex(of: "--debug-editor-shot"), flag + 1 < args.count else { return false }
        let output = URL(fileURLWithPath: args[flag + 1])
        if args.contains("--dark") { NSApp.appearance = NSAppearance(named: .darkAqua) }
        NSApp.setActivationPolicy(.accessory)
        let tool = args.firstIndex(of: "--tool").flatMap { i in i + 1 < args.count ? EditorTool(rawValue: args[i + 1]) : nil }
        let selectKind = args.firstIndex(of: "--select").flatMap { i in i + 1 < args.count ? AnnotationKind(rawValue: args[i + 1]) : nil }
        let onScreen = args.contains("--onscreen")
        Task { @MainActor in
            await renderEditor(to: output, tool: tool, selectKind: selectKind, onScreen: onScreen)
            exit(0)
        }
        return true
    }

    /// The process's physical footprint in MB: the number Xcode's memory gauge shows.
    private static func footprintMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return status == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }

    /// Opens and closes editor windows several times and prints the footprint at each stage, and whether the
    /// controller, model and window were actually freed. Only weak references are kept here, so nothing in
    /// this harness itself keeps a closed editor alive. `withEdits` adds annotations, a crop and a rotation,
    /// which leave full-size images in the undo history.
    private static func runMemoryTest(withEdits: Bool) async {
        func settle() async { try? await Task.sleep(nanoseconds: 900_000_000) }

        /// Creates an editor and returns only weak references to its parts.
        func openEditor() -> (EditorWindowController, EditorModel, NSWindow)? {
            let controller = EditorWindowController.present(CaptureResult(image: SampleScreenshot.make(width: 1280, height: 800), scale: 2), savedURL: nil)
            guard let window = controller.window else { return nil }
            window.setFrameOrigin(NSPoint(x: -6000, y: 200))
            let model = controller.model
            if withEdits {
                for (i, kind) in [AnnotationKind.rectangle, .obfuscate, .arrow, .step].enumerated() {
                    var a = model.makeAnnotation(kind)
                    a.rect = CGRect(x: 200 + 150 * i, y: 200, width: 300, height: 120)
                    if a.isLinear { a.start = CGPoint(x: 100, y: 100); a.end = CGPoint(x: 600, y: 400) }
                    model.add(a, select: false)
                }
                model.crop(to: CGRect(x: 40, y: 40, width: 2200, height: 1400))
                model.rotate(clockwise: true)
            }
            return (controller, model, window)
        }

        await settle()
        let baseline = footprintMB()
        print(String(format: "baseline (menu bar only)      %6.1f MB", baseline))
        for cycle in 1...5 {
            weak var weakController: EditorWindowController?
            weak var weakModel: EditorModel?
            weak var weakWindow: NSWindow?
            do {
                guard let parts = openEditor() else { return }
                weakController = parts.0; weakModel = parts.1; weakWindow = parts.2
            }
            await settle()
            let open = footprintMB()
            EditorWindowController.controllers.last?.window?.close()
            await settle()
            let closed = footprintMB()
            print(String(format: "cycle %d: open %6.1f MB   closed %6.1f MB (%+.1f vs baseline)   freed: controller=%@ model=%@ window=%@",
                         cycle, open, closed, closed - baseline,
                         weakController == nil ? "yes" : "NO", weakModel == nil ? "yes" : "NO", weakWindow == nil ? "yes" : "NO"))
            fflush(stdout)
        }
    }

    private final class PopoverSwitch: ObservableObject { @Published var on = false }

    private struct PopoverProbe: View {
        @ObservedObject var model: PopoverSwitch
        var body: some View {
            Color.clear
                .background(PopoverAnchor(isPresented: Binding(get: { model.on }, set: { model.on = $0 })) {
                    ColorEditorDemo(color: .red)
                })
        }
    }

    /// Two editor windows, a colour popover open in the front one, and a periodic log of window order
    /// and popover state, so a real click on the other window can be judged from outside.
    private static func runTwoWindows() async {
        let settingsAsB = CommandLine.arguments.contains("--settings-as-b")
        // With --settings-as-b the second window is the Settings window instead of another editor.
        var b: EditorWindowController?
        if settingsAsB {
            Preferences.register()
            SettingsWindowController.shared.show()
        } else {
            b = EditorWindowController.present(CaptureResult(image: SampleScreenshot.make(width: 900, height: 560), scale: 2), savedURL: nil)
        }
        let a = EditorWindowController.present(CaptureResult(image: SampleScreenshot.make(width: 900, height: 560), scale: 2), savedURL: nil)
        guard let windowA = a.window, let windowB = settingsAsB ? SettingsWindowController.shared.window : b?.window else { return }
        // B at the left, A overlapping its right part and in front.
        if settingsAsB {
            windowB.setFrameOrigin(NSPoint(x: 60, y: 200))
        } else {
            windowB.setFrame(NSRect(x: 60, y: 200, width: 700, height: 520), display: true)
            windowB.title = "WINDOW-B"
        }
        windowA.setFrame(NSRect(x: 460, y: 260, width: 700, height: 520), display: true)
        windowA.title = "WINDOW-A"
        windowB.orderFrontRegardless()
        windowA.makeKeyAndOrderFront(nil)
        try? await Task.sleep(nanoseconds: 600_000_000)

        let model = PopoverSwitch()
        let host = NSHostingView(rootView: PopoverProbe(model: model))
        host.frame = NSRect(x: 120, y: 120, width: 60, height: 24)
        windowA.contentView?.addSubview(host)
        windowA.contentView?.layoutSubtreeIfNeeded()
        // The anchor view must already be in the window when the flag flips, or nothing is shown.
        try? await Task.sleep(nanoseconds: 400_000_000)
        if !CommandLine.arguments.contains("--no-popover") { model.on = true }
        try? await Task.sleep(nanoseconds: 700_000_000)
        // Timeline of everything that could explain a window coming forward (timestamps in ms since start).
        let t0 = Date()
        func stamp() -> String { String(format: "T+%05d", Int(Date().timeIntervalSince(t0) * 1000)) }
        func name(_ w: NSWindow?) -> String { w === windowA ? "A" : (w === windowB ? "B" : (w == nil ? "-" : "other:\(type(of: w!))")) }
        for (label, notification) in [("KEY", NSWindow.didBecomeKeyNotification), ("RESIGN-KEY", NSWindow.didResignKeyNotification),
                                      ("MAIN", NSWindow.didBecomeMainNotification), ("RESIGN-MAIN", NSWindow.didResignMainNotification)] {
            NotificationCenter.default.addObserver(forName: notification, object: nil, queue: .main) { note in
                print("\(stamp()) \(label) \(name(note.object as? NSWindow))"); fflush(stdout)
            }
        }
        NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { event in
            print("\(stamp()) \(event.type == .leftMouseDown ? "MOUSE-DOWN" : "MOUSE-UP") on \(name(event.window))"); fflush(stdout)
            return event
        }
        var lastOrder = ""
        Task { @MainActor in
            while true {
                let order = NSApp.orderedWindows.compactMap { $0 === windowA ? "A" : ($0 === windowB ? "B" : nil) }.joined()
                if order != lastOrder { print("\(stamp()) ORDER \(order)  (key=\(name(NSApp.keyWindow)) main=\(name(NSApp.mainWindow)))"); fflush(stdout); lastOrder = order }
                try? await Task.sleep(nanoseconds: 15_000_000)
            }
        }
        print("READY A=\(windowA.windowNumber) B=\(windowB.windowNumber)")
        fflush(stdout)
        for _ in 0..<30 {
            try? await Task.sleep(nanoseconds: 700_000_000)
            let order = NSApp.orderedWindows.compactMap { $0 === windowA ? "A" : ($0 === windowB ? "B" : nil) }.joined()
            let popovers = NSApp.windows.filter { $0.isVisible && String(describing: type(of: $0)).contains("Popover") }.count
            print("STATE active=\(NSApp.isActive) key=\(NSApp.keyWindow?.title ?? "-") front-to-back=\(order) popover=\(popovers)")
            fflush(stdout)
        }
    }

    private struct ColorEditorDemo: View {
        @State var color: RGBAColor
        var body: some View { ColorEditor(title: "Border Color", color: $color, allowsNone: true) }
    }

    /// Shows the colour editor popover beside an editor window, for a screenshot.
    private static func showColorPopover(color: RGBAColor) async {
        let sample = SampleScreenshot.make(width: 900, height: 560)
        let controller = EditorWindowController.present(CaptureResult(image: sample, scale: 2), savedURL: nil)
        guard let window = controller.window, let content = window.contentView else { return }
        window.setFrame(NSRect(x: 60, y: 200, width: 1100, height: 780), display: true)
        window.orderFrontRegardless()
        try? await Task.sleep(nanoseconds: 600_000_000)
        let host = NSHostingController(rootView: ColorEditorDemo(color: color))
        host.sizingOptions = [.preferredContentSize]
        let popover = NSPopover()
        popover.behavior = .applicationDefined
        popover.contentViewController = host
        popover.show(relativeTo: NSRect(x: content.bounds.midX, y: content.bounds.maxY - 50, width: 24, height: 24), of: content, preferredEdge: .minY)
        try? await Task.sleep(nanoseconds: 500_000_000)
        guard let popoverWindow = host.view.window else { return }
        print("WINDOW \(popoverWindow.windowNumber)")
        fflush(stdout)
        try? await Task.sleep(nanoseconds: 9_000_000_000)
    }

    /// Shows the region-selection overlay over synthetic content, in a small window, mid-drag.
    private static func renderOverlay(windowMode: Bool) async {
        guard let screen = NSScreen.main else { return }
        let sample = SampleScreenshot.make(width: 1000, height: 650)
        let frozen = FrozenDisplay(screen: screen, displayID: 0, image: sample, scale: 2)
        let frame = NSRect(x: 60, y: 200, width: 1000, height: 650)
        let controller = CaptureOverlayController(frozen: [frozen], mode: windowMode ? .window : .region, windows: [], showLoupe: true, frame: frame)
        controller.begin { _ in }
        guard let window = controller.overlayWindows.first, let view = controller.views.first else { return }
        func event(_ type: NSEvent.EventType, _ p: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: view.convert(p, to: nil), modifierFlags: [], timestamp: 0,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
        }
        if !windowMode {
            // The drag ends on text, so the magnifier has something to show.
            view.mouseMoved(with: event(.mouseMoved, CGPoint(x: 240, y: 600)))
            view.mouseDown(with: event(.leftMouseDown, CGPoint(x: 240, y: 600)))
            view.mouseDragged(with: event(.leftMouseDragged, CGPoint(x: 330, y: 500)))
            view.mouseDragged(with: event(.leftMouseDragged, CGPoint(x: 404, y: 421)))
        }
        print("WINDOW \(window.windowNumber)")
        fflush(stdout)
        try? await Task.sleep(nanoseconds: 9_000_000_000)
    }

    private static func renderEditor(to url: URL, tool: EditorTool?, selectKind: AnnotationKind?, onScreen: Bool) async {
        // `--small` mimics a small region capture: the editor then opens at its smallest natural size.
        let small = CommandLine.arguments.contains("--small")
        let sample = small ? SampleScreenshot.make(width: 360, height: 220) : SampleScreenshot.make(width: 1280, height: 800)
        let controller = EditorWindowController.present(CaptureResult(image: sample, scale: 2), savedURL: nil)
        let model = controller.model
        if !CommandLine.arguments.contains("--ocr-demo") { SampleScreenshot.annotate(model) }
        if let kind = selectKind, let match = model.annotations.first(where: { $0.kind == kind }) { model.selection = [match.id]; model.refresh() }
        // `--docs`: a plain file name in the title bar, for the pictures on the project page.
        if CommandLine.arguments.contains("--docs") { model.displayName = "Invoice 2026-0142"; model.refresh() }
        if CommandLine.arguments.contains("--edit-text") { controller.debugBeginTextEditing(of: .text) }
        if let tool {
            controller.selectTool(tool)
            if tool == .crop { model.cropRect = CGRect(x: 300, y: 260, width: 1700, height: 1000); model.refresh() }
        }
        guard let window = controller.window else { return }
        // `--settle`: let the window show at its natural size first, as a real window does, before it is resized below.
        if CommandLine.arguments.contains("--settle") { try? await Task.sleep(nanoseconds: 1_500_000_000) }
        if CommandLine.arguments.contains("--ocr") {
            // Text recognition on the synthetic sample: prints what Vision found, optionally with a selection.
            controller.toggleTextRecognition(nil)
            for _ in 0..<80 where model.textMode == .recognizing { try? await Task.sleep(nanoseconds: 250_000_000) }
            let lines = model.recognizedText?.lines ?? []
            print("OCR mode=\(model.textMode) tool=\(model.tool.rawValue) lines=\(lines.count) codes=\(model.recognizedText?.codes.count ?? 0)")
            for code in model.recognizedText?.codes ?? [] { print("OCR code \(code.kindName): \(code.payload)") }
            for match in model.sensitiveMatches { print("OCR suggestion \(match.kind.rawValue): \(match.text)") }
            for (i, line) in lines.enumerated() { print(String(format: "OCR %2d x=%4.0f y=%4.0f w=%4.0f h=%3.0f  %@", i, line.rect.minX, line.rect.minY, line.rect.width, line.rect.height, line.text)) }
            if CommandLine.arguments.contains("--ocr-select"), lines.count > 4 {
                model.textSelection = TextSelection(anchor: TextPosition(line: 1, offset: 3), head: TextPosition(line: 4, offset: min(6, lines[4].text.count)))
                model.refresh()
                print("OCR selected: \(model.selectedRecognizedText ?? "-")")
            }
            if let word = CommandLine.arguments.firstIndex(of: "--ocr-select-word").map({ CommandLine.arguments[$0 + 1] }),
               let first = model.recognizedText?.occurrences(of: word).first {
                model.textSelection = first
                print("OCR word \"\(word)\" occurs \(model.occurrencesOfSelectedText) time(s)")
            }
            if CommandLine.arguments.contains("--ocr-censor-suggestions") { print("OCR censored \(model.censorSuggestions()) suggestion(s); lines left: \(model.recognizedText?.lines.count ?? 0)") }
            if CommandLine.arguments.contains("--ocr-censor-all") { print("OCR censored \(model.censorAllOccurrencesOfSelectedText()) occurrence(s); lines left: \(model.recognizedText?.lines.count ?? 0)") }
            if CommandLine.arguments.contains("--ocr-pick-code") { model.selectedCodeIndex = 0; model.refresh() }
            fflush(stdout)
        }
        if small {
            window.setFrameOrigin(NSPoint(x: onScreen ? 60 : -6000, y: 300))
            // `--min`: shrink to the smallest size the user can drag the window to.
            if CommandLine.arguments.contains("--min") { window.setContentSize(window.contentMinSize) }
        } else {
            window.setFrame(NSRect(x: onScreen ? 60 : -6000, y: 200, width: 1100, height: 780), display: true)
        }
        window.orderFrontRegardless()
        if !small { controller.zoomToFit() }
        if CommandLine.arguments.contains("--geometry"), let scroll = controller.canvasForTesting.enclosingScrollView {
            try? await Task.sleep(nanoseconds: 800_000_000)
            print("GEOM window=\(window.frame) canvas=\(controller.canvasForTesting.frame) clipBounds=\(scroll.contentView.bounds) clipFrame=\(scroll.contentView.frame) contentSize=\(scroll.contentSize) zoom=\(model.zoom)")
            fflush(stdout)
        }
        if onScreen {
            // The caller grabs just this window with `screencapture -l <number>`.
            print("WINDOW \(window.windowNumber)")
            print("editing=\(model.editingTextID != nil) firstResponder=\(String(describing: window.firstResponder))")
            fflush(stdout)
            for _ in 0..<14 {
                try? await Task.sleep(nanoseconds: 700_000_000)
                print("editing=\(model.editingTextID != nil) tool=\(model.tool.rawValue) key=\(window.isKeyWindow) annotations=\(model.annotations.count) steps=\(model.annotations.filter { $0.kind == .step }.count)")
                fflush(stdout)
            }
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            return
        }
        try? await Task.sleep(nanoseconds: 1_200_000_000)

        guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        if let png = rep.representation(using: .png, properties: [:]) {
            try? png.write(to: url)
        }
    }
}

/// Verifies the real ScreenCaptureKit paths against a window WhiteShot draws itself: four solid colour
/// quadrants. Only pixels inside that fixture are inspected; nothing else on screen is read out,
/// saved or printed.
@MainActor
enum CaptureSelfTest {
    private final class QuadrantView: NSView {
        override func draw(_ dirtyRect: NSRect) {
            let colors: [NSColor] = [NSColor(srgbRed: 1, green: 0, blue: 0, alpha: 1), NSColor(srgbRed: 0, green: 0.85, blue: 0, alpha: 1),
                                     NSColor(srgbRed: 0, green: 0, blue: 1, alpha: 1), NSColor(srgbRed: 1, green: 0.9, blue: 0, alpha: 1)]
            let w = bounds.width / 2, h = bounds.height / 2
            // Cocoa y is up: top-left red, top-right green, bottom-left blue, bottom-right yellow.
            let rects = [NSRect(x: 0, y: h, width: w, height: h), NSRect(x: w, y: h, width: w, height: h),
                         NSRect(x: 0, y: 0, width: w, height: h), NSRect(x: w, y: 0, width: w, height: h)]
            for (c, r) in zip(colors, rects) { c.setFill(); r.fill() }
        }
    }

    private static func report(_ name: String, _ ok: Bool, _ detail: String = "") {
        print("\(ok ? "PASS" : "FAIL") \(name) \(detail)")
        fflush(stdout)
    }

    /// Dominant-channel check, tolerant of colour management between sRGB and the display profile.
    private static func looksLike(_ p: (r: Int, g: Int, b: Int, a: Int), _ expected: String) -> Bool {
        switch expected {
        case "red": return p.r > 200 && p.g < 90 && p.b < 90
        case "green": return p.g > 150 && p.r < 90 && p.b < 90
        case "blue": return p.b > 200 && p.r < 90 && p.g < 90
        default: return p.r > 200 && p.g > 180 && p.b < 90
        }
    }

    private static func checkQuadrants(_ name: String, _ image: CGImage) {
        let w = image.width, h = image.height
        let points = [("red", w / 4, h / 4), ("green", 3 * w / 4, h / 4), ("blue", w / 4, 3 * h / 4), ("yellow", 3 * w / 4, 3 * h / 4)]
        let bad = points.filter { !looksLike(TestPixel.read(image, $0.1, $0.2), $0.0) }.map(\.0)
        report(name, bad.isEmpty, "\(w)x\(h) \(bad.isEmpty ? "" : "wrong: \(bad)")")
    }

    static func run() async {
        guard CGPreflightScreenCaptureAccess() else {
            report("permission", false, "Screen Recording is not granted to this process")
            return
        }
        guard let screen = NSScreen.main, let displayID = ScreenGrabber.displayID(of: screen) else { report("screen", false); return }
        let frame = NSRect(x: screen.frame.minX + 300, y: screen.frame.maxY - 600, width: 400, height: 240)
        let window = NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = QuadrantView(frame: NSRect(origin: .zero, size: frame.size))
        window.level = .screenSaver
        window.hasShadow = false
        window.isOpaque = true
        window.orderFrontRegardless()
        try? await Task.sleep(nanoseconds: 800_000_000)

        let local = CGRect(x: frame.minX - screen.frame.minX, y: screen.frame.maxY - frame.maxY, width: frame.width, height: frame.height)

        do {
            let frozen = try await ScreenGrabber.grabAllDisplays(includeCursor: false)
            guard let display = frozen.first(where: { $0.displayID == displayID }) else { report("freeze-frame", false, "main display missing"); return }
            let s = display.scale
            report("freeze-frame scale", s >= 1, "scale \(s)")
            let pixels = CGRect(x: local.minX * s, y: local.minY * s, width: local.width * s, height: local.height * s)
            if let crop = ImageOps.crop(display.image, to: pixels) {
                checkQuadrants("freeze-frame crop", crop)
                report("freeze-frame size", crop.width == Int(local.width * s), "\(crop.width) expected \(Int(local.width * s))")
            } else { report("freeze-frame crop", false, "crop failed") }
        } catch { report("freeze-frame", false, "\(error)") }

        do {
            let grabbed = try await ScreenGrabber.grabRegion(displayID: displayID, rect: local, includeCursor: false)
            checkQuadrants("direct region", grabbed.image)
        } catch { report("direct region", false, "\(error)") }

        do {
            let grabbed = try await ScreenGrabber.grabWindow(id: CGWindowID(window.windowNumber), includeCursor: false)
            checkQuadrants("single window", grabbed.image)
        } catch { report("single window", false, "\(error)") }

        // Window mode: hovering the fixture must find it, and the highlight must land exactly on it.
        // (Moves the pointer briefly, then puts it back.)
        do {
            let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
            let cgFrame = CGRect(x: frame.minX, y: primaryHeight - frame.maxY, width: frame.width, height: frame.height)
            let info = WindowInfo(id: CGWindowID(window.windowNumber), frame: cgFrame, title: "fixture", ownerName: "WhiteShot")
            let frozen = FrozenDisplay(screen: screen, displayID: displayID, image: TestPixel.blank(), scale: screen.backingScaleFactor)
            let controller = CaptureOverlayController(frozen: [frozen], mode: .window, windows: [info], showLoupe: false)
            var outcome: CaptureOverlayController.Outcome?
            controller.begin(present: false) { outcome = $0 }
            let original = NSEvent.mouseLocation
            CGWarpMouseCursorPosition(CGPoint(x: cgFrame.midX, y: cgFrame.midY))
            try? await Task.sleep(nanoseconds: 200_000_000)
            controller.refreshHover()
            report("window hover finds the window", controller.hoveredWindow?.id == info.id)
            let highlight = controller.hoveredWindowFrame(on: screen)
            let expected = CGRect(x: frame.minX - screen.frame.minX, y: frame.minY - screen.frame.minY, width: frame.width, height: frame.height)
            report("window highlight rectangle", highlight.map { abs($0.minX - expected.minX) < 1 && abs($0.minY - expected.minY) < 1 && abs($0.width - expected.width) < 1 && abs($0.height - expected.height) < 1 } ?? false,
                   "got \(String(describing: highlight)) expected \(expected)")
            CGWarpMouseCursorPosition(CGPoint(x: cgFrame.maxX + 120, y: cgFrame.midY))
            try? await Task.sleep(nanoseconds: 200_000_000)
            controller.refreshHover()
            report("window hover off the window", controller.hoveredWindow == nil)
            controller.cancel()
            CGWarpMouseCursorPosition(CGPoint(x: original.x, y: primaryHeight - original.y))
            _ = outcome
        }

        let listed = WindowList.onScreenWindows()
        report("window list", true, "\(listed.count) windows (own fixture excluded by layer)")
        window.orderOut(nil)
    }
}

/// Pixel reader used by the self-test (the unit tests have their own).
enum TestPixel {
    static func blank() -> CGImage {
        let ctx = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        return ctx.makeImage()!
    }

    static func read(_ image: CGImage, _ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
        var data = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return (Int(data[0]), Int(data[1]), Int(data[2]), Int(data[3]))
    }
}

/// A made-up app window with fictional data, so tests never involve real screen content.
enum SampleScreenshot {
    static func make(width: Int, height: Int) -> CGImage {
        let w = width * 2, h = height * 2
        let ctx = Renderer.makeContext(width: w, height: h, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)!
        ctx.scaleBy(x: 2, y: 2)
        ctx.translateBy(x: 0, y: CGFloat(height))
        ctx.scaleBy(x: 1, y: -1)
        let graphics = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics

        func fill(_ r: CGRect, _ c: NSColor) { c.setFill(); r.fill() }
        func text(_ s: String, _ p: CGPoint, size: CGFloat = 14, weight: NSFont.Weight = .regular, color: NSColor = NSColor(white: 0.12, alpha: 1)) {
            (s as NSString).draw(at: p, withAttributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color])
        }

        fill(CGRect(x: 0, y: 0, width: width, height: height), NSColor(white: 0.97, alpha: 1))
        fill(CGRect(x: 0, y: 0, width: width, height: 44), NSColor(white: 0.90, alpha: 1))
        for (i, c) in [NSColor.systemRed, .systemYellow, .systemGreen].enumerated() {
            c.setFill(); NSBezierPath(ovalIn: CGRect(x: 16 + i * 22, y: 15, width: 13, height: 13)).fill()
        }
        text("Fabrikam Billing", CGPoint(x: 540, y: 13), size: 14, weight: .semibold)
        fill(CGRect(x: 0, y: 44, width: 220, height: height - 44), NSColor(white: 0.93, alpha: 1))
        for (i, item) in ["Dashboard", "Invoices", "Customers", "Payments", "Reports", "Settings"].enumerated() {
            if i == 1 { fill(CGRect(x: 10, y: 66 + i * 36, width: 200, height: 30), NSColor.systemBlue.withAlphaComponent(0.18)) }
            text(item, CGPoint(x: 28, y: 73 + i * 36), size: 14, weight: i == 1 ? .semibold : .regular)
        }
        text("Invoice #2026-0142", CGPoint(x: 260, y: 70), size: 26, weight: .bold)
        text("Customer: Contoso Ltd", CGPoint(x: 260, y: 116), size: 15)
        text("Contact: Alex Example, alex@example.com", CGPoint(x: 260, y: 142), size: 15)
        // Well-known test numbers: they pass the IBAN and card checksums but belong to nobody.
        text("IBAN: DE89 3704 0044 0532 0130 00", CGPoint(x: 260, y: 168), size: 15)
        text("Card: 4111 1111 1111 1111", CGPoint(x: 260, y: 194), size: 15)
        text("Phone: +49 30 1234567", CGPoint(x: 260, y: 220), size: 15)
        text("Portal: https://contoso.example/billing", CGPoint(x: 760, y: 168), size: 15)
        text("Server: 192.168.0.12", CGPoint(x: 760, y: 194), size: 15)
        if let filter = CIFilter(name: "CIQRCodeGenerator") {
            filter.setValue(Data("https://contoso.example/pay/2026-0142".utf8), forKey: "inputMessage")
            filter.setValue("M", forKey: "inputCorrectionLevel")
            if let output = filter.outputImage {
                let scaled = output.transformed(by: CGAffineTransform(scaleX: 5, y: 5))
                if let qr = CIContext().createCGImage(scaled, from: scaled.extent) {
                    fill(CGRect(x: 1066, y: 58, width: 140, height: 140), .white)
                    NSImage(cgImage: qr, size: NSSize(width: 120, height: 120)).draw(in: CGRect(x: 1076, y: 68, width: 120, height: 120), from: .zero,
                        operation: .sourceOver, fraction: 1, respectFlipped: true, hints: [.interpolation: NSImageInterpolation.none])
                }
            }
        }
        fill(CGRect(x: 260, y: 250, width: 960, height: 36), NSColor(white: 0.86, alpha: 1))
        for (i, head) in ["Item", "Qty", "Price", "Total"].enumerated() {
            text(head, CGPoint(x: 276 + i * 230, y: 259), size: 13, weight: .semibold)
        }
        for row in 0..<6 {
            let y = 296 + row * 44
            fill(CGRect(x: 260, y: y, width: 960, height: 40), row % 2 == 0 ? .white : NSColor(white: 0.985, alpha: 1))
            text("Consulting package \(row + 1)", CGPoint(x: 276, y: y + 11), size: 14)
            text("\(row + 1)", CGPoint(x: 506, y: y + 11), size: 14)
            text("€ \(120 + row * 15).00", CGPoint(x: 736, y: y + 11), size: 14)
            text("€ \((120 + row * 15) * (row + 1)).00", CGPoint(x: 966, y: y + 11), size: 14)
        }
        fill(CGRect(x: 1020, y: 590, width: 200, height: 44), NSColor.systemGreen)
        text("Mark as paid", CGPoint(x: 1060, y: 603), size: 15, weight: .semibold, color: .white)

        NSGraphicsContext.restoreGraphicsState()
        return ctx.makeImage()!
    }

    @MainActor
    static func annotate(_ model: EditorModel) {
        func add(_ kind: AnnotationKind, _ configure: (inout Annotation) -> Void) {
            var a = model.makeAnnotation(kind)
            configure(&a)
            model.add(a, select: false)
        }
        let k: CGFloat = 2
        add(.obfuscate) { $0.rect = CGRect(x: 260 * k, y: 164 * k, width: 330 * k, height: 26 * k); $0.style.obfuscateMode = .pixelate }
        add(.obfuscate) { $0.rect = CGRect(x: 260 * k, y: 190 * k, width: 270 * k, height: 26 * k); $0.style.obfuscateMode = .blur }
        add(.rectangle) { $0.rect = CGRect(x: 255 * k, y: 105 * k, width: 290 * k, height: 50 * k); $0.style.strokeColor = .red; $0.style.lineWidth = 3 * k }
        add(.arrow) { $0.start = CGPoint(x: 700 * k, y: 140 * k); $0.end = CGPoint(x: 560 * k, y: 128 * k); $0.style.lineWidth = 4 * k; $0.style.shadow = true }
        add(.text) {
            $0.rect = CGRect(x: 710 * k, y: 120 * k, width: 260 * k, height: 40 * k)
            $0.text = "Check the customer name"
            $0.style.fontSize = 20 * k; $0.style.bold = true
        }
        add(.highlight) { $0.rect = CGRect(x: 258 * k, y: 66 * k, width: 270 * k, height: 36 * k); $0.style.highlightMode = .text }
        add(.step) { $0.rect = CGRect(x: 236 * k, y: 255 * k, width: 30 * k, height: 30 * k) }
        add(.step) { $0.rect = CGRect(x: 1190 * k, y: 566 * k, width: 30 * k, height: 30 * k) }
        add(.ellipse) { $0.rect = CGRect(x: 1010 * k, y: 580 * k, width: 220 * k, height: 64 * k); $0.style.strokeColor = .blue; $0.style.lineWidth = 3 * k }
        add(.bubble) {
            $0.rect = CGRect(x: 800 * k, y: 660 * k, width: 260 * k, height: 70 * k)
            $0.tail = CGPoint(x: 1060 * k, y: 640 * k)
            $0.text = "Click here when paid"
        }
        add(.freehand) {
            $0.points = (0...40).map { (i: Int) -> CGPoint in
                let x: CGFloat = CGFloat(300 + i * 9) * k
                let wave: CGFloat = CGFloat(sin(Double(i) / 3)) * 14
                return CGPoint(x: x, y: (690 + wave) * k)
            }
            $0.style.strokeColor = .green; $0.style.lineWidth = 4 * k
        }
        model.selection = []
        model.undoManager.removeAllActions()
        model.markClean()
    }
}


/// Debug builds only: with `WHITESHOT_DEBUG_ACTIVATION=<file>` set, writes what the app believes about being active and
/// about its menu bar to that file (every change, and the key events around it). With `WHITESHOT_FAKE_CAPTURE=1` the
/// capture shortcuts deliver a synthetic picture through the normal output pipeline instead of reading the screen.
@MainActor
enum ActivationProbe {
    static var fakeCaptureRequested: Bool { ProcessInfo.processInfo.environment["WHITESHOT_FAKE_CAPTURE"] == "1" }
    /// `WHITESHOT_FAKE_CAPTURE=overlay`: the real selection overlay, but over a synthetic picture instead of the screen.
    static var fakeOverlayRequested: Bool { ProcessInfo.processInfo.environment["WHITESHOT_FAKE_CAPTURE"] == "overlay" }

    static func syntheticDisplays() -> [FrozenDisplay] {
        NSScreen.screens.map { screen in
            FrozenDisplay(screen: screen, displayID: ScreenGrabber.displayID(of: screen) ?? 0,
                          image: SampleScreenshot.make(width: Int(screen.frame.width), height: Int(screen.frame.height)), scale: 2)
        }
    }

    private static var lastState = ""

    private nonisolated static func menuItem(_ action: Selector, in menu: NSMenu?) -> NSMenuItem? {
        guard let menu else { return nil }
        for item in menu.items {
            if item.action == action { return item }
            if let found = menuItem(action, in: item.submenu) { return found }
        }
        return nil
    }

    static func start() {
        guard let path = ProcessInfo.processInfo.environment["WHITESHOT_DEBUG_ACTIVATION"] else { return }
        FileManager.default.createFile(atPath: path, contents: nil)
        let start = Date()
        func log(_ text: String) {
            guard let handle = FileHandle(forWritingAtPath: path) else { return }
            handle.seekToEndOfFile()
            handle.write(String(format: "%6.2f %@\n", Date().timeIntervalSince(start), text).data(using: .utf8)!)
            try? handle.close()
        }
        let center = NotificationCenter.default
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
                     NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification, NSWindow.didBecomeMainNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { note in
                let title = (note.object as? NSWindow)?.title ?? ""
                MainActor.assumeIsolated { log("EVENT \(note.name.rawValue.replacingOccurrences(of: "NS", with: "")) \(title)") }
            }
        }
        log("PROBE started pid=\(ProcessInfo.processInfo.processIdentifier)")
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            MainActor.assumeIsolated {
                NSApp.mainMenu?.update()
                func enabled(_ selector: Selector) -> String {
                    guard let item = menuItem(selector, in: NSApp.mainMenu) else { return "?" }
                    return item.isEnabled ? "on" : "OFF"
                }
                let editors = EditorWindowController.controllers.count
                let state = "policy=\(NSApp.activationPolicy().rawValue) isActive=\(NSApp.isActive) runningAppActive=\(NSRunningApplication.current.isActive)"
                    + " frontmost=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "-")"
                    + " key=\(NSApp.keyWindow?.title ?? "-") main=\(NSApp.mainWindow?.title ?? "-") editors=\(editors) zoom=\(EditorWindowController.controllers.first?.model.zoom ?? 0)"
                    + " menuBarVisible=\(NSMenu.menuBarVisible())"
                    + " | menu: zoomIn=\(enabled(#selector(EditorWindowController.zoomInMenu(_:)))) save=\(enabled(#selector(EditorWindowController.saveDocument(_:))))"
                    + " close=\(enabled(#selector(NSWindow.performClose(_:)))) settings=\(enabled(#selector(AppDelegate.showSettings(_:))))"
                if state != lastState { lastState = state; log("STATE \(state)") }
            }
        }
    }
}


/// Captures one of WhiteShot's own windows with and without its shadow and reports the sizes and the transparency around it.
/// Only that window's pixels are looked at.
@MainActor
enum WindowShadowTest {
    static func run() async {
        guard CGPreflightScreenCaptureAccess() else { print("FAIL permission"); return }
        guard let screen = NSScreen.main else { return }
        let frame = NSRect(x: screen.frame.minX + 300, y: screen.frame.maxY - 640, width: 420, height: 260)
        let window = NSWindow(contentRect: frame, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Shadow fixture"
        let view = NSView(frame: NSRect(origin: .zero, size: frame.size))
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.systemTeal.cgColor
        window.contentView = view
        window.hasShadow = true
        window.setFrame(frame, display: true)
        window.orderFrontRegardless()
        try? await Task.sleep(nanoseconds: 900_000_000)
        print("window frame \(window.frame) number \(window.windowNumber)")
        for shadow in [false, true] {
            do {
                let grabbed = try await ScreenGrabber.grabWindow(id: CGWindowID(window.windowNumber), includeCursor: false, includeShadow: shadow)
                let image = grabbed.image
                func alpha(_ x: Int, _ y: Int) -> Int { TestPixel.read(image, x, y).a }
                print("shadow=\(shadow): image \(image.width)x\(image.height) scale \(grabbed.scale); alpha corner(0,0)=\(alpha(0, 0)) edge-mid-left=\(alpha(0, image.height / 2)) centre=\(alpha(image.width / 2, image.height / 2)) below-bottom-mid=\(alpha(image.width / 2, image.height - 1))")
            } catch { print("shadow=\(shadow): error \(error)") }
        }
        // Experiments with the output size: where do the opaque window and its faint shadow end up?
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false),
              let target = content.windows.first(where: { $0.windowID == CGWindowID(window.windowNumber) }) else { window.orderOut(nil); return }
        let filter = SCContentFilter(desktopIndependentWindow: target)
        func bounds(_ image: CGImage, minAlpha: Int) -> String {
            var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
            let ctx = CGContext(data: &data, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
            let width = image.width
            for y in 0..<image.height {
                for x in 0..<width {
                    let alpha = Int(data[(y * width + x) * 4 + 3])
                    if alpha >= minAlpha {
                        minX = min(minX, x); maxX = max(maxX, x)
                        minY = min(minY, y); maxY = max(maxY, y)
                    }
                }
            }
            return maxX < 0 ? "none" : "x \(minX)...\(maxX) y \(minY)...\(maxY)"
        }
        for (label, w, h) in [("default size 840x520", 840, 520), ("padded 1200x880", 1200, 880), ("padded 1000x760", 1000, 760)] {
            let config = SCStreamConfiguration()
            config.width = w; config.height = h
            config.ignoreShadowsSingleWindow = false
            config.pixelFormat = kCVPixelFormatType_32BGRA
            if let image = try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config) {
                print("\(label): image \(image.width)x\(image.height); opaque(255) \(bounds(image, minAlpha: 250)); any shadow(>=2) \(bounds(image, minAlpha: 2))")
            }
        }
        window.orderOut(nil)
    }
}


/// Drags the picture out of an editor onto a window of this process and reports what arrived. Needs a real mouse drag from
/// outside (cliclick), between two of WhiteShot's own windows.
@MainActor
enum DragTest {
    private final class DropTargetView: NSView {
        var onDrop: ([URL]) -> Void = { _ in }

        override init(frame: NSRect) {
            super.init(frame: frame)
            registerForDraggedTypes([.fileURL])
        }

        required init?(coder: NSCoder) { fatalError() }

        override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { .copy }

        override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
            let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
            onDrop(urls)
            return !urls.isEmpty
        }

        override func draw(_ dirtyRect: NSRect) {
            NSColor.systemGreen.withAlphaComponent(0.35).setFill()
            bounds.fill()
        }
    }

    private static func findHandle(in view: NSView) -> ImageDragSourceView? {
        if let handle = view as? ImageDragSourceView { return handle }
        for sub in view.subviews { if let found = findHandle(in: sub) { return found } }
        return nil
    }

    static func run() async {
        let controller = EditorWindowController.present(CaptureResult(image: SampleScreenshot.make(width: 640, height: 400), scale: 2), savedURL: nil)
        guard let window = controller.window, let screen = NSScreen.main else { return }
        window.setFrame(NSRect(x: 60, y: screen.frame.maxY - 760, width: 900, height: 620), display: true)
        let target = NSWindow(contentRect: NSRect(x: 1000, y: screen.frame.maxY - 640, width: 300, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        target.title = "Drop here"
        let dropView = DropTargetView(frame: NSRect(origin: .zero, size: NSSize(width: 300, height: 300)))
        var dropped = false
        dropView.onDrop = { urls in
            dropped = true
            for url in urls {
                let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? -1
                let decoded = ImageEncoder.decode(contentsOf: url)
                print("DROPPED \(url.lastPathComponent) bytes=\(size) image=\(decoded.map { "\($0.image.width)x\($0.image.height)" } ?? "unreadable") inDragFolder=\(url.path.hasPrefix(Exporter.dragDirectory.path))")
            }
            fflush(stdout)
        }
        target.contentView = dropView
        target.orderFrontRegardless()
        window.orderFrontRegardless()
        try? await Task.sleep(nanoseconds: 1_500_000_000)

        guard let handle = findHandle(in: window.contentView ?? NSView()) else { print("NOHANDLE"); return }
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        func cg(_ rect: NSRect) -> CGPoint { CGPoint(x: rect.midX, y: primaryHeight - rect.midY) }
        let handlePoint = cg(window.convertToScreen(handle.convert(handle.bounds, to: nil)))
        let targetPoint = cg(target.convertToScreen(dropView.convert(dropView.bounds, to: nil)))
        print("READY handle=\(Int(handlePoint.x)),\(Int(handlePoint.y)) target=\(Int(targetPoint.x)),\(Int(targetPoint.y)) pid=\(ProcessInfo.processInfo.processIdentifier)")
        fflush(stdout)
        for _ in 0..<120 where !dropped { try? await Task.sleep(nanoseconds: 250_000_000) }
        print(dropped ? "DONE" : "TIMEOUT")
        fflush(stdout)
    }
}
#endif
