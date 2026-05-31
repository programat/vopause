import Foundation
import ServiceManagement

enum LaunchAtLoginService {
    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static func currentStatusLabel() -> String {
        switch SMAppService.mainApp.status {
        case .enabled:
            "On"
        case .notRegistered:
            "Off"
        case .notFound:
            "Unavailable"
        case .requiresApproval:
            "Needs Approval"
        @unknown default:
            "Unknown"
        }
    }

    static func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}
