import XCTest
@testable import WatchDotCore

final class AvatarPresentationTests: XCTestCase {
    func testBaselineRepliesDoNotOpenReader() {
        let historical = reply("History")
        let state = AvatarPresentation(baselineReplies: [historical])
            .receiving([historical], canPresent: true)
        XCTAssertTrue(state.visibleReplies.isEmpty)
        XCTAssertTrue(state.pendingReplies.isEmpty)
    }

    func testNewReplyPresentsOnceAndPreservesInputState() {
        let initial = AvatarPresentation()
        let answer = reply("Answer")
        let presented = initial.receiving([answer, answer], canPresent: true)
        XCTAssertEqual(presented.visibleReplies, [answer])
        XCTAssertEqual(presented.receiving([answer], canPresent: true), presented)
        XCTAssertTrue(initial.visibleReplies.isEmpty)
        XCTAssertTrue(initial.seenIDs.isEmpty)
    }

    func testBlockedRepliesQueueAndPresentTogetherWhenAllowed() {
        let first = reply("First")
        let second = reply("Second")
        let waiting = AvatarPresentation().receiving([first, second], canPresent: false)
        XCTAssertTrue(waiting.visibleReplies.isEmpty)
        XCTAssertEqual(waiting.pendingReplies, [first, second])
        XCTAssertEqual(waiting.presentingPending(ifAllowed: false), waiting)
        let shown = waiting.presentingPending(ifAllowed: true)
        XCTAssertEqual(shown.visibleReplies, [first, second])
        XCTAssertTrue(shown.pendingReplies.isEmpty)
    }

    func testNewReplyAppendsToExistingReader() {
        let first = reply("First")
        let second = reply("Second")
        let state = AvatarPresentation().receiving([first], canPresent: true)
            .receiving([first, second], canPresent: true)
        XCTAssertEqual(state.visibleReplies, [first, second])
    }

    func testSameIDUpdatesVisibleAndQueuedTextWithoutDuplicates() {
        let first = reply("First")
        let changed = reply("Expanded answer", id: first.id)
        let visible = AvatarPresentation().receiving([first], canPresent: true)
            .receiving([changed], canPresent: false)
        XCTAssertEqual(visible.visibleReplies, [changed])
        XCTAssertTrue(visible.pendingReplies.isEmpty)
        let waiting = AvatarPresentation().receiving([first], canPresent: false)
            .receiving([changed, changed], canPresent: false)
        XCTAssertEqual(waiting.pendingReplies, [changed])
    }

    func testBlockedNewReplyDoesNotInterruptVisibleReader() {
        let first = reply("First")
        let second = reply("Second")
        let waiting = AvatarPresentation().receiving([first], canPresent: true)
            .receiving([second], canPresent: false)
        XCTAssertEqual(waiting.visibleReplies, [first])
        XCTAssertEqual(waiting.pendingReplies, [second])
        XCTAssertEqual(waiting.presentingPending(ifAllowed: true).visibleReplies, [first, second])
    }

    func testDismissedRepliesDoNotResurrectEvenWithUpdatedText() {
        let first = reply("First")
        let closed = AvatarPresentation().receiving([first], canPresent: true).dismissing()
        let repeated = closed.receiving([reply("Updated", id: first.id)], canPresent: true)
        XCTAssertTrue(repeated.visibleReplies.isEmpty)
        XCTAssertTrue(repeated.pendingReplies.isEmpty)
    }

    func testDismissPreservesBlockedNewReplies() {
        let first = reply("First")
        let second = reply("Second")
        let closed = AvatarPresentation().receiving([first], canPresent: true)
            .receiving([second], canPresent: false).dismissing()
        XCTAssertTrue(closed.presentingPending(ifAllowed: true).visibleReplies.isEmpty)
        XCTAssertEqual(closed.dismissalCompleted(canPresent: true).visibleReplies, [second])
    }

    func testReplyDuringDismissalSurvivesRepeatedCloseAndPresentsOnceAfterCompletion() {
        let first = reply("First")
        let second = reply("Second")
        let closing = AvatarPresentation().receiving([first], canPresent: true).dismissing()
        let waiting = closing.receiving([first, second], canPresent: true)
        XCTAssertTrue(waiting.isDismissing)
        XCTAssertTrue(waiting.visibleReplies.isEmpty)
        XCTAssertEqual(waiting.pendingReplies, [second])
        XCTAssertEqual(waiting.dismissing(), waiting)
        XCTAssertEqual(waiting.presentingPending(ifAllowed: true), waiting)

        let shown = waiting.dismissing().dismissalCompleted(canPresent: true)
        XCTAssertFalse(shown.isDismissing)
        XCTAssertEqual(shown.visibleReplies, [second])
        XCTAssertTrue(shown.pendingReplies.isEmpty)
        XCTAssertEqual(shown.receiving([first, second], canPresent: true), shown)
        XCTAssertEqual(shown.dismissalCompleted(canPresent: true), shown)
    }

    func testDismissalCompletionWhileBlockedPreservesUpdatedPendingReply() {
        let first = reply("First")
        let second = reply("Second")
        let updated = reply("Expanded second", id: second.id)
        let waiting = AvatarPresentation().receiving([first], canPresent: true).dismissing()
            .receiving([second, updated], canPresent: true)
            .dismissalCompleted(canPresent: false)
        XCTAssertFalse(waiting.isDismissing)
        XCTAssertTrue(waiting.visibleReplies.isEmpty)
        XCTAssertEqual(waiting.pendingReplies, [updated])
        XCTAssertEqual(waiting.presentingPending(ifAllowed: true).visibleReplies, [updated])
    }

    func testResetDuringDismissalClearsBoundaryAndPriorReplies() {
        let prior = reply("Prior account")
        let closing = AvatarPresentation().receiving([prior], canPresent: true).dismissing()
        XCTAssertTrue(closing.isDismissing)
        let reset = AvatarPresentation(baselineReplies: [prior])
        XCTAssertFalse(reset.isDismissing)
        XCTAssertTrue(reset.visibleReplies.isEmpty)
        XCTAssertTrue(reset.pendingReplies.isEmpty)
        XCTAssertEqual(reset.dismissalCompleted(canPresent: true), reset)
        XCTAssertTrue(reset.receiving([prior], canPresent: true).visibleReplies.isEmpty)
    }

    func testResetClearsPriorConversationAndAcceptsNewEvents() {
        let prior = reply("Prior account")
        let initial = AvatarPresentation().receiving([prior], canPresent: false)
        let reset = AvatarPresentation()
        XCTAssertFalse(initial.pendingReplies.isEmpty)
        XCTAssertTrue(reset.pendingReplies.isEmpty)
        XCTAssertTrue(reset.seenIDs.isEmpty)
        XCTAssertEqual(reset.receiving([prior], canPresent: true).visibleReplies, [prior])
    }

    func testUserAndBlankMessagesCannotOpenReader() {
        let invalid = [ChatMessage(role: .user, text: "Input"), reply(" \n")]
        XCTAssertEqual(AvatarPresentation().receiving(invalid, canPresent: true), AvatarPresentation())
    }

    private func reply(_ text: String, id: UUID = UUID()) -> ChatMessage {
        ChatMessage(id: id, role: .assistant, text: text)
    }
}
