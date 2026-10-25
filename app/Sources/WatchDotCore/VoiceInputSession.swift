import Foundation
import Combine

public enum VoiceInputIssue: Error, Equatable, LocalizedError {
    case permissionDenied, microphoneUnavailable, interrupted, noSpeech, invalidAudio
    case unavailable, sessionChanged, malformedResponse, transcriptTooLong, sendRejected
    case transcriptionHTTP(Int), challenge

    public var message: String {
        switch self {
        case .permissionDenied: "Allow microphone access in Settings, or use text input."
        case .microphoneUnavailable: "The microphone is unavailable. Try again or use text input."
        case .interrupted: "Recording was interrupted. Try again."
        case .noSpeech: "No speech was detected. Try again."
        case .invalidAudio: "The recording could not be used. Try again."
        case .unavailable: "Voice transcription is unavailable. Try again or use text input."
        case .challenge: "Voice transcription requires service verification. Use text input."
        case .transcriptionHTTP(let status):
            switch status {
            case 403: "Voice transcription access was denied (HTTP 403). Use text input."
            case 429: "Voice transcription reached a service limit (HTTP 429). Wait before trying again."
            default: "Voice transcription is unavailable (HTTP \(status)). Try again or use text input."
            }
        case .sessionChanged: "Your connection changed. Start a new recording."
        case .malformedResponse: "The transcription response could not be read. Try again."
        case .transcriptTooLong: "The transcript is too long. Try a shorter recording."
        case .sendRejected: "Your message could not be sent. Review or copy the transcript."
        }
    }
    public var errorDescription: String? { message }
}

public struct VoiceClip: Sendable {
    public let data: Data
    public let duration: TimeInterval
    public let hasSpeech: Bool
    public init(data: Data, duration: TimeInterval, hasSpeech: Bool) {
        self.data = data; self.duration = duration; self.hasSpeech = hasSpeech
    }
    func validate() throws {
        guard hasSpeech else { throw VoiceInputIssue.noSpeech }
        guard !data.isEmpty, data.count <= 2_000_000, duration.isFinite,
              duration > 0, duration <= 60 else { throw VoiceInputIssue.invalidAudio }
    }
}

@MainActor public protocol VoiceRecording: AnyObject {
    var level: Double { get }
    var recordingIssue: VoiceInputIssue? { get }
    func start() async throws
    func stop() throws -> VoiceClip
    func cancel()
}

extension VoiceRecording {
    public var recordingIssue: VoiceInputIssue? { nil }
}

@MainActor public struct VoiceTurn {
    let transcribe: @MainActor (VoiceClip) async throws -> String
    let send: @MainActor (String) -> Bool
    public init(transcribe: @escaping @MainActor (VoiceClip) async throws -> String,
                send: @escaping @MainActor (String) -> Bool) {
        self.transcribe = transcribe; self.send = send
    }
}

public enum VoiceInputPhase: Equatable { case idle, requesting, listening, transcribing, failed }

@MainActor public final class VoiceInputSession: ObservableObject {
    @Published public private(set) var phase: VoiceInputPhase = .idle
    @Published public private(set) var level: Double = 0
    @Published public private(set) var elapsed: TimeInterval = 0
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var retainedTranscript: String?
    private let recorder: any VoiceRecording
    private let prepare: @MainActor () throws -> VoiceTurn
    private let now: () -> Date
    private var operation: UUID?
    private var work: Task<Void, Never>?
    private var meter: Task<Void, Never>?
    private var turn: VoiceTurn?
    private var startedAt: Date?

    public init(recorder: any VoiceRecording, prepare: @escaping @MainActor () throws -> VoiceTurn,
                now: @escaping () -> Date = Date.init) {
        self.recorder = recorder; self.prepare = prepare; self.now = now
    }

    public func tap() {
        switch phase {
        case .idle, .failed: begin()
        case .listening: finish()
        case .requesting, .transcribing: break
        }
    }

    public func cancel() {
        operation = nil
        work?.cancel(); work = nil
        meter?.cancel(); meter = nil
        recorder.cancel()
        turn = nil; startedAt = nil
        level = 0; elapsed = 0; errorMessage = nil; retainedTranscript = nil
        phase = .idle
    }

    private func begin() {
        cancel()
        let id = UUID()
        operation = id
        do { turn = try prepare() }
        catch { fail(error, operation: id); return }
        phase = .requesting
        work = Task { [weak self] in
            guard let self else { return }
            do {
                try await self.recorder.start()
                guard self.operation == id, !Task.isCancelled else { return }
                self.startedAt = self.now()
                self.phase = .listening
                self.work = nil
                self.startMeter(operation: id)
            } catch { self.fail(error, operation: id) }
        }
    }

    private func startMeter(operation id: UUID) {
        meter = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                guard let self, self.operation == id, self.phase == .listening else { return }
                self.sampleRecording()
            }
        }
    }

    // Internal entry point permits deterministic limit/interruption tests without real-time waits.
    func sampleRecording() {
        guard phase == .listening, let id = operation, let startedAt else { return }
        if let issue = recorder.recordingIssue { fail(issue, operation: id); return }
        level = recorder.level.isFinite ? min(1, max(0, recorder.level)) : 0
        elapsed = max(0, now().timeIntervalSince(startedAt))
        if elapsed >= 60 { finish() }
    }

    private func finish() {
        guard phase == .listening, let id = operation, let turn else { return }
        phase = .transcribing
        meter?.cancel(); meter = nil; level = 0
        do {
            let clip = try recorder.stop()
            try clip.validate()
            work = Task { [weak self] in
                do {
                    let text = try await turn.transcribe(clip)
                    guard let self, self.operation == id, !Task.isCancelled else { return }
                    let transcript = try DotTranscription.validatedText(text)
                    // Consume the operation before handing off synchronously. Existing send recovery owns acceptance.
                    self.operation = nil; self.work = nil; self.turn = nil
                    if turn.send(transcript) { self.phase = .idle; self.elapsed = 0 }
                    else {
                        self.retainedTranscript = transcript
                        self.errorMessage = VoiceInputIssue.sendRejected.message
                        self.phase = .failed
                    }
                } catch { self?.fail(error, operation: id) }
            }
        } catch { fail(error, operation: id) }
    }

    private func fail(_ error: Error, operation id: UUID) {
        guard operation == id else { return }
        operation = nil
        work = nil; meter?.cancel(); meter = nil; turn = nil
        recorder.cancel(); level = 0
        errorMessage = (error as? VoiceInputIssue)?.message ?? VoiceInputIssue.unavailable.message
        phase = .failed
    }
}
