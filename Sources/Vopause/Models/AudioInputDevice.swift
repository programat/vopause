import Foundation
import VopauseCore

struct AudioInputDevice: Identifiable, Equatable, Sendable {
    var id: UInt32
    var name: String
    var uid: String?
    var isRunning: Bool
}

enum MonitorHealth: Equatable, Sendable {
    case ok
    case warning(String)

    var message: String {
        switch self {
        case .ok:
            "OK"
        case .warning(let message):
            message
        }
    }
}

struct MicHardwareSnapshot: Equatable, Sendable {
    var rawActivity: RawMicActivity
    var inputDevices: [AudioInputDevice]
    var observedAt: Date
    var health: MonitorHealth
}
