import AppKit
import SwiftUI

/// Small deterministic generator, so the torn-edge preview and the final result use the same edge.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Presents SwiftUI content as a sheet on an editor window.
@MainActor
enum SheetPresenter {
    static func present<Content: View>(over window: NSWindow, @ViewBuilder content: (_ dismiss: @escaping () -> Void) -> Content) {
        var sheet: NSWindow?
        let dismiss: () -> Void = {
            if let sheet { window.endSheet(sheet) }
        }
        let host = NSHostingController(rootView: content(dismiss))
        let panel = NSWindow(contentViewController: host)
        panel.styleMask = [.titled]
        sheet = panel
        window.beginSheet(panel)
    }
}

private struct Checkerboard: View {
    var body: some View {
        Canvas { context, size in
            let tile: CGFloat = 8
            for row in 0..<Int(ceil(size.height / tile)) {
                for col in 0..<Int(ceil(size.width / tile)) where (row + col) % 2 == 0 {
                    context.fill(Path(CGRect(x: CGFloat(col) * tile, y: CGFloat(row) * tile, width: tile, height: tile)), with: .color(.gray.opacity(0.18)))
                }
            }
        }
    }
}

/// Dialog skeleton: title, content, Cancel / Apply.
private struct SheetFrame<Content: View>: View {
    let title: String
    let applyTitle: String
    var canApply = true
    let onApply: () -> Void
    let onCancel: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            content
            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button(applyTitle, action: onApply).keyboardShortcut(.defaultAction).disabled(!canApply)
            }
        }
        .padding(20)
    }
}

/// An effect dialog with a live preview rendered on a small copy of the image.
struct EffectSheet<Params: Equatable, Controls: View>: View {
    let title: String
    let base: CGImage
    let render: (CGImage, Params, CGFloat) -> CGImage?
    let onApply: (Params) -> Void
    let onCancel: () -> Void
    @ViewBuilder let controls: (Binding<Params>) -> Controls

    @State private var params: Params
    @State private var preview: CGImage?
    private let thumbnail: CGImage
    private let factor: CGFloat

    init(title: String, base: CGImage, initial: Params,
         render: @escaping (CGImage, Params, CGFloat) -> CGImage?,
         onApply: @escaping (Params) -> Void, onCancel: @escaping () -> Void,
         @ViewBuilder controls: @escaping (Binding<Params>) -> Controls) {
        self.title = title
        self.base = base
        self.render = render
        self.onApply = onApply
        self.onCancel = onCancel
        self.controls = controls
        _params = State(initialValue: initial)
        let longest = CGFloat(max(base.width, base.height))
        let f = min(1, 300 / longest)
        factor = f
        thumbnail = f < 1 ? (ImageOps.resize(base, to: CGSize(width: CGFloat(base.width) * f, height: CGFloat(base.height) * f)) ?? base) : base
    }

    var body: some View {
        SheetFrame(title: title, applyTitle: String(localized: "Apply"), onApply: { onApply(params) }, onCancel: onCancel) {
            HStack(alignment: .top, spacing: 18) {
                ZStack {
                    Checkerboard()
                    if let preview {
                        Image(decorative: preview, scale: 1).resizable().aspectRatio(contentMode: .fit).padding(6)
                    }
                }
                .frame(width: 320, height: 240)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.15)))

                VStack(alignment: .leading, spacing: 10) { controls($params) }
                    .frame(width: 240, alignment: .leading)
            }
        }
        .onChange(of: params, initial: true) { _, new in preview = render(thumbnail, new, factor) }
    }
}

private struct SliderRow: View {
    let label: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var format = "%.0f"

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(label)
                Spacer()
                Text(String(format: format, value)).monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range)
        }
    }
}

// MARK: - Concrete effect dialogs

@MainActor
enum EffectSheets {
    struct ShadowParams: Equatable {
        var offsetX = 6.0, offsetY = 6.0, blur = 10.0
        var color = RGBAColor.black.with(alpha: 0.55)
    }

    static func dropShadow(model: EditorModel, window: NSWindow) {
        SheetPresenter.present(over: window) { dismiss in
            EffectSheet(title: String(localized: "Drop Shadow"), base: model.baseImage, initial: ShadowParams(),
                        render: { image, p, f in
                            ImageOps.dropShadow(image, offset: CGSize(width: p.offsetX * f, height: p.offsetY * f), blur: p.blur * f, color: p.color)?.image
                        },
                        onApply: { p in
                            dismiss()
                            model.applyEffect(String(localized: "Drop Shadow")) {
                                ImageOps.dropShadow($0, offset: CGSize(width: p.offsetX * model.scale, height: p.offsetY * model.scale), blur: p.blur * model.scale, color: p.color)
                            }
                        },
                        onCancel: dismiss) { $p in
                SliderRow(label: String(localized: "Horizontal offset"), value: $p.offsetX, range: -30...30)
                SliderRow(label: String(localized: "Vertical offset"), value: $p.offsetY, range: -30...30)
                SliderRow(label: String(localized: "Blur"), value: $p.blur, range: 0...40)
                ColorField(label: String(localized: "Shadow Color"), color: $p.color, systemImage: "paintpalette", allowsNone: false)
            }
        }
    }

    struct BorderParams: Equatable {
        var width = 2.0
        var color = RGBAColor.black
    }

    static func border(model: EditorModel, window: NSWindow) {
        SheetPresenter.present(over: window) { dismiss in
            EffectSheet(title: String(localized: "Border"), base: model.baseImage, initial: BorderParams(),
                        render: { image, p, f in ImageOps.border(image, width: max(1, Int((p.width * f).rounded())), color: p.color)?.image },
                        onApply: { p in
                            dismiss()
                            model.applyEffect(String(localized: "Border")) { ImageOps.border($0, width: max(1, Int((p.width * model.scale).rounded())), color: p.color) }
                        },
                        onCancel: dismiss) { $p in
                SliderRow(label: String(localized: "Width"), value: $p.width, range: 1...40)
                ColorField(label: String(localized: "Border Color"), color: $p.color, systemImage: "paintpalette", allowsNone: false)
            }
        }
    }

    struct TornParams: Equatable {
        var tooth = 8.0, range = 14.0
        var top = true, right = true, bottom = true, left = true
        var shadow = true
        var seed = UInt64.random(in: 1...UInt64.max)
    }

    static func tornEdge(model: EditorModel, window: NSWindow) {
        func options(_ p: TornParams, _ f: CGFloat) -> ImageOps.TornEdgeOptions {
            var o = ImageOps.TornEdgeOptions()
            o.toothHeight = p.tooth * f; o.horizontalToothRange = p.range * f
            o.top = p.top; o.right = p.right; o.bottom = p.bottom; o.left = p.left; o.shadow = p.shadow
            return o
        }
        SheetPresenter.present(over: window) { dismiss in
            EffectSheet(title: String(localized: "Torn Edge"), base: model.baseImage, initial: TornParams(),
                        render: { image, p, f in
                            var rng = SeededGenerator(seed: p.seed)
                            return ImageOps.tornEdge(image, options: options(p, f), using: &rng)?.image
                        },
                        onApply: { p in
                            dismiss()
                            model.applyEffect(String(localized: "Torn Edge")) {
                                var rng = SeededGenerator(seed: p.seed)
                                return ImageOps.tornEdge($0, options: options(p, model.scale), using: &rng)
                            }
                        },
                        onCancel: dismiss) { $p in
                SliderRow(label: String(localized: "Tooth height"), value: $p.tooth, range: 2...30)
                SliderRow(label: String(localized: "Tooth width"), value: $p.range, range: 5...50)
                HStack {
                    Toggle("Top", isOn: $p.top); Toggle("Right", isOn: $p.right)
                    Toggle("Bottom", isOn: $p.bottom); Toggle("Left", isOn: $p.left)
                }
                .toggleStyle(.checkbox)
                Toggle("Shadow", isOn: $p.shadow)
                Button("New Random Edge") { p.seed = UInt64.random(in: 1...UInt64.max) }
            }
        }
    }

    struct ColorParams: Equatable {
        var brightness = 0.0, contrast = 1.0, gamma = 1.0
    }

    static func adjustColors(model: EditorModel, window: NSWindow) {
        SheetPresenter.present(over: window) { dismiss in
            EffectSheet(title: String(localized: "Adjust Colors"), base: model.baseImage, initial: ColorParams(),
                        render: { image, p, _ in ImageFilters.adjustColors(image, brightness: p.brightness, contrast: p.contrast, gamma: p.gamma) },
                        onApply: { p in
                            dismiss()
                            model.applyFilter(String(localized: "Adjust Colors")) {
                                ImageFilters.adjustColors($0, brightness: p.brightness, contrast: p.contrast, gamma: p.gamma)
                            }
                        },
                        onCancel: dismiss) { $p in
                SliderRow(label: String(localized: "Brightness"), value: $p.brightness, range: -0.5...0.5, format: "%.2f")
                SliderRow(label: String(localized: "Contrast"), value: $p.contrast, range: 0.5...2, format: "%.2f")
                SliderRow(label: String(localized: "Gamma"), value: $p.gamma, range: 0.4...2.5, format: "%.2f")
                Button("Reset") { p = ColorParams() }
            }
        }
    }

    // MARK: Resize and canvas size

    private struct ResizeView: View {
        let original: CGSize
        let onApply: (CGSize) -> Void
        let onCancel: () -> Void
        @State private var width: Int
        @State private var height: Int
        @State private var keepAspect = true

        init(original: CGSize, onApply: @escaping (CGSize) -> Void, onCancel: @escaping () -> Void) {
            self.original = original
            self.onApply = onApply
            self.onCancel = onCancel
            _width = State(initialValue: Int(original.width))
            _height = State(initialValue: Int(original.height))
        }

        var body: some View {
            SheetFrame(title: String(localized: "Resize Image"), applyTitle: String(localized: "Resize"),
                       canApply: width > 0 && height > 0 && width <= 20000 && height <= 20000,
                       onApply: { onApply(CGSize(width: width, height: height)) }, onCancel: onCancel) {
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                    GridRow {
                        Text("Width")
                        TextField("", value: $width, format: .number.grouping(.never)).frame(width: 80).multilineTextAlignment(.trailing)
                        Text("px")
                    }
                    GridRow {
                        Text("Height")
                        TextField("", value: $height, format: .number.grouping(.never)).frame(width: 80).multilineTextAlignment(.trailing)
                        Text("px")
                    }
                    GridRow {
                        Text("Scale")
                        Slider(value: Binding(get: { Double(width) / Double(original.width) * 100 },
                                              set: { setPercent($0) }), in: 10...400)
                        Text("\(Int((Double(width) / Double(original.width) * 100).rounded()))%").monospacedDigit()
                    }
                }
                Toggle("Keep proportions", isOn: $keepAspect)
            }
            .onChange(of: width) { old, new in
                guard keepAspect, old != new, new > 0 else { return }
                let h = Int((CGFloat(new) * original.height / original.width).rounded())
                if h != height { height = h }
            }
            .onChange(of: height) { old, new in
                guard keepAspect, old != new, new > 0 else { return }
                let w = Int((CGFloat(new) * original.width / original.height).rounded())
                if w != width { width = w }
            }
        }

        private func setPercent(_ percent: Double) {
            width = max(1, Int((Double(original.width) * percent / 100).rounded()))
            height = max(1, Int((Double(original.height) * percent / 100).rounded()))
        }
    }

    static func resize(model: EditorModel, window: NSWindow) {
        SheetPresenter.present(over: window) { dismiss in
            ResizeView(original: model.imageSize, onApply: { size in dismiss(); model.resize(to: size) }, onCancel: dismiss)
        }
    }

    private struct CanvasSizeView: View {
        let onApply: (Int, Int, Int, Int, RGBAColor) -> Void
        let onCancel: () -> Void
        @State private var top = 20
        @State private var left = 20
        @State private var bottom = 20
        @State private var right = 20
        @State private var color = RGBAColor.white

        var body: some View {
            SheetFrame(title: String(localized: "Canvas Size"), applyTitle: String(localized: "Apply"),
                       onApply: { onApply(top, left, bottom, right, color) }, onCancel: onCancel) {
                Text("Adds space around the image. Use negative values to cut edges away.").foregroundStyle(.secondary).font(.callout)
                    .fixedSize(horizontal: false, vertical: true).frame(width: 300, alignment: .leading)
                Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 8) {
                    GridRow { Text("Top"); field($top) }
                    GridRow { Text("Left"); field($left) }
                    GridRow { Text("Bottom"); field($bottom) }
                    GridRow { Text("Right"); field($right) }
                    GridRow { Text("Fill"); ColorField(label: String(localized: "Fill Color"), color: $color, allowsNone: true) }
                }
            }
        }

        private func field(_ value: Binding<Int>) -> some View {
            HStack {
                TextField("", value: value, format: .number.grouping(.never)).frame(width: 70).multilineTextAlignment(.trailing)
                Text("px")
            }
        }
    }

    static func canvasSize(model: EditorModel, window: NSWindow) {
        SheetPresenter.present(over: window) { dismiss in
            CanvasSizeView(onApply: { t, l, b, r, color in
                dismiss()
                // Negative margins crop; positive ones extend. Apply the cuts first, then the additions.
                let cutLeft = CGFloat(max(0, -l)), cutRight = CGFloat(max(0, -r))
                let cutTop = CGFloat(max(0, -t)), cutBottom = CGFloat(max(0, -b))
                let cut = CGRect(x: cutLeft, y: cutTop,
                                 width: model.imageSize.width - cutLeft - cutRight,
                                 height: model.imageSize.height - cutTop - cutBottom)
                if cut.width >= 1, cut.height >= 1, cut.size != model.imageSize { model.crop(to: cut) }
                if max(t, l, b, r) > 0 { model.extendCanvas(top: max(0, t), left: max(0, l), bottom: max(0, b), right: max(0, r), color: color) }
            }, onCancel: dismiss)
        }
    }
}
