import XCTest
@testable import WatchDotCore

final class AvatarAnimationTests: XCTestCase {
    func testDocumentedRowsAndDurations() {
        XCTAssertEqual(AvatarAnimation.idle.row, 0)
        XCTAssertEqual(AvatarAnimation.listening.row, 6)
        XCTAssertEqual(AvatarAnimation.working.row, 7)
        XCTAssertEqual(AvatarAnimation.replied.row, 8)
        XCTAssertEqual(AvatarAnimation.failed.row, 5)
        XCTAssertEqual(AvatarAnimation.idle.durationsMilliseconds, [280, 110, 110, 140, 140, 320])
        XCTAssertEqual(AvatarAnimation.listening.durationsMilliseconds, [150, 150, 150, 150, 150, 260])
        XCTAssertEqual(AvatarAnimation.working.durationsMilliseconds, [120, 120, 120, 120, 120, 220])
        XCTAssertEqual(AvatarAnimation.replied.durationsMilliseconds, [150, 150, 150, 150, 150, 280])
        XCTAssertEqual(AvatarAnimation.failed.durationsMilliseconds, [140, 140, 140, 140, 140, 140, 140, 240])
    }

    func testEveryFrameBoundaryAndCycleUsesFixedGrid() {
        for animation in AvatarAnimation.allCases {
            XCTAssertLessThan(animation.row, AvatarAnimation.rows)
            XCTAssertLessThanOrEqual(animation.durationsMilliseconds.count, AvatarAnimation.columns)
            let duration = animation.durationsMilliseconds.reduce(0, +)
            for millisecond in 0..<(duration * 2) {
                let position = millisecond % duration
                let expected = animation.durationsMilliseconds.indices.first { index in
                    position < animation.durationsMilliseconds.prefix(index + 1).reduce(0, +)
                }
                XCTAssertEqual(animation.frame(at: (Double(millisecond) + 0.1) / 1_000), expected)
            }
        }
        XCTAssertEqual(AvatarAnimation.columns * AvatarAnimation.cellWidth, 1536)
        XCTAssertEqual(AvatarAnimation.rows * AvatarAnimation.cellHeight, 2288)
    }

    func testInactiveReducedMotionAndAlwaysOnShowIdle() {
        XCTAssertEqual(AvatarAnimation.displayed(.working, active: false, reduceMotion: false, luminanceReduced: false), .idle)
        XCTAssertEqual(AvatarAnimation.displayed(.working, active: true, reduceMotion: true, luminanceReduced: false), .idle)
        XCTAssertEqual(AvatarAnimation.displayed(.working, active: true, reduceMotion: false, luminanceReduced: true), .idle)
        XCTAssertEqual(AvatarAnimation.displayed(.working, active: true, reduceMotion: false, luminanceReduced: false), .working)
    }

    func testInvalidOrInitialTimeUsesFirstFrame() {
        for value in [Double.nan, .infinity, -.infinity, -1, 0] {
            XCTAssertEqual(AvatarAnimation.idle.frame(at: value), 0)
        }
    }
}
