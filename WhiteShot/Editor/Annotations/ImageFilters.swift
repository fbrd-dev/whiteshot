import CoreGraphics
import CoreImage

/// Pixel-level filters used by the censoring and highlight tools. All of them take and return an
/// image of identical size, so the result can be drawn straight back over the region it came from.
enum ImageFilters {
    /// Colour management off: filters then work directly on the pixel values, like other image
    /// editors do. In Core Image's default linear working space "invert" and "brightness" would
    /// give surprising results (inverting 10 would give 255, not 245).
    private static let ciContext = CIContext(options: [.cacheIntermediates: false, .workingColorSpace: NSNull()])

    static func rgbColorSpace(for image: CGImage) -> CGColorSpace {
        if let space = image.colorSpace, space.model == .rgb { return space }
        return CGColorSpace(name: CGColorSpace.sRGB)!
    }

    /// Replaces every `blockSize` x `blockSize` cell with its average colour. Cells are anchored to
    /// the image's top-left corner. With cells larger than the text they cover, the original
    /// content cannot be reconstructed.
    static func pixelate(_ image: CGImage, blockSize: Int) -> CGImage? {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return nil }
        let block = max(2, blockSize)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: rgbColorSpace(for: image),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let raw = ctx.data else { return nil }
        let rowBytes = ctx.bytesPerRow
        let pixels = raw.bindMemory(to: UInt8.self, capacity: rowBytes * h)

        var y = 0
        while y < h {
            let bh = min(block, h - y)
            var x = 0
            while x < w {
                let bw = min(block, w - x)
                var r = 0, g = 0, b = 0, a = 0
                for yy in y..<(y + bh) {
                    var p = yy * rowBytes + x * 4
                    for _ in 0..<bw {
                        r += Int(pixels[p]); g += Int(pixels[p + 1]); b += Int(pixels[p + 2]); a += Int(pixels[p + 3])
                        p += 4
                    }
                }
                let count = bw * bh
                let ar = UInt8(r / count), ag = UInt8(g / count), ab = UInt8(b / count), aa = UInt8(a / count)
                for yy in y..<(y + bh) {
                    var p = yy * rowBytes + x * 4
                    for _ in 0..<bw {
                        pixels[p] = ar; pixels[p + 1] = ag; pixels[p + 2] = ab; pixels[p + 3] = aa
                        p += 4
                    }
                }
                x += block
            }
            y += block
        }
        return ctx.makeImage()
    }

    /// Gaussian blur that only samples inside the image, so the edges do not pick up colour from outside.
    static func blur(_ image: CGImage, radius: Double) -> CGImage? {
        let input = CIImage(cgImage: image)
        let blurred = input.clampedToExtent()
            .applyingGaussianBlur(sigma: max(0.5, radius))
            .cropped(to: input.extent)
        return ciContext.createCGImage(blurred, from: input.extent, format: .RGBA8, colorSpace: rgbColorSpace(for: image))
    }

    static func grayscale(_ image: CGImage) -> CGImage? {
        let input = CIImage(cgImage: image)
        guard let filter = CIFilter(name: "CIColorControls") else { return nil }
        filter.setValue(input, forKey: kCIInputImageKey)
        filter.setValue(0.0, forKey: kCIInputSaturationKey)
        guard let output = filter.outputImage else { return nil }
        return ciContext.createCGImage(output, from: input.extent, format: .RGBA8, colorSpace: rgbColorSpace(for: image))
    }

    static func invert(_ image: CGImage) -> CGImage? {
        let input = CIImage(cgImage: image)
        guard let filter = CIFilter(name: "CIColorInvert") else { return nil }
        filter.setValue(input, forKey: kCIInputImageKey)
        guard let output = filter.outputImage else { return nil }
        return ciContext.createCGImage(output, from: input.extent, format: .RGBA8, colorSpace: rgbColorSpace(for: image))
    }

    /// Brightness (-1...1), contrast (0...4, 1 = unchanged) and gamma (0.1...4, 1 = unchanged).
    static func adjustColors(_ image: CGImage, brightness: Double, contrast: Double, gamma: Double) -> CGImage? {
        var output = CIImage(cgImage: image)
        let extent = output.extent
        if let controls = CIFilter(name: "CIColorControls") {
            controls.setValue(output, forKey: kCIInputImageKey)
            controls.setValue(brightness, forKey: kCIInputBrightnessKey)
            controls.setValue(contrast, forKey: kCIInputContrastKey)
            if let result = controls.outputImage { output = result }
        }
        if abs(gamma - 1) > 0.001, let adjust = CIFilter(name: "CIGammaAdjust") {
            adjust.setValue(output, forKey: kCIInputImageKey)
            adjust.setValue(gamma, forKey: "inputPower")
            if let result = adjust.outputImage { output = result }
        }
        return ciContext.createCGImage(output, from: extent, format: .RGBA8, colorSpace: rgbColorSpace(for: image))
    }
}
