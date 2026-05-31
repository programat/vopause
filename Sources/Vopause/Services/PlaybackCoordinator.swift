import AppKit
import ApplicationServices
@preconcurrency import CoreAudio
import Darwin
import Foundation
import ObjectiveC
import OSLog

actor PlaybackCoordinator {
    private let controller = ScriptedPlaybackController()
    private let logger = Logger(subsystem: AppConstants.loggerSubsystem, category: "Playback")
    private var pauseTokens: [PauseToken] = []
    private var lastReinforcementAt: Date?
    private var reinforcementTask: Task<Void, Never>?

    var ownsPause: Bool {
        !pauseTokens.isEmpty
    }

    func pauseForMicrophone(mode: PlaybackPauseMode) -> Bool {
        if !pauseTokens.isEmpty {
            if mode == .full {
                let existingKeys = Set(pauseTokens.map(\.key))
                let newTokens = controller.pauseAllPlayingPlayers(mode: .full)
                    .filter { !existingKeys.contains($0.key) }
                if !newTokens.isEmpty {
                    pauseTokens.append(contentsOf: newTokens)
                    logger.info(
                        "Paused \(newTokens.count, privacy: .public) additional player(s) for microphone activation"
                    )
                    return true
                }
            }

            return reinforcePauseForMicrophone()
        }

        let tokens = controller.pauseAllPlayingPlayers(mode: mode)
        guard !tokens.isEmpty else {
            logger.info("No playing player found; skipping automatic pause")
            return false
        }

        pauseTokens = tokens
        startReinforcementBurst()
        logger.info("Paused \(tokens.count, privacy: .public) player(s) for microphone activation")
        return true
    }

    func resumeAfterMicrophone() -> Bool {
        guard !pauseTokens.isEmpty else {
            return false
        }

        let tokens = pauseTokens
        pauseTokens = []
        lastReinforcementAt = nil
        reinforcementTask?.cancel()
        reinforcementTask = nil

        let resumedCount = controller.resume(tokens)
        guard resumedCount > 0 else {
            logger.info("Skipped resume for paused players")
            return false
        }

        logger.info("Resumed \(resumedCount, privacy: .public) player(s) after microphone release")
        return true
    }

    func clearOwnership() {
        pauseTokens = []
        lastReinforcementAt = nil
        reinforcementTask?.cancel()
        reinforcementTask = nil
    }

    private func reinforcePauseForMicrophone() -> Bool {
        let now = Date.now
        if let lastReinforcementAt, now.timeIntervalSince(lastReinforcementAt) < 0.25 {
            return false
        }

        lastReinforcementAt = now
        guard controller.reinforcePause(pauseTokens) else {
            return false
        }

        logger.info("Reinforced pause for microphone activation")
        return true
    }

    private func startReinforcementBurst() {
        reinforcementTask?.cancel()
        reinforcementTask = Task { [weak self] in
            for delay in [120_000_000, 320_000_000, 650_000_000] as [UInt64] {
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled else {
                    return
                }
                guard let self else {
                    return
                }
                _ = await self.reinforcePauseForMicrophone()
            }
        }
    }
}

enum PlaybackPauseMode: Equatable, Sendable {
    case fast
    case full
}

private enum PauseToken {
    case mediaRemotePlayer(MediaRemotePlayerToken)
    case systemNowPlaying(identity: NowPlayingIdentity?)
    case mediaRemoteApp(AudioOutputProcess)
    case controlCenter(ControlCenterMediaTarget)
    case accessibilityMenu(AccessibilityMenuPlayer)
    case player(ScriptedPlayer)
    case browser(BrowserMediaTarget)

    var key: String {
        switch self {
        case .mediaRemotePlayer(let player):
            "mr-player:\(player.key)"
        case .systemNowPlaying(let identity):
            "system:\(identity?.key ?? "unknown")"
        case .mediaRemoteApp(let process):
            "remote:\(process.key)"
        case .controlCenter(let target):
            "control-center:\(target.key)"
        case .accessibilityMenu(let player):
            "ax-menu:\(player.key)"
        case .player(let player):
            "player:\(player.bundleID)"
        case .browser(let target):
            "browser:\(target.browser.bundleID):\(target.windowIndex):\(target.tabIndex):\(target.url)"
        }
    }

    var bundleID: String? {
        switch self {
        case .mediaRemotePlayer(let player):
            player.bundleID
        case .systemNowPlaying(let identity):
            identity?.bundleID ?? identity?.parentBundleID
        case .mediaRemoteApp(let process):
            process.bundleID
        case .controlCenter(let target):
            target.bundleID
        case .accessibilityMenu(let player):
            player.bundleID
        case .player(let player):
            player.bundleID
        case .browser(let target):
            target.browser.bundleID
        }
    }

    var outputProcess: AudioOutputProcess? {
        switch self {
        case .mediaRemoteApp(let process):
            process
        case .controlCenter(let target):
            target.source
        case .accessibilityMenu(let player):
            player.source
        default:
            nil
        }
    }
}

private struct NowPlayingIdentity: Equatable {
    var bundleID: String?
    var parentBundleID: String?
    var processID: pid_t?

    var key: String {
        if let bundleID {
            return "bundle:\(bundleID)"
        }
        if let parentBundleID {
            return "parent:\(parentBundleID)"
        }
        if let processID {
            return "pid:\(processID)"
        }
        return "unknown"
    }

    func matches(_ other: NowPlayingIdentity) -> Bool {
        if let processID, let otherProcessID = other.processID, processID == otherProcessID {
            return true
        }
        if let bundleID, bundleID == other.bundleID || bundleID == other.parentBundleID {
            return true
        }
        if let parentBundleID, parentBundleID == other.bundleID || parentBundleID == other.parentBundleID {
            return true
        }
        return false
    }
}

private struct MediaRemotePause {
    var identity: NowPlayingIdentity?
}

private struct MediaRemotePlayerToken {
    var path: AnyObject
    var key: String
    var displayName: String
    var bundleID: String?
}

private struct MediaRemotePlayerSnapshot {
    var path: AnyObject
    var key: String
    var displayName: String
    var bundleID: String?
    var playbackRate: Double?

    var isPlaying: Bool {
        (playbackRate ?? 0) > 0.01
    }

    var token: MediaRemotePlayerToken {
        MediaRemotePlayerToken(
            path: path,
            key: key,
            displayName: displayName,
            bundleID: bundleID
        )
    }
}

private struct AccessibilityMenuPlayer: Equatable {
    var processID: pid_t
    var bundleID: String
    var displayName: String
    var source: AudioOutputProcess

    var key: String {
        "\(bundleID):\(processID)"
    }
}

private struct PlaybackAppCandidate: Equatable {
    var appDisplayName: String
    var bundleID: String?
    var source: AudioOutputProcess
}

private struct ControlCenterMediaTarget: Equatable {
    var appDisplayName: String
    var bundleID: String?
    var cardLabel: String
    var source: AudioOutputProcess

    var key: String {
        [
            bundleID,
            appDisplayName,
            cardLabel,
            source.key
        ]
            .compactMap { $0 }
            .joined(separator: "|")
    }
}

private struct ControlCenterPauseCandidate: Equatable {
    var appDisplayName: String
    var bundleID: String?
    var source: AudioOutputProcess
}

private struct ControlCenterPauseRequest: Equatable {
    var source: AudioOutputProcess
    var candidates: [ControlCenterPauseCandidate]
}

private struct AudioOutputProcess: Equatable {
    var processID: pid_t?
    var bundleID: String?
    var displayName: String

    var key: String {
        if let bundleID {
            return "bundle:\(bundleID)"
        }
        if let processID {
            return "pid:\(processID)"
        }
        return "name:\(displayName)"
    }

    func matches(_ other: AudioOutputProcess) -> Bool {
        if let processID, let otherProcessID = other.processID {
            return processID == otherProcessID
        }
        if let bundleID, let otherBundleID = other.bundleID {
            return bundleID == otherBundleID
        }
        return false
    }

    var nowPlayingIdentity: NowPlayingIdentity? {
        guard bundleID != nil || processID != nil else {
            return nil
        }
        return NowPlayingIdentity(bundleID: bundleID, parentBundleID: nil, processID: processID)
    }
}

private struct BrowserApp: Equatable {
    enum ScriptKind {
        case chrome
        case safari
    }

    var bundleID: String
    var scriptKind: ScriptKind
}

private struct BrowserMediaTarget: Equatable {
    var browser: BrowserApp
    var windowIndex: Int
    var tabIndex: Int
    var title: String
    var url: String
}

private struct ScriptedPlayer: Equatable {
    var bundleID: String
    var displayName: String
    var stateExpression: String
    var pauseCommand: String
    var playCommand: String
}

private enum PlayerPlaybackState {
    case playing
    case paused
    case stopped
    case unknown

    init(_ rawValue: String?) {
        switch rawValue?.lowercased() {
        case "playing":
            self = .playing
        case "paused":
            self = .paused
        case "stopped":
            self = .stopped
        default:
            self = .unknown
        }
    }
}

private final class ScriptedPlaybackController {
    private let logger = Logger(subsystem: AppConstants.loggerSubsystem, category: "Playback")
    private let systemNowPlaying = MediaRemoteNowPlayingController()
    private let controlCenter = ControlCenterNowPlayingController()
    private let accessibilityMenu = AccessibilityMenuPlaybackController()
    private let outputReader = CoreAudioOutputProcessReader()
    private let players = [
        ScriptedPlayer(
            bundleID: "com.spotify.client",
            displayName: "Spotify",
            stateExpression: "player state as string",
            pauseCommand: "pause",
            playCommand: "play"
        ),
        ScriptedPlayer(
            bundleID: "com.apple.Music",
            displayName: "Music",
            stateExpression: "player state as string",
            pauseCommand: "pause",
            playCommand: "play"
        )
    ]
    private let browsers = [
        BrowserApp(bundleID: "com.apple.Safari", scriptKind: .safari),
        BrowserApp(bundleID: "com.google.Chrome", scriptKind: .chrome),
        BrowserApp(bundleID: "com.microsoft.edgemac", scriptKind: .chrome),
        BrowserApp(bundleID: "com.brave.Browser", scriptKind: .chrome),
        BrowserApp(bundleID: "company.thebrowser.Browser", scriptKind: .chrome)
    ]

    func pauseAllPlayingPlayers(mode: PlaybackPauseMode) -> [PauseToken] {
        let mediaRemotePlayers = systemNowPlaying.playingPlayerSnapshots()
        if mediaRemotePlayers.isEmpty {
            logger.info("No playing MediaRemote player paths captured before microphone pause")
        } else {
            let sources = mediaRemotePlayers.map(\.displayName).joined(separator: ", ")
            logger.info("Captured MediaRemote player path(s): \(sources, privacy: .public)")
        }

        let capturedOutput = outputReader.runningOutputProcesses()
        if capturedOutput.isEmpty {
            logger.info("No running CoreAudio output processes captured before microphone pause")
        } else {
            let sources = capturedOutput.map(\.displayName).joined(separator: ", ")
            logger.info("Captured CoreAudio output process(es): \(sources, privacy: .public)")
        }

        var tokens: [PauseToken] = []
        var tokenKeys = Set<String>()

        func append(_ token: PauseToken) {
            guard tokenKeys.insert(token.key).inserted else {
                return
            }
            tokens.append(token)
        }

        for player in mediaRemotePlayers {
            guard systemNowPlaying.pause(player) else {
                continue
            }

            append(.mediaRemotePlayer(player.token))
        }

        if mode == .fast {
            if tokens.isEmpty,
               systemNowPlaying.isAvailable,
               let pause = systemNowPlaying.pauseIfPlaying() {
                append(.systemNowPlaying(identity: pause.identity))
            }

            return tokens
        }

        let runningPlayersWithStates = runningSupportedPlayers().map { player in
            (player: player, state: state(of: player))
        }

        let pausedMediaRemoteBundleIDs = Set(
            tokens.compactMap { token -> String? in
                guard case .mediaRemotePlayer(let player) = token else {
                    return nil
                }
                return player.bundleID
            }
        )
        for item in runningPlayersWithStates {
            if pausedMediaRemoteBundleIDs.contains(item.player.bundleID) {
                continue
            }

            guard item.state == .playing else {
                continue
            }

            guard execute(item.player.pauseCommand, for: item.player) != nil else {
                continue
            }

            append(.player(item.player))
        }

        for browser in runningSupportedBrowsers() {
            if pausedMediaRemoteBundleIDs.contains(browser.bundleID) {
                continue
            }

            for target in pausePlayingBrowserTabs(in: browser) {
                append(.browser(target))
            }
        }

        let claimedBundleIDs = Set(tokens.compactMap(\.bundleID))
        let pausedScriptableBundleIDs = Set(
            runningPlayersWithStates
                .filter { $0.state == .paused || $0.state == .stopped }
                .map(\.player.bundleID)
        )
        let ignoredBundleIDs = claimedBundleIDs
            .union(pausedScriptableBundleIDs)
            .union(pausedMediaRemoteBundleIDs)
        let remainingOutput = outputReader.runningOutputProcesses(
            matching: capturedOutput.filter { process in
                guard let bundleID = process.bundleID else {
                    return true
                }
                return !ignoredBundleIDs.contains(bundleID)
            }
        )

        var remoteOutput = remainingOutput.isEmpty
            ? capturedOutput.filter { process in
                guard let bundleID = process.bundleID else {
                    return true
                }
                return !ignoredBundleIDs.contains(bundleID)
            }
            : remainingOutput

        if !remoteOutput.isEmpty {
            let controlCenterTokens = pauseControlCenterSources(remoteOutput)
            for token in controlCenterTokens {
                append(token)
            }

            let controlCenterProcesses = controlCenterTokens.compactMap(\.outputProcess)
            remoteOutput = remoteOutput.filter { process in
                !controlCenterProcesses.contains { $0.matches(process) }
            }
        }

        if !remoteOutput.isEmpty {
            let accessibilityTokens = pauseAccessibilityMenuSources(remoteOutput)
            for token in accessibilityTokens {
                append(token)
            }

            let accessibilityProcesses = accessibilityTokens.compactMap(\.outputProcess)
            remoteOutput = remoteOutput.filter { process in
                !accessibilityProcesses.contains { $0.matches(process) }
            }
        }

        if !remoteOutput.isEmpty {
            let globalIdentity = remoteOutput.count == 1
                ? remoteOutput.first?.nowPlayingIdentity
                : systemNowPlaying.snapshotIdentity()
            if systemNowPlaying.pauseUntilQuiet(capturedProcesses: remoteOutput, outputReader: outputReader) {
                append(.systemNowPlaying(identity: globalIdentity))
                for process in remoteOutput where process.bundleID != nil {
                    append(.mediaRemoteApp(process))
                }
            }
        }

        if tokens.isEmpty,
           systemNowPlaying.isAvailable,
           let pause = systemNowPlaying.pauseIfPlaying() {
            append(.systemNowPlaying(identity: pause.identity))
        }

        return tokens
    }

    func reinforcePause(_ tokens: [PauseToken]) -> Bool {
        var didSendCommand = false

        for token in tokens {
            switch token {
            case .mediaRemotePlayer(let player):
                didSendCommand = systemNowPlaying.pause(player) || didSendCommand
            case .systemNowPlaying:
                didSendCommand = systemNowPlaying.pauseIfPlaying() != nil || didSendCommand
            case .mediaRemoteApp:
                continue
            case .controlCenter:
                continue
            case .accessibilityMenu(let player):
                didSendCommand = accessibilityMenu.pause(player) || didSendCommand
            case .player(let player):
                guard state(of: player) == .playing else {
                    continue
                }
                didSendCommand = execute(player.pauseCommand, for: player) != nil || didSendCommand
            case .browser:
                continue
            }
        }

        let capturedProcesses = tokens.compactMap { token -> AudioOutputProcess? in
            if case .mediaRemoteApp(let process) = token {
                return process
            }
            return nil
        }
        if !capturedProcesses.isEmpty {
            didSendCommand = systemNowPlaying.pauseUntilQuiet(
                capturedProcesses: capturedProcesses,
                outputReader: outputReader,
                maxPasses: 2
            ) || didSendCommand
        }

        return didSendCommand
    }

    func resume(_ tokens: [PauseToken]) -> Int {
        var resumedCount = 0
        let controlCenterTargets = tokens.compactMap { token -> ControlCenterMediaTarget? in
            if case .controlCenter(let target) = token {
                return target
            }
            return nil
        }

        for token in tokens.reversed() {
            switch token {
            case .mediaRemotePlayer(let player):
                resumedCount += systemNowPlaying.resume(player) ? 1 : 0
            case .mediaRemoteApp:
                continue
            case .controlCenter:
                continue
            case .accessibilityMenu(let player):
                resumedCount += accessibilityMenu.resume(player) ? 1 : 0
            case .systemNowPlaying(let identity):
                resumedCount += systemNowPlaying.resumeIfSafe(identity: identity) ? 1 : 0
            case .player(let player):
                resumedCount += resume(player) ? 1 : 0
            case .browser(let target):
                resumedCount += resume(target) ? 1 : 0
            }
        }

        resumedCount += controlCenter.resume(controlCenterTargets)
        return resumedCount
    }

    private func resume(_ player: ScriptedPlayer) -> Bool {
        guard isRunning(player) else {
            return false
        }

        let currentState = state(of: player)
        guard currentState == .paused else {
            return false
        }

        return execute(player.playCommand, for: player) != nil
    }

    private func runningSupportedPlayers() -> [ScriptedPlayer] {
        players.filter(isRunning)
    }

    private func pauseControlCenterSources(_ processes: [AudioOutputProcess]) -> [PauseToken] {
        var seenSources = Set<String>()
        let requests = processes.compactMap { process -> ControlCenterPauseRequest? in
            guard seenSources.insert(process.key).inserted else {
                return nil
            }

            let candidates = controlCenterCandidates(for: process).map { candidate in
                ControlCenterPauseCandidate(
                    appDisplayName: candidate.appDisplayName,
                    bundleID: candidate.bundleID,
                    source: process
                )
            }
            guard !candidates.isEmpty else {
                return nil
            }

            return ControlCenterPauseRequest(source: process, candidates: candidates)
        }

        return controlCenter.pause(requests).map { target in
            .controlCenter(target)
        }
    }

    private func controlCenterCandidates(for process: AudioOutputProcess) -> [PlaybackAppCandidate] {
        let menuPlayers = accessibilityMenuPlayers(for: process)
        if !menuPlayers.isEmpty {
            return menuPlayers.map {
                PlaybackAppCandidate(appDisplayName: $0.displayName, bundleID: $0.bundleID, source: process)
            }
        }

        guard !process.displayName.isEmpty else {
            return []
        }

        return [
            PlaybackAppCandidate(
                appDisplayName: process.displayName,
                bundleID: process.bundleID,
                source: process
            )
        ]
    }

    private func pauseAccessibilityMenuSources(_ processes: [AudioOutputProcess]) -> [PauseToken] {
        var tokens: [PauseToken] = []
        var seenApps = Set<String>()

        for process in processes {
            for player in accessibilityMenuPlayers(for: process) {
                guard seenApps.insert(player.key).inserted else {
                    continue
                }

                guard accessibilityMenu.pause(player) else {
                    continue
                }

                Thread.sleep(forTimeInterval: 0.08)
                tokens.append(.accessibilityMenu(player))
                break
            }
        }

        return tokens
    }

    private func accessibilityMenuPlayers(for process: AudioOutputProcess) -> [AccessibilityMenuPlayer] {
        let runningApplications = NSWorkspace.shared.runningApplications
        var players: [AccessibilityMenuPlayer] = []
        var seen = Set<String>()

        for bundleID in controllerBundleIDCands(for: process.bundleID) {
            for application in runningApplications where application.bundleIdentifier == bundleID {
                append(application, source: process, to: &players, seen: &seen)
            }
        }

        if let bundleID = process.bundleID {
            for application in runningApplications {
                guard let appBundleID = application.bundleIdentifier,
                      bundleID.hasPrefix("\(appBundleID)."),
                      appBundleID != AppConstants.bundleIdentifier else {
                    continue
                }
                append(application, source: process, to: &players, seen: &seen)
            }
        }

        return players
    }

    private func append(
        _ application: NSRunningApplication,
        source: AudioOutputProcess,
        to players: inout [AccessibilityMenuPlayer],
        seen: inout Set<String>
    ) {
        guard let bundleID = application.bundleIdentifier,
              bundleID != AppConstants.bundleIdentifier else {
            return
        }

        let processID = application.processIdentifier
        let key = "\(bundleID):\(processID)"
        guard seen.insert(key).inserted else {
            return
        }

        players.append(
            AccessibilityMenuPlayer(
                processID: processID,
                bundleID: bundleID,
                displayName: application.localizedName ?? source.displayName,
                source: source
            )
        )
    }

    private func controllerBundleIDCands(for bundleID: String?) -> [String] {
        guard let bundleID, !bundleID.isEmpty else {
            return []
        }

        var candidates = [bundleID]
        let lowercased = bundleID.lowercased()
        if let helperRange = lowercased.range(of: ".helper") {
            let parent = String(bundleID[..<helperRange.lowerBound])
            if !parent.isEmpty {
                candidates.append(parent)
            }
        }

        var seen = Set<String>()
        return candidates.filter { seen.insert($0).inserted }
    }

    private func runningSupportedBrowsers() -> [BrowserApp] {
        browsers.filter(isRunning)
    }

    private func isRunning(_ player: ScriptedPlayer) -> Bool {
        isRunning(bundleID: player.bundleID)
    }

    private func isRunning(_ browser: BrowserApp) -> Bool {
        isRunning(bundleID: browser.bundleID)
    }

    private func isRunning(bundleID: String) -> Bool {
        NSWorkspace.shared.runningApplications.contains { application in
            application.bundleIdentifier == bundleID
        }
    }

    private func state(of player: ScriptedPlayer) -> PlayerPlaybackState {
        PlayerPlaybackState(execute("return \(player.stateExpression)", for: player))
    }

    @discardableResult
    private func execute(_ body: String, for player: ScriptedPlayer) -> String? {
        let source = """
        tell application id "\(player.bundleID)"
            \(body)
        end tell
        """

        guard let script = NSAppleScript(source: source) else {
            return nil
        }

        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let message = errorInfo[NSAppleScript.errorMessage] as? String ?? "Unknown AppleScript error"
            logger.warning("\(player.displayName, privacy: .public) AppleScript failed: \(message, privacy: .public)")
            return nil
        }

        return result.stringValue ?? result.description
    }

    private func pauseFirstPlayingBrowserTab(in browser: BrowserApp) -> BrowserMediaTarget? {
        let source: String
        switch browser.scriptKind {
        case .chrome:
            source = chromePauseFirstPlayingTabScript(bundleID: browser.bundleID)
        case .safari:
            source = safariPauseFirstPlayingTabScript(bundleID: browser.bundleID)
        }

        guard let descriptor = executeDescriptor(source) else {
            return nil
        }

        return browserTarget(from: descriptor, browser: browser)
    }

    private func pausePlayingBrowserTabs(in browser: BrowserApp) -> [BrowserMediaTarget] {
        var targets: [BrowserMediaTarget] = []
        var seen = Set<String>()

        while targets.count < 16 {
            guard let target = pauseFirstPlayingBrowserTab(in: browser) else {
                break
            }
            let key = "\(target.windowIndex):\(target.tabIndex):\(target.url)"
            guard seen.insert(key).inserted else {
                break
            }
            targets.append(target)
        }

        return targets
    }

    private func resume(_ target: BrowserMediaTarget) -> Bool {
        guard isRunning(target.browser) else {
            return false
        }

        let source: String
        switch target.browser.scriptKind {
        case .chrome:
            source = chromeResumeScript(target: target)
        case .safari:
            source = safariResumeScript(target: target)
        }

        return executeDescriptor(source)?.booleanValue == true
    }

    private func executeDescriptor(_ source: String) -> NSAppleEventDescriptor? {
        guard let script = NSAppleScript(source: source) else {
            return nil
        }

        var errorInfo: NSDictionary?
        let result = script.executeAndReturnError(&errorInfo)
        if let errorInfo {
            let message = errorInfo[NSAppleScript.errorMessage] as? String ?? "Unknown AppleScript error"
            logger.warning("Browser AppleScript failed: \(message, privacy: .public)")
            return nil
        }

        return result
    }

    private func browserTarget(from descriptor: NSAppleEventDescriptor, browser: BrowserApp) -> BrowserMediaTarget? {
        guard descriptor.numberOfItems >= 4,
              let windowIndex = descriptor.atIndex(1)?.int32Value,
              let tabIndex = descriptor.atIndex(2)?.int32Value else {
            return nil
        }

        return BrowserMediaTarget(
            browser: browser,
            windowIndex: Int(windowIndex),
            tabIndex: Int(tabIndex),
            title: descriptor.atIndex(3)?.stringValue ?? "",
            url: descriptor.atIndex(4)?.stringValue ?? ""
        )
    }

    private func chromePauseFirstPlayingTabScript(bundleID: String) -> String {
        """
        tell application id "\(bundleID)"
            repeat with windowIndex from 1 to count of windows
                repeat with tabIndex from 1 to count of tabs of window windowIndex
                    set isPlaying to execute tab tabIndex of window windowIndex javascript "\(Self.browserPlayingJavaScript)"
                    if isPlaying is "playing" then
                        set tabTitle to title of tab tabIndex of window windowIndex
                        set tabURL to URL of tab tabIndex of window windowIndex
                        execute tab tabIndex of window windowIndex javascript "\(Self.browserPauseJavaScript)"
                        return {windowIndex, tabIndex, tabTitle, tabURL}
                    end if
                end repeat
            end repeat
        end tell
        return {}
        """
    }

    private func safariPauseFirstPlayingTabScript(bundleID: String) -> String {
        """
        tell application id "\(bundleID)"
            repeat with windowIndex from 1 to count of windows
                repeat with tabIndex from 1 to count of tabs of window windowIndex
                    set isPlaying to do JavaScript "\(Self.browserPlayingJavaScript)" in tab tabIndex of window windowIndex
                    if isPlaying is "playing" then
                        set tabTitle to name of tab tabIndex of window windowIndex
                        set tabURL to URL of tab tabIndex of window windowIndex
                        do JavaScript "\(Self.browserPauseJavaScript)" in tab tabIndex of window windowIndex
                        return {windowIndex, tabIndex, tabTitle, tabURL}
                    end if
                end repeat
            end repeat
        end tell
        return {}
        """
    }

    private func chromeResumeScript(target: BrowserMediaTarget) -> String {
        """
        tell application id "\(target.browser.bundleID)"
            if (count of windows) < \(target.windowIndex) then return false
            if (count of tabs of window \(target.windowIndex)) < \(target.tabIndex) then return false
            set tabTitle to title of tab \(target.tabIndex) of window \(target.windowIndex)
            set tabURL to URL of tab \(target.tabIndex) of window \(target.windowIndex)
            if tabTitle is not "\(Self.appleScriptQuoted(target.title))" then return false
            if tabURL is not "\(Self.appleScriptQuoted(target.url))" then return false
            set isPlaying to execute tab \(target.tabIndex) of window \(target.windowIndex) javascript "\(Self.browserPlayingJavaScript)"
            if isPlaying is "playing" then return false
            set didResume to execute tab \(target.tabIndex) of window \(target.windowIndex) javascript "\(Self.browserResumeJavaScript)"
            return didResume is "resumed"
        end tell
        """
    }

    private func safariResumeScript(target: BrowserMediaTarget) -> String {
        """
        tell application id "\(target.browser.bundleID)"
            if (count of windows) < \(target.windowIndex) then return false
            if (count of tabs of window \(target.windowIndex)) < \(target.tabIndex) then return false
            set tabTitle to name of tab \(target.tabIndex) of window \(target.windowIndex)
            set tabURL to URL of tab \(target.tabIndex) of window \(target.windowIndex)
            if tabTitle is not "\(Self.appleScriptQuoted(target.title))" then return false
            if tabURL is not "\(Self.appleScriptQuoted(target.url))" then return false
            set isPlaying to do JavaScript "\(Self.browserPlayingJavaScript)" in tab \(target.tabIndex) of window \(target.windowIndex)
            if isPlaying is "playing" then return false
            set didResume to do JavaScript "\(Self.browserResumeJavaScript)" in tab \(target.tabIndex) of window \(target.windowIndex)
            return didResume is "resumed"
        end tell
        """
    }

    private static let browserPlayingJavaScript = appleScriptQuoted(
        "(() => Array.from(document.querySelectorAll('video,audio')).some((media) => !media.paused && !media.ended) ? 'playing' : '')()"
    )

    private static let browserPauseJavaScript = appleScriptQuoted(
        "(() => { Array.from(document.querySelectorAll('video,audio')).filter((media) => !media.paused && !media.ended).forEach((media) => media.pause()); return 'paused'; })()"
    )

    private static let browserResumeJavaScript = appleScriptQuoted(
        "(() => { const media = Array.from(document.querySelectorAll('video,audio')).find((item) => item.paused && !item.ended); if (!media) return ''; media.play(); return 'resumed'; })()"
    )

    private static func appleScriptQuoted(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "")
    }
}

private final class ControlCenterNowPlayingController {
    private struct Card {
        var label: String
        var pauseButton: AXUIElement?
        var playButton: AXUIElement?
    }

    private let logger = Logger(subsystem: AppConstants.loggerSubsystem, category: "Playback")

    func pause(_ requests: [ControlCenterPauseRequest]) -> [ControlCenterMediaTarget] {
        guard !requests.isEmpty else {
            return []
        }

        return withNowPlayingCards { cards in
            var targets: [ControlCenterMediaTarget] = []
            var handledSources = Set<String>()
            var handledCards = Set<String>()

            for request in requests {
                guard handledSources.insert(request.source.key).inserted else {
                    continue
                }

                for candidate in request.candidates {
                    guard let card = matchingCard(in: cards, appDisplayName: candidate.appDisplayName) else {
                        logMissingCard(appDisplayName: candidate.appDisplayName, cards: cards)
                        continue
                    }

                    guard handledCards.insert(normalizedTitle(card.label)).inserted else {
                        continue
                    }

                    guard let pauseButton = card.pauseButton else {
                        logger.info(
                            "Control Center card for \(candidate.appDisplayName, privacy: .public) is not playing: \(card.label, privacy: .public)"
                        )
                        continue
                    }

                    guard press(pauseButton, actionName: "pause", appDisplayName: candidate.appDisplayName) else {
                        continue
                    }

                    targets.append(
                        ControlCenterMediaTarget(
                            appDisplayName: candidate.appDisplayName,
                            bundleID: candidate.bundleID,
                            cardLabel: card.label,
                            source: candidate.source
                        )
                    )
                    break
                }
            }

            return targets
        } ?? []
    }

    func resume(_ targets: [ControlCenterMediaTarget]) -> Int {
        guard !targets.isEmpty else {
            return 0
        }

        return withNowPlayingCards { cards in
            var resumedCount = 0
            var handledCards = Set<String>()

            for target in targets {
                guard let card = matchingCard(in: cards, target: target) else {
                    logMissingCard(appDisplayName: target.appDisplayName, cards: cards)
                    continue
                }

                guard handledCards.insert(normalizedTitle(card.label)).inserted else {
                    continue
                }

                guard let playButton = card.playButton else {
                    logger.info(
                        "Control Center card for \(target.appDisplayName, privacy: .public) is not paused: \(card.label, privacy: .public)"
                    )
                    continue
                }

                if press(playButton, actionName: "play", appDisplayName: target.appDisplayName) {
                    resumedCount += 1
                }
            }

            return resumedCount
        } ?? 0
    }

    private func withNowPlayingCards<T>(_ body: ([Card]) -> T?) -> T? {
        guard AXIsProcessTrusted() else {
            logger.info("Accessibility is not trusted; skipping Control Center Now Playing")
            return nil
        }

        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.apple.controlcenter"
        }) else {
            logger.info("Control Center process not found")
            return nil
        }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.8)

        let wasOpen = nowPlayingCards(in: appElement) != nil
        guard wasOpen || pressNowPlayingMenuItem(in: appElement) else {
            logger.info("Control Center Now Playing menu bar item not found")
            return nil
        }

        if !wasOpen {
            Thread.sleep(forTimeInterval: 0.16)
        }

        defer {
            if !wasOpen {
                _ = pressNowPlayingMenuItem(in: appElement)
            }
        }

        guard let cards = nowPlayingCards(in: appElement) else {
            logger.info("Control Center Now Playing cards did not appear")
            return nil
        }

        return body(cards)
    }

    private func pressNowPlayingMenuItem(in appElement: AXUIElement) -> Bool {
        guard let menuBar = descendants(of: appElement).first(where: {
            role(of: $0) == "AXMenuBar"
        }) else {
            return false
        }

        guard let item = children(of: menuBar).first(where: {
            normalizedTitle(description(of: $0)) == "now playing"
        }) else {
            return false
        }

        return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success
    }

    private func nowPlayingCards(in appElement: AXUIElement) -> [Card]? {
        for window in children(of: appElement) where role(of: window) == "AXWindow" {
            let cards = mediaCards(in: window)
            if !cards.isEmpty {
                return cards
            }
        }

        return nil
    }

    private func mediaCards(in root: AXUIElement) -> [Card] {
        descendants(of: root)
            .compactMap(card)
    }

    private func card(from element: AXUIElement) -> Card? {
        guard role(of: element) == "AXGroup" else {
            return nil
        }

        let directChildren = children(of: element)
        let label = directChildren
            .filter { role(of: $0) == "AXStaticText" }
            .compactMap { textValue(of: $0) }
            .first { !$0.isEmpty }
        guard let label else {
            return nil
        }

        let buttons = directChildren.filter { role(of: $0) == "AXButton" }
        let pauseButton = buttons.first { normalizedTitle(description(of: $0)) == "pause" }
        let playButton = buttons.first { normalizedTitle(description(of: $0)) == "play" }
        guard pauseButton != nil || playButton != nil else {
            return nil
        }

        return Card(label: label, pauseButton: pauseButton, playButton: playButton)
    }

    private func matchingCard(in cards: [Card], target: ControlCenterMediaTarget) -> Card? {
        cards.first { normalizedTitle($0.label) == normalizedTitle(target.cardLabel) }
            ?? matchingCard(in: cards, appDisplayName: target.appDisplayName)
    }

    private func matchingCard(in cards: [Card], appDisplayName: String) -> Card? {
        let needle = normalizedTitle(appDisplayName)
        return cards.first { normalizedTitle($0.label).contains(needle) }
    }

    private func press(_ element: AXUIElement, actionName: String, appDisplayName: String) -> Bool {
        let error = AXUIElementPerformAction(element, kAXPressAction as CFString)
        guard error == .success else {
            logger.info(
                "Control Center \(actionName, privacy: .public) failed for \(appDisplayName, privacy: .public): \(String(describing: error), privacy: .public)"
            )
            return false
        }

        logger.info("Sent Control Center \(actionName, privacy: .public) to \(appDisplayName, privacy: .public)")
        return true
    }

    private func logMissingCard(appDisplayName: String, cards: [Card]) {
        let labels = cards.map(\.label).joined(separator: " | ")
        logger.info(
            "Control Center card for \(appDisplayName, privacy: .public) not found. Cards: \(labels, privacy: .public)"
        )
    }

    private func descendants(of element: AXUIElement) -> [AXUIElement] {
        var result: [AXUIElement] = []
        var stack = children(of: element)
        while let next = stack.popLast() {
            result.append(next)
            stack.append(contentsOf: children(of: next))
        }
        return result
    }

    private func children(of element: AXUIElement) -> [AXUIElement] {
        guard let children = attribute(kAXChildrenAttribute, of: element) as? [AXUIElement] else {
            return []
        }
        return children
    }

    private func role(of element: AXUIElement) -> String {
        attribute(kAXRoleAttribute, of: element) as? String ?? ""
    }

    private func description(of element: AXUIElement) -> String {
        attribute(kAXDescriptionAttribute, of: element) as? String ?? ""
    }

    private func textValue(of element: AXUIElement) -> String? {
        (attribute(kAXValueAttribute, of: element) as? String)
            ?? (attribute(kAXTitleAttribute, of: element) as? String)
    }

    private func attribute(_ attribute: String, of element: AXUIElement) -> AnyObject? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard error == .success else {
            return nil
        }
        return value as AnyObject?
    }

    private func normalizedTitle(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

private final class AccessibilityMenuPlaybackController {
    private let logger = Logger(subsystem: AppConstants.loggerSubsystem, category: "Playback")
    private let playbackMenuTitles = ["Playback"]
    private let pauseTitles = ["Pause", "Pause Playback"]
    private let playTitles = ["Play", "Resume", "Resume Playback"]

    func pause(_ player: AccessibilityMenuPlayer) -> Bool {
        pressPlaybackCommand(titledAnyOf: pauseTitles, in: player, commandName: "pause")
    }

    func resume(_ player: AccessibilityMenuPlayer) -> Bool {
        pressPlaybackCommand(titledAnyOf: playTitles, in: player, commandName: "play")
    }

    private func pressPlaybackCommand(
        titledAnyOf titles: [String],
        in player: AccessibilityMenuPlayer,
        commandName: String
    ) -> Bool {
        guard AXIsProcessTrusted() else {
            logger.info("Accessibility is not trusted; skipping menu \(commandName, privacy: .public) for \(player.displayName, privacy: .public)")
            return false
        }

        let appElement = AXUIElementCreateApplication(player.processID)
        AXUIElementSetMessagingTimeout(appElement, 0.3)

        guard let menuBarValue = attribute(kAXMenuBarAttribute, of: appElement) else {
            logger.info("Accessibility menu bar unavailable for \(player.displayName, privacy: .public)")
            return false
        }
        let menuBar = menuBarValue as! AXUIElement

        let normalizedTitles = Set(titles.map(normalizedTitle))
        for menuBarItem in children(of: menuBar) where isPlaybackMenu(menuBarItem) {
            if let menuItem = findMenuItem(in: menuBarItem, titledAnyOf: normalizedTitles) {
                return press(menuItem, player: player, commandName: commandName)
            }
        }

        return false
    }

    private func isPlaybackMenu(_ element: AXUIElement) -> Bool {
        guard let title = title(of: element) else {
            return false
        }

        return playbackMenuTitles.map(normalizedTitle).contains(normalizedTitle(title))
    }

    private func findMenuItem(
        in element: AXUIElement,
        titledAnyOf titles: Set<String>,
        depth: Int = 0
    ) -> AXUIElement? {
        guard depth <= 6 else {
            return nil
        }

        if let title = title(of: element),
           titles.contains(normalizedTitle(title)),
           isEnabled(element) {
            return element
        }

        for child in children(of: element) {
            if let found = findMenuItem(in: child, titledAnyOf: titles, depth: depth + 1) {
                return found
            }
        }

        return nil
    }

    private func press(_ element: AXUIElement, player: AccessibilityMenuPlayer, commandName: String) -> Bool {
        let error = AXUIElementPerformAction(element, kAXPressAction as CFString)
        guard error == .success else {
            logger.info(
                "Accessibility menu \(commandName, privacy: .public) failed for \(player.displayName, privacy: .public): \(String(describing: error), privacy: .public)"
            )
            return false
        }

        logger.info("Sent Accessibility menu \(commandName, privacy: .public) to \(player.displayName, privacy: .public)")
        return true
    }

    private func children(of element: AXUIElement) -> [AXUIElement] {
        guard let children = attribute(kAXChildrenAttribute, of: element) as? [AXUIElement] else {
            return []
        }
        return children
    }

    private func title(of element: AXUIElement) -> String? {
        attribute(kAXTitleAttribute, of: element) as? String
    }

    private func isEnabled(_ element: AXUIElement) -> Bool {
        (attribute(kAXEnabledAttribute, of: element) as? Bool) ?? true
    }

    private func attribute(_ attribute: String, of element: AXUIElement) -> AnyObject? {
        var value: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard error == .success else {
            return nil
        }
        return value as AnyObject?
    }

    private func normalizedTitle(_ title: String) -> String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

private final class MediaRemoteNowPlayingController {
    private enum Command {
        static let play: UInt32 = 0
        static let pause: UInt32 = 1
    }

    private typealias IsPlayingCallback = @convention(block) (Bool) -> Void
    private typealias GetIsPlaying = @convention(c) (DispatchQueue, @escaping IsPlayingCallback) -> Void
    private typealias SendCommand = @convention(c) (UInt32, NSDictionary?) -> Bool
    private typealias InfoCallback = @convention(block) (AnyObject?) -> Void
    private typealias GetNowPlayingInfo = @convention(c) (DispatchQueue, @escaping InfoCallback) -> Void
    private typealias ClientCallback = @convention(block) (AnyObject?) -> Void
    private typealias GetNowPlayingClient = @convention(c) (DispatchQueue, @escaping ClientCallback) -> Void
    private typealias ArrayCallback = @convention(block) (NSArray?) -> Void
    private typealias GetActivePlayerPathsForOrigin = @convention(c) (
        AnyObject?,
        DispatchQueue?,
        @escaping ArrayCallback
    ) -> Void
    private typealias GetNowPlayingInfoForPlayer = @convention(c) (
        AnyObject,
        Bool,
        DispatchQueue?,
        @escaping InfoCallback
    ) -> Void
    private typealias SendCommandCompletion = @convention(block) (AnyObject?, NSArray?) -> Void
    private typealias SendCommandToPlayer = @convention(c) (
        UInt32,
        NSDictionary?,
        AnyObject,
        UInt32,
        DispatchQueue?,
        @escaping SendCommandCompletion
    ) -> Bool
    private typealias ClientStringGetter = @convention(c) (AnyObject?) -> Unmanaged<CFString>?
    private typealias ClientPIDGetter = @convention(c) (AnyObject?) -> pid_t

    private let logger = Logger(subsystem: AppConstants.loggerSubsystem, category: "Playback")
    private let getIsPlaying: GetIsPlaying?
    private let sendCommand: SendCommand?
    private let getNowPlayingInfo: GetNowPlayingInfo?
    private let getNowPlayingClient: GetNowPlayingClient?
    private let getActivePlayerPathsForOrigin: GetActivePlayerPathsForOrigin?
    private let getNowPlayingInfoForPlayer: GetNowPlayingInfoForPlayer?
    private let sendCommandToPlayer: SendCommandToPlayer?
    private let getBundleID: ClientStringGetter?
    private let getParentBundleID: ClientStringGetter?
    private let getDisplayName: ClientStringGetter?
    private let getProcessID: ClientPIDGetter?

    var isAvailable: Bool {
        sendCommand != nil || sendCommandToPlayer != nil
    }

    init() {
        let handle = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW | RTLD_GLOBAL)
        guard let handle else {
            logger.warning("MediaRemote unavailable: \(String(cString: dlerror()), privacy: .public)")
            getIsPlaying = nil
            sendCommand = nil
            getNowPlayingInfo = nil
            getNowPlayingClient = nil
            getActivePlayerPathsForOrigin = nil
            getNowPlayingInfoForPlayer = nil
            sendCommandToPlayer = nil
            getBundleID = nil
            getParentBundleID = nil
            getDisplayName = nil
            getProcessID = nil
            return
        }

        getIsPlaying = Self.symbol(handle, "MRMediaRemoteGetNowPlayingApplicationIsPlaying")
        sendCommand = Self.symbol(handle, "MRMediaRemoteSendCommand")
        getNowPlayingInfo = Self.symbol(handle, "MRMediaRemoteGetNowPlayingInfo")
        getNowPlayingClient = Self.symbol(handle, "MRMediaRemoteGetNowPlayingClient")
        getActivePlayerPathsForOrigin = Self.symbol(handle, "MRMediaRemoteGetActivePlayerPathsForOrigin")
        getNowPlayingInfoForPlayer = Self.symbol(handle, "MRMediaRemoteGetNowPlayingInfoForPlayer")
        sendCommandToPlayer = Self.symbol(handle, "MRMediaRemoteSendCommandToPlayer")
        getBundleID = Self.symbol(handle, "MRNowPlayingClientGetBundleIdentifier")
        getParentBundleID = Self.symbol(handle, "MRNowPlayingClientGetParentAppBundleIdentifier")
        getDisplayName = Self.symbol(handle, "MRNowPlayingClientGetDisplayName")
        getProcessID = Self.symbol(handle, "MRNowPlayingClientGetProcessIdentifier")
    }

    func pauseIfPlaying() -> MediaRemotePause? {
        guard currentIsPlaying() == true || currentPlaybackRateIsPlaying() else {
            return nil
        }

        let identity = currentIdentity()
        guard sendCommand?(Command.pause, nil) == true else {
            return nil
        }

        logger.info("Sent MediaRemote pause to System Now Playing")
        return MediaRemotePause(identity: identity)
    }

    func playingPlayerSnapshots() -> [MediaRemotePlayerSnapshot] {
        activePlayerPaths().compactMap { path in
            let snapshot = describePlayerPath(path)
            return snapshot.isPlaying ? snapshot : nil
        }
    }

    func pause(_ snapshot: MediaRemotePlayerSnapshot) -> Bool {
        pause(snapshot.token)
    }

    func pause(_ token: MediaRemotePlayerToken) -> Bool {
        guard send(command: Command.pause, to: token.path) else {
            return false
        }

        Thread.sleep(forTimeInterval: 0.04)
        if isPlaying(path: token.path) {
            logger.info("MediaRemote player-path pause did not quiet \(token.displayName, privacy: .public)")
            return false
        }

        logger.info("Sent MediaRemote player-path pause to \(token.displayName, privacy: .public)")
        return true
    }

    func resume(_ token: MediaRemotePlayerToken) -> Bool {
        guard !isPlaying(path: token.path) else {
            logger.info("Skipped MediaRemote player-path resume because \(token.displayName, privacy: .public) is already playing")
            return false
        }

        guard send(command: Command.play, to: token.path) else {
            return false
        }

        logger.info("Sent MediaRemote player-path play to \(token.displayName, privacy: .public)")
        return true
    }

    func pauseUntilQuiet(
        capturedProcesses: [AudioOutputProcess],
        outputReader: CoreAudioOutputProcessReader,
        maxPasses: Int = 4
    ) -> Bool {
        guard !capturedProcesses.isEmpty, let sendCommand else {
            return false
        }

        var didSend = false
        for pass in 0..<maxPasses {
            let stillPlaying = outputReader.runningOutputProcesses(matching: capturedProcesses)
            guard !stillPlaying.isEmpty else {
                return didSend
            }

            guard sendCommand(Command.pause, nil) else {
                break
            }

            didSend = true
            logger.info(
                "Sent MediaRemote global pause pass \(pass + 1, privacy: .public) for \(stillPlaying.count, privacy: .public) output process(es)"
            )
            Thread.sleep(forTimeInterval: 0.045)
        }

        let finalStillPlaying = outputReader.runningOutputProcesses(matching: capturedProcesses)
        if finalStillPlaying.isEmpty {
            return didSend
        }

        let names = finalStillPlaying.map(\.displayName).joined(separator: ", ")
        logger.info("MediaRemote pause did not quiet captured source(s): \(names, privacy: .public)")
        return false
    }

    func resumeIfSafe(identity: NowPlayingIdentity?) -> Bool {
        guard let identity else {
            logger.info("Skipped MediaRemote resume because Now Playing identity was unavailable")
            return false
        }

        guard currentIsPlaying() == false else {
            logger.info("Skipped MediaRemote resume because something is already playing")
            return false
        }

        guard let currentIdentity = currentIdentity() else {
            logger.info("Skipped MediaRemote resume because current Now Playing identity is unavailable")
            return false
        }

        if !identity.matches(currentIdentity) {
            logger.info("Skipped MediaRemote resume because Now Playing identity changed")
            return false
        }

        guard sendCommand?(Command.play, nil) == true else {
            return false
        }

        logger.info("Sent MediaRemote play to System Now Playing")
        return true
    }

    func snapshotIdentity() -> NowPlayingIdentity? {
        currentIdentity()
    }

    private func activePlayerPaths(timeout: TimeInterval = 0.5) -> [AnyObject] {
        guard let getActivePlayerPathsForOrigin else {
            return []
        }

        let group = DispatchGroup()
        let lock = NSLock()
        var result: [AnyObject] = []

        group.enter()
        getActivePlayerPathsForOrigin(nil, .global(qos: .userInitiated)) { paths in
            lock.lock()
            result = (paths as? [AnyObject]) ?? []
            lock.unlock()
            group.leave()
        }

        guard group.wait(timeout: .now() + timeout) == .success else {
            logger.warning("Timed out while reading MediaRemote active player paths")
            return []
        }

        lock.lock()
        defer {
            lock.unlock()
        }
        return result
    }

    private func describePlayerPath(_ path: AnyObject) -> MediaRemotePlayerSnapshot {
        let info = nowPlayingInfo(for: path)
        let client = objectValue(path, selector: "client")
        let player = objectValue(path, selector: "player")
        let bundleID = retainedString(from: getBundleID?(client)) ?? retainedString(from: getParentBundleID?(client))
        let title = info?["kMRMediaRemoteNowPlayingInfoTitle"] as? String
        let artist = info?["kMRMediaRemoteNowPlayingInfoArtist"] as? String
        let playbackRate = (info?["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? NSNumber)?.doubleValue
        let clientName = retainedString(from: getDisplayName?(client))
        let playerName = stringValue(player, selector: "displayName")
        let displayName: String
        if let title, !title.isEmpty {
            if let artist, !artist.isEmpty {
                displayName = "\(title) - \(artist)"
            } else {
                displayName = title
            }
        } else {
            displayName = playerName ?? clientName ?? bundleID ?? "System Media Source"
        }

        return MediaRemotePlayerSnapshot(
            path: path,
            key: playerPathKey(path, bundleID: bundleID, title: title),
            displayName: displayName,
            bundleID: bundleID,
            playbackRate: playbackRate
        )
    }

    private func playerPathKey(_ path: AnyObject, bundleID: String?, title: String?) -> String {
        if let data = objectValue(path, selector: "data") as? Data {
            return data.base64EncodedString()
        }
        if let data = objectValue(path, selector: "data") as? NSData {
            return data.base64EncodedString()
        }
        let player = objectValue(path, selector: "player")
        let playerID = stringValue(player, selector: "identifier")
        return [bundleID, playerID, title, String(describing: path)]
            .compactMap { $0 }
            .joined(separator: "|")
    }

    private func isPlaying(path: AnyObject) -> Bool {
        guard let rate = (nowPlayingInfo(for: path)?["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? NSNumber)?.doubleValue else {
            return false
        }
        return rate > 0.01
    }

    private func nowPlayingInfo(for path: AnyObject, timeout: TimeInterval = 0.35) -> NSDictionary? {
        guard let getNowPlayingInfoForPlayer else {
            return nil
        }

        let group = DispatchGroup()
        let lock = NSLock()
        var result: NSDictionary?

        group.enter()
        getNowPlayingInfoForPlayer(path, false, .global(qos: .userInitiated)) { info in
            lock.lock()
            result = info as? NSDictionary
            lock.unlock()
            group.leave()
        }

        guard group.wait(timeout: .now() + timeout) == .success else {
            logger.warning("Timed out while reading MediaRemote player Now Playing info")
            return nil
        }

        lock.lock()
        defer {
            lock.unlock()
        }
        return result
    }

    private func send(command: UInt32, to path: AnyObject, timeout: TimeInterval = 0.35) -> Bool {
        guard let sendCommandToPlayer else {
            return false
        }

        let group = DispatchGroup()
        let lock = NSLock()
        var completedWithoutError = false

        group.enter()
        let didSend = sendCommandToPlayer(command, nil, path, 0, .global(qos: .userInitiated)) { error, _ in
            lock.lock()
            completedWithoutError = error == nil
            lock.unlock()
            group.leave()
        }

        guard didSend else {
            return false
        }

        guard group.wait(timeout: .now() + timeout) == .success else {
            logger.warning("Timed out while sending MediaRemote player command")
            return true
        }

        lock.lock()
        defer {
            lock.unlock()
        }
        return completedWithoutError
    }

    private func objectValue(_ object: AnyObject?, selector selectorName: String) -> AnyObject? {
        guard let object = object as? NSObject else {
            return nil
        }

        let selector = NSSelectorFromString(selectorName)
        guard object.responds(to: selector) else {
            return nil
        }

        return object.perform(selector)?.takeUnretainedValue()
    }

    private func stringValue(_ object: AnyObject?, selector selectorName: String) -> String? {
        objectValue(object, selector: selectorName) as? String
    }

    private static func symbol<T>(_ handle: UnsafeMutableRawPointer, _ name: String) -> T? {
        guard let pointer = dlsym(handle, name) else {
            return nil
        }
        return unsafeBitCast(pointer, to: T.self)
    }

    private func currentIsPlaying(timeout: TimeInterval = 0.35) -> Bool? {
        guard let getIsPlaying else {
            return nil
        }

        let group = DispatchGroup()
        let lock = NSLock()
        var result: Bool?

        group.enter()
        getIsPlaying(.global(qos: .userInitiated)) { isPlaying in
            lock.lock()
            result = isPlaying
            lock.unlock()
            group.leave()
        }

        guard group.wait(timeout: .now() + timeout) == .success else {
            logger.warning("Timed out while reading System Now Playing state")
            return nil
        }

        lock.lock()
        defer {
            lock.unlock()
        }
        return result
    }

    private func currentPlaybackRateIsPlaying() -> Bool {
        guard let info = currentNowPlayingInfo(),
              let rate = info["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? NSNumber else {
            return false
        }
        return rate.doubleValue > 0.01
    }

    private func currentNowPlayingInfo(timeout: TimeInterval = 0.35) -> NSDictionary? {
        guard let getNowPlayingInfo else {
            return nil
        }

        let group = DispatchGroup()
        let lock = NSLock()
        var result: NSDictionary?

        group.enter()
        getNowPlayingInfo(.global(qos: .userInitiated)) { info in
            lock.lock()
            result = info as? NSDictionary
            lock.unlock()
            group.leave()
        }

        guard group.wait(timeout: .now() + timeout) == .success else {
            logger.warning("Timed out while reading System Now Playing info")
            return nil
        }

        lock.lock()
        defer {
            lock.unlock()
        }
        return result
    }

    private func currentIdentity(timeout: TimeInterval = 0.35) -> NowPlayingIdentity? {
        guard let getNowPlayingClient else {
            return nil
        }

        let group = DispatchGroup()
        let lock = NSLock()
        var client: AnyObject?

        group.enter()
        getNowPlayingClient(.global(qos: .userInitiated)) { nowPlayingClient in
            lock.lock()
            client = nowPlayingClient
            lock.unlock()
            group.leave()
        }

        guard group.wait(timeout: .now() + timeout) == .success else {
            logger.warning("Timed out while reading System Now Playing client")
            return nil
        }

        lock.lock()
        defer {
            lock.unlock()
        }

        guard let client else {
            return nil
        }

        return NowPlayingIdentity(
            bundleID: retainedString(from: getBundleID?(client)),
            parentBundleID: retainedString(from: getParentBundleID?(client)),
            processID: getProcessID?(client)
        )
    }

    private func retainedString(from unmanaged: Unmanaged<CFString>?) -> String? {
        unmanaged?.takeUnretainedValue() as String?
    }
}

private struct CoreAudioOutputProcessReader {
    private let logger = Logger(subsystem: AppConstants.loggerSubsystem, category: "Playback")

    func runningOutputProcesses() -> [AudioOutputProcess] {
        let processObjectIDs: [AudioObjectID]
        do {
            processObjectIDs = try readObjectIDArray(
                AudioObjectID(kAudioObjectSystemObject),
                selector: kAudioHardwarePropertyProcessObjectList
            )
        } catch {
            logger.warning("Output process scan failed: \(error.localizedDescription, privacy: .public)")
            return []
        }

        var processes: [AudioOutputProcess] = []
        var seen = Set<String>()

        for processObjectID in processObjectIDs {
            guard readUInt32(processObjectID, selector: kAudioProcessPropertyIsRunningOutput) == 1 else {
                continue
            }

            let processID = readPID(processObjectID)
            let runningApplication = processID.flatMap(NSRunningApplication.init(processIdentifier:))
            let bundleID = readStringProperty(processObjectID, selector: kAudioProcessPropertyBundleID)
                ?? runningApplication?.bundleIdentifier

            guard bundleID != AppConstants.bundleIdentifier else {
                continue
            }

            let displayName = runningApplication?.localizedName
                ?? bundleID
                ?? processID.map { "Process \($0)" }
                ?? "Unknown Audio Source"
            let process = AudioOutputProcess(
                processID: processID,
                bundleID: bundleID,
                displayName: displayName
            )

            guard seen.insert(process.key).inserted else {
                continue
            }
            processes.append(process)
        }

        return processes
    }

    func runningOutputProcesses(matching capturedProcesses: [AudioOutputProcess]) -> [AudioOutputProcess] {
        guard !capturedProcesses.isEmpty else {
            return []
        }

        let current = runningOutputProcesses()
        return capturedProcesses.filter { captured in
            current.contains { currentProcess in
                currentProcess.matches(captured)
            }
        }
    }

    private func readObjectIDArray(
        _ objectID: AudioObjectID,
        selector: AudioObjectPropertySelector
    ) throws -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &dataSize)
        guard status == noErr else {
            throw CoreAudioOutputReaderError.status("process object list size", status)
        }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else {
            return []
        }

        var objectIDs = Array(repeating: AudioObjectID(0), count: count)
        status = objectIDs.withUnsafeMutableBufferPointer { buffer in
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &dataSize, buffer.baseAddress!)
        }
        guard status == noErr else {
            throw CoreAudioOutputReaderError.status("process object list read", status)
        }

        return objectIDs
    }

    private func readUInt32(_ objectID: AudioObjectID, selector: AudioObjectPropertySelector) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        guard AudioObjectHasProperty(objectID, &address) else {
            return nil
        }

        var value: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &dataSize, &value)
        return status == noErr ? value : nil
    }

    private func readPID(_ objectID: AudioObjectID) -> pid_t? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        guard AudioObjectHasProperty(objectID, &address) else {
            return nil
        }

        var value = pid_t()
        var dataSize = UInt32(MemoryLayout<pid_t>.size)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &dataSize, &value)
        return status == noErr ? value : nil
    }

    private func readStringProperty(_ objectID: AudioObjectID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )

        guard AudioObjectHasProperty(objectID, &address) else {
            return nil
        }

        var value: Unmanaged<CFString>?
        var dataSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(objectID, &address, 0, nil, &dataSize, &value)
        guard status == noErr, let value else {
            return nil
        }

        return value.takeRetainedValue() as String
    }
}

private enum CoreAudioOutputReaderError: LocalizedError {
    case status(String, OSStatus)

    var errorDescription: String? {
        switch self {
        case .status(let operation, let status):
            "\(operation): \(status)"
        }
    }
}
