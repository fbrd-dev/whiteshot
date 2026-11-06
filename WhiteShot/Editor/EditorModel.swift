import AppKit
import Observation

enum EditorTool: String, CaseIterable, Identifiable, Codable {
    case select, rectangle, ellipse, line, arrow, freehand, text, bubble, step, obfuscate, highlight, crop

    var id: String { rawValue }

    /// The kind of annotation this tool draws, if it draws one.
    var kind: AnnotationKind? {
        switch self {
        case .select, .crop: return nil
        case .rectangle: return .rectangle
        case .ellipse: return .ellipse
        case .line: return .line
        case .arrow: return .arrow
        case .freehand: return .freehand
        case .text: return .text
        case .bubble: return .bubble
        case .step: return .step
        case .obfuscate: return .obfuscate
        case .highlight: return .highlight
        }
    }

    init?(kind: AnnotationKind) {
        guard let tool = EditorTool.allCases.first(where: { $0.kind == kind }) else { return nil }
        self = tool
    }

    var title: String {
        switch self {
        case .select: return String(localized: "Select")
        case .rectangle: return String(localized: "Rectangle")
        case .ellipse: return String(localized: "Ellipse")
        case .line: return String(localized: "Line")
        case .arrow: return String(localized: "Arrow")
        case .freehand: return String(localized: "Freehand")
        case .text: return String(localized: "Text")
        case .bubble: return String(localized: "Speech Bubble")
        case .step: return String(localized: "Step Number")
        case .obfuscate: return String(localized: "Censor")
        case .highlight: return String(localized: "Highlight")
        case .crop: return String(localized: "Crop")
        }
    }

    var symbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .line: return "line.diagonal"
        case .arrow: return "arrow.up.right"
        case .freehand: return "scribble.variable"
        case .text: return "textformat"
        case .bubble: return "bubble.left"
        case .step: return "1.circle"
        case .obfuscate: return "eye.slash"
        case .highlight: return "highlighter"
        case .crop: return "crop"
        }
    }

    /// Single-key shortcut shown in tooltips and handled by the canvas.
    var shortcut: String {
        switch self {
        case .select: return "V"
        case .rectangle: return "R"
        case .ellipse: return "E"
        case .line: return "L"
        case .arrow: return "A"
        case .freehand: return "F"
        case .text: return "T"
        case .bubble: return "B"
        case .step: return "N"
        case .obfuscate: return "O"
        case .highlight: return "H"
        case .crop: return "C"
        }
    }

    /// Tool defaults at 1x; scaled by the capture's scale when an editor opens.
    var defaultStyle: Style {
        var s = Style()
        switch self {
        case .rectangle, .ellipse:
            s.lineWidth = 2
        case .line, .freehand:
            s.lineWidth = 3
        case .arrow:
            s.lineWidth = 3
            s.arrowHeads = .end
        case .text:
            s.strokeColor = .clear
            s.lineWidth = 1
            s.fontSize = 18
        case .bubble:
            s.fillColor = .white
            s.textColor = .black
            s.lineWidth = 2
            s.fontSize = 16
            s.textAlign = .center
            s.verticalAlign = .middle
        case .step:
            s.fillColor = .red
            s.strokeColor = .white
            s.textColor = .white
            s.lineWidth = 2
            s.fontSize = 14
        case .obfuscate:
            s.pixelSize = 8
            s.blurRadius = 6
            s.fillColor = .black
            s.lineWidth = 0
        case .highlight:
            s.strokeColor = .red
            s.lineWidth = 2
        case .select, .crop:
            break
        }
        return s
    }
}

/// The document being edited: base image, annotations, undo history, and the tool state around
/// them. The canvas reads from it and calls back into it for every change, so there is exactly one
/// place where "something changed" is decided.
@Observable
final class EditorModel {
    struct Snapshot {
        var base: CGImage
        var annotations: [Annotation]
        var selection: Set<UUID>
    }

    // Document
    private(set) var baseImage: CGImage
    private(set) var annotations: [Annotation] = []
    /// Backing scale of the capture (2 for Retina), used for DPI metadata and sensible default sizes.
    let scale: CGFloat
    var fileURL: URL?
    var isDirty = false
    /// Name shown in the window title before the image has a file.
    var displayName: String
    var captureDate = Date()

    // Tool state
    var tool: EditorTool = .select
    var selection: Set<UUID> = []
    var toolStyles: [EditorTool: Style] = [:]
    var cropRect: CGRect?
    var editingTextID: UUID?
    var zoom: CGFloat = 1
    var pointerLocation: CGPoint?
    /// Set by the editor window from the room it has: see `PaletteDensity`.
    var paletteDensity: PaletteDensity = .regular

    // Text recognition (OCR). While it is on, the picture is read-only and the text on it can be selected.
    enum TextMode: Equatable { case off, recognizing, active }
    private(set) var textMode: TextMode = .off
    /// What Vision found, for the picture exactly as it is now. Dropped as soon as the picture changes.
    private(set) var recognizedText: RecognizedText?
    var textSelection: TextSelection?
    private(set) var recognitionError: String?
    @ObservationIgnored private var recognitionGeneration = 0
    @ObservationIgnored private var preservingRecognition = false
    /// The QR code or barcode picked on the canvas, as an index into `recognizedText.codes`.
    var selectedCodeIndex: Int?
    /// Everything that looks like sensitive text, of every kind; `suggestionKinds` says which kinds are in play.
    private(set) var sensitiveMatches: [SensitiveMatch] = []
    var suggestionKinds: Set<SensitiveKind> = []
    /// Which kinds start out switched on for each recognition: the user's settings (tests replace this).
    @ObservationIgnored var suggestionKindsProvider: () -> Set<SensitiveKind> = { Preferences.sensitiveKinds() }

    @ObservationIgnored let undoManager = UndoManager()
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private var cachedComposite: CGImage?
    @ObservationIgnored private var compositeDirty = true
    @ObservationIgnored private var nextSerial = 1
    @ObservationIgnored private var lastCoalesceKey: String?
    @ObservationIgnored private var lastCoalesceDate = Date.distantPast
    @ObservationIgnored private var cachedHiddenText: UUID?

    // Revision counters let SwiftUI react without observing the heavy arrays directly.
    private(set) var revision = 0
    var canUndo: Bool { undoManager.canUndo }
    var canRedo: Bool { undoManager.canRedo }

    init(image: CGImage, scale: CGFloat = 1, displayName: String = String(localized: "Screenshot")) {
        self.baseImage = image
        self.scale = max(1, scale)
        self.displayName = displayName
        undoManager.groupsByEvent = false
        undoManager.levelsOfUndo = 200
        for tool in EditorTool.allCases where tool.kind != nil {
            toolStyles[tool] = Self.loadDefaultStyle(for: tool).scaled(by: self.scale)
        }
    }

    var imageSize: CGSize { CGSize(width: baseImage.width, height: baseImage.height) }
    var imageBounds: CGRect { CGRect(origin: .zero, size: imageSize) }

    // MARK: - Rendering

    /// The flattened picture. Re-rendered lazily, once per burst of changes. With nothing drawn on it, the
    /// picture *is* the base image: no second full-size bitmap is made (about 16 MB for a 2560x1600 capture).
    func composite() -> CGImage {
        if annotations.isEmpty {
            // Let go of a cached render left over from annotations that have since been removed.
            cachedComposite = nil
            compositeDirty = true
            return baseImage
        }
        if compositeDirty || cachedHiddenText != editingTextID || cachedComposite == nil {
            var options = Renderer.Options()
            options.scale = scale
            options.hiddenTextID = editingTextID
            cachedComposite = Renderer.render(base: baseImage, annotations: annotations, options: options) ?? baseImage
            cachedHiddenText = editingTextID
            compositeDirty = false
        }
        return cachedComposite ?? baseImage
    }

    /// Final output, with nothing hidden: what gets saved, copied and printed.
    func flattenedImage() -> CGImage {
        guard !annotations.isEmpty else { return baseImage }
        var options = Renderer.Options()
        options.scale = scale
        return Renderer.render(base: baseImage, annotations: annotations, options: options) ?? baseImage
    }

    private func changed(dirty: Bool = true) {
        compositeDirty = true
        revision += 1
        if dirty { isDirty = true }
        if !preservingRecognition { discardRecognizedText() }
        onChange?()
    }

    /// Redraw request that does not touch the document (selection handles, crop overlay).
    func refresh() {
        revision += 1
        onChange?()
    }

    // MARK: - Snapshots and undo

    func snapshot() -> Snapshot { Snapshot(base: baseImage, annotations: annotations, selection: selection) }

    private func restore(_ s: Snapshot) {
        baseImage = s.base
        annotations = s.annotations
        let ids = Set(annotations.map(\.id))
        selection = s.selection.intersection(ids)
        if let editing = editingTextID, !ids.contains(editing) { editingTextID = nil }
        changed()
    }

    private func swapState(to target: Snapshot, name: String) {
        let current = snapshot()
        undoManager.registerUndo(withTarget: self) { $0.swapState(to: current, name: name) }
        undoManager.setActionName(name)
        restore(target)
    }

    /// Registers an undo step for a change that has already been applied. `coalesceKey` merges
    /// bursts of the same kind of change (a slider drag) into one step.
    func registerUndo(from before: Snapshot, name: String, coalesceKey: String? = nil) {
        let now = Date()
        if let key = coalesceKey, key == lastCoalesceKey, now.timeIntervalSince(lastCoalesceDate) < 1.2,
           undoManager.canUndo, !undoManager.isUndoing, !undoManager.isRedoing {
            lastCoalesceDate = now
            return
        }
        lastCoalesceKey = coalesceKey
        lastCoalesceDate = now
        undoManager.beginUndoGrouping()
        undoManager.registerUndo(withTarget: self) { $0.swapState(to: before, name: name) }
        undoManager.setActionName(name)
        undoManager.endUndoGrouping()
    }

    func undo() {
        guard undoManager.canUndo else { return }
        lastCoalesceKey = nil
        undoManager.undo()
    }

    func redo() {
        guard undoManager.canRedo else { return }
        lastCoalesceKey = nil
        undoManager.redo()
    }

    /// Applies a change to the annotation list and records it for undo.
    func edit(_ name: String, coalesceKey: String? = nil, _ body: (inout [Annotation]) -> Void) {
        let before = snapshot()
        body(&annotations)
        guard annotations != before.annotations else { return }
        registerUndo(from: before, name: name, coalesceKey: coalesceKey)
        changed()
    }

    // MARK: - Interaction support (drags)

    /// Applies a change without recording undo; the caller commits it with `commit(from:name:)` when the drag ends.
    func mutateLive(_ body: (inout [Annotation]) -> Void) {
        body(&annotations)
        changed()
    }

    func commit(from before: Snapshot, name: String) {
        guard annotations != before.annotations || baseImage !== before.base else { return }
        registerUndo(from: before, name: name)
    }

    func nextAnnotationSerial() -> Int {
        defer { nextSerial += 1 }
        return nextSerial
    }

    // MARK: - Annotation editing

    func annotation(withID id: UUID) -> Annotation? { annotations.first { $0.id == id } }
    var selectedAnnotations: [Annotation] { annotations.filter { selection.contains($0.id) } }

    func style(for tool: EditorTool) -> Style { toolStyles[tool] ?? tool.defaultStyle.scaled(by: scale) }

    func makeAnnotation(_ kind: AnnotationKind) -> Annotation {
        let tool = EditorTool(kind: kind) ?? .rectangle
        return Annotation(kind: kind, serial: nextAnnotationSerial(), style: style(for: tool))
    }

    func add(_ annotation: Annotation, select: Bool = true) {
        edit(String(localized: "Add")) { $0.append(annotation) }
        if select { self.selection = [annotation.id] }
        refresh()
    }

    /// The kind whose properties the property bar should show.
    var activeKind: AnnotationKind? {
        if selection.count == 1, let a = annotation(withID: selection.first!) { return a.kind }
        if !selection.isEmpty, let first = selectedAnnotations.first { return first.kind }
        return tool.kind
    }

    /// Style the property bar displays: that of the selection, or the current tool's default.
    var activeStyle: Style {
        if let first = selectedAnnotations.first { return first.style }
        return style(for: tool)
    }

    /// Changes one style property on the selection and remembers it as the default for new shapes.
    func updateStyle(coalesceKey: String? = nil, _ change: (inout Style) -> Void) {
        let affected = selectedAnnotations
        if affected.isEmpty {
            guard tool.kind != nil else { return }
            var s = style(for: tool)
            change(&s)
            toolStyles[tool] = s
            Self.saveDefaultStyle(s.normalised(by: scale), for: tool)
            refresh()
            return
        }
        let ids = Set(affected.map(\.id))
        edit(String(localized: "Change Style"), coalesceKey: coalesceKey ?? "style") { list in
            for i in list.indices where ids.contains(list[i].id) {
                change(&list[i].style)
                // Text boxes grow to fit their content when the font changes.
                if list[i].hasText { Self.fitTextHeight(&list[i]) }
            }
        }
        for a in affected {
            if let tool = EditorTool(kind: a.kind), var s = annotation(withID: a.id)?.style {
                // Per-annotation properties (geometry-bound) never leak into defaults.
                s.stepStart = style(for: tool).stepStart
                toolStyles[tool] = s
                Self.saveDefaultStyle(s.normalised(by: scale), for: tool)
            }
        }
        refresh()
    }

    func setStepStart(_ value: Int) {
        let start = max(0, value)
        var s = style(for: .step)
        s.stepStart = start
        toolStyles[.step] = s
        edit(String(localized: "Change Style"), coalesceKey: "stepStart") { list in
            for i in list.indices where list[i].kind == .step { list[i].style.stepStart = start }
        }
        refresh()
    }

    /// Makes a text box at least tall enough for its content. It never shrinks a box the user made taller.
    static func fitTextHeight(_ a: inout Annotation) {
        guard a.kind == .text else { return }
        let needed = TextLayout.requiredHeight(for: a.text, style: a.style, width: a.rect.width)
        if a.rect.height < needed { a.rect.size.height = needed }
    }

    func setText(_ text: String, for id: UUID) {
        guard let index = annotations.firstIndex(where: { $0.id == id }) else { return }
        annotations[index].text = text
        Self.fitTextHeight(&annotations[index])
        changed()
    }

    func deleteSelection() {
        guard !selection.isEmpty else { return }
        let ids = selection
        edit(String(localized: "Delete")) { $0.removeAll { ids.contains($0.id) } }
        selection = []
        refresh()
    }

    func selectAll() {
        selection = Set(annotations.map(\.id))
        refresh()
    }

    func nudgeSelection(dx: CGFloat, dy: CGFloat) {
        let ids = selection
        guard !ids.isEmpty else { return }
        edit(String(localized: "Move"), coalesceKey: "nudge") { list in
            for i in list.indices where ids.contains(list[i].id) { list[i].move(by: CGPoint(x: dx, y: dy)) }
        }
    }

    func duplicateSelection() {
        let originals = selectedAnnotations
        guard !originals.isEmpty else { return }
        let offset = CGPoint(x: 12 * scale, y: 12 * scale)
        var copies: [Annotation] = []
        for original in originals {
            var copy = original.offset(by: offset)
            copy.id = UUID()
            copy.serial = nextAnnotationSerial()
            copies.append(copy)
        }
        edit(String(localized: "Duplicate")) { $0.append(contentsOf: copies) }
        selection = Set(copies.map(\.id))
        refresh()
    }

    enum Arrange { case forward, backward, front, back }

    func arrangeSelection(_ how: Arrange) {
        let ids = selection
        guard !ids.isEmpty else { return }
        edit(String(localized: "Arrange")) { list in
            switch how {
            case .front:
                let picked = list.filter { ids.contains($0.id) }
                list.removeAll { ids.contains($0.id) }
                list.append(contentsOf: picked)
            case .back:
                let picked = list.filter { ids.contains($0.id) }
                list.removeAll { ids.contains($0.id) }
                list.insert(contentsOf: picked, at: 0)
            case .forward:
                var i = list.count - 2
                while i >= 0 {
                    if ids.contains(list[i].id), !ids.contains(list[i + 1].id) { list.swapAt(i, i + 1) }
                    i -= 1
                }
            case .backward:
                var i = 1
                while i < list.count {
                    if ids.contains(list[i].id), !ids.contains(list[i - 1].id) { list.swapAt(i, i - 1) }
                    i += 1
                }
            }
        }
    }

    // MARK: - Image-level operations

    /// Replaces the base image and remaps annotations alongside it, as one undoable step.
    private func transformBase(_ name: String, image: CGImage, map: (CGPoint) -> CGPoint, sizeFactor: CGFloat? = nil) {
        let before = snapshot()
        baseImage = image
        for i in annotations.indices {
            annotations[i].mapGeometry(map)
            if let k = sizeFactor { annotations[i].style = annotations[i].style.scaled(by: k) }
        }
        registerUndo(from: before, name: name)
        cropRect = nil
        changed()
    }

    func crop(to rect: CGRect) {
        guard let cropped = ImageOps.crop(baseImage, to: rect) else { return }
        let origin = rect.integral.intersection(imageBounds).origin
        transformBase(String(localized: "Crop"), image: cropped) { CGPoint(x: $0.x - origin.x, y: $0.y - origin.y) }
    }

    func autoCrop() {
        guard let rect = ImageOps.autoCropRect(baseImage), rect.size != imageSize else { return }
        crop(to: rect)
    }

    func rotate(clockwise: Bool) {
        guard let rotated = ImageOps.rotate(baseImage, clockwise: clockwise) else { return }
        let w = CGFloat(baseImage.width), h = CGFloat(baseImage.height)
        transformBase(String(localized: "Rotate"), image: rotated) { p in
            clockwise ? CGPoint(x: h - p.y, y: p.x) : CGPoint(x: p.y, y: w - p.x)
        }
    }

    func flip(horizontal: Bool) {
        guard let flipped = ImageOps.flip(baseImage, horizontal: horizontal) else { return }
        let w = CGFloat(baseImage.width), h = CGFloat(baseImage.height)
        transformBase(String(localized: "Flip"), image: flipped) { p in
            horizontal ? CGPoint(x: w - p.x, y: p.y) : CGPoint(x: p.x, y: h - p.y)
        }
    }

    func resize(to size: CGSize) {
        guard size.width >= 1, size.height >= 1, let resized = ImageOps.resize(baseImage, to: size) else { return }
        let fx = CGFloat(resized.width) / CGFloat(baseImage.width), fy = CGFloat(resized.height) / CGFloat(baseImage.height)
        transformBase(String(localized: "Resize"), image: resized, map: { CGPoint(x: $0.x * fx, y: $0.y * fy) }, sizeFactor: (fx + fy) / 2)
    }

    func extendCanvas(top: Int, left: Int, bottom: Int, right: Int, color: RGBAColor) {
        guard let extended = ImageOps.extendCanvas(baseImage, top: top, left: left, bottom: bottom, right: right, color: color) else { return }
        transformBase(String(localized: "Canvas Size"), image: extended) { CGPoint(x: $0.x + CGFloat(left), y: $0.y + CGFloat(top)) }
    }

    func applyEffect(_ name: String, _ effect: (CGImage) -> ImageOps.EffectResult?) {
        guard let result = effect(baseImage) else { return }
        transformBase(name, image: result.image) { CGPoint(x: $0.x + result.shift.x, y: $0.y + result.shift.y) }
    }

    func applyFilter(_ name: String, _ filter: (CGImage) -> CGImage?) {
        guard let image = filter(baseImage) else { return }
        transformBase(name, image: image) { $0 }
    }

    /// Flattens everything into the base image, e.g. after loading an image as a starting point.
    func replaceBaseImage(_ image: CGImage, name: String) {
        transformBase(name, image: image) { $0 }
    }

    // MARK: - Text recognition

    var isTextMode: Bool { textMode != .off }

    /// While text recognition is on, only the Select tool is available.
    func isToolEnabled(_ tool: EditorTool) -> Bool { !isTextMode || tool == .select }

    /// The selected text, if any.
    var selectedRecognizedText: String? {
        guard let text = recognizedText, let selection = textSelection, !selection.isEmpty else { return nil }
        let string = text.text(in: selection)
        return string.isEmpty ? nil : string
    }

    /// All recognised text, for storing in a saved file. Nil if recognition has not been run on the current picture.
    var recognizedTextForExport: String? {
        guard let text = recognizedText, !text.isEmpty else { return nil }
        return text.fullText
    }

    /// Switches text recognition on. Returns the number to hand back to `finishTextRecognition` when Vision has to
    /// run, or nil if the text for this picture is already known (the overlay then appears at once).
    func beginTextRecognition() -> Int? {
        tool = .select
        cropRect = nil
        selection = []
        textSelection = nil
        selectedCodeIndex = nil
        recognitionError = nil
        recognitionGeneration += 1
        if recognizedText != nil {
            textMode = .active
            refresh()
            return nil
        }
        textMode = .recognizing
        refresh()
        return recognitionGeneration
    }

    /// Takes the result of a recognition started by `beginTextRecognition`; ignored if the user has moved on since.
    func finishTextRecognition(_ result: Result<RecognizedText, Error>, generation: Int) {
        guard textMode == .recognizing, generation == recognitionGeneration else { return }
        switch result {
        case .success(let text):
            let censored = annotations.filter { $0.kind == .obfuscate }.map(\.bounds)
            recognizedText = text.removingLines(intersecting: censored)
            suggestionKinds = suggestionKindsProvider()
            refreshSensitiveMatches()
        case .failure(let error):
            recognizedText = RecognizedText(lines: [])
            recognitionError = error.localizedDescription
        }
        textMode = .active
        refresh()
    }

    /// Leaves text recognition. The text found stays available (to save with the image) until the picture changes.
    func endTextRecognition() {
        guard textMode != .off else { return }
        recognitionGeneration += 1
        if textMode == .recognizing { recognizedText = nil }
        textMode = .off
        textSelection = nil
        refresh()
    }

    private func discardRecognizedText() {
        recognitionGeneration += 1
        recognizedText = nil
        sensitiveMatches = []
        selectedCodeIndex = nil
        recognitionError = nil
        textSelection = nil
        textMode = .off
    }

    // MARK: Codes

    var selectedCode: RecognizedCode? {
        guard let codes = recognizedText?.codes, let index = selectedCodeIndex, codes.indices.contains(index) else { return nil }
        return codes[index]
    }

    // MARK: Suggestions

    /// The matches of the kinds currently switched on.
    var activeSuggestions: [SensitiveMatch] { sensitiveMatches.filter { suggestionKinds.contains($0.kind) } }

    func suggestionCount(for kind: SensitiveKind) -> Int { sensitiveMatches.filter { $0.kind == kind }.count }

    func toggleSuggestionKind(_ kind: SensitiveKind) {
        if suggestionKinds.contains(kind) { suggestionKinds.remove(kind) } else { suggestionKinds.insert(kind) }
        refresh()
    }

    private func refreshSensitiveMatches() {
        sensitiveMatches = recognizedText.map(SensitiveDetector.matches(in:)) ?? []
    }

    // MARK: Censoring recognised text

    /// How the next censoring of recognised text looks: the Censor tool's current mode.
    var censorMode: ObfuscateMode { style(for: .obfuscate).obfuscateMode }

    func setCensorMode(_ mode: ObfuscateMode) {
        var s = style(for: .obfuscate)
        s.obfuscateMode = mode
        toolStyles[.obfuscate] = s
        Self.saveDefaultStyle(s.normalised(by: scale), for: .obfuscate)
        refresh()
    }

    /// Number of other places where the selected text appears (including the selection itself); 0 if nothing usable is selected.
    var occurrencesOfSelectedText: Int {
        guard let text = selectedRecognizedText, let recognized = recognizedText else { return 0 }
        return recognized.occurrences(of: text).count
    }

    /// Covers the selected text with Censor boxes.
    @discardableResult
    func censorSelectedText() -> Int {
        guard let recognized = recognizedText, let selection = textSelection, !selection.isEmpty else { return 0 }
        return censor(recognized.rects(for: selection))
    }

    /// Covers every place the selected text appears, anywhere in the picture.
    @discardableResult
    func censorAllOccurrencesOfSelectedText() -> Int {
        guard let recognized = recognizedText, let text = selectedRecognizedText else { return 0 }
        let rects = recognized.occurrences(of: text).flatMap { recognized.rects(for: $0) }
        return censor(rects)
    }

    /// Covers everything the switched-on suggestion kinds found.
    @discardableResult
    func censorSuggestions() -> Int {
        guard let recognized = recognizedText else { return 0 }
        return censor(activeSuggestions.map { SensitiveDetector.rect(of: $0, in: recognized) })
    }

    /// Places one Censor box over each rectangle, as a single undo step, and keeps text recognition running on what is left:
    /// the text under the new boxes is gone from the recognised text, the rest stays selectable.
    private func censor(_ rects: [CGRect]) -> Int {
        guard textMode == .active, let recognized = recognizedText else { return 0 }
        let boxes = rects.map { rect -> CGRect in
            let pad = max(2 * scale, rect.height * 0.12)
            return rect.insetBy(dx: -pad, dy: -pad).intersection(imageBounds)
        }.filter { !$0.isNull && $0.width >= 2 && $0.height >= 2 }
        guard !boxes.isEmpty else { return 0 }
        let added = boxes.map { box -> Annotation in
            var a = makeAnnotation(.obfuscate)
            a.rect = box
            return a
        }
        preservingRecognition = true
        edit(String(localized: "Censor Text")) { $0.append(contentsOf: added) }
        preservingRecognition = false
        selection = []
        recognizedText = recognized.removingCharacters(coveredBy: boxes)
        textSelection = nil
        selectedCodeIndex = nil
        refreshSensitiveMatches()
        refresh()
        return added.count
    }

    // MARK: - Loading a saved project

    func loadAnnotations(_ list: [Annotation]) {
        annotations = list
        nextSerial = (list.map(\.serial).max() ?? 0) + 1
        selection = []
        undoManager.removeAllActions()
        changed(dirty: false)
    }

    func markClean() {
        isDirty = false
        revision += 1
        onChange?()
    }

    // MARK: - Remembered tool defaults

    private static func defaultsKey(_ tool: EditorTool) -> String { "toolStyle.\(tool.rawValue)" }

    private static func loadDefaultStyle(for tool: EditorTool) -> Style {
        if let data = UserDefaults.standard.data(forKey: defaultsKey(tool)),
           let style = try? JSONDecoder().decode(Style.self, from: data) {
            return style
        }
        return tool.defaultStyle
    }

    private static func saveDefaultStyle(_ style: Style, for tool: EditorTool) {
        if let data = try? JSONEncoder().encode(style) {
            UserDefaults.standard.set(data, forKey: defaultsKey(tool))
        }
    }
}
