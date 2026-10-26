public struct SpriteAtlasLayout: Equatable, Sendable {
    public struct Crop: Equatable, Sendable {
        public let x: Int
        public let y: Int
        public let width: Int
        public let height: Int
    }

    public let width: Int
    public let height: Int

    public init?(width: Int, height: Int) {
        guard width == 1536, height == 1872 || height == 2288 else { return nil }
        self.width = width
        self.height = height
    }

    public func crop(minX: Int, minY: Int, maxX: Int, maxY: Int) -> Crop? {
        guard minX >= 0, minY >= 0, maxX > minX, maxY > minY,
              maxX <= AvatarAnimation.cellWidth, maxY <= AvatarAnimation.cellHeight else { return nil }
        let x = max(0, minX - 2)
        let y = max(0, minY - 2)
        return Crop(x: x, y: y, width: min(AvatarAnimation.cellWidth, maxX + 2) - x,
                    height: min(AvatarAnimation.cellHeight, maxY + 2) - y)
    }
}
