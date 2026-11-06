import CoreGraphics
import Foundation
@testable import WhiteShot

enum TestImage {
    /// Opaque image where each pixel's colour comes from `color(x, y)`. Origin top-left.
    static func make(width: Int, height: Int, color: (Int, Int) -> (UInt8, UInt8, UInt8)) -> CGImage {
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let (r, g, b) = color(x, y)
                let i = (y * width + x) * 4
                bytes[i] = r; bytes[i + 1] = g; bytes[i + 2] = b; bytes[i + 3] = 255
            }
        }
        let provider = CGDataProvider(data: Data(bytes) as CFData)!
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpace(name: CGColorSpace.sRGB)!,
                       bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    }

    static func solid(_ width: Int, _ height: Int, _ c: (UInt8, UInt8, UInt8) = (255, 255, 255)) -> CGImage {
        make(width: width, height: height) { _, _ in c }
    }

    /// Black text-like stripes on white, so pixelating or blurring visibly changes it.
    static func stripes(_ width: Int, _ height: Int) -> CGImage {
        make(width: width, height: height) { x, _ in x % 4 < 2 ? (0, 0, 0) : (255, 255, 255) }
    }

    static func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> (r: Int, g: Int, b: Int, a: Int) {
        var data = [UInt8](repeating: 0, count: 4)
        let ctx = CGContext(data: &data, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // Shift so pixel (x, y) from the top-left lands in the 1x1 context.
        ctx.draw(image, in: CGRect(x: -x, y: -(image.height - 1 - y), width: image.width, height: image.height))
        return (Int(data[0]), Int(data[1]), Int(data[2]), Int(data[3]))
    }
}


/// The editor remembers per-tool styles in UserDefaults. Tests must neither depend on a developer's
/// saved styles nor leave their own behind, so they stash and restore that one family of keys.
enum StyleDefaults {
    private static var stashed: [String: Any] = [:]

    static func stash() {
        let defaults = UserDefaults.standard
        stashed = [:]
        for (key, value) in defaults.dictionaryRepresentation() where key.hasPrefix("toolStyle.") {
            stashed[key] = value
            defaults.removeObject(forKey: key)
        }
    }

    static func restore() {
        let defaults = UserDefaults.standard
        for (key, _) in defaults.dictionaryRepresentation() where key.hasPrefix("toolStyle.") { defaults.removeObject(forKey: key) }
        for (key, value) in stashed { defaults.set(value, forKey: key) }
        stashed = [:]
    }
}
