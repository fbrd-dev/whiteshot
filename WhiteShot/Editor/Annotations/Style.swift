import AppKit

/// A colour that can be stored in a project file and compared. Always sRGB.
struct RGBAColor: Codable, Equatable, Hashable {
    var r: Double
    var g: Double
    var b: Double
    var a: Double

    init(r: Double, g: Double, b: Double, a: Double = 1) {
        self.r = r; self.g = g; self.b = b; self.a = a
    }

    init(_ color: NSColor) {
        let c = color.usingColorSpace(.sRGB) ?? color
        self.init(r: Double(c.redComponent), g: Double(c.greenComponent), b: Double(c.blueComponent), a: Double(c.alphaComponent))
    }

    var nsColor: NSColor { NSColor(srgbRed: r, green: g, blue: b, alpha: a) }
    var cgColor: CGColor { nsColor.cgColor }
    var isVisible: Bool { a > 0.004 }

    func with(alpha: Double) -> RGBAColor { RGBAColor(r: r, g: g, b: b, a: alpha) }

    // MARK: Colour codes

    /// Red, green and blue as 0...255, the way hex and RGB colour codes write them.
    var rgb255: (r: Int, g: Int, b: Int) {
        func byte(_ v: Double) -> Int { max(0, min(255, Int((v * 255).rounded()))) }
        return (byte(r), byte(g), byte(b))
    }

    /// Six hex digits without a leading "#", e.g. `E8352F`.
    var hexString: String {
        let c = rgb255
        return String(format: "%02X%02X%02X", c.r, c.g, c.b)
    }

    /// Parses `#RGB`, `#RRGGBB` or `#RRGGBBAA`, with or without the "#", in any letter case.
    init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("#") { text.removeFirst() }
        guard [3, 6, 8].contains(text.count), text.allSatisfy(\.isHexDigit) else { return nil }
        if text.count == 3 { text = text.map { "\($0)\($0)" }.joined() }
        guard let value = UInt64(text, radix: 16) else { return nil }
        let hasAlpha = text.count == 8
        let shift: UInt64 = hasAlpha ? 8 : 0
        let alpha = hasAlpha ? Double(value & 0xFF) / 255 : 1
        self.init(r: Double((value >> (16 + shift)) & 0xFF) / 255,
                  g: Double((value >> (8 + shift)) & 0xFF) / 255,
                  b: Double((value >> shift) & 0xFF) / 255,
                  a: alpha)
    }

    /// This colour after the user typed `text` as a colour code, or nil if it isn't one. Without an
    /// explicit alpha the current opacity is kept; a colour that was "None" becomes visible.
    func applying(hex text: String) -> RGBAColor? {
        guard let parsed = RGBAColor(hex: text) else { return nil }
        let digits = text.trimmingCharacters(in: CharacterSet(charactersIn: "# \n\t")).count
        return parsed.with(alpha: digits == 8 ? parsed.a : (isVisible ? a : 1))
    }

    /// This colour with some channels (0...255) replaced. Keeps the opacity, and a "None" colour becomes visible.
    func replacing(red: Int? = nil, green: Int? = nil, blue: Int? = nil) -> RGBAColor {
        let c = rgb255
        return RGBAColor(red: red ?? c.r, green: green ?? c.g, blue: blue ?? c.b, alpha: isVisible ? a : 1)
    }

    /// Builds a colour from 0...255 channel values (values outside the range are clamped).
    init(red: Int, green: Int, blue: Int, alpha: Double = 1) {
        func unit(_ v: Int) -> Double { Double(max(0, min(255, v))) / 255 }
        self.init(r: unit(red), g: unit(green), b: unit(blue), a: alpha)
    }

    static let clear = RGBAColor(r: 0, g: 0, b: 0, a: 0)
    static let black = RGBAColor(r: 0, g: 0, b: 0)
    static let white = RGBAColor(r: 1, g: 1, b: 1)
    static let red = RGBAColor(r: 0.93, g: 0.17, b: 0.15)
    static let orange = RGBAColor(r: 1.0, g: 0.58, b: 0.0)
    static let yellow = RGBAColor(r: 1.0, g: 0.9, b: 0.1)
    static let green = RGBAColor(r: 0.2, g: 0.78, b: 0.35)
    static let blue = RGBAColor(r: 0.0, g: 0.48, b: 1.0)
    static let purple = RGBAColor(r: 0.69, g: 0.32, b: 0.87)
    static let gray = RGBAColor(r: 0.56, g: 0.56, b: 0.58)
}

enum ArrowHeads: String, Codable, CaseIterable {
    case end, start, both, none
}

enum ObfuscateMode: String, Codable, CaseIterable {
    case pixelate, blur, blackout
}

enum HighlightMode: String, Codable, CaseIterable {
    case text, area, grayscale, magnify
}

enum TextAlign: String, Codable, CaseIterable {
    case left, center, right
}

enum VerticalAlign: String, Codable, CaseIterable {
    case top, middle, bottom
}

/// Every look-and-feel property an annotation can have. Each kind of annotation uses only the
/// subset that makes sense for it, so a single struct can describe, store and copy them all.
/// Sizes are in image pixels; use `scaled(by:)` to adapt point-based defaults to a Retina capture.
struct Style: Codable, Equatable {
    var strokeColor: RGBAColor = .red
    var fillColor: RGBAColor = .clear
    var lineWidth: CGFloat = 3
    var shadow = false

    // Text (also used by speech bubbles and step labels)
    var textColor: RGBAColor = .red
    var fontName = ""            // empty = system font
    var fontSize: CGFloat = 18
    var bold = false
    var italic = false
    var underline = false
    var textAlign: TextAlign = .left
    var verticalAlign: VerticalAlign = .top

    var arrowHeads: ArrowHeads = .end

    // Obfuscate
    var obfuscateMode: ObfuscateMode = .pixelate
    var pixelSize: CGFloat = 10
    var blurRadius: CGFloat = 8

    // Highlight
    var highlightMode: HighlightMode = .text
    var highlightColor: RGBAColor = .yellow
    var dim: Double = 0.55
    var magnification: Double = 2

    // Step label
    var stepStart = 1

    /// Multiplies every size-like value, turning a 1x default into one that looks the same on a 2x capture.
    func scaled(by factor: CGFloat) -> Style {
        var s = self
        s.lineWidth *= factor
        s.fontSize *= factor
        s.pixelSize *= factor
        s.blurRadius *= factor
        return s
    }

    /// Inverse of `scaled(by:)`, used when persisting defaults independent of the capture's scale.
    func normalised(by factor: CGFloat) -> Style { scaled(by: 1 / factor) }

    func font(sizeFactor: CGFloat = 1) -> NSFont {
        let size = max(1, fontSize * sizeFactor)
        var font: NSFont
        if fontName.isEmpty {
            font = NSFont.systemFont(ofSize: size, weight: bold ? .bold : .regular)
        } else {
            font = NSFont(name: fontName, size: size) ?? NSFont.systemFont(ofSize: size)
            if bold { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
        }
        if italic { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
        return font
    }

    func textAttributes(sizeFactor: CGFloat = 1) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        switch textAlign {
        case .left: paragraph.alignment = .left
        case .center: paragraph.alignment = .center
        case .right: paragraph.alignment = .right
        }
        paragraph.lineBreakMode = .byWordWrapping
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font(sizeFactor: sizeFactor),
            .foregroundColor: textColor.nsColor,
            .paragraphStyle: paragraph,
        ]
        if underline { attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue }
        return attributes
    }
}
