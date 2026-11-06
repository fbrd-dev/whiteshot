import SwiftUI

/// Actions the SwiftUI chrome needs from the window controller.
@MainActor
protocol EditorCommands: AnyObject {
    func selectTool(_ tool: EditorTool)
    func applyCrop()
    func cancelCrop()
    func zoomIn()
    func zoomOut()
    func zoomToActualSize()
    func zoomToFit()
    func endTextRecognition()
    func copyAllRecognizedText()
    func copyRecognizedSelection()
    func openSelectedCode()
    func pinImage()
    /// Writes the picture as it looks now to a temporary file for dragging out of the window.
    func prepareDragFile() -> (url: URL, preview: NSImage)?
}

// MARK: - Look

/// Floating panel background: Liquid Glass on macOS 26, a material with a hairline on older systems.
struct FloatingBackground: ViewModifier {
    var cornerRadius: CGFloat = 14

    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
        } else {
            content
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous).strokeBorder(Color.primary.opacity(0.10)))
                .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
        }
    }
}

extension View {
    func floatingBackground(cornerRadius: CGFloat = 14) -> some View { modifier(FloatingBackground(cornerRadius: cornerRadius)) }
}

extension Color {
    init(_ c: RGBAColor) { self.init(.sRGB, red: c.r, green: c.g, blue: c.b, opacity: c.a) }
}

// MARK: - Tool palette

/// How much room the tool palette has: it shrinks its buttons, and as a last resort scrolls, instead of being cut off.
enum PaletteDensity {
    case regular, compact, scrolling
}

struct ToolPaletteView: View {
    let model: EditorModel
    unowned let commands: EditorCommands

    private static let groups: [[EditorTool]] = [
        [.select],
        [.rectangle, .ellipse, .line, .arrow, .freehand],
        [.text, .bubble, .step],
        [.obfuscate, .highlight],
        [.crop],
    ]

    /// Height of the palette pill itself for a density (not counting the space around it).
    static func contentHeight(for density: PaletteDensity) -> CGFloat {
        let compact = density != .regular
        let buttons = CGFloat(groups.flatMap { $0 }.count)
        let dividers = CGFloat(groups.count - 1)
        let spacing = compact ? 2.0 : 4.0
        let items = buttons + dividers
        let dividerHeight = compact ? 1.0 : 5.0           // the rule plus its own padding
        return buttons * (compact ? 24 : 30) + dividers * dividerHeight + (items - 1) * spacing + (compact ? 10 : 16)
    }

    var body: some View {
        let density = model.paletteDensity
        Group {
            if density == .scrolling {
                ScrollView(.vertical, showsIndicators: false) { pill(compact: true).padding(.vertical, 6) }
            } else {
                pill(compact: density == .compact)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private func pill(compact: Bool) -> some View {
        VStack(spacing: compact ? 2 : 4) {
            ForEach(Array(Self.groups.enumerated()), id: \.offset) { index, tools in
                if index > 0 { Divider().padding(.horizontal, 8).padding(.vertical, compact ? 0 : 2) }
                ForEach(tools) { tool in
                    ToolButton(tool: tool, isSelected: model.tool == tool, compact: compact, isEnabled: model.isToolEnabled(tool)) { commands.selectTool(tool) }
                }
            }
        }
        .padding(.vertical, compact ? 5 : 8)
        .padding(.horizontal, 6)
        .floatingBackground(cornerRadius: 16)
        .padding(.horizontal, 8)
        .fixedSize()
    }
}

private struct ToolButton: View {
    let tool: EditorTool
    let isSelected: Bool
    var compact = false
    /// Off while text recognition is on: only the Select tool can be used then.
    var isEnabled = true
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: tool.symbol)
                .font(.system(size: compact ? 14 : 15, weight: .regular))
                .frame(width: 32, height: compact ? 24 : 30)
                .foregroundStyle(isSelected ? Color.white : Color(nsColor: .labelColor))
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(isSelected ? Color.accentColor : (hovering ? Color.primary.opacity(0.08) : Color.clear))
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.3)
        .onHover { hovering = $0 && isEnabled }
        .help("\(tool.title) (\(tool.shortcut))")
        .accessibilityLabel(tool.title)
    }
}

// MARK: - Property bar

/// Height the property bar needs: taller while text recognition shows its second row.
func propertyBarHeight(for model: EditorModel) -> CGFloat {
    model.isTextMode && TextRecognitionBar.showsActions(model) ? 76 : 42
}

struct PropertyBarView: View {
    let model: EditorModel
    unowned let commands: EditorCommands

    var body: some View {
        HStack {
            Spacer(minLength: 0)
            content
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder private var content: some View {
        if model.isTextMode {
            TextRecognitionBar(model: model, commands: commands)
        } else if model.tool == .crop {
            CropBar(model: model, commands: commands)
        } else if let kind = model.activeKind {
            HStack(spacing: 12) {
                StyleControls(model: model, kind: kind)
                if !model.selection.isEmpty {
                    Divider().frame(height: 18)
                    Button { model.deleteSelection() } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .help(String(localized: "Delete"))
                }
            }
            .controlSize(.small)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .floatingBackground(cornerRadius: 14)
        }
    }
}

/// The bar above the picture while text recognition is on: what to do with the text and codes found.
private struct TextRecognitionBar: View {
    let model: EditorModel
    unowned let commands: EditorCommands

    /// The second row (copying, censoring, suggestions) only makes sense once there is text.
    static func showsActions(_ model: EditorModel) -> Bool {
        model.textMode == .active && !(model.recognizedText?.lines.isEmpty ?? true)
    }

    var body: some View {
        VStack(spacing: 7) {
            statusRow
            if Self.showsActions(model) {
                // Scrolls sideways in a narrow window instead of cutting the chips off.
                ViewThatFits(in: .horizontal) {
                    actionRow
                    ScrollView(.horizontal, showsIndicators: false) { actionRow }
                }
            }
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .floatingBackground(cornerRadius: 14)
    }

    private var statusRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "text.viewfinder").foregroundStyle(Color.accentColor)
            if model.textMode == .recognizing {
                ProgressView().controlSize(.small)
                Text("Recognizing text…").foregroundStyle(.secondary)
            } else if let error = model.recognitionError {
                Text("Text recognition failed: \(error)").foregroundStyle(.secondary).lineLimit(1)
            } else if let code = model.selectedCode {
                Image(systemName: code.isQR ? "qrcode" : "barcode").foregroundStyle(.secondary)
                Text(verbatim: "\(code.kindName): \(code.payload)").lineLimit(1).truncationMode(.middle).frame(maxWidth: 340, alignment: .leading)
                Button("Copy") { commands.copyRecognizedSelection() }
                if code.openableURL != nil { Button("Open") { commands.openSelectedCode() } }
            } else if !(model.recognizedText?.hasContent ?? false) {
                Text("No text found in this image.").foregroundStyle(.secondary)
            } else {
                let codes = model.recognizedText?.codes.count ?? 0
                if codes > 0 && (model.recognizedText?.lines.isEmpty ?? true) {
                    Text("Click a code to copy or open its contents.").foregroundStyle(.secondary).lineLimit(1)
                } else if codes > 0 {
                    Text("Select text to copy or censor it. Click a code for its contents.").foregroundStyle(.secondary).lineLimit(1)
                } else {
                    Text("Drag over the text to select it, then copy or censor it.").foregroundStyle(.secondary).lineLimit(1)
                }
                if !(model.recognizedText?.lines.isEmpty ?? true) { Button("Copy All") { commands.copyAllRecognizedText() } }
            }
            Button("Done") { commands.endTextRecognition() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
        }
    }

    private var actionRow: some View {
        HStack(spacing: 10) {
            Button("Copy") { commands.copyRecognizedSelection() }
                .disabled(model.selectedRecognizedText == nil)
            Menu {
                Button(model.occurrencesOfSelectedText > 1 ? String(localized: "Censor All \(model.occurrencesOfSelectedText) Occurrences") : String(localized: "Censor All Occurrences")) {
                    model.censorAllOccurrencesOfSelectedText()
                }
                .disabled(model.occurrencesOfSelectedText == 0)
            } label: {
                Label("Censor", systemImage: "eye.slash")
            } primaryAction: {
                model.censorSelectedText()
            }
            .menuStyle(.button)
            .fixedSize()
            .disabled(model.selectedRecognizedText == nil)
            .help(String(localized: "Cover the selected text with a censor box"))
            Picker("Style", selection: Binding(get: { model.censorMode }, set: { model.setCensorMode($0) })) {
                Text("Pixelate").tag(ObfuscateMode.pixelate)
                Text("Blur").tag(ObfuscateMode.blur)
                Text("Black Out").tag(ObfuscateMode.blackout)
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            .help(String(localized: "How censored text looks"))

            if !model.sensitiveMatches.isEmpty {
                Divider().frame(height: 16)
                Text("Suggested").foregroundStyle(.secondary)
                ForEach(SensitiveKind.allCases.filter { model.suggestionCount(for: $0) > 0 }) { kind in
                    Toggle(isOn: Binding(get: { model.suggestionKinds.contains(kind) }, set: { _ in model.toggleSuggestionKind(kind) })) {
                        Label("\(kind.shortTitle) \(model.suggestionCount(for: kind))", systemImage: kind.symbol)
                    }
                    .toggleStyle(.button)
                    .tint(.orange)
                    .help(kind.title)
                }
                Button("Censor \(model.activeSuggestions.count)") { model.censorSuggestions() }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                    .disabled(model.activeSuggestions.isEmpty)
                    .help(String(localized: "Cover everything that is marked in orange"))
            }
        }
    }
}

private struct CropBar: View {
    let model: EditorModel
    unowned let commands: EditorCommands

    var body: some View {
        HStack(spacing: 10) {
            if let r = model.cropRect, r.width >= 1 {
                Text(verbatim: "\(Int(r.width)) × \(Int(r.height)) px").monospacedDigit().foregroundStyle(.secondary)
            } else {
                Text("Drag on the image to choose the area to keep").foregroundStyle(.secondary)
            }
            Button("Cancel") { commands.cancelCrop() }
            Button("Crop") { commands.applyCrop() }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(model.cropRect.map { $0.width < 1 || $0.height < 1 } ?? true)
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .floatingBackground(cornerRadius: 14)
    }
}

private struct StyleControls: View {
    let model: EditorModel
    let kind: AnnotationKind

    private func binding<T>(_ keyPath: WritableKeyPath<Style, T>, key: String) -> Binding<T> {
        Binding(get: { model.activeStyle[keyPath: keyPath] },
                set: { value in model.updateStyle(coalesceKey: key) { $0[keyPath: keyPath] = value } })
    }

    var body: some View {
        switch kind {
        case .rectangle, .ellipse:
            ColorField(label: String(localized: "Line Color"), color: binding(\.strokeColor, key: "stroke"), systemImage: "pencil.line")
            ColorField(label: String(localized: "Fill Color"), color: binding(\.fillColor, key: "fill"), systemImage: "drop.fill")
            WidthField(value: binding(\.lineWidth, key: "width"), range: 0...60)
            ShadowToggle(isOn: binding(\.shadow, key: "shadow"))
        case .line, .freehand:
            ColorField(label: String(localized: "Line Color"), color: binding(\.strokeColor, key: "stroke"), systemImage: "pencil.line", allowsNone: false)
            WidthField(value: binding(\.lineWidth, key: "width"), range: 1...60)
            ShadowToggle(isOn: binding(\.shadow, key: "shadow"))
        case .arrow:
            ColorField(label: String(localized: "Line Color"), color: binding(\.strokeColor, key: "stroke"), systemImage: "pencil.line", allowsNone: false)
            WidthField(value: binding(\.lineWidth, key: "width"), range: 1...60)
            Picker(String(localized: "Arrowheads"), selection: binding(\.arrowHeads, key: "heads")) {
                Text("End →").tag(ArrowHeads.end)
                Text("Start ←").tag(ArrowHeads.start)
                Text("Both ↔").tag(ArrowHeads.both)
                Text("None —").tag(ArrowHeads.none)
            }
            .labelsHidden().pickerStyle(.menu).frame(width: 90)
            ShadowToggle(isOn: binding(\.shadow, key: "shadow"))
        case .text, .bubble:
            TextControls(model: model, kind: kind)
        case .step:
            ColorField(label: String(localized: "Circle Color"), color: binding(\.fillColor, key: "fill"), systemImage: "circle.fill", allowsNone: false)
            ColorField(label: String(localized: "Number Color"), color: binding(\.textColor, key: "text"), systemImage: "textformat.123", allowsNone: false)
            ColorField(label: String(localized: "Outline Color"), color: binding(\.strokeColor, key: "stroke"), systemImage: "circle")
            HStack(spacing: 4) {
                Text("Start at").foregroundStyle(.secondary)
                Stepper(value: Binding(get: { model.activeStyle.stepStart }, set: { model.setStepStart($0) }), in: 0...999) {
                    Text("\(model.activeStyle.stepStart)").monospacedDigit().frame(minWidth: 22, alignment: .trailing)
                }
            }
            ShadowToggle(isOn: binding(\.shadow, key: "shadow"))
        case .obfuscate:
            ObfuscateControls(model: model)
        case .highlight:
            HighlightControls(model: model)
        case .image:
            Text("Image").foregroundStyle(.secondary)
            ShadowToggle(isOn: binding(\.shadow, key: "shadow"))
        }
    }
}

private struct TextControls: View {
    let model: EditorModel
    let kind: AnnotationKind

    private func binding<T>(_ keyPath: WritableKeyPath<Style, T>, key: String) -> Binding<T> {
        Binding(get: { model.activeStyle[keyPath: keyPath] },
                set: { value in model.updateStyle(coalesceKey: key) { $0[keyPath: keyPath] = value } })
    }

    static let families: [String] = NSFontManager.shared.availableFontFamilies

    var body: some View {
        ColorField(label: String(localized: "Text Color"), color: binding(\.textColor, key: "text"), systemImage: "textformat", allowsNone: false)
        Picker(String(localized: "Font"), selection: binding(\.fontName, key: "font")) {
            Text("System").tag("")
            Divider()
            ForEach(Self.families, id: \.self) { Text($0).tag($0) }
        }
        .labelsHidden().pickerStyle(.menu).frame(width: 120)
        HStack(spacing: 2) {
            Stepper(value: binding(\.fontSize, key: "size"), in: 6...400, step: 1) {
                Text("\(Int(model.activeStyle.fontSize))").monospacedDigit().frame(minWidth: 26, alignment: .trailing)
            }
        }
        HStack(spacing: 2) {
            Toggle(isOn: binding(\.bold, key: "bold")) { Image(systemName: "bold") }.toggleStyle(.button).help(String(localized: "Bold"))
            Toggle(isOn: binding(\.italic, key: "italic")) { Image(systemName: "italic") }.toggleStyle(.button).help(String(localized: "Italic"))
            Toggle(isOn: binding(\.underline, key: "underline")) { Image(systemName: "underline") }.toggleStyle(.button).help(String(localized: "Underline"))
        }
        Picker(String(localized: "Alignment"), selection: binding(\.textAlign, key: "align")) {
            Image(systemName: "text.alignleft").tag(TextAlign.left)
            Image(systemName: "text.aligncenter").tag(TextAlign.center)
            Image(systemName: "text.alignright").tag(TextAlign.right)
        }
        .labelsHidden().pickerStyle(.segmented).frame(width: 90)
        Divider().frame(height: 18)
        ColorField(label: String(localized: "Fill Color"), color: binding(\.fillColor, key: "fill"), systemImage: "drop.fill")
        ColorField(label: String(localized: "Border Color"), color: binding(\.strokeColor, key: "stroke"), systemImage: "square.dashed")
        if model.activeStyle.strokeColor.isVisible {
            WidthField(value: binding(\.lineWidth, key: "width"), range: 0...30)
        }
        ShadowToggle(isOn: binding(\.shadow, key: "shadow"))
    }
}

private struct ObfuscateControls: View {
    let model: EditorModel

    private func binding<T>(_ keyPath: WritableKeyPath<Style, T>, key: String) -> Binding<T> {
        Binding(get: { model.activeStyle[keyPath: keyPath] },
                set: { value in model.updateStyle(coalesceKey: key) { $0[keyPath: keyPath] = value } })
    }

    var body: some View {
        Picker(String(localized: "Mode"), selection: binding(\.obfuscateMode, key: "mode")) {
            Text("Pixelate").tag(ObfuscateMode.pixelate)
            Text("Blur").tag(ObfuscateMode.blur)
            Text("Black Out").tag(ObfuscateMode.blackout)
        }
        .labelsHidden().pickerStyle(.segmented).frame(width: 210)

        switch model.activeStyle.obfuscateMode {
        case .pixelate:
            HStack(spacing: 6) {
                Text("Block size").foregroundStyle(.secondary)
                Slider(value: binding(\.pixelSize, key: "pixel"), in: 4...(48 * model.scale)).frame(width: 110)
            }
        case .blur:
            HStack(spacing: 6) {
                Text("Radius").foregroundStyle(.secondary)
                Slider(value: binding(\.blurRadius, key: "blur"), in: 2...(40 * model.scale)).frame(width: 110)
            }
        case .blackout:
            ColorField(label: String(localized: "Color"), color: binding(\.fillColor, key: "fill"), systemImage: "square.fill", allowsNone: false)
        }
    }
}

private struct HighlightControls: View {
    let model: EditorModel

    private func binding<T>(_ keyPath: WritableKeyPath<Style, T>, key: String) -> Binding<T> {
        Binding(get: { model.activeStyle[keyPath: keyPath] },
                set: { value in model.updateStyle(coalesceKey: key) { $0[keyPath: keyPath] = value } })
    }

    var body: some View {
        Picker(String(localized: "Mode"), selection: binding(\.highlightMode, key: "mode")) {
            Text("Marker").tag(HighlightMode.text)
            Text("Spotlight").tag(HighlightMode.area)
            Text("Grayscale").tag(HighlightMode.grayscale)
            Text("Magnify").tag(HighlightMode.magnify)
        }
        .labelsHidden().pickerStyle(.segmented).frame(width: 280)

        switch model.activeStyle.highlightMode {
        case .text:
            ColorField(label: String(localized: "Marker Color"), color: binding(\.highlightColor, key: "marker"), systemImage: "highlighter", allowsNone: false)
        case .area:
            HStack(spacing: 6) {
                Text("Dimming").foregroundStyle(.secondary)
                Slider(value: binding(\.dim, key: "dim"), in: 0.1...0.9).frame(width: 100)
            }
        case .grayscale:
            EmptyView()
        case .magnify:
            HStack(spacing: 6) {
                Text("Zoom").foregroundStyle(.secondary)
                Slider(value: binding(\.magnification, key: "zoom"), in: 1.5...6).frame(width: 90)
                Text(String(format: "%.1f×", model.activeStyle.magnification)).monospacedDigit().foregroundStyle(.secondary)
            }
            ColorField(label: String(localized: "Border Color"), color: binding(\.strokeColor, key: "stroke"), systemImage: "square.dashed")
        }
    }
}

// MARK: - Small controls

struct WidthField: View {
    @Binding var value: CGFloat
    let range: ClosedRange<CGFloat>

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: "lineweight").foregroundStyle(.secondary).help(String(localized: "Line Width"))
            Stepper(value: $value, in: range, step: 1) {
                Text("\(Int(value))").monospacedDigit().frame(minWidth: 22, alignment: .trailing)
            }
        }
    }
}

struct ShadowToggle: View {
    @Binding var isOn: Bool

    var body: some View {
        Toggle("Shadow", isOn: $isOn)
            .toggleStyle(.button)
            .help(String(localized: "Shadow"))
    }
}

struct Swatch: View {
    let color: RGBAColor
    var selected = false

    var body: some View {
        ZStack {
            if !color.isVisible {
                RoundedRectangle(cornerRadius: 4).fill(Color.white)
                GeometryReader { proxy in
                    Path { p in
                        p.move(to: CGPoint(x: proxy.size.width * 0.12, y: proxy.size.height * 0.88))
                        p.addLine(to: CGPoint(x: proxy.size.width * 0.88, y: proxy.size.height * 0.12))
                    }
                    .stroke(Color(nsColor: .systemRed), lineWidth: 1.5)
                }
            } else {
                if color.a < 0.99 { RoundedRectangle(cornerRadius: 4).fill(Color.white) }
                RoundedRectangle(cornerRadius: 4).fill(Color(color))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color(nsColor: .labelColor).opacity(0.35), lineWidth: 0.5))
        .overlay {
            if selected {
                RoundedRectangle(cornerRadius: 5).strokeBorder(Color.accentColor, lineWidth: 2).padding(-2)
            }
        }
    }
}

// MARK: - Status bar

struct StatusBarView: View {
    let model: EditorModel
    unowned let commands: EditorCommands

    var body: some View {
        HStack(spacing: 14) {
            Text(verbatim: "\(Int(model.imageSize.width)) × \(Int(model.imageSize.height)) px").monospacedDigit()
            if let p = model.pointerLocation {
                Text(verbatim: "x \(Int(p.x))  y \(Int(p.y))").monospacedDigit().foregroundStyle(.secondary)
            }
            Spacer()
            Button { commands.pinImage() } label: { Label("Pin", systemImage: "pin").labelStyle(.titleAndIcon) }
                .help(String(localized: "Pin the picture on top of other windows (⇧⌘P)"))
            ImageDragHandle(commands: commands)
            Divider().frame(height: 12)
            Button { commands.zoomOut() } label: { Image(systemName: "minus") }.help(String(localized: "Zoom Out"))
            Button { commands.zoomToActualSize() } label: {
                Text("\(Int((model.zoom * 100).rounded()))%").monospacedDigit().frame(minWidth: 40)
            }
            .help(String(localized: "Actual Size"))
            Button { commands.zoomIn() } label: { Image(systemName: "plus") }.help(String(localized: "Zoom In"))
            Button { commands.zoomToFit() } label: { Image(systemName: "arrow.up.left.and.arrow.down.right") }.help(String(localized: "Fit to Window"))
        }
        .buttonStyle(.borderless)
        .font(.system(size: 11))
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity)
    }
}
