import Foundation

public enum RawMicActivity: Equatable, Sendable {
    case active
    case inactive
    case unknown
}

public enum MicActivityPhase: Equatable, Sendable {
    case inactive
    case pendingActive(since: Date)
    case active(since: Date)
    case pendingInactive(since: Date, activeSince: Date?)

    public var isCommittedActive: Bool {
        switch self {
        case .active, .pendingInactive:
            true
        case .inactive, .pendingActive:
            false
        }
    }

    public var activeSince: Date? {
        switch self {
        case .active(let since):
            since
        case .pendingInactive(_, let activeSince):
            activeSince
        case .inactive, .pendingActive:
            nil
        }
    }
}

public enum MicActivityCommit: Equatable, Sendable {
    case becameActive(at: Date)
    case becameInactive(at: Date)
}

public struct MicActivitySettings: Equatable, Sendable {
    public var activationDebounce: TimeInterval
    public var deactivationGrace: TimeInterval

    public init(
        activationDebounce: TimeInterval = 0.18,
        deactivationGrace: TimeInterval = 0.9
    ) {
        self.activationDebounce = max(0, activationDebounce)
        self.deactivationGrace = max(0, deactivationGrace)
    }
}

public struct MicActivityStateMachine: Equatable, Sendable {
    public private(set) var phase: MicActivityPhase
    public private(set) var lastRawActivity: RawMicActivity

    public init(
        phase: MicActivityPhase = .inactive,
        lastRawActivity: RawMicActivity = .unknown
    ) {
        self.phase = phase
        self.lastRawActivity = lastRawActivity
    }

    @discardableResult
    public mutating func ingest(
        _ rawActivity: RawMicActivity,
        at date: Date,
        settings: MicActivitySettings
    ) -> [MicActivityCommit] {
        lastRawActivity = rawActivity

        switch rawActivity {
        case .active:
            ingestActive(at: date)
        case .inactive, .unknown:
            ingestInactive(at: date)
        }

        return tick(at: date, settings: settings)
    }

    @discardableResult
    public mutating func tick(
        at date: Date,
        settings: MicActivitySettings
    ) -> [MicActivityCommit] {
        switch phase {
        case .pendingActive(let since)
            where date.timeIntervalSince(since) >= settings.activationDebounce:
            phase = .active(since: since)
            return [.becameActive(at: date)]

        case .pendingInactive(let since, _)
            where date.timeIntervalSince(since) >= settings.deactivationGrace:
            phase = .inactive
            return [.becameInactive(at: date)]

        default:
            return []
        }
    }

    public func nextDeadline(settings: MicActivitySettings) -> Date? {
        switch phase {
        case .pendingActive(let since):
            since.addingTimeInterval(settings.activationDebounce)
        case .pendingInactive(let since, _):
            since.addingTimeInterval(settings.deactivationGrace)
        case .inactive, .active:
            nil
        }
    }

    private mutating func ingestActive(at date: Date) {
        switch phase {
        case .inactive:
            phase = .pendingActive(since: date)
        case .pendingActive:
            break
        case .active:
            break
        case .pendingInactive(_, let activeSince):
            phase = .active(since: activeSince ?? date)
        }
    }

    private mutating func ingestInactive(at date: Date) {
        switch phase {
        case .inactive:
            break
        case .pendingActive:
            phase = .inactive
        case .active(let activeSince):
            phase = .pendingInactive(since: date, activeSince: activeSince)
        case .pendingInactive:
            break
        }
    }
}
