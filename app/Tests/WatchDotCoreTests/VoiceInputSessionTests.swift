import XCTest
@testable import WatchDotCore

@MainActor private final class VoiceRecorderStub: VoiceRecording {
    var level: Double = 0.4
    var recordingIssue: VoiceInputIssue?
    var clip = VoiceClip(data: Data([1, 2, 3]), duration: 2, hasSpeech: true)
    var startError: VoiceInputIssue?
    var holdPermission = false
    var permission: CheckedContinuation<Void, Never>?
    var starts = 0
    var stops = 0
    var cancels = 0
    func start() async throws {
        starts += 1
        if holdPermission { await withCheckedContinuation { permission = $0 } }
        if let startError { throw startError }
    }
    func stop() throws -> VoiceClip { stops += 1; return clip }
    func cancel() { cancels += 1 }
    func release() { permission?.resume(); permission = nil }
}

@MainActor final class VoiceInputSessionTests: XCTestCase {
    private func settle(_ predicate: () -> Bool) async throws {
        for _ in 0..<100 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        XCTFail("Expected lifecycle transition")
    }

    func testRepeatedTapsStopAndSendExactlyOnce() async throws {
        let recorder = VoiceRecorderStub()
        var sends: [String] = []
        let session = VoiceInputSession(recorder: recorder, prepare: {
            VoiceTurn(transcribe: { _ in "  Hello Dot  " }, send: { sends = sends + [$0]; return true })
        })
        session.tap(); session.tap()
        try await settle { session.phase == .listening }
        session.sampleRecording()
        XCTAssertEqual(session.level, 0.4)
        session.tap(); session.tap(); session.tap()
        try await settle { session.phase == .idle }
        XCTAssertEqual(recorder.starts, 1)
        XCTAssertEqual(recorder.stops, 1)
        XCTAssertEqual(sends, ["Hello Dot"])
        XCTAssertNil(session.retainedTranscript)
    }

    func testCancelDuringNonCooperativePermissionDoesNotRecordOrSend() async throws {
        let recorder = VoiceRecorderStub(); recorder.holdPermission = true
        var sends = 0
        let session = VoiceInputSession(recorder: recorder, prepare: {
            VoiceTurn(transcribe: { _ in "text" }, send: { _ in sends += 1; return true })
        })
        session.tap()
        try await settle { recorder.permission != nil }
        session.cancel(); recorder.release()
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertEqual(session.phase, .idle)
        XCTAssertEqual(recorder.stops, 0)
        XCTAssertEqual(sends, 0)
    }

    func testCancelledNonCooperativeTranscriptionCannotSendIntoNewOperation() async throws {
        let recorder = VoiceRecorderStub()
        var continuation: CheckedContinuation<String, Never>?
        var sends = 0
        let session = VoiceInputSession(recorder: recorder, prepare: {
            VoiceTurn(transcribe: { _ in await withCheckedContinuation { continuation = $0 } },
                      send: { _ in sends += 1; return true })
        })
        session.tap(); try await settle { session.phase == .listening }; session.tap()
        try await settle { continuation != nil }
        session.cancel(); session.tap()
        try await settle { session.phase == .listening }
        continuation?.resume(returning: "stale transcript")
        try await Task.sleep(for: .milliseconds(10))
        XCTAssertEqual(session.phase, .listening)
        XCTAssertEqual(sends, 0)
        session.cancel()
    }

    func testSilenceInvalidAudioAndEmptyTranscriptNeverSend() async throws {
        let clips = [VoiceClip(data: Data([1]), duration: 1, hasSpeech: false),
                     VoiceClip(data: Data(), duration: 1, hasSpeech: true),
                     VoiceClip(data: Data([1]), duration: 1, hasSpeech: true)]
        for clip in clips {
            let recorder = VoiceRecorderStub(); recorder.clip = clip
            var sends = 0
            let session = VoiceInputSession(recorder: recorder, prepare: {
                VoiceTurn(transcribe: { _ in " \n " }, send: { _ in sends += 1; return true })
            })
            session.tap(); try await settle { session.phase == .listening }; session.tap()
            try await settle { session.phase == .failed }
            XCTAssertEqual(sends, 0)
            XCTAssertNil(session.retainedTranscript)
        }
    }

    func testPermissionFailureUsesSafeEnglishAndNoUpload() async throws {
        let recorder = VoiceRecorderStub(); recorder.startError = .permissionDenied
        var uploaded = false
        let session = VoiceInputSession(recorder: recorder, prepare: {
            VoiceTurn(transcribe: { _ in uploaded = true; return "text" }, send: { _ in true })
        })
        session.tap(); try await settle { session.phase == .failed }
        XCTAssertEqual(session.errorMessage, VoiceInputIssue.permissionDenied.message)
        XCTAssertFalse(uploaded)
    }

    func testLimitStopsOnceAndInterruptionFailsImmediately() async throws {
        let recorder = VoiceRecorderStub()
        var date = Date()
        var sends = 0
        let session = VoiceInputSession(recorder: recorder, prepare: {
            VoiceTurn(transcribe: { _ in "limit" }, send: { _ in sends += 1; return true })
        }, now: { date })
        session.tap(); try await settle { session.phase == .listening }
        date = date.addingTimeInterval(60)
        session.sampleRecording(); session.sampleRecording()
        try await settle { session.phase == .idle }
        XCTAssertEqual(recorder.stops, 1); XCTAssertEqual(sends, 1)
        session.tap(); try await settle { session.phase == .listening }
        recorder.recordingIssue = .interrupted
        session.sampleRecording()
        XCTAssertEqual(session.phase, .failed)
        XCTAssertEqual(session.errorMessage, VoiceInputIssue.interrupted.message)
        XCTAssertEqual(recorder.stops, 1)
    }

    func testBusySendRetainsReviewTextWithoutRetryAndCancelClearsIt() async throws {
        let recorder = VoiceRecorderStub()
        var sends = 0
        let session = VoiceInputSession(recorder: recorder, prepare: {
            VoiceTurn(transcribe: { _ in "review this" }, send: { _ in sends += 1; return false })
        })
        session.tap(); try await settle { session.phase == .listening }; session.tap()
        try await settle { session.phase == .failed }
        XCTAssertEqual(session.retainedTranscript, "review this")
        XCTAssertEqual(sends, 1)
        session.cancel()
        XCTAssertNil(session.retainedTranscript)
        XCTAssertEqual(sends, 1)
    }

    func testPreparationFailsBeforeMicrophonePermission() {
        let recorder = VoiceRecorderStub()
        let session = VoiceInputSession(recorder: recorder, prepare: { throw VoiceInputIssue.sessionChanged })
        session.tap()
        XCTAssertEqual(session.phase, .failed)
        XCTAssertEqual(recorder.starts, 0)
    }
}
