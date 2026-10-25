import XCTest
@testable import WatchDotCore

final class HomeInteractionTests: XCTestCase {
    private func recovery(delivery: DeliveryState = .idle, storage: String? = nil,
                          canSend: Bool = true, retry: Bool = false, readOnly: Bool = false,
                          discard: Bool = false, save: Bool = false) -> HomeRecovery? {
        HomeRecovery(delivery: delivery, storageIssue: storage, canSend: canSend, canRetry: retry,
            retryIsReadOnly: readOnly, canDiscard: discard, canRetrySaving: save)
    }

    func testReadyHomeHasNoRecovery() {
        XCTAssertNil(recovery())
        XCTAssertNil(recovery(delivery: .answered))
        XCTAssertNil(recovery(delivery: .waiting))
    }

    func testFailureShowsSafeReasonAndReceiptOnlyRetryTitle() {
        let state = recovery(delivery: .failed("Your message may have arrived."), canSend: false,
                             retry: true, readOnly: true)
        XCTAssertEqual(state?.reason, "Your message may have arrived.")
        XCTAssertEqual(state?.retryTitle, "Check for Reply")
        XCTAssertEqual(state?.canDiscard, false)
        XCTAssertEqual(state?.canSave, false)
    }

    func testKnownUnsentMessageOffersExplicitResumeAndDiscard() {
        let state = recovery(delivery: .failed("Connection unavailable."), canSend: false,
                             retry: true, discard: true)
        XCTAssertEqual(state?.retryTitle, "Resume Message")
        XCTAssertEqual(state?.canDiscard, true)
    }

    func testStorageFailureTakesPriorityAndCannotTriggerSendOrDiscard() {
        let state = recovery(delivery: .failed("Delivery issue"), storage: "Save the history.",
                             canSend: false, retry: true, discard: true, save: true)
        XCTAssertEqual(state?.reason, "Save the history.")
        XCTAssertEqual(state?.canSave, true)
        XCTAssertNil(state?.retryTitle)
        XCTAssertEqual(state?.canDiscard, false)
    }

    func testUnreadableHistoryOffersNoSaveAction() {
        let state = recovery(storage: "History could not be read. Reopen the app.", canSend: false)
        XCTAssertEqual(state?.canSave, false)
        XCTAssertNil(state?.retryTitle)
    }

    func testActiveTurnCannotBeDiscarded() {
        for delivery in [DeliveryState.sending, .waiting] {
            let state = recovery(delivery: delivery, canSend: false, discard: true)
            XCTAssertNotNil(state)
            XCTAssertEqual(state?.canDiscard, false)
            XCTAssertNil(state?.retryTitle)
        }
    }

    func testCancelledAndOfflineTurnsExposeRecoveryWithoutAutomaticRetry() {
        XCTAssertNotNil(recovery(delivery: .cancelled, canSend: false))
        XCTAssertNotNil(recovery(delivery: .waitingForConnection, canSend: false))
        XCTAssertNil(recovery(delivery: .waitingForConnection, canSend: false)?.retryTitle)
    }

    func testListeningAccessibilityDescribesSendingAndWholeSeconds() {
        let state = VoiceAccessibility(phase: .listening, name: "Companion", elapsed: 2.9,
            recoveryReason: nil, isRealConnection: true)
        XCTAssertEqual(state.label, "Stop recording and send")
        XCTAssertEqual(state.hint, "Sends the recording for transcription and delivers the message.")
        XCTAssertEqual(state.value, "Listening, 2 of 60 seconds")
        for elapsed in [-1.0, Double.nan, .infinity] {
            XCTAssertEqual(VoiceAccessibility(phase: .listening, name: "Companion", elapsed: elapsed,
                recoveryReason: nil, isRealConnection: true).value, "Listening, 0 of 60 seconds")
        }
        XCTAssertEqual(VoiceAccessibility(phase: .listening, name: "Companion", elapsed: 70,
            recoveryReason: nil, isRealConnection: true).value, "Listening, 60 of 60 seconds")
    }

    func testBlockedAccessibilityExplainsRecoveryRatherThanRecording() {
        let state = VoiceAccessibility(phase: .idle, name: "Companion", elapsed: 0,
            recoveryReason: "Message pending", isRealConnection: true)
        XCTAssertEqual(state.label, "Review message")
        XCTAssertEqual(state.value, "Message pending")
        XCTAssertEqual(state.hint, "Opens available recovery actions.")
    }
}
