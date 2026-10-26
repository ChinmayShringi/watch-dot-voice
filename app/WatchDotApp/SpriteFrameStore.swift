import SwiftUI
import ImageIO
import UniformTypeIdentifiers

struct SpriteFrames: @unchecked Sendable {
    let poster: CGImage
    let rows: [Int: [CGImage]]

    func image(animation: AvatarAnimation, frame: Int) -> CGImage {
        guard let images = rows[animation.row], images.indices.contains(frame) else { return poster }
        return images[frame]
    }

    var posterOnly: Self { Self(poster: poster, rows: [:]) }
}

@MainActor
final class SpriteFrameStore: ObservableObject {
    static let shared = SpriteFrameStore()
    @Published private(set) var generation = UUID()
    private let decoder = SpriteDecoder()
    private var frames: [String: SpriteFrames] = [:]
    private var posters: [String: SpriteFrames] = [:]
    private var frameOrder: [String] = []
    private var posterOrder: [String] = []
    private var requests: [UUID: Task<SpriteFrames, Error>] = [:]

    func purge() {
        for request in requests.values { request.cancel() }
        requests = [:]
        frames = [:]
        posters = [:]
        frameOrder = []
        posterOrder = []
        generation = UUID()
    }

    func cachedPoster(atlasURL: URL?) -> SpriteFrames? {
        posters[atlasURL?.absoluteString ?? "bundled"]
    }

    func load(atlasURL: URL?, playbackActive: Bool) async throws -> SpriteFrames {
        try Task.checkCancellation()
        let key = atlasURL?.absoluteString ?? "bundled"
        if playbackActive, let cached = frames[key] { return cached }
        if !playbackActive, let cached = posters[key] { return cached }
        let expectedGeneration = generation
        let requestID = UUID()
        let request = Task { try await decoder.decode(atlasURL: atlasURL, includeFrames: playbackActive) }
        requests = requests.merging([requestID: request]) { _, new in new }
        defer { requests = requests.filter { $0.key != requestID } }
        let decoded = try await withTaskCancellationHandler {
            try await request.value
        } onCancel: {
            request.cancel()
        }
        try Task.checkCancellation()
        guard generation == expectedGeneration else { throw CancellationError() }
        if playbackActive {
            frameOrder = Array((frameOrder.filter { $0 != key } + [key]).suffix(2))
            frames = frames.merging([key: decoded]) { _, new in new }.filter { frameOrder.contains($0.key) }
        }
        posterOrder = Array((posterOrder.filter { $0 != key } + [key]).suffix(24))
        posters = posters.merging([key: decoded.posterOnly]) { _, new in new }
            .filter { posterOrder.contains($0.key) }
        return decoded
    }
}

private actor SpriteDecoder {
    private enum DecodeError: Error { case invalidAtlas }
    private let alphaThreshold: UInt8 = 8

    func decode(atlasURL: URL?, includeFrames: Bool) throws -> SpriteFrames {
        try Task.checkCancellation()
        let (pixels, layout) = try readPixels(atlasURL: atlasURL)
        let crop = try contentBounds(pixels: pixels, layout: layout)
        let animations: [AvatarAnimation] = includeFrames ? AvatarAnimation.allCases : [.idle]
        let rows = try Dictionary(uniqueKeysWithValues: animations.map { animation in
            let count = includeFrames ? animation.durationsMilliseconds.count : 1
            let images = try (0..<count).map { frame in
                try Task.checkCancellation()
                return try copyFrame(pixels: pixels, layout: layout, crop: crop, row: animation.row, frame: frame)
            }
            return (animation.row, images)
        })
        guard let poster = rows[AvatarAnimation.idle.row]?.first else { throw DecodeError.invalidAtlas }
        return SpriteFrames(poster: poster, rows: includeFrames ? rows : [:])
    }

    private func readPixels(atlasURL: URL?) throws -> ([UInt8], SpriteAtlasLayout) {
        try autoreleasepool {
            let image = try sourceImage(atlasURL: atlasURL)
            guard let layout = SpriteAtlasLayout(width: image.width, height: image.height) else {
                throw DecodeError.invalidAtlas
            }
            return (try rgbaPixels(image), layout)
        }
    }

    private func sourceImage(atlasURL: URL?) throws -> CGImage {
        guard let atlasURL else {
            guard let image = UIImage(named: "AvatarAtlas")?.cgImage else { throw DecodeError.invalidAtlas }
            return image
        }
        guard atlasURL.isFileURL else { throw DecodeError.invalidAtlas }
        let values = try atlasURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard values.isRegularFile == true, let size = values.fileSize, size > 0, size <= 16 * 1024 * 1024,
              let source = CGImageSourceCreateWithURL(atlasURL as CFURL, options),
              CGImageSourceGetCount(source) == 1,
              let type = CGImageSourceGetType(source) as String?,
              [UTType.png.identifier, UTType.webP.identifier].contains(type),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, options) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              SpriteAtlasLayout(width: width, height: height) != nil,
              let image = CGImageSourceCreateImageAtIndex(source, 0, options) else { throw DecodeError.invalidAtlas }
        return image
    }

    private func rgbaPixels(_ image: CGImage) throws -> [UInt8] {
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        try pixels.withUnsafeMutableBytes { buffer in
            guard let context = CGContext(data: buffer.baseAddress, width: image.width, height: image.height,
                bitsPerComponent: 8, bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue)
            else { throw DecodeError.invalidAtlas }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        return pixels
    }

    private func contentBounds(pixels: [UInt8], layout: SpriteAtlasLayout) throws -> SpriteAtlasLayout.Crop {
        var minX = AvatarAnimation.cellWidth, minY = AvatarAnimation.cellHeight
        var maxX = 0, maxY = 0
        for animation in AvatarAnimation.allCases {
            for frame in animation.durationsMilliseconds.indices {
                try Task.checkCancellation()
                for y in 0..<AvatarAnimation.cellHeight {
                    for x in 0..<AvatarAnimation.cellWidth {
                        let atlasX = frame * AvatarAnimation.cellWidth + x
                        let atlasY = animation.row * AvatarAnimation.cellHeight + y
                        if pixels[(atlasY * layout.width + atlasX) * 4 + 3] > alphaThreshold {
                            minX = min(minX, x); minY = min(minY, y)
                            maxX = max(maxX, x + 1); maxY = max(maxY, y + 1)
                        }
                    }
                }
            }
        }
        guard let crop = layout.crop(minX: minX, minY: minY, maxX: maxX, maxY: maxY) else {
            throw DecodeError.invalidAtlas
        }
        return crop
    }

    private func copyFrame(pixels: [UInt8], layout: SpriteAtlasLayout, crop: SpriteAtlasLayout.Crop,
                           row: Int, frame: Int) throws -> CGImage {
        let data = Data((0..<crop.height).flatMap { y -> ArraySlice<UInt8> in
            let x = frame * AvatarAnimation.cellWidth + crop.x
            let atlasY = row * AvatarAnimation.cellHeight + crop.y + y
            let start = (atlasY * layout.width + x) * 4
            return pixels[start..<(start + crop.width * 4)]
        })
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(width: crop.width, height: crop.height, bitsPerComponent: 8, bitsPerPixel: 32,
                bytesPerRow: crop.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Big.rawValue |
                    CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider,
                decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw DecodeError.invalidAtlas }
        return image
    }
}
