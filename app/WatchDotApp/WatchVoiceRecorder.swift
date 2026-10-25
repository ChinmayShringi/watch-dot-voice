import AVFoundation
import Foundation
import OSLog

@MainActor
final class WatchVoiceRecorder: NSObject, VoiceRecording, AVAudioRecorderDelegate {
    private static let maximumDuration: TimeInterval = 60
    private static let maximumBytes = 2_000_000
    private static let minimumDuration: TimeInterval = 0.25
    private static let directoryPrefix = "watch-dot-voice-"
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "WatchDot", category: "VoiceRecorder")
    private static var activeDirectories: Set<URL> = []

    private struct Meter {
        let level: Double
        let sampledAt: TimeInterval
        let audibleDuration: TimeInterval
        static let empty = Meter(level: 0, sampledAt: 0, audibleDuration: 0)
    }

    private let audioSession = AVAudioSession.sharedInstance()
    private let files = FileManager.default
    private var generation = UUID()
    private var requestingPermission = false
    private var recorder: AVAudioRecorder?
    private var directory: URL?
    private var sessionActive = false
    private var meter = Meter.empty
    private var meterTask: Task<Void, Never>?
    private var completed: Result<VoiceClip, VoiceInputIssue>?
    private var observers: AudioObservers?
    private var cleanupFailed = false

    var level: Double { meter.level }
    private(set) var recordingIssue: VoiceInputIssue?

    override init() {
        super.init()
        cleanupFailed = !purgeAbandonedRecordings()
        observers = AudioObservers { [weak self] in
            Task { @MainActor in self?.interrupt() }
        }
    }

    isolated deinit {
        cancel()
    }

    func start() async throws {
        guard recorder == nil, !requestingPermission else {
            throw VoiceInputIssue.microphoneUnavailable
        }
        cancel()
        cleanupFailed = !purgeAbandonedRecordings() || cleanupFailed
        guard !cleanupFailed else { throw VoiceInputIssue.microphoneUnavailable }
        let operation = UUID()
        generation = operation
        requestingPermission = true
        let permitted = await AVAudioApplication.requestRecordPermission()
        guard generation == operation, !Task.isCancelled else {
            if generation == operation { cancel() }
            throw CancellationError()
        }
        requestingPermission = false
        guard permitted else { throw VoiceInputIssue.permissionDenied }
        do {
            try recordingStep("category") { try audioSession.setCategory(.record, mode: .default) }
            try recordingStep("activation") { try audioSession.setActive(true) }
            sessionActive = true
            guard audioSession.isInputAvailable else {
                Self.report("Capture failed: input-unavailable")
                throw VoiceInputIssue.microphoneUnavailable
            }
            try beginRecording()
        } catch {
            cancel()
            throw (error as? VoiceInputIssue) ?? .microphoneUnavailable
        }
    }

    func stop() throws -> VoiceClip {
        if recorder != nil { finishRecording() }
        guard let result = completed else {
            cancel()
            throw VoiceInputIssue.invalidAudio
        }
        completed = nil
        recordingIssue = nil
        return try result.get()
    }

    func cancel() {
        generation = UUID()
        requestingPermission = false
        completed = nil
        recordingIssue = nil
        let deactivated = discardCapture()
        cleanupFailed = !removeRecordingDirectory()
        if cleanupFailed || !deactivated { recordingIssue = .microphoneUnavailable }
    }

    private func beginRecording() throws {
        let folder = files.temporaryDirectory.appendingPathComponent(
            Self.directoryPrefix + UUID().uuidString, isDirectory: true)
        directory = folder
        Self.activeDirectories = Self.activeDirectories.union([folder])
        try recordingStep("create-directory") {
            try files.createDirectory(at: folder, withIntermediateDirectories: false,
                attributes: [.protectionKey: FileProtectionType.complete])
        }
        let url = folder.appendingPathComponent("speech.m4a")
        let capture = try recordingStep("create-recorder") {
            try AVAudioRecorder(url: url, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 16_000,
                AVNumberOfChannelsKey: 1,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
            ])
        }
        recorder = capture
        capture.delegate = self
        capture.isMeteringEnabled = true
        guard capture.prepareToRecord() else {
            Self.report("Capture failed: prepare-recorder")
            throw VoiceInputIssue.microphoneUnavailable
        }
        try recordingStep("protect-file") {
            try files.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
        }
        guard capture.record(forDuration: Self.maximumDuration) else {
            Self.report("Capture failed: start-recorder")
            throw VoiceInputIssue.microphoneUnavailable
        }
        Self.logger.notice("Capture started")
        meterTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(100)) }
                catch { return }
                self?.sampleMeter()
            }
        }
    }

    private func sampleMeter() {
        guard let recorder, recorder.isRecording else { return }
        recorder.updateMeters()
        let average = Double(recorder.averagePower(forChannel: 0))
        let peak = Double(recorder.peakPower(forChannel: 0))
        let time = recorder.currentTime
        let interval = max(0, min(0.15, time - meter.sampledAt))
        // This only rejects near-silence; it does not claim to recognize speech.
        let audible = average > -55 && peak > -45
        let normalized = max(0, min(1, (pow(10, average / 20) - 0.001) / 0.999))
        meter = Meter(level: normalized.isFinite ? normalized : 0, sampledAt: time,
            audibleDuration: meter.audibleDuration + (audible ? interval : 0))
    }

    private func finishRecording() {
        guard let capture = recorder else { return }
        sampleMeter()
        let hasSpeech = meter.audibleDuration >= 0.15
        let url = capture.url
        let deactivated = discardCapture()
        do {
            guard deactivated else { throw VoiceInputIssue.microphoneUnavailable }
            let clip = try readClip(at: url, hasSpeech: hasSpeech)
            guard removeRecordingDirectory() else { throw VoiceInputIssue.microphoneUnavailable }
            completed = .success(clip)
        } catch {
            _ = removeRecordingDirectory()
            let issue = (error as? VoiceInputIssue) ?? .invalidAudio
            recordingIssue = issue
            completed = .failure(issue)
        }
    }

    private func readClip(at url: URL, hasSpeech: Bool) throws -> VoiceClip {
        let attributes = try files.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber,
              size.intValue > 0, size.intValue <= Self.maximumBytes else {
            throw VoiceInputIssue.invalidAudio
        }
        let audio = try AVAudioFile(forReading: url)
        let duration = Double(audio.length) / audio.processingFormat.sampleRate
        guard audio.length > 0, duration.isFinite, duration >= Self.minimumDuration,
              duration <= Self.maximumDuration + 0.25 else {
            throw VoiceInputIssue.invalidAudio
        }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: Self.maximumBytes + 1) ?? Data()
        guard data.count == size.intValue, data.count <= Self.maximumBytes else {
            throw VoiceInputIssue.invalidAudio
        }
        // AAC may pad the final packet; the native recording cap still bounds capture to 60 seconds.
        return VoiceClip(data: data, duration: min(duration, Self.maximumDuration), hasSpeech: hasSpeech)
    }

    @discardableResult
    private func discardCapture() -> Bool {
        meterTask?.cancel()
        meterTask = nil
        let capture = recorder
        recorder = nil
        capture?.delegate = nil
        capture?.stop()
        meter = .empty
        if sessionActive {
            do {
                try audioSession.setActive(false, options: .notifyOthersOnDeactivation)
                sessionActive = false
            } catch {
                logFailure("deactivation", error: error)
                recordingIssue = .microphoneUnavailable
                return false
            }
        }
        return true
    }

    private func interrupt() {
        guard recorder != nil || requestingPermission else { return }
        cancel()
        recordingIssue = .interrupted
        completed = .failure(.interrupted)
    }

    private func removeRecordingDirectory() -> Bool {
        guard let directory else { return true }
        do {
            if files.fileExists(atPath: directory.path) { try files.removeItem(at: directory) }
            Self.activeDirectories = Self.activeDirectories.subtracting([directory])
            self.directory = nil
            return true
        } catch {
            logFailure("remove-directory", error: error)
            cleanupFailed = true
            return false
        }
    }

    private func purgeAbandonedRecordings() -> Bool {
        do {
            let folders = try files.contentsOfDirectory(at: files.temporaryDirectory,
                includingPropertiesForKeys: nil)
            for folder in folders where folder.lastPathComponent.hasPrefix(Self.directoryPrefix)
                && !Self.activeDirectories.contains(folder) {
                try files.removeItem(at: folder)
            }
            return true
        } catch {
            logFailure("purge-directories", error: error)
            return false
        }
    }

    private func recordingStep<T>(_ stage: String, action: () throws -> T) throws -> T {
        do { return try action() }
        catch {
            logFailure(stage, error: error)
            throw error
        }
    }

    private func logFailure(_ stage: String, error: Error) {
        let failure = error as NSError
        // Never include localized descriptions, userInfo, paths, or captured content.
        let knownDomains = [NSOSStatusErrorDomain, NSCocoaErrorDomain, AVFoundationErrorDomain]
        let domain = knownDomains.contains(failure.domain) ? failure.domain : "other"
        Self.report("Capture failed: \(stage), domain=\(domain), code=\(failure.code)")
    }

    private static func report(_ message: String) {
        logger.error("\(message, privacy: .public)")
    }

    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        let url = recorder.url
        Task { @MainActor [weak self] in
            guard let self, self.recorder?.url == url else { return }
            if flag { self.finishRecording() }
            else { self.interrupt() }
        }
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        let url = recorder.url
        Task { @MainActor [weak self] in
            guard let self, self.recorder?.url == url else { return }
            self.interrupt()
        }
    }
}

private final class AudioObservers {
    private let tokens: [NSObjectProtocol]

    init(onInterruption: @escaping @Sendable () -> Void) {
        let center = NotificationCenter.default
        let interruption = center.addObserver(forName: AVAudioSession.interruptionNotification,
            object: nil, queue: nil) { notification in
                let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                if raw == AVAudioSession.InterruptionType.began.rawValue { onInterruption() }
            }
        let reset = center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil, queue: nil) { _ in onInterruption() }
        tokens = [interruption, reset]
    }

    deinit {
        for token in tokens { NotificationCenter.default.removeObserver(token) }
    }
}
