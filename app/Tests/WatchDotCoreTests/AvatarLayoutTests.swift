import XCTest
@testable import WatchDotCore

final class AvatarLayoutTests: XCTestCase {
    func testInvalidAndCompressedSpaceCannotProduceNegativeOrNonfiniteSize() {
        for appearance in CompanionAppearance.allCases {
            for dimension in [-1.0, 0, Double.infinity, -Double.infinity, Double.nan] {
                XCTAssertEqual(AvatarLayout.glyphSide(width: dimension, height: 180, appearance: appearance), 0)
                XCTAssertEqual(AvatarLayout.glyphSide(width: 180, height: dimension, appearance: appearance), 0)
            }
            XCTAssertEqual(AvatarLayout.glyphSide(width: 4, height: 180, appearance: appearance), 0)
            XCTAssertEqual(AvatarLayout.glyphSide(width: 180, height: 8, appearance: appearance), 0)
        }
    }

    func testFullListeningScaleAndBobStayInsideAllocatedCanvas() {
        let canvases = [(160.0, 100.0), (160, 180), (192, 210), (192, 80), (80, 192)]
        for (width, height) in canvases {
            for appearance in CompanionAppearance.allCases {
                let side = AvatarLayout.glyphSide(width: width, height: height, appearance: appearance)
                for point in boundaryPoints(for: appearance) {
                    let x = abs(point.x * side * 1.06)
                    let y = abs(point.y * side * 1.06) + 2
                    XCTAssertLessThanOrEqual(x, width / 2 - 2 + 0.000001)
                    XCTAssertLessThanOrEqual(y, height / 2 - 2 + 0.000001)
                }
            }
        }
    }

    func testOriginalCharactersGrowWithinRepresentativeHomeAndPickerAllocations() {
        for (width, height) in [(160.0, 140.0), (184, 180), (192, 210)] {
            for appearance in [CompanionAppearance.pebble, .orbit, .pixel] {
                let priorSide = min(width, height) * 0.8
                let side = AvatarLayout.glyphSide(width: width, height: height, appearance: appearance)
                XCTAssertGreaterThan(side / priorSide, 1.04)
            }
        }
    }

    func testMissingSpriteUsesTheSameBoundsAsPebble() {
        XCTAssertEqual(AvatarLayout.glyphSide(width: 160, height: 180, appearance: .sprite),
                       AvatarLayout.glyphSide(width: 160, height: 180, appearance: .pebble))
    }

    private func boundaryPoints(for appearance: CompanionAppearance) -> [(x: Double, y: Double)] {
        switch appearance {
        case .sprite, .pebble:
            let angle = -7 * Double.pi / 180
            return [-0.44, 0.44].flatMap { x in
                [-0.47, 0.47].map { y in
                    (x * cos(angle) - y * sin(angle), x * sin(angle) + y * cos(angle))
                }
            }
        case .orbit:
            return (0..<360).flatMap { degrees -> [(x: Double, y: Double)] in
                let angle = Double(degrees) * Double.pi / 180
                let center = (x: 0.48 * cos(angle), y: 0.48 * sin(angle))
                return [(0.4975 * cos(angle), 0.4975 * sin(angle)),
                        (center.x + 0.05, center.y), (center.x - 0.05, center.y),
                        (center.x, center.y + 0.05), (center.x, center.y - 0.05)]
            }
        case .pixel:
            return [(-0.44, -0.44), (-0.44, 0.44), (0.44, -0.44), (0.44, 0.44)]
        }
    }
}
