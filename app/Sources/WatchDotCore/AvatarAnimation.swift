import Foundation

/// Timings for the optional sprite atlas contract. Each cell is 192 by 208 pixels.
public enum AvatarAnimation: CaseIterable, Sendable {
    case idle, listening, working, replied, failed

    public static let columns = 8
    public static let rows = 11
    public static let cellWidth = 192
    public static let cellHeight = 208

    public var row: Int {
        switch self {
        case .idle: 0
        case .listening: 6
        case .working: 7
        case .replied: 8
        case .failed: 5
        }
    }

    public var durationsMilliseconds: [Int] {
        switch self {
        case .idle: [280, 110, 110, 140, 140, 320]
        case .listening: [150, 150, 150, 150, 150, 260]
        case .working: [120, 120, 120, 120, 120, 220]
        case .replied: [150, 150, 150, 150, 150, 280]
        case .failed: [140, 140, 140, 140, 140, 140, 140, 240]
        }
    }

    public func frame(at elapsed: TimeInterval) -> Int {
        guard elapsed.isFinite, elapsed > 0 else { return 0 }
        let durations = durationsMilliseconds
        let cycle = durations.reduce(0, +)
        let milliseconds = (elapsed * 1_000).truncatingRemainder(dividingBy: Double(cycle))
        return durations.indices.first { index in
            milliseconds < Double(durations.prefix(index + 1).reduce(0, +))
        } ?? 0
    }

    public static func displayed(_ animation: Self, active: Bool, reduceMotion: Bool,
                                 luminanceReduced: Bool) -> Self {
        active && !reduceMotion && !luminanceReduced ? animation : .idle
    }
}
