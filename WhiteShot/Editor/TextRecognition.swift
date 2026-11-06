import AppKit
@preconcurrency import Vision

/// One line of recognised text and where it sits in the image. Coordinates are image pixels with the
/// origin at the top-left, like everything else in the model.
struct RecognizedLine: Equatable {
    var text: String
    var rect: CGRect
    /// x position of the gap before each character and after the last one, ascending: `text.count + 1` values.
    var edges: [CGFloat]

    var characters: [Character] { Array(text) }
}

/// A QR code or barcode Vision found.
struct RecognizedCode: Equatable {
    var payload: String
    /// Image pixels, origin top-left.
    var rect: CGRect
    var isQR: Bool

    /// The address to open, but only for web and mail links: a code must not be able to launch other apps or open files.
    var openableURL: URL? {
        guard let url = URL(string: payload.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(), ["http", "https", "mailto"].contains(scheme) else { return nil }
        return url
    }

    var kindName: String { isQR ? String(localized: "QR code") : String(localized: "Barcode") }
}

/// A caret position in the recognised text: a character gap inside a line.
struct TextPosition: Comparable, Equatable {
    var line: Int
    var offset: Int

    static func < (a: TextPosition, b: TextPosition) -> Bool {
        a.line != b.line ? a.line < b.line : a.offset < b.offset
    }
}

/// What the user has selected: from where the drag began to where it is now (either may come first).
struct TextSelection: Equatable {
    var anchor: TextPosition
    var head: TextPosition

    var start: TextPosition { min(anchor, head) }
    var end: TextPosition { max(anchor, head) }
    var isEmpty: Bool { anchor == head }
}

/// The text Vision found in an image, with enough geometry to select it and to draw the selection on the picture.
struct RecognizedText: Equatable {
    var lines: [RecognizedLine]
    var codes: [RecognizedCode] = []

    var isEmpty: Bool { lines.isEmpty }
    /// Text or codes: whether there is anything to show for the picture.
    var hasContent: Bool { !lines.isEmpty || !codes.isEmpty }
    var fullText: String { lines.map(\.text).joined(separator: "\n") }

    var fullRange: TextSelection? {
        guard let last = lines.indices.last else { return nil }
        return TextSelection(anchor: TextPosition(line: 0, offset: 0), head: TextPosition(line: last, offset: lines[last].text.count))
    }

    // MARK: Finding text under a point

    /// The caret position under `point`, or nil if the point is not on or right beside a line of text.
    func position(at point: CGPoint) -> TextPosition? {
        var best: (index: Int, distance: CGFloat)?
        for (index, line) in lines.enumerated() {
            let pad = line.rect.height * 0.3
            guard line.rect.insetBy(dx: -pad, dy: -pad).contains(point) else { continue }
            let distance = abs(point.y - line.rect.midY)
            if best == nil || distance < best!.distance { best = (index, distance) }
        }
        return best.map { TextPosition(line: $0.index, offset: Self.offset(in: lines[$0.index], at: point.x)) }
    }

    /// The caret position closest to `point`, wherever it is. Used while dragging, when the pointer may leave the text.
    func nearestPosition(to point: CGPoint) -> TextPosition? {
        guard !lines.isEmpty else { return nil }
        var best = 0
        var bestDistance = CGFloat.greatestFiniteMagnitude
        for (index, line) in lines.enumerated() {
            let dx = max(line.rect.minX - point.x, 0, point.x - line.rect.maxX)
            let dy = max(line.rect.minY - point.y, 0, point.y - line.rect.maxY)
            // Vertical distance counts double: a pointer between two lines belongs to the line it is closer to,
            // however far along the other one it is horizontally.
            let distance = dx + dy * 2
            if distance < bestDistance { best = index; bestDistance = distance }
        }
        let line = lines[best]
        if best == 0, point.y < line.rect.minY { return TextPosition(line: 0, offset: 0) }
        if best == lines.count - 1, point.y > line.rect.maxY { return TextPosition(line: best, offset: line.text.count) }
        return TextPosition(line: best, offset: Self.offset(in: line, at: point.x))
    }

    private static func offset(in line: RecognizedLine, at x: CGFloat) -> Int {
        var nearest = 0
        var nearestDistance = CGFloat.greatestFiniteMagnitude
        for (index, edge) in line.edges.enumerated() {
            let distance = abs(edge - x)
            if distance < nearestDistance { nearest = index; nearestDistance = distance }
        }
        return nearest
    }

    /// The character under `x`, for word selection.
    private static func character(in line: RecognizedLine, at x: CGFloat) -> Int? {
        guard !line.text.isEmpty else { return nil }
        for index in 0..<line.text.count where x <= line.edges[index + 1] { return index }
        return line.text.count - 1
    }

    /// The word (or the run of spaces or punctuation) under the point, as a selection.
    func wordSelection(at point: CGPoint) -> TextSelection? {
        guard let position = position(at: point) else { return nil }
        let line = lines[position.line]
        let chars = line.characters
        guard let index = Self.character(in: line, at: point.x) else { return nil }
        func isWordCharacter(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }
        let kind = isWordCharacter(chars[index])
        var lower = index, upper = index + 1
        if kind || chars[index].isWhitespace {
            let same: (Character) -> Bool = kind ? isWordCharacter : { $0.isWhitespace }
            while lower > 0, same(chars[lower - 1]) { lower -= 1 }
            while upper < chars.count, same(chars[upper]) { upper += 1 }
        }
        return TextSelection(anchor: TextPosition(line: position.line, offset: lower), head: TextPosition(line: position.line, offset: upper))
    }

    /// The whole line under the point, as a selection.
    func lineSelection(at point: CGPoint) -> TextSelection? {
        guard let position = position(at: point) else { return nil }
        return TextSelection(anchor: TextPosition(line: position.line, offset: 0),
                             head: TextPosition(line: position.line, offset: lines[position.line].text.count))
    }

    // MARK: Reading a selection

    private func segments(of selection: TextSelection) -> [(line: Int, from: Int, to: Int)] {
        let start = selection.start, end = selection.end
        guard !lines.isEmpty, start.line < lines.count else { return [] }
        var result: [(Int, Int, Int)] = []
        for index in start.line...min(end.line, lines.count - 1) {
            let count = lines[index].text.count
            let from = index == start.line ? min(start.offset, count) : 0
            let to = index == end.line ? min(end.offset, count) : count
            if to > from || (start.line != end.line && count == 0) { result.append((index, from, to)) }
        }
        return result
    }

    /// The selected text; lines are separated by a line break.
    func text(in selection: TextSelection) -> String {
        segments(of: selection).map { segment in
            String(lines[segment.line].characters[segment.from..<segment.to])
        }.joined(separator: "\n")
    }

    /// One rectangle per selected line (image pixels), for drawing the highlight.
    func rects(for selection: TextSelection) -> [CGRect] {
        segments(of: selection).map { segment in
            let line = lines[segment.line]
            let left = line.edges[segment.from], right = line.edges[segment.to]
            return CGRect(x: left, y: line.rect.minY, width: max(right - left, 0), height: line.rect.height)
        }
    }

    // MARK: Filtering

    /// Without the lines that touch any of `rects`. Text under a censoring box must never be offered for
    /// copying or stored in a saved file, even if Vision manages to read it through a light blur.
    func removingLines(intersecting rects: [CGRect]) -> RecognizedText {
        guard !rects.isEmpty else { return self }
        return RecognizedText(lines: lines.filter { line in !rects.contains { $0.intersects(line.rect) } },
                              codes: codes.filter { code in !rects.contains { $0.intersects(code.rect) } })
    }

    /// Without the characters that lie under any of `rects`. A line that a box covers only in part keeps what is left on
    /// either side as lines of their own, so censoring one email address does not take the rest of its line along.
    func removingCharacters(coveredBy rects: [CGRect]) -> RecognizedText {
        guard !rects.isEmpty else { return self }
        var result: [RecognizedLine] = []
        for line in lines {
            let touching = rects.filter { $0.intersects(line.rect) }
            guard !touching.isEmpty else { result.append(line); continue }
            let characters = line.characters
            let covered = characters.indices.map { index in
                touching.contains { $0.minX < line.edges[index + 1] && $0.maxX > line.edges[index] }
            }
            var index = 0
            while index < characters.count {
                guard !covered[index] else { index += 1; continue }
                var end = index
                while end < characters.count, !covered[end] { end += 1 }
                var from = index, to = end
                while from < to, characters[from].isWhitespace { from += 1 }
                while to > from, characters[to - 1].isWhitespace { to -= 1 }
                if to > from {
                    result.append(RecognizedLine(text: String(characters[from..<to]),
                                                 rect: CGRect(x: line.edges[from], y: line.rect.minY, width: line.edges[to] - line.edges[from], height: line.rect.height),
                                                 edges: Array(line.edges[from...to])))
                }
                index = end
            }
        }
        return RecognizedText(lines: result, codes: codes.filter { code in !rects.contains { $0.intersects(code.rect) } })
    }

    /// Every place inside a single line where `needle` occurs, ignoring case. Needles shorter than two characters or
    /// spanning several lines find nothing: a lone letter would match everywhere.
    func occurrences(of needle: String) -> [TextSelection] {
        let target = Array(needle.trimmingCharacters(in: .whitespaces)).map { String($0).lowercased() }
        guard target.count >= 2, !needle.contains("\n") else { return [] }
        var found: [TextSelection] = []
        for (lineIndex, line) in lines.enumerated() {
            let characters = line.characters.map { String($0).lowercased() }
            guard characters.count >= target.count else { continue }
            var start = 0
            while start + target.count <= characters.count {
                if Array(characters[start..<start + target.count]) == target {
                    found.append(TextSelection(anchor: TextPosition(line: lineIndex, offset: start),
                                               head: TextPosition(line: lineIndex, offset: start + target.count)))
                    start += target.count
                } else {
                    start += 1
                }
            }
        }
        return found
    }
}

/// Runs Apple's Vision text recognition (`VNRecognizeTextRequest`) on an image. Everything happens on the Mac.
enum TextRecognizer {
    /// Recognises the text and the QR codes / barcodes in `image`. `text` and `codes` switch either part off.
    /// Throws `CancellationError` if the surrounding task is cancelled.
    static func recognize(in image: CGImage, text wantText: Bool = true, codes wantCodes: Bool = true) async throws -> RecognizedText {
        let textRequest = VNRecognizeTextRequest()
        textRequest.recognitionLevel = .accurate
        textRequest.usesLanguageCorrection = true
        textRequest.automaticallyDetectsLanguage = true
        let codeRequest = VNDetectBarcodesRequest()
        var requests: [VNRequest] = []
        if wantText { requests.append(textRequest) }
        if wantCodes { requests.append(codeRequest) }
        guard !requests.isEmpty else { return RecognizedText(lines: []) }
        let toRun = requests
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        try VNImageRequestHandler(cgImage: image, options: [:]).perform(toRun)
                        var result = wantText ? lines(from: textRequest.results ?? [], width: image.width, height: image.height) : RecognizedText(lines: [])
                        if wantCodes { result.codes = codes(from: codeRequest.results ?? [], width: image.width, height: image.height) }
                        continuation.resume(returning: result)
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            toRun.forEach { $0.cancel() }
        }
    }

    /// What a "grab text" capture puts on the clipboard: the text, then the contents of any codes, one per line.
    static func clipboardString(from result: RecognizedText, text: Bool, codes: Bool) -> String {
        var parts: [String] = []
        if text { parts.append(contentsOf: result.lines.map(\.text)) }
        if codes { parts.append(contentsOf: result.codes.map(\.payload)) }
        return parts.joined(separator: "\n")
    }

    static func codes(from observations: [VNBarcodeObservation], width: Int, height: Int) -> [RecognizedCode] {
        let w = CGFloat(width), h = CGFloat(height)
        return observations.compactMap { observation in
            guard let payload = observation.payloadStringValue, !payload.isEmpty else { return nil }
            let box = observation.boundingBox
            return RecognizedCode(payload: payload,
                                  rect: CGRect(x: box.minX * w, y: (1 - box.maxY) * h, width: box.width * w, height: box.height * h),
                                  isQR: observation.symbology == .qr || observation.symbology == .microQR)
        }
    }

    /// Converts Vision's normalised, bottom-left-origin results to the model's pixel coordinates.
    static func lines(from observations: [VNRecognizedTextObservation], width: Int, height: Int) -> RecognizedText {
        let w = CGFloat(width), h = CGFloat(height)
        var lines: [RecognizedLine] = []
        for observation in observations {
            guard let candidate = observation.topCandidates(1).first, !candidate.string.isEmpty else { continue }
            let box = observation.boundingBox
            let rect = CGRect(x: box.minX * w, y: (1 - box.maxY) * h, width: box.width * w, height: box.height * h)
            lines.append(RecognizedLine(text: candidate.string, rect: rect, edges: edges(for: candidate, in: rect, imageWidth: w)))
        }
        return RecognizedText(lines: lines)
    }

    /// Where each character sits along the line. Vision only measures whole words: asked for the box of one character it
    /// returns the box of the word around it (and an empty box for a space). So each word's box is split among its
    /// characters in proportion to how wide the characters are in a typical font, and spaces take the gap between words.
    private static func edges(for candidate: VNRecognizedText, in rect: CGRect, imageWidth: CGFloat) -> [CGFloat] {
        let string = candidate.string
        var spans: [(min: CGFloat, max: CGFloat)?] = []
        var index = string.startIndex
        while index < string.endIndex {
            let next = string.index(after: index)
            if let box = (try? candidate.boundingBox(for: index..<next))?.boundingBox, box.width > 0 {
                spans.append((box.minX * imageWidth, box.maxX * imageWidth))
            } else {
                spans.append(nil)
            }
            index = next
        }
        return edges(characters: Array(string), spans: spans, lineRect: rect)
    }

    /// The edge positions for `characters`, given each character's word span (nil for spaces). Pure, so it can be tested.
    static func edges(characters: [Character], spans: [(min: CGFloat, max: CGFloat)?], lineRect: CGRect) -> [CGFloat] {
        let n = characters.count
        guard n > 0, spans.count == n else { return evenEdges(count: n, in: lineRect) }
        let offsets = glyphOffsets(for: characters)           // n + 1 values, in an arbitrary unit
        var edges = [CGFloat](repeating: 0, count: n + 1)
        var i = 0
        while i < n {
            var j = i + 1
            if let span = spans[i] {
                while j < n, let other = spans[j], abs(other.min - span.min) < 0.01, abs(other.max - span.max) < 0.01 { j += 1 }
                let total = offsets[j] - offsets[i]
                for k in i...j {
                    edges[k] = total > 0 ? span.min + (span.max - span.min) * (offsets[k] - offsets[i]) / total
                                         : span.min + (span.max - span.min) * CGFloat(k - i) / CGFloat(j - i)
                }
            } else {
                while j < n, spans[j] == nil { j += 1 }
                // A run of spaces (or characters Vision gave no box for) fills the gap to the next word.
                let left = i == 0 ? lineRect.minX : edges[i]
                let right = j == n ? lineRect.maxX : (spans[j]?.min ?? lineRect.maxX)
                for k in i..<j { edges[k] = left + (right - left) * CGFloat(k - i) / CGFloat(j - i) }
                edges[j] = right
            }
            i = j
        }
        // Boxes that disagree (right-to-left text, overlapping words) must never produce a backwards selection.
        guard zip(edges, edges.dropFirst()).allSatisfy({ $0 <= $1 }) else { return evenEdges(count: n, in: lineRect) }
        return edges
    }

    /// x offset of every character boundary when the line is set in the system font (CoreText, so any thread may call this).
    private static func glyphOffsets(for characters: [Character]) -> [CGFloat] {
        let font = CTFontCreateUIFontForLanguage(.system, 20, nil) ?? CTFontCreateWithName("Helvetica" as CFString, 20, nil)
        let attributed = NSAttributedString(string: String(characters), attributes: [.font: font])
        let line = CTLineCreateWithAttributedString(attributed)
        var offsets: [CGFloat] = []
        var utf16 = 0
        for character in characters {
            offsets.append(CTLineGetOffsetForStringIndex(line, utf16, nil))
            utf16 += String(character).utf16.count
        }
        offsets.append(CTLineGetTypographicBounds(line, nil, nil, nil))
        return offsets
    }

    private static func evenEdges(count: Int, in rect: CGRect) -> [CGFloat] {
        (0...count).map { rect.minX + rect.width * CGFloat($0) / CGFloat(max(count, 1)) }
    }
}
