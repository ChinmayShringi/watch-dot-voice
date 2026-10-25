import XCTest
@testable import WatchDotCore

final class HistoryScrollPolicyTests: XCTestCase {
    func testInitialHistoryFollowsLatest() {
        let policy = HistoryScrollPolicy()
        XCTAssertTrue(policy.shouldFollow(layout()))
        XCTAssertTrue(policy.observing(layout()).followsLatest)
        XCTAssertNil(policy.layout)
    }

    func testGrowthPreservesPinnedIntentBeforeAndAfterNewLayout() {
        let pinned = HistoryScrollPolicy().observing(layout())
        let grown = layout(revision: 2, height: 600, bottom: 500)
        XCTAssertTrue(pinned.shouldFollow(grown))
        let pendingScroll = pinned.observing(grown)
        XCTAssertTrue(pendingScroll.followsLatest)
        XCTAssertFalse(pendingScroll.shouldFollow(grown))
        XCTAssertTrue(pendingScroll.observing(layout(revision: 2, height: 600)).followsLatest)
    }

    func testRemoteGrowthAndStatusResizeDoNotMoveHistoryReader() {
        let reading = HistoryScrollPolicy().observing(layout()).observing(layout(bottom: 400))
        XCTAssertFalse(reading.followsLatest)
        let newReply = layout(revision: 2, height: 600, bottom: 700)
        XCTAssertFalse(reading.shouldFollow(newReply))
        let resized = reading.observing(newReply)
        XCTAssertFalse(resized.followsLatest)
        XCTAssertFalse(resized.shouldFollow(layout(revision: 3, height: 650, bottom: 750)))
    }

    func testViewportAndContentSizeChangesPreserveReadingIntent() {
        let pinned = HistoryScrollPolicy().observing(layout())
        let changed = HistoryScrollLayout(revision: 1, contentHeight: 450, viewportHeight: 150, bottom: 300)
        XCTAssertTrue(pinned.shouldFollow(changed))
        XCTAssertTrue(pinned.observing(changed).followsLatest)
        let reading = pinned.observing(layout(bottom: 400))
        XCTAssertFalse(reading.shouldFollow(changed))
        XCTAssertFalse(reading.observing(changed).followsLatest)
    }

    func testInteractionPreventsFollowingAndScrollBackToEndRestoresIt() {
        let moving = HistoryScrollPolicy().observing(layout()).interacting(true)
        XCTAssertFalse(moving.shouldFollow(layout(revision: 2, height: 500, bottom: 400)))
        let reading = moving.observing(layout(bottom: 400)).interacting(false)
        XCTAssertFalse(reading.followsLatest)
        let end = reading.observing(layout())
        XCTAssertTrue(end.followsLatest)
        XCTAssertTrue(end.shouldFollow(layout(revision: 2, height: 500, bottom: 400)))
    }

    func testExplicitJumpOrSendReenablesFollowing() {
        let reading = HistoryScrollPolicy().observing(layout()).observing(layout(bottom: 400))
        let selected = reading.jumpingToLatest()
        XCTAssertTrue(selected.followsLatest)
        XCTAssertFalse(selected.isInteracting)
        XCTAssertFalse(reading.followsLatest)
    }

    func testGrowthDuringGestureCannotLeaveStaleFollowIntentAfterRelease() {
        let tracking = HistoryScrollPolicy().observing(layout()).interacting(true)
        let grown = layout(revision: 2, height: 500, bottom: 400)
        XCTAssertFalse(tracking.shouldFollow(grown))
        let stopped = tracking.observing(grown).interacting(false)
        XCTAssertFalse(stopped.followsLatest)
        XCTAssertFalse(stopped.shouldFollow(layout(revision: 3, height: 600, bottom: 500)))
        XCTAssertTrue(stopped.observing(layout(revision: 2, height: 500)).followsLatest)
    }

    func testInvalidGeometryDoesNotChangeIntentOrRequestScrolling() {
        let policy = HistoryScrollPolicy().observing(layout())
        let invalid = HistoryScrollLayout(revision: 2, contentHeight: .infinity, viewportHeight: 0, bottom: .nan)
        XCTAssertEqual(policy.observing(invalid), policy)
        XCTAssertFalse(policy.shouldFollow(invalid))
    }

    private func layout(revision: Int = 1, height: Double = 300, bottom: Double = 200) -> HistoryScrollLayout {
        HistoryScrollLayout(revision: revision, contentHeight: height, viewportHeight: 200, bottom: bottom)
    }
}
