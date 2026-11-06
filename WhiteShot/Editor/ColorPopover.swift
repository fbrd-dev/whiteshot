import AppKit
import SwiftUI

/// Samples a colour from anywhere on screen with the system magnifier loupe.
@MainActor
final class EyeDropper {
    static let shared = EyeDropper()
    private var sampler: NSColorSampler?
    /// True while the loupe is up. Clicks then belong to the loupe and must not dismiss the colour popover.
    private(set) var isSampling = false

    /// Starts the loupe. `completion` is called with the colour under the click, and not at all if the user cancels.
    func pick(_ completion: @escaping (RGBAColor) -> Void) {
        let sampler = NSColorSampler()
        self.sampler = sampler
        isSampling = true
        sampler.show { [weak self] color in
            // The system calls this on the main thread; say so for the compiler.
            MainActor.assumeIsolated {
                self?.sampler = nil
                self?.isSampling = false
                if let color { completion(RGBAColor(color)) }
            }
        }
    }
}

/// Shows SwiftUI content in an NSPopover that stays open while the eyedropper loupe or the colour wheel
/// is in use, and closes the moment the user clicks anywhere else.
///
/// AppKit's own dismissal rules do not fit: a transient popover closes when the loupe is clicked, and a
/// semitransient one does not close when you click the canvas next to it, and, worse, while one is open
/// it keeps its parent window in front of other windows of the app. So the popover is
/// application-defined and closed by `Coordinator`, before the click that dismisses it is processed.
struct PopoverAnchor<Content: View>: NSViewRepresentable {
    @Binding var isPresented: Bool
    let content: () -> Content

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        let coordinator = context.coordinator
        coordinator.isPresented = $isPresented
        coordinator.anchor = view
        if isPresented {
            guard coordinator.popover == nil, view.window != nil else { return }
            let host = NSHostingController(rootView: content())
            host.sizingOptions = [.preferredContentSize]
            let popover = NSPopover()
            popover.behavior = .applicationDefined
            // No animation: closing must be immediate so it is done before the dismissing click is handled.
            popover.animates = false
            popover.contentViewController = host
            popover.delegate = coordinator
            popover.show(relativeTo: view.bounds, of: view, preferredEdge: .minY)
            coordinator.popover = popover
            coordinator.startWatching()
        } else {
            coordinator.close()
        }
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) {
        coordinator.close()
    }

    @MainActor
    final class Coordinator: NSObject, NSPopoverDelegate {
        var popover: NSPopover?
        var isPresented: Binding<Bool>?
        weak var anchor: NSView?
        private var monitor: Any?
        private var closeObserver: NSObjectProtocol?

        /// Closes the popover on a click outside it and on Escape, for as long as it is open.
        func startWatching() {
            stopWatching()
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]) { [weak self] event in
                MainActor.assumeIsolated { self?.handle(event) }
                return event
            }
            if let window = anchor?.window {
                closeObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.close() }
                }
            }
        }

        private func stopWatching() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
            closeObserver = nil
        }

        func handle(_ event: NSEvent) {
            guard let popover, popover.isShown else { return }
            let popoverWindow = popover.contentViewController?.view.window
            if event.type == .keyDown {
                if event.keyCode == 53, event.window === popoverWindow || event.window === anchor?.window { close() }
                return
            }
            // Clicks that belong to the popover, the colour wheel panel or the eyedropper loupe keep it open.
            if event.window === popoverWindow || event.window is NSColorPanel || EyeDropper.shared.isSampling { return }
            // A click on the swatch itself is the swatch's own toggle; closing here would make it reopen.
            if let anchor, event.window === anchor.window,
               anchor.bounds.contains(anchor.convert(event.locationInWindow, from: nil)) { return }
            close()
        }

        func close() {
            stopWatching()
            guard let popover else { return }
            self.popover = nil
            popover.delegate = nil
            popover.close()
            isPresented?.wrappedValue = false
        }

        nonisolated func popoverDidClose(_ notification: Notification) {
            MainActor.assumeIsolated {
                stopWatching()
                popover = nil
                isPresented?.wrappedValue = false
            }
        }
    }
}

/// A swatch that opens the colour editor.
struct ColorField: View {
    let label: String
    @Binding var color: RGBAColor
    var systemImage: String?
    var allowsNone = true
    @State private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            HStack(spacing: 4) {
                if let systemImage { Image(systemName: systemImage).foregroundStyle(Color(nsColor: .secondaryLabelColor)) }
                Swatch(color: color).frame(width: 18, height: 18)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
        .background(PopoverAnchor(isPresented: $open) {
            ColorEditor(title: label, color: $color, allowsNone: allowsNone)
        })
    }
}

/// Presets, an eyedropper, hex and RGB fields (which show and accept colour codes) and opacity.
struct ColorEditor: View {
    let title: String
    @Binding var color: RGBAColor
    let allowsNone: Bool

    @State private var hexText = ""

    private static let presets: [RGBAColor] = [
        .black, RGBAColor(r: 0.28, g: 0.28, b: 0.3), .gray, .white,
        .red, .orange, .yellow, .green,
        RGBAColor(r: 0.0, g: 0.78, b: 0.75), .blue, RGBAColor(r: 0.35, g: 0.34, b: 0.84), .purple,
        RGBAColor(r: 1.0, g: 0.18, b: 0.33),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)

            // 7 columns hold the 13 presets plus "No Color" as two full rows, so nothing is left dangling.
            LazyVGrid(columns: Array(repeating: GridItem(.fixed(26), spacing: 6), count: 7), spacing: 6) {
                ForEach(Array(Self.presets.enumerated()), id: \.offset) { _, preset in
                    Button { choose(preset) } label: {
                        Swatch(color: preset, selected: color.isVisible && sameColor(preset)).frame(width: 26, height: 26)
                    }
                    .buttonStyle(.plain)
                    .help("#\(preset.hexString)")
                }
                if allowsNone {
                    Button { color = color.with(alpha: 0) } label: {
                        Swatch(color: .clear, selected: !color.isVisible).frame(width: 26, height: 26)
                    }
                    .buttonStyle(.plain)
                    .help(String(localized: "No Color"))
                }
            }

            Divider()

            HStack {
                Button {
                    EyeDropper.shared.pick { picked in
                        color = picked.with(alpha: color.isVisible ? color.a : 1)
                    }
                } label: {
                    Label("Pick from Screen", systemImage: "eyedropper")
                }
                Spacer()
                ColorPicker("Color Wheel", selection: wheelBinding, supportsOpacity: false)
                    .labelsHidden()
                    .help(String(localized: "Color Wheel"))
            }

            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    Text("Hex").foregroundStyle(.secondary)
                    HStack(spacing: 4) {
                        Text("#").foregroundStyle(.secondary)
                        TextField("RRGGBB", text: $hexText)
                            .font(.system(.body, design: .monospaced))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 92)
                            .onSubmit(applyHex)
                        copyMenu
                    }
                    .gridCellColumns(3)
                }
                GridRow {
                    Text("RGB").foregroundStyle(.secondary)
                    channelField(\.r)
                    channelField(\.g)
                    channelField(\.b)
                }
            }

            HStack(spacing: 8) {
                Text("Opacity").foregroundStyle(.secondary)
                Slider(value: Binding(get: { color.a }, set: { color = color.with(alpha: $0) }), in: 0...1)
                    .disabled(!color.isVisible)
                Text("\(Int((color.a * 100).rounded()))%").monospacedDigit().frame(width: 40, alignment: .trailing)
            }
        }
        .padding(14)
        .frame(width: 268)
        .onAppear { hexText = color.hexString }
        .onChange(of: color) { _, new in hexText = new.hexString }
    }

    // MARK: Pieces

    private var copyMenu: some View {
        Menu {
            Button("Copy Hex (#\(color.hexString))") { copy("#" + color.hexString) }
            Button("Copy RGB (\(rgbText))") { copy(rgbText) }
        } label: {
            Image(systemName: "doc.on.doc")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(String(localized: "Copy the color code"))
    }

    private var rgbText: String {
        let c = color.rgb255
        return "\(c.r), \(c.g), \(c.b)"
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// One 0...255 number field. Editing it re-colours immediately; an invisible colour becomes visible.
    private func channelField(_ channel: KeyPath<RGBAColor, Double>) -> some View {
        let binding = Binding<Int>(
            get: {
                let c = color.rgb255
                return channel == \RGBAColor.r ? c.r : (channel == \RGBAColor.g ? c.g : c.b)
            },
            set: { value in
                if channel == \RGBAColor.r { color = color.replacing(red: value) }
                else if channel == \RGBAColor.g { color = color.replacing(green: value) }
                else { color = color.replacing(blue: value) }
            })
        return TextField("", value: binding, format: .number.grouping(.never))
            .multilineTextAlignment(.trailing)
            .textFieldStyle(.roundedBorder)
            .frame(width: 56)
    }

    /// The colour wheel's well always shows an opaque colour, so "No Color" never renders as a confusing
    /// half-black, half-white box. Choosing something on the wheel makes the colour visible again.
    private var wheelBinding: Binding<Color> {
        Binding(get: { Color(color.with(alpha: 1)) },
                set: { picked in color = RGBAColor(NSColor(picked)).with(alpha: color.isVisible ? color.a : 1) })
    }

    private func choose(_ preset: RGBAColor) {
        color = preset.with(alpha: color.isVisible ? color.a : 1)
    }

    private func sameColor(_ other: RGBAColor) -> Bool {
        let a = color.rgb255, b = other.rgb255
        return a.r == b.r && a.g == b.g && a.b == b.b
    }

    private func applyHex() {
        if let applied = color.applying(hex: hexText) { color = applied }
        hexText = color.hexString      // show what was actually applied, or snap back if the text was invalid
    }
}
