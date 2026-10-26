import CoreGraphics
import ImageIO
import XCTest
import libwebp
@testable import WatchDotCore

@MainActor final class PetWebPDecoderTests: XCTestCase {
    func testForcedFallbackProducesNativePNGForBothAtlasContracts() async throws {
        let validator = PetImageValidator(supportsNativeWebP: false)
        for height in [1872, 2288] {
            let webp = try fixture(height: height)
            let payload = try await validator.validate(data: webp, mimeType: "image/webp")
            XCTAssertEqual(payload.format, .png)
            XCTAssertEqual(payload.mimeType, "image/png")
            XCTAssertEqual(payload.width, 1536)
            XCTAssertEqual(payload.rowCount, height / 208)
            XCTAssertLessThanOrEqual(payload.data.count, PetImageDownloader.maximumBytes)
            XCTAssertNoThrow(try PetImageDownloader.validate(data: payload.data, mimeType: payload.mimeType))
        }
    }

    func testFallbackPreservesStraightAlphaWithoutDarkening() async throws {
        let validator = PetImageValidator(supportsNativeWebP: false)
        let payload = try await validator.validate(data: fixture(color: [128, 64, 32, 128]), mimeType: "image/webp")
        let source = try XCTUnwrap(CGImageSourceCreateWithData(payload.data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var pixel = [UInt8](repeating: 0, count: 4)
        try pixel.withUnsafeMutableBytes { bytes in
            let context = try XCTUnwrap(CGContext(data: bytes.baseAddress, width: 1, height: 1,
                bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        XCTAssertEqual(pixel, [64, 32, 16, 128])
    }

    func testNativeRuntimeRetainsWebPAndPNGDoesNotUseFallback() async throws {
        let webp = try fixture()
        let native = PetImageValidator(supportsNativeWebP: true)
        let unchanged = try await native.validate(data: webp, mimeType: "image/webp")
        XCTAssertEqual(unchanged.data, webp)
        XCTAssertEqual(unchanged.format, .webP)
        let fallback = PetImageValidator(supportsNativeWebP: false)
        let png = try await fallback.validate(data: webp, mimeType: "image/webp")
        let second = try await fallback.validate(data: png.data, mimeType: "image/png")
        XCTAssertEqual(second.data, png.data)
    }

    func testMalformedOversizedAnimatedAndWrongDimensionsAreRejected() throws {
        let animation = Data(base64Encoded: "UklGRogAAABXRUJQVlA4WAoAAAACAAAABwAABwAAQU5JTQYAAAD/////AABBTk1GKgAAAAAAAAAAAAcAAAcAAGQAAABWUDhMEQAAAC8HwAEAB1DAAhW4/4GI6H8AAEFOTUYqAAAAAAAAAAAABwAABwAAZAAAAFZQOEwRAAAALwfAAQAHUMACF6j/gYjofwAA")!
        let valid = try fixture()
        let cases: [(Data, PetImageDownloadError)] = [
            (try fixture(width: 8, height: 8), .dimensions),
            (animation, .animatedImage),
            (valid.dropLast(12), .invalidImage),
            (Data("RIFF1234WEBP".utf8), .invalidImage),
            (Data("not an image".utf8), .unsupportedFormat),
            (Data(repeating: 0, count: PetImageDownloader.maximumBytes + 1), .tooLarge)
        ]
        for (data, expected) in cases {
            XCTAssertThrowsError(try PetWebPDecoder.decode(data)) {
                XCTAssertEqual($0 as? PetImageDownloadError, expected)
            }
        }
    }

    func testForcedFallbackStillRequiresMIMEAgreementAndPreservesCancellation() async throws {
        let validator = PetImageValidator(supportsNativeWebP: false)
        let data = try fixture()
        do { _ = try await validator.validate(data: data, mimeType: "image/png"); XCTFail("Must reject MIME mismatch") }
        catch { XCTAssertEqual(error as? PetImageDownloadError, .unsupportedFormat) }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await validator.validate(data: data, mimeType: "image/webp")
        }
        do { _ = try await task.value; XCTFail("Must preserve cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    private func fixture(width: Int = 1536, height: Int = 1872,
                         color: [UInt8] = [64, 128, 192, 255]) throws -> Data {
        let pixels = Array(repeating: color, count: width * height).flatMap { $0 }
        var encoded: UnsafeMutablePointer<UInt8>?
        let length = pixels.withUnsafeBufferPointer {
            WebPEncodeLosslessRGBA($0.baseAddress, Int32(width), Int32(height), Int32(width * 4), &encoded)
        }
        let output = try XCTUnwrap(encoded)
        defer { WebPFree(output) }
        XCTAssertGreaterThan(length, 0)
        return Data(bytes: output, count: length)
    }
}
