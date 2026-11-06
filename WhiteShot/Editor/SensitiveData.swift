import Foundation

/// The kinds of personal or confidential text WhiteShot can point out in a recognised screenshot. Which of them are looked
/// for is a setting; nothing is ever censored without a click.
enum SensitiveKind: String, CaseIterable, Identifiable, Hashable {
    case email, phone, iban, card, url, ip

    var id: String { rawValue }

    var title: String {
        switch self {
        case .email: return String(localized: "Email addresses")
        case .phone: return String(localized: "Phone numbers")
        case .iban: return String(localized: "IBANs")
        case .card: return String(localized: "Card numbers")
        case .url: return String(localized: "Web addresses")
        case .ip: return String(localized: "IP addresses")
        }
    }

    /// Short name for the chips in the editor.
    var shortTitle: String {
        switch self {
        case .email: return String(localized: "Emails")
        case .phone: return String(localized: "Phones")
        case .iban: return String(localized: "IBANs")
        case .card: return String(localized: "Cards")
        case .url: return String(localized: "URLs")
        case .ip: return String(localized: "IPs")
        }
    }

    var symbol: String {
        switch self {
        case .email: return "envelope"
        case .phone: return "phone"
        case .iban: return "building.columns"
        case .card: return "creditcard"
        case .url: return "link"
        case .ip: return "network"
        }
    }

    /// Looked for out of the box. Web and IP addresses are often harmless in a screenshot, so they start off.
    var enabledByDefault: Bool { self != .url && self != .ip }

    var preferenceKey: String { "recognition.sensitive.\(rawValue)" }

    /// When two kinds match the same characters, the one earlier in this list wins (a card number is not also a phone number).
    fileprivate var priority: Int {
        switch self {
        case .iban: return 0
        case .card: return 1
        case .email: return 2
        case .url: return 3
        case .ip: return 4
        case .phone: return 5
        }
    }
}

/// A stretch of one recognised line that looks like sensitive data.
struct SensitiveMatch: Equatable {
    var kind: SensitiveKind
    var line: Int
    /// Character offsets inside the line's text.
    var range: Range<Int>
    var text: String
}

enum SensitiveDetector {
    /// Every match of every kind, with overlaps settled by priority. Filter by kind afterwards.
    static func matches(in recognized: RecognizedText) -> [SensitiveMatch] {
        var result: [SensitiveMatch] = []
        for (index, line) in recognized.lines.enumerated() {
            var found: [SensitiveMatch] = []
            for kind in SensitiveKind.allCases {
                for range in ranges(of: kind, in: line.text) {
                    let characters = Array(line.text)
                    found.append(SensitiveMatch(kind: kind, line: index, range: range, text: String(characters[range])))
                }
            }
            // Strongest kind first; a weaker match that overlaps one already kept is dropped.
            var kept: [SensitiveMatch] = []
            for match in found.sorted(by: { ($0.kind.priority, $0.range.lowerBound) < ($1.kind.priority, $1.range.lowerBound) }) {
                if !kept.contains(where: { $0.range.overlaps(match.range) }) { kept.append(match) }
            }
            result.append(contentsOf: kept.sorted { $0.range.lowerBound < $1.range.lowerBound })
        }
        return result
    }

    /// Where on the picture a match is (image pixels), from the character positions Vision gave.
    static func rect(of match: SensitiveMatch, in recognized: RecognizedText) -> CGRect {
        let line = recognized.lines[match.line]
        let left = line.edges[match.range.lowerBound], right = line.edges[match.range.upperBound]
        return CGRect(x: left, y: line.rect.minY, width: max(right - left, 0), height: line.rect.height)
    }

    // MARK: Patterns

    private static func regex(_ pattern: String) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    private static let emailPattern = regex(#"[A-Z0-9._%+\-]+@[A-Z0-9\-]+(?:\.[A-Z0-9\-]+)*\.[A-Z]{2,}"#)
    private static let ibanPattern = regex(#"(?<![A-Z0-9])[A-Z]{2}\d{2}(?: ?[A-Z0-9]{4}){2,7}(?: ?[A-Z0-9]{1,3})?(?![A-Z0-9])"#)
    private static let cardPattern = regex(#"(?<![\d])(?:\d[ \-]?){12,18}\d(?![\d])"#)
    private static let urlPattern = regex(#"(?:https?://|www\.)[^\s<>"']+"#)
    private static let ipPattern = regex(#"(?<![\d.])(?:(?:25[0-5]|2[0-4]\d|1?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|1?\d?\d)(?![\d.])"#)
    private static let phonePattern = regex(#"(?<![\w:])(?:\+|00)?[\d(][\d\s().\-/]{5,}\d(?![\w:])"#)

    private static func ranges(of kind: SensitiveKind, in text: String) -> [Range<Int>] {
        let pattern: NSRegularExpression
        switch kind {
        case .email: pattern = emailPattern
        case .iban: pattern = ibanPattern
        case .card: pattern = cardPattern
        case .url: pattern = urlPattern
        case .ip: pattern = ipPattern
        case .phone: pattern = phonePattern
        }
        let whole = NSRange(text.startIndex..., in: text)
        var result: [Range<Int>] = []
        for match in pattern.matches(in: text, range: whole) {
            guard var range = Range(match.range, in: text) else { continue }
            if kind == .url { range = trimmingTrailingPunctuation(range, in: text) }
            let candidate = String(text[range])
            let valid: Bool
            switch kind {
            case .iban: valid = isValidIBAN(candidate)
            case .card: valid = isValidCardNumber(candidate)
            case .phone: valid = looksLikePhoneNumber(candidate)
            default: valid = true
            }
            guard valid else { continue }
            let lower = text.distance(from: text.startIndex, to: range.lowerBound)
            let upper = text.distance(from: text.startIndex, to: range.upperBound)
            result.append(lower..<upper)
        }
        return result
    }

    private static func trimmingTrailingPunctuation(_ range: Range<String.Index>, in text: String) -> Range<String.Index> {
        var end = range.upperBound
        while end > range.lowerBound, ".,;:!?)]}".contains(text[text.index(before: end)]) { end = text.index(before: end) }
        return range.lowerBound..<end
    }

    // MARK: Validation

    /// ISO 7064 mod 97: the check that makes a random string of letters and digits very unlikely to pass as an IBAN.
    static func isValidIBAN(_ candidate: String) -> Bool {
        let compact = candidate.filter { !$0.isWhitespace }.uppercased()
        guard (15...34).contains(compact.count), compact.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return false }
        let rearranged = compact.dropFirst(4) + compact.prefix(4)
        var remainder = 0
        for character in rearranged {
            let digits = character.isNumber ? String(character) : String(character.asciiValue! - 55)   // A = 10 … Z = 35
            for digit in digits { remainder = (remainder * 10 + Int(String(digit))!) % 97 }
        }
        return remainder == 1
    }

    /// Luhn checksum over 13–19 digits.
    static func isValidCardNumber(_ candidate: String) -> Bool {
        let digits = candidate.compactMap { $0.wholeNumberValue }
        guard (13...19).contains(digits.count), Set(digits).count > 1 else { return false }
        var sum = 0
        for (position, digit) in digits.reversed().enumerated() {
            var value = digit
            if position % 2 == 1 { value *= 2; if value > 9 { value -= 9 } }
            sum += value
        }
        return sum % 10 == 0
    }

    /// Plain numbers with a dash or two (dates, invoice numbers, amounts) must not count as phone numbers, so a candidate
    /// needs a telltale: a leading "+" or "00", a national leading "0", parentheses, or ten digits in groups.
    static func looksLikePhoneNumber(_ candidate: String) -> Bool {
        let trimmed = candidate.trimmingCharacters(in: .whitespaces)
        let digits = trimmed.filter(\.isNumber)
        guard (7...15).contains(digits.count) else { return false }
        // 04.11.2026 or 2026-11-04 are dates, however many digits they have.
        let date = try! NSRegularExpression(pattern: #"^(?:\d{1,2}[./\-]\d{1,2}[./\-]\d{2,4}|\d{4}[./\-]\d{1,2}[./\-]\d{1,2})$"#)
        if date.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) != nil { return false }
        if trimmed.hasPrefix("+") || trimmed.hasPrefix("00") { return true }
        if trimmed.contains("(") && trimmed.contains(")") { return true }
        if trimmed.hasPrefix("0") && digits.count >= 8 { return true }
        let separators = trimmed.filter { " .-/".contains($0) }.count
        return digits.count >= 10 && separators >= 2
    }
}
