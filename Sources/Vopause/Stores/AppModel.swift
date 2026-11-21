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
    private var playbackTask: Task<Void, Never>?
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

        let commits = stateMachine.ingest(
            snapshot.rawActivity,
            at: snapshot.observedAt,
            settings: settings
        )
        micPhase = stateMachine.phase
        apply(commits: commits)
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
        statusMessage = "Mic active"
        pausePlaybackIfNeeded()
    }

    private func handleMicBecameInactive() {
        logger.info("Microphone became inactive")
        statusMessage = "Mic idle"
        enqueuePlayback { model in
            guard !model.micPhase.isCommittedActive else { return }
            if model.autoResume {
                let didResume = await model.playback.resumeAfterMicrophone()
                if didResume, !model.micPhase.isCommittedActive, model.canRunActions {
                    model.statusMessage = "Resumed playback"
                }
            } else {
                await model.playback.clearOwnership()
            }
        }
    }

    private func reconcilePolicyChange() {
        if !isEnabled || isSnoozed {
            resumePlaybackSilently()
            statusMessage = isEnabled ? "Utility paused" : "Utility off"
            return
        }

        if micPhase.isCommittedActive {
            pausePlaybackIfNeeded()
        } else {
            statusMessage = "Utility active"
        }
    }

    private func pausePlaybackIfNeeded() {
        enqueuePlayback { model in
            guard model.canRunActions, model.micPhase.isCommittedActive else { return }
            let didPause = await model.playback.pauseForMicrophone()
            if didPause, model.canRunActions, model.micPhase.isCommittedActive {
                model.statusMessage = "Paused playback"
            }
        }
    }

    private func resumePlaybackSilently() {
        enqueuePlayback { model in
            _ = await model.playback.resumeAfterMicrophone()
        }
    }

    private func enqueuePlayback(_ action: @escaping @MainActor (AppModel) async -> Void) {
        playbackTask = Task { [weak self, previous = playbackTask] in
            await previous?.value
            guard let self else { return }
            await action(self)
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
