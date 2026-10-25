import Foundation

/// Runtime presentation only. History hydration and dismissed replies never reopen the reader.
public struct AvatarPresentation: Equatable, Sendable {
    public let visibleReplies: [ChatMessage]
    public let pendingReplies: [ChatMessage]
    public let seenIDs: Set<UUID>

    public init(baselineReplies: [ChatMessage] = []) {
        self.init(visibleReplies: [], pendingReplies: [], seenIDs: Set(baselineReplies.map(\.id)))
    }

    private init(visibleReplies: [ChatMessage], pendingReplies: [ChatMessage], seenIDs: Set<UUID>) {
        self.visibleReplies = visibleReplies
        self.pendingReplies = pendingReplies
        self.seenIDs = seenIDs
    }

    public func receiving(_ replies: [ChatMessage], canPresent: Bool) -> Self {
        replies.reduce(self) { state, reply in state.receiving(reply) }
            .presentingPending(ifAllowed: canPresent)
    }

    public func presentingPending(ifAllowed allowed: Bool) -> Self {
        guard allowed, !pendingReplies.isEmpty else { return self }
        return Self(visibleReplies: visibleReplies + pendingReplies, pendingReplies: [], seenIDs: seenIDs)
    }

    public func dismissing() -> Self {
        Self(visibleReplies: [], pendingReplies: pendingReplies, seenIDs: seenIDs)
    }

    private func receiving(_ reply: ChatMessage) -> Self {
        guard reply.role == .assistant,
              !reply.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return self }
        if visibleReplies.contains(where: { $0.id == reply.id }) {
            return Self(visibleReplies: replacing(reply, in: visibleReplies),
                        pendingReplies: pendingReplies, seenIDs: seenIDs)
        }
        if pendingReplies.contains(where: { $0.id == reply.id }) {
            return Self(visibleReplies: visibleReplies, pendingReplies: replacing(reply, in: pendingReplies),
                        seenIDs: seenIDs)
        }
        guard !seenIDs.contains(reply.id) else { return self }
        return Self(visibleReplies: visibleReplies, pendingReplies: pendingReplies + [reply],
                    seenIDs: seenIDs.union([reply.id]))
    }

    private func replacing(_ reply: ChatMessage, in replies: [ChatMessage]) -> [ChatMessage] {
        replies.map { $0.id == reply.id ? reply : $0 }
    }
}
