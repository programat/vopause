import Foundation

enum AppConstants {
    static let appName = "Vopause"
    static let bundleIdentifier = "dev.egor.vopause"
    static let loggerSubsystem = bundleIdentifier

    enum DefaultsKey {
        static let isEnabled = "vopause.isEnabled"
        static let autoResume = "vopause.autoResume"
        static let activationDebounceMilliseconds = "vopause.activationDebounceMilliseconds"
        static let deactivationGraceMilliseconds = "vopause.deactivationGraceMilliseconds"
        static let snoozedUntil = "vopause.snoozedUntil"
    }
}
