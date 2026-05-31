import AppKit
import ApplicationServices
import Foundation
import OSLog
import VopauseCore

@MainActor
@Observable
final class AppModel {
    var inputDevices: [AudioInputDevice] = []
    var monitorHealth: MonitorHealth = .warning("Starting")
    var micPhase: MicActivityPhase = .inactive
    var statusMessage = "Starting"
    var launchAtLoginStatus = LaunchAtLoginService.currentStatusLabel()
    var launchAtLoginEnabled = LaunchAtLoginService.isEnabled
    var accessibilityTrusted = AXIsProcessTrusted()

    var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: AppConstants.DefaultsKey.isEnabled)
            reconcilePolicyChange()
        }
    }

    var autoResume: Bool {
        didSet {
            defaults.set(autoResume, forKey: AppConstants.DefaultsKey.autoResume)
        }
    }

    var activationDebounceMilliseconds: Int {
        didSet {
            defaults.set(
                activationDebounceMilliseconds,
                forKey: AppConstants.DefaultsKey.activationDebounceMilliseconds
            )
            scheduleReducerTick()
        }
    }

    var deactivationGraceMilliseconds: Int {
        didSet {
            defaults.set(
                deactivationGraceMilliseconds,
                forKey: AppConstants.DefaultsKey.deactivationGraceMilliseconds
            )
            scheduleReducerTick()
        }
    }

    var snoozedUntil: Date? {
        didSet {
            if let snoozedUntil {
                defaults.set(snoozedUntil, forKey: AppConstants.DefaultsKey.snoozedUntil)
            } else {
                defaults.removeObject(forKey: AppConstants.DefaultsKey.snoozedUntil)
            }
            scheduleSnoozeExpiry()
        }
    }

    private let defaults: UserDefaults
    private let logger = Logger(subsystem: AppConstants.loggerSubsystem, category: "State")
    private let playback = PlaybackCoordinator()
    private var stateMachine = MicActivityStateMachine()
    private var monitor: CoreAudioMicMonitor?
    private var reducerTickTask: Task<Void, Never>?
    private var snoozeTask: Task<Void, Never>?
    private var wakeObserver: NSObjectProtocol?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        isEnabled = defaults.object(forKey: AppConstants.DefaultsKey.isEnabled) as? Bool ?? true
        autoResume = defaults.object(forKey: AppConstants.DefaultsKey.autoResume) as? Bool ?? true
        activationDebounceMilliseconds = defaults.object(
            forKey: AppConstants.DefaultsKey.activationDebounceMilliseconds
        ) as? Int ?? 180
        deactivationGraceMilliseconds = defaults.object(
            forKey: AppConstants.DefaultsKey.deactivationGraceMilliseconds
        ) as? Int ?? 900
        snoozedUntil = defaults.object(forKey: AppConstants.DefaultsKey.snoozedUntil) as? Date

        monitor = CoreAudioMicMonitor { [weak self] snapshot in
            Task { @MainActor in
                self?.handle(snapshot: snapshot)
            }
        }
        monitor?.start()
        configureWakeObserver()
        scheduleSnoozeExpiry()
        refreshLaunchAtLoginStatus()
    }

    var isMicActive: Bool {
        micPhase.isCommittedActive
    }

    var isSnoozed: Bool {
        guard let snoozedUntil else {
            return false
        }
        return snoozedUntil > Date.now
    }

    var canRunActions: Bool {
        isEnabled && !isSnoozed
    }

    var modeLabel: String {
        if !isEnabled {
            return "Off"
        }
        if let snoozedUntil, snoozedUntil > Date.now {
            return "Paused until \(snoozedUntil.formatted(date: .omitted, time: .shortened))"
        }
        return "On"
    }

    var micLabel: String {
        switch micPhase {
        case .inactive:
            "Mic idle"
        case .pendingActive:
            "Mic starting"
        case .active:
            "Mic active"
        case .pendingInactive:
            "Mic settling"
        }
    }

    var menuBarSystemImage: String {
        if !isEnabled || isSnoozed {
            return "pause.circle"
        }
        if isMicActive {
            return "mic.fill"
        }
        return "mic"
    }

    var settings: MicActivitySettings {
        MicActivitySettings(
            activationDebounce: TimeInterval(activationDebounceMilliseconds) / 1_000,
            deactivationGrace: TimeInterval(deactivationGraceMilliseconds) / 1_000
        )
    }

    func snooze(for interval: TimeInterval) {
        snoozedUntil = Date.now.addingTimeInterval(interval)
        resumePlaybackSilently()
        statusMessage = "Paused utility"
    }

    func resumeUtilityNow() {
        snoozedUntil = nil
        statusMessage = "Utility active"
        reconcilePolicyChange()
    }

    func toggleLaunchAtLogin() {
        do {
            try LaunchAtLoginService.setEnabled(!launchAtLoginEnabled)
            refreshLaunchAtLoginStatus()
        } catch {
            launchAtLoginStatus = "Error"
            statusMessage = "Login item failed"
            logger.error("Login item failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    func refreshLaunchAtLoginStatus() {
        launchAtLoginEnabled = LaunchAtLoginService.isEnabled
        launchAtLoginStatus = LaunchAtLoginService.currentStatusLabel()
    }

    func refreshAccessibilityStatus() {
        accessibilityTrusted = AXIsProcessTrusted()
    }

    func openAccessibilitySettings() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        accessibilityTrusted = AXIsProcessTrustedWithOptions(options)

        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    func refreshAudioDevices() {
        monitor?.forceRefresh()
    }

    private func handle(snapshot: MicHardwareSnapshot) {
        inputDevices = snapshot.inputDevices
        monitorHealth = snapshot.health
        let previousPhase = stateMachine.phase

        if snapshot.rawActivity == .active {
            pausePlaybackIfNeeded(mode: .fast, statusWhenSkipped: "Mic active")
        }

        let commits = stateMachine.ingest(
            snapshot.rawActivity,
            at: snapshot.observedAt,
            settings: settings
        )
        micPhase = stateMachine.phase
        apply(commits: commits)
        reconcileCancelledEarlyPause(previousPhase: previousPhase)
        scheduleReducerTick()
    }

    private func advanceReducer(at date: Date = Date.now) {
        let commits = stateMachine.tick(at: date, settings: settings)
        micPhase = stateMachine.phase
        apply(commits: commits)
        scheduleReducerTick()
    }

    private func apply(commits: [MicActivityCommit]) {
        for commit in commits {
            switch commit {
            case .becameActive:
                handleMicBecameActive()
            case .becameInactive:
                handleMicBecameInactive()
            }
        }
    }

    private func handleMicBecameActive() {
        logger.info("Microphone became active")
        guard canRunActions else {
            statusMessage = "Mic active"
            return
        }

        pausePlaybackIfNeeded(mode: .full, statusWhenSkipped: "Mic active")
    }

    private func handleMicBecameInactive() {
        logger.info("Microphone became inactive")
        if autoResume {
            statusMessage = "Mic idle"
            resumePlaybackAfterMicrophone(statusWhenSkipped: "Mic idle")
        } else {
            clearPlaybackOwnership()
            statusMessage = "Mic idle"
        }
    }

    private func reconcileCancelledEarlyPause(previousPhase: MicActivityPhase) {
        guard case .pendingActive = previousPhase, case .inactive = micPhase else {
            return
        }

        resumePlaybackAfterMicrophone(statusWhenSkipped: "Mic idle")
        statusMessage = "Mic idle"
    }

    private func reconcilePolicyChange() {
        if !isEnabled || isSnoozed {
            resumePlaybackSilently()
            statusMessage = isEnabled ? "Utility paused" : "Utility off"
            return
        }

        if micPhase.isCommittedActive {
            pausePlaybackIfNeeded(mode: .full, statusWhenSkipped: "Mic active")
        } else {
            statusMessage = "Utility active"
        }
    }

    private func pausePlaybackIfNeeded(mode: PlaybackPauseMode, statusWhenSkipped: String) {
        guard canRunActions else {
            return
        }

        Task { [weak self] in
            guard let self else {
                return
            }

            let didPause = await playback.pauseForMicrophone(mode: mode)
            let ownsPause = await playback.ownsPause
            guard canRunActions,
                  stateMachine.lastRawActivity == .active || micPhase.isCommittedActive else {
                return
            }

            statusMessage = didPause || ownsPause ? "Paused playback" : statusWhenSkipped
        }
    }

    private func resumePlaybackAfterMicrophone(statusWhenSkipped: String) {
        Task { [weak self] in
            guard let self else {
                return
            }

            let didResume = await playback.resumeAfterMicrophone()
            guard !micPhase.isCommittedActive else {
                return
            }

            statusMessage = didResume ? "Resumed playback" : statusWhenSkipped
        }
    }

    private func resumePlaybackSilently() {
        Task { [playback] in
            _ = await playback.resumeAfterMicrophone()
        }
    }

    private func clearPlaybackOwnership() {
        Task { [playback] in
            await playback.clearOwnership()
        }
    }

    private func scheduleReducerTick() {
        reducerTickTask?.cancel()
        guard let deadline = stateMachine.nextDeadline(settings: settings) else {
            return
        }

        let delay = max(0, deadline.timeIntervalSinceNow)
        reducerTickTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else {
                return
            }
            await MainActor.run {
                self?.advanceReducer()
            }
        }
    }

    private func scheduleSnoozeExpiry() {
        snoozeTask?.cancel()
        guard let snoozedUntil, snoozedUntil > Date.now else {
            if snoozedUntil != nil {
                self.snoozedUntil = nil
            }
            return
        }

        let delay = snoozedUntil.timeIntervalSinceNow
        snoozeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
            guard !Task.isCancelled else {
                return
            }
            await MainActor.run {
                self?.resumeUtilityNow()
            }
        }
    }

    private func configureWakeObserver() {
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.monitor?.forceRefresh()
            }
        }
    }
}
