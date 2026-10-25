import Foundation

public struct HomeRecovery: Equatable {
    public let reason: String
    public let retryTitle: String?
    public let canDiscard: Bool
    public let canSave: Bool

    public init?(delivery: DeliveryState, storageIssue: String?, canSend: Bool,
                 canRetry: Bool, retryIsReadOnly: Bool, canDiscard: Bool, canRetrySaving: Bool) {
        if let storageIssue {
            reason = storageIssue
        } else {
            switch delivery {
            case .failed(let message): reason = message
            case .cancelled: reason = "Waiting stopped. Your message may still be running."
            case .waitingForConnection: reason = "Offline. Your message is still pending."
            case .sending where !canSend: reason = "Sending your message."
            case .waiting where !canSend: reason = "Waiting for your reply."
            default:
                guard !canSend else { return nil }
                reason = "Review the pending message before starting another."
            }
        }
        retryTitle = storageIssue == nil && canRetry
            ? (retryIsReadOnly ? "Check for Reply" : "Resume Message") : nil
        self.canDiscard = storageIssue == nil && canDiscard && !delivery.isActive
        canSave = storageIssue != nil && canRetrySaving
    }
}

public struct VoiceAccessibility: Equatable {
    public let label: String
    public let hint: String
    public let value: String

    public init(phase: VoiceInputPhase, name: String, elapsed: TimeInterval,
                recoveryReason: String?, isRealConnection: Bool) {
        switch phase {
        case .listening:
            label = "Stop recording and send"
            hint = "Sends the recording for transcription and delivers the message."
            let seconds = elapsed.isFinite ? Int(min(60, max(0, elapsed))) : 0
            value = "Listening, \(seconds) of 60 seconds"
        case .requesting:
            label = "Preparing microphone"
            hint = "Recording starts after microphone access is allowed."
            value = "Preparing"
        case .transcribing:
            label = "Transcribing"
            hint = "Sends your message when transcription finishes."
            value = "Working"
        case .idle, .failed:
            if let recoveryReason {
                label = "Review message"
                hint = "Opens available recovery actions."
                value = recoveryReason
            } else {
                label = name
                hint = isRealConnection ? "Starts recording a voice message." : "Opens local demo text input."
                value = isRealConnection ? "Ready to record" : "Demo"
            }
        }
    }
}
