import CoreGraphics
import Foundation
import ImageIO
import libwebp

/// Serializes bounded decoding work away from the UI actor.
public actor PetImageValidator {
    public static let shared = PetImageValidator()
    private let supportsNativeWebP: Bool

    init(supportsNativeWebP: Bool = (CGImageSourceCopyTypeIdentifiers() as? [String] ?? [])
        .contains(PetImageFormat.webP.typeIdentifier)) {
        self.supportsNativeWebP = supportsNativeWebP
    }

    public func validate(data: Data, mimeType: String) throws -> PetImagePayload {
        try Task.checkCancellation()
        let format = try PetImageDownloader.validateEnvelope(data: data, mimeType: mimeType)
        let payload = if format == .webP && !supportsNativeWebP {
            try PetWebPDecoder.decode(data)
        } else {
            try PetImageDownloader.validate(data: data, mimeType: mimeType)
        }
        try Task.checkCancellation()
        return payload
    }
}

enum PetWebPDecoder {
    static func decode(_ data: Data) throws -> PetImagePayload {
        _ = try PetImageDownloader.validateEnvelope(data: data, mimeType: "image/webp")
        var features = WebPBitstreamFeatures()
        let status = data.withUnsafeBytes {
            WebPGetFeatures($0.bindMemory(to: UInt8.self).baseAddress, data.count, &features)
        }
        guard status == VP8_STATUS_OK else { throw PetImageDownloadError.invalidImage }
        guard features.has_animation == 0 else { throw PetImageDownloadError.animatedImage }
        let width = Int(features.width), height = Int(features.height)
        guard width == 1536, height == 1872 || height == 2288 else {
            throw PetImageDownloadError.dimensions
        }
        try Task.checkCancellation()
        let stride = width * 4
        let byteCount = stride * height
        var pixels = Data(count: byteCount)
        let decoded = pixels.withUnsafeMutableBytes { destination in
            data.withUnsafeBytes { source in
                WebPDecodeRGBAInto(source.bindMemory(to: UInt8.self).baseAddress, data.count,
                    destination.bindMemory(to: UInt8.self).baseAddress, byteCount, Int32(stride)) != nil
            }
        }
        guard decoded else { throw PetImageDownloadError.invalidImage }
        try Task.checkCancellation()
        guard let provider = CGDataProvider(data: pixels as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: stride, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider,
                decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw PetImageDownloadError.invalidImage
        }
        let png = try encodePNG(image)
        return PetImagePayload(data: png, format: .png, width: width, height: height)
    }

    private static func encodePNG(_ image: CGImage) throws -> Data {
        let output = BoundedPNGOutput()
        var callbacks = CGDataConsumerCallbacks(putBytes: { info, bytes, count in
            guard let info else { return 0 }
            let output = Unmanaged<BoundedPNGOutput>.fromOpaque(info).takeUnretainedValue()
            guard count <= PetImageDownloader.maximumBytes - output.data.count else {
                output.tooLarge = true
                return 0
            }
            output.data.append(bytes.assumingMemoryBound(to: UInt8.self), count: count)
            return count
        }, releaseConsumer: nil)
        guard let consumer = CGDataConsumer(info: Unmanaged.passUnretained(output).toOpaque(), cbks: &callbacks),
              let destination = CGImageDestinationCreateWithDataConsumer(consumer, "public.png" as CFString, 1, nil) else {
            throw PetImageDownloadError.invalidImage
        }
        CGImageDestinationAddImage(destination, image, nil)
        let complete = CGImageDestinationFinalize(destination)
        if output.tooLarge { throw PetImageDownloadError.tooLarge }
        guard complete else { throw PetImageDownloadError.invalidImage }
        return output.data
    }
}

private final class BoundedPNGOutput {
    var data = Data()
    var tooLarge = false
}
