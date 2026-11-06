import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import OsbManagerCore

struct ScreenshotAndOptionsTests {
    private func png(width: Int, height: Int, noisy: Bool) throws -> Data {
        let context = try #require(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        if noisy, let pixels = context.data?.assumingMemoryBound(to: UInt8.self) {
            var generator = SystemRandomNumberGenerator()
            for index in 0..<(width * height * 4) {
                pixels[index] = UInt8.random(in: 0...255, using: &generator)
            }
        } else {
            context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        }
        let image = try #require(context.makeImage())
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
        return output as Data
    }

    @Test func aWideScreenshotIsScaledToNineteenHundredTwentyPixels() throws {
        let source = try png(width: 3840, height: 2000, noisy: false)

        let encoded = try #require(ScreenshotEncoder.encode(source))

        let size = try #require(ScreenshotEncoder.dimensions(of: encoded))
        #expect(size.width == 1920)
        #expect(size.height == 1000)
        #expect(encoded.count <= ReportPayload.maxScreenshotBytes)
        #expect(Array(encoded.prefix(8)) == [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
    }

    @Test func aSmallScreenshotKeepsItsSize() throws {
        let source = try png(width: 640, height: 360, noisy: false)

        let encoded = try #require(ScreenshotEncoder.encode(source))

        #expect(ScreenshotEncoder.dimensions(of: encoded)?.width == 640)
    }

    @Test func aScreenshotThatStaysTooBigIsShrunkUntilItFitsTheLimit() throws {
        let source = try png(width: 2400, height: 1400, noisy: true)
        #expect(source.count > ReportPayload.maxScreenshotBytes)

        let encoded = try #require(ScreenshotEncoder.encode(source))

        #expect(encoded.count <= ReportPayload.maxScreenshotBytes)
        let size = try #require(ScreenshotEncoder.dimensions(of: encoded))
        #expect(size.width <= 1920 && size.width >= ScreenshotEncoder.minimumWidth)
    }

    @Test func notAnImageGivesNothing() {
        #expect(ScreenshotEncoder.encode(Data("not an image".utf8)) == nil)
        #expect(ScreenshotEncoder.encode(Data()) == nil)
    }

    private func chunkTypes(_ png: Data) -> [String] {
        var types: [String] = []
        var offset = 8
        let bytes = [UInt8](png)
        while offset + 8 <= bytes.count {
            let length = Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            types.append(String(decoding: bytes[(offset + 4)..<(offset + 8)], as: UTF8.self))
            offset += 12 + length
        }
        return types
    }

    @Test func theReEncodedScreenshotCarriesNoTextOrExifChunks() throws {
        let source = try png(width: 800, height: 450, noisy: false)

        let encoded = try #require(ScreenshotEncoder.encode(source))

        let types = chunkTypes(encoded)
        #expect(types.first == "IHDR")
        #expect(types.last == "IEND")
        for forbidden in ["tEXt", "iTXt", "zTXt", "eXIf", "tIME"] {
            #expect(!types.contains(forbidden), "chunks: \(types)")
        }
    }

    @Test func theDataFolderHoldsThePrivacyFileAndTheOutbox() {
        let paths = AppPaths(root: URL(fileURLWithPath: "/tmp/osb-test", isDirectory: true))

        #expect(paths.privacyFile.lastPathComponent == "privacy.json")
        #expect(paths.outbox.lastPathComponent == "outbox")
        #expect(paths.privacyFile.deletingLastPathComponent() == paths.root)
    }

    @Test func theShortVersionIsTheBundleVersionOrZero() {
        #expect(AppVersion.shortText(from: ["CFBundleShortVersionString": "1.2.3", "CFBundleVersion": "9"]) == "1.2.3")
        #expect(AppVersion.shortText(from: nil) == "0.0.0")
        #expect(AppVersion.shortText(from: ["CFBundleShortVersionString": ""]) == "0.0.0")
    }

    #if DEBUG
    @Test func debugBuildsReadTheTelemetryTestOptions() throws {
        let options = try LaunchOptions.parse(["--telemetry-url", "http://127.0.0.1:9/v1", "--telemetry-time-scale", "60", "--telemetry-consent", "--latency-log", "/tmp/l.jsonl", "--dialog-shots", "/tmp/shots", "--language", "tr"])

        #expect(options.telemetryUrl?.absoluteString == "http://127.0.0.1:9/v1")
        #expect(options.telemetryTimeScale == 60)
        #expect(options.telemetryConsent)
        #expect(options.latencyLog?.path == "/tmp/l.jsonl")
        #expect(options.dialogShots?.path == "/tmp/shots")
        #expect(options.interfaceLanguage == "tr")
    }

    @Test(arguments: [["--telemetry-time-scale", "0"], ["--telemetry-time-scale", "x"], ["--telemetry-url", "nonsense"]])
    func debugOptionsRejectBadValues(arguments: [String]) {
        #expect(throws: LaunchOptionsError.self) {
            _ = try LaunchOptions.parse(arguments)
        }
    }
    #endif
}
