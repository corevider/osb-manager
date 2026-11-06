import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

public enum ScreenshotEncoder {
    public static let minimumWidth = 320

    public static func encode(
        _ image: Data,
        maxWidth: Int = ReportPayload.maxScreenshotWidth,
        maxBytes: Int = ReportPayload.maxScreenshotBytes
    ) -> Data? {
        guard let source = CGImageSourceCreateWithData(image as CFData, nil),
              let original = CGImageSourceCreateImageAtIndex(source, 0, nil),
              original.width > 0, original.height > 0 else { return nil }
        var width = min(original.width, maxWidth)
        while width >= minimumWidth {
            if let scaled = scale(original, toWidth: width), let encoded = png(scaled).map(strippingAncillaryChunks), encoded.count <= maxBytes {
                return encoded
            }
            width = Int(Double(width) * 0.8)
        }
        return nil
    }

    public static func dimensions(of png: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (width, height)
    }

    static func strippingAncillaryChunks(_ png: Data) -> Data {
        let keep: Set<String> = ["IHDR", "PLTE", "IDAT", "IEND", "sRGB"]
        let bytes = [UInt8](png)
        guard bytes.count > 8 else { return png }
        var output = Data(bytes[0..<8])
        var offset = 8
        while offset + 12 <= bytes.count {
            let length = Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            let end = offset + 12 + length
            guard end <= bytes.count else { return png }
            if keep.contains(String(decoding: bytes[(offset + 4)..<(offset + 8)], as: UTF8.self)) {
                output.append(contentsOf: bytes[offset..<end])
            }
            offset = end
        }
        return output
    }

    private static func scale(_ image: CGImage, toWidth width: Int) -> CGImage? {
        let height = max(1, Int((Double(image.height) * Double(width) / Double(image.width)).rounded()))
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private static func png(_ image: CGImage) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }
}
