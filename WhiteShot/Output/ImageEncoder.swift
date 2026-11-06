import AppKit
import ImageIO
import UniformTypeIdentifiers

enum ImageFormat: String, CaseIterable, Identifiable {
    case png, jpg, gif, tiff, bmp, heic

    var id: String { rawValue }

    var utType: UTType {
        switch self {
        case .png: return .png
        case .jpg: return .jpeg
        case .gif: return .gif
        case .tiff: return .tiff
        case .bmp: return .bmp
        case .heic: return .heic
        }
    }

    var fileExtension: String { rawValue }

    var displayName: String {
        switch self {
        case .png: return "PNG"
        case .jpg: return "JPEG"
        case .gif: return "GIF"
        case .tiff: return "TIFF"
        case .bmp: return "BMP"
        case .heic: return "HEIC"
        }
    }

    var supportsAlpha: Bool { self == .png || self == .tiff || self == .heic }
    var isLossy: Bool { self == .jpg || self == .heic }

    init?(fileExtension ext: String) {
        switch ext.lowercased() {
        case "png": self = .png
        case "jpg", "jpeg": self = .jpg
        case "gif": self = .gif
        case "tif", "tiff": self = .tiff
        case "bmp": self = .bmp
        case "heic": self = .heic
        default: return nil
        }
    }
}

enum ImageEncoder {
    /// Longest text stored in a file. JPEG keeps such text in one 64 KB metadata segment, so there has to be a limit.
    static let maxEmbeddedTextLength = 20_000

    /// Encodes `image`. `scale` is stored as DPI (72 x scale) so Retina captures keep their point size
    /// when opened in Preview or dropped into a document. `text` (recognised text) is stored as the image's
    /// description where the format has room for one: PNG, JPEG, TIFF and HEIC.
    static func data(for image: CGImage, format: ImageFormat, quality: Double = 0.9, scale: CGFloat = 1, text: String? = nil) -> Data? {
        // JPEG and BMP have no alpha channel: composite on white rather than letting transparency turn black.
        let source = (!format.supportsAlpha && ImageOps.hasAlpha(image)) ? (ImageOps.flatten(image) ?? image) : image
        let output = NSMutableData()
        func encode(as format: ImageFormat) -> Data? {
            output.length = 0
            guard let destination = CGImageDestinationCreateWithData(output, format.utType.identifier as CFString, 1, nil) else { return nil }
            var properties: [CFString: Any] = [
                kCGImagePropertyDPIWidth: 72 * scale,
                kCGImagePropertyDPIHeight: 72 * scale,
            ]
            if format.isLossy { properties[kCGImageDestinationLossyCompressionQuality] = quality }
            if let text, !text.isEmpty {
                let description = String(text.prefix(maxEmbeddedTextLength))
                switch format {
                case .png: properties[kCGImagePropertyPNGDictionary] = [kCGImagePropertyPNGDescription: description]
                case .jpg, .tiff, .heic: properties[kCGImagePropertyTIFFDictionary] = [kCGImagePropertyTIFFImageDescription: description]
                case .gif, .bmp: break
                }
            }
            CGImageDestinationAddImage(destination, source, properties as CFDictionary)
            return CGImageDestinationFinalize(destination) ? output as Data : nil
        }
        // HEIC encoders are not available everywhere; PNG is a safe lossless fallback.
        return encode(as: format) ?? (format == .png ? nil : encode(as: .png))
    }

    static func decode(_ data: Data) -> (image: CGImage, scale: CGFloat)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return (image, scale(of: source))
    }

    static func decode(contentsOf url: URL) -> (image: CGImage, scale: CGFloat)? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return (image, scale(of: source))
    }

    /// Reads the DPI the file was saved with and turns it back into a display scale.
    private static func scale(of source: CGImageSource) -> CGFloat {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let dpi = props[kCGImagePropertyDPIWidth] as? Double, dpi > 0 else { return 1 }
        let ratio = CGFloat(dpi / 72)
        return ratio >= 1.5 ? min(ratio.rounded(), 4) : 1
    }

    /// The description stored in an encoded image (see `data(for:text:)`), if there is one.
    static func embeddedText(in data: Data) -> String? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
        let png = properties[kCGImagePropertyPNGDictionary] as? [CFString: Any]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        return (png?[kCGImagePropertyPNGDescription] as? String) ?? (tiff?[kCGImagePropertyTIFFImageDescription] as? String)
    }

    static func nsImage(for image: CGImage, scale: CGFloat) -> NSImage {
        NSImage(cgImage: image, size: NSSize(width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale))
    }
}
