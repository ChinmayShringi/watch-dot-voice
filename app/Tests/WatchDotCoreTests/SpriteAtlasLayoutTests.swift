import XCTest
@testable import WatchDotCore

final class SpriteAtlasLayoutTests: XCTestCase {
    func testOnlyKnownNineAndElevenRowAtlasesAreAccepted() {
        XCTAssertNotNil(SpriteAtlasLayout(width: 1536, height: 1872))
        XCTAssertNotNil(SpriteAtlasLayout(width: 1536, height: 2288))
        for dimensions in [(0, 0), (1535, 2288), (1536, 2080), (3072, 4576), (1536, Int.max)] {
            XCTAssertNil(SpriteAtlasLayout(width: dimensions.0, height: dimensions.1))
        }
    }

    func testEveryUsedFrameFitsBothContracts() throws {
        for height in [1872, 2288] {
            let atlas = try XCTUnwrap(SpriteAtlasLayout(width: 1536, height: height))
            for animation in AvatarAnimation.allCases {
                XCTAssertLessThanOrEqual((animation.row + 1) * AvatarAnimation.cellHeight, atlas.height)
                XCTAssertLessThanOrEqual(animation.durationsMilliseconds.count * AvatarAnimation.cellWidth, atlas.width)
            }
        }
    }

    func testGlobalUnionHasTwoPixelMargin() throws {
        let atlas = try XCTUnwrap(SpriteAtlasLayout(width: 1536, height: 2288))
        let crop = try XCTUnwrap(atlas.crop(minX: 20, minY: 5, maxX: 172, maxY: 203))
        XCTAssertEqual(crop.x, 18)
        XCTAssertEqual(crop.y, 3)
        XCTAssertEqual(crop.width, 156)
        XCTAssertEqual(crop.height, 202)
    }

    func testMarginStopsAtCellEdgesAndRejectsEmptyOrInvalidBounds() throws {
        let atlas = try XCTUnwrap(SpriteAtlasLayout(width: 1536, height: 1872))
        let crop = try XCTUnwrap(atlas.crop(minX: 0, minY: 0, maxX: 192, maxY: 208))
        XCTAssertEqual(crop.width, 192)
        XCTAssertEqual(crop.height, 208)
        for bounds in [(0, 0, 0, 0), (-1, 0, 10, 10), (0, 0, 193, 208), (0, 0, 192, 209)] {
            XCTAssertNil(atlas.crop(minX: bounds.0, minY: bounds.1, maxX: bounds.2, maxY: bounds.3))
        }
    }
}
