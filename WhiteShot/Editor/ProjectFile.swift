import Foundation
import CoreGraphics

/// `.whiteshot` files keep the screenshot and every annotation editable. Layout:
/// `"WSHP"`, UInt32 version, UInt64 header length, JSON header, PNG of the untouched base image.
///
/// The base image is stored *without* annotations. A censored area therefore still contains the
/// original pixels inside the project file: share the flattened PNG, never the project file.
enum ProjectFile {
    private static let magic = Data("WSHP".utf8)
    static let currentVersion: UInt32 = 1
    static let fileExtension = "whiteshot"

    struct Header: Codable {
        var scale: Double
        var annotations: [Annotation]
    }

    struct Contents {
        var image: CGImage
        var scale: CGFloat
        var annotations: [Annotation]
    }

    static func encode(image: CGImage, scale: CGFloat, annotations: [Annotation]) -> Data? {
        guard let png = ImageEncoder.data(for: image, format: .png, scale: scale),
              let json = try? JSONEncoder().encode(Header(scale: Double(scale), annotations: annotations)) else { return nil }
        var data = magic
        withUnsafeBytes(of: currentVersion.bigEndian) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: UInt64(json.count).bigEndian) { data.append(contentsOf: $0) }
        data.append(json)
        data.append(png)
        return data
    }

    static func decode(_ data: Data) -> Contents? {
        let headerSize = magic.count + 4 + 8
        guard data.count > headerSize, data.prefix(magic.count) == magic else { return nil }
        let base = data.startIndex
        let versionBytes = data[(base + 4)..<(base + 8)]
        let lengthBytes = data[(base + 8)..<(base + 16)]
        let version = versionBytes.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let length = lengthBytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        guard version <= currentVersion, length < UInt64(data.count - headerSize) else { return nil }
        let jsonEnd = base + headerSize + Int(length)
        guard let header = try? JSONDecoder().decode(Header.self, from: data[(base + headerSize)..<jsonEnd]),
              let (image, _) = ImageEncoder.decode(Data(data[jsonEnd...])) else { return nil }
        return Contents(image: image, scale: CGFloat(header.scale), annotations: header.annotations)
    }
}
