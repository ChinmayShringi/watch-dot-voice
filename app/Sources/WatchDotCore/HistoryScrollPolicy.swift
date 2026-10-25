/// A revision travels with its measured layout so content growth cannot masquerade as a scroll.
public struct HistoryScrollLayout: Equatable, Sendable {
    public let revision: Int
    public let contentHeight: Double
    public let viewportHeight: Double
    public let bottom: Double

    public init(revision: Int, contentHeight: Double, viewportHeight: Double, bottom: Double) {
        self.revision = revision
        self.contentHeight = contentHeight
        self.viewportHeight = viewportHeight
        self.bottom = bottom
    }

    public var isAtEnd: Bool { bottom <= viewportHeight + 2 }

    fileprivate var isValid: Bool {
        contentHeight.isFinite && viewportHeight.isFinite && bottom.isFinite &&
        contentHeight >= 0 && viewportHeight > 0
    }

    fileprivate func hasSameContentSize(as other: Self) -> Bool {
        revision == other.revision && abs(contentHeight - other.contentHeight) < 0.5 &&
        abs(viewportHeight - other.viewportHeight) < 0.5
    }
}

public struct HistoryScrollPolicy: Equatable, Sendable {
    public let followsLatest: Bool
    public let isInteracting: Bool
    public let layout: HistoryScrollLayout?

    public init() { self.init(followsLatest: true, isInteracting: false, layout: nil) }

    private init(followsLatest: Bool, isInteracting: Bool, layout: HistoryScrollLayout?) {
        self.followsLatest = followsLatest
        self.isInteracting = isInteracting
        self.layout = layout
    }

    public func shouldFollow(_ next: HistoryScrollLayout) -> Bool {
        guard next.isValid, followsLatest, !isInteracting else { return false }
        return layout.map { !next.hasSameContentSize(as: $0) } ?? true
    }

    public func observing(_ next: HistoryScrollLayout) -> Self {
        guard next.isValid else { return self }
        let unchangedContent = layout.map { next.hasSameContentSize(as: $0) } ?? false
        return Self(followsLatest: unchangedContent ? next.isAtEnd : followsLatest,
                    isInteracting: isInteracting, layout: next)
    }

    public func interacting(_ active: Bool) -> Self {
        let follows = isInteracting && !active ? (layout?.isAtEnd ?? followsLatest) : followsLatest
        return Self(followsLatest: follows, isInteracting: active, layout: layout)
    }

    public func jumpingToLatest() -> Self {
        Self(followsLatest: true, isInteracting: false, layout: layout)
    }
}
