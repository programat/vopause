@preconcurrency import CoreAudio
import Foundation
import OSLog
import VopauseCore

final class CoreAudioMicMonitor: @unchecked Sendable {
    typealias SnapshotHandler = @Sendable (MicHardwareSnapshot) -> Void

    private let queue = DispatchQueue(label: "dev.egor.vopause.core-audio")
    private let handler: SnapshotHandler
    private let logger = Logger(subsystem: AppConstants.loggerSubsystem, category: "Audio")
    private var isStarted = false
    private var systemDevicesListener: AudioObjectPropertyListenerBlock?
    private var systemProcessListListener: AudioObjectPropertyListenerBlock?
    private var deviceRunningListeners: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    private var processInputListeners: [AudioObjectID: AudioObjectPropertyListenerBlock] = [:]
    private var inputDeviceIDs: [AudioObjectID] = []
    private var processObjectIDs: [AudioObjectID] = []
    private var canUseProcessInputState = false
    private var lastWarning: String?

    init(handler: @escaping SnapshotHandler) {
        self.handler = handler
    }

    deinit {
        stop()
    }

    func start() {
        queue.async { [weak self] in
            guard let self, !self.isStarted else {
                return
            }

            self.isStarted = true
            self.installSystemProcessListListener()
            self.installSystemDevicesListener()
            self.rebuildProcessListeners()
            self.rebuildDeviceListeners()
        }
    }

    func stop() {
        queue.sync {
            guard isStarted else {
                return
            }

            removeSystemDevicesListener()
            removeSystemProcessListListener()
            removeProcessInputListeners()
            removeDeviceRunningListeners()
            isStarted = false
        }
    }

    func forceRefresh() {
        queue.async { [weak self] in
            self?.refreshProcessMonitoring()
            self?.rebuildDeviceListeners()
        }
    }

    private func installSystemDevicesListener() {
        guard systemDevicesListener == nil else {
            return
        }

        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.rebuildDeviceListeners()
        }
        var address = Self.devicesAddress
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            queue,
            listener
        )

        if status == noErr {
            systemDevicesListener = listener
        } else {
            setWarning("Device listener failed: \(Self.describe(status: status))")
        }
    }

    private func installSystemProcessListListener() {
        guard systemProcessListListener == nil else {
            return
        }

        var address = Self.processObjectListAddress
        guard AudioObjectHasProperty(AudioObjectID(kAudioObjectSystemObject), &address) else {
            canUseProcessInputState = false
            setWarning("Process input state unavailable")
            return
        }

        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.rebuildProcessListeners()
        }
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            queue,
            listener
        )

        if status == noErr {
            systemProcessListListener = listener
            canUseProcessInputState = true
        } else {
            canUseProcessInputState = false
            setWarning("Process listener failed: \(Self.describe(status: status))")
        }
    }

    private func removeSystemDevicesListener() {
        guard let listener = systemDevicesListener else {
            return
        }

        var address = Self.devicesAddress
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            queue,
            listener
        )
        systemDevicesListener = nil
    }

    private func removeSystemProcessListListener() {
        guard let listener = systemProcessListListener else {
            return
        }

        var address = Self.processObjectListAddress
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            queue,
            listener
        )
        systemProcessListListener = nil
    }

    private func rebuildProcessListeners() {
        removeProcessInputListeners()

        guard canUseProcessInputState else {
            publishSnapshot()
            return
        }

        do {
            processObjectIDs = try readObjectIDArray(
                AudioObjectID(kAudioObjectSystemObject),
                selector: kAudioHardwarePropertyProcessObjectList,
                scope: kAudioObjectPropertyScopeGlobal
            )
            for processObjectID in processObjectIDs {
                installProcessInputListener(for: processObjectID)
            }
            if inputDeviceIDs.isEmpty {
                lastWarning = nil
            }
        } catch {
            processObjectIDs = []
            canUseProcessInputState = false
            setWarning("Process scan failed: \(error.localizedDescription)")
        }

        publishSnapshot()
    }

    private func refreshProcessMonitoring() {
        if !canUseProcessInputState {
            removeSystemProcessListListener()
            installSystemProcessListListener()
        }

        rebuildProcessListeners()
    }

    private func rebuildDeviceListeners() {
        removeDeviceRunningListeners()

        do {
            inputDeviceIDs = try readAllDeviceIDs().filter(deviceHasInputChannels)
            for deviceID in inputDeviceIDs {
                installRunningListener(for: deviceID)
            }
            if inputDeviceIDs.isEmpty {
                setWarning("No input devices")
            } else {
                lastWarning = nil
            }
        } catch {
            inputDeviceIDs = []
            setWarning("Audio scan failed: \(error.localizedDescription)")
        }

        publishSnapshot()
    }

    private func installProcessInputListener(for processObjectID: AudioObjectID) {
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.publishSnapshot()
        }
        var address = Self.processIsRunningInputAddress
        let status = AudioObjectAddPropertyListenerBlock(processObjectID, &address, queue, listener)

        if status == noErr {
            processInputListeners[processObjectID] = listener
        }
    }

    private func removeProcessInputListeners() {
        for (processObjectID, listener) in processInputListeners {
            var address = Self.processIsRunningInputAddress
            guard AudioObjectHasProperty(processObjectID, &address) else {
                continue
            }
            AudioObjectRemovePropertyListenerBlock(processObjectID, &address, queue, listener)
        }
        processInputListeners.removeAll()
    }

    private func installRunningListener(for deviceID: AudioObjectID) {
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.publishSnapshot()
        }
        var address = Self.runningSomewhereAddress
        let status = AudioObjectAddPropertyListenerBlock(deviceID, &address, queue, listener)

        if status == noErr {
            deviceRunningListeners[deviceID] = listener
        } else {
            setWarning("Mic listener failed: \(Self.describe(status: status))")
        }
    }

    private func removeDeviceRunningListeners() {
        for (deviceID, listener) in deviceRunningListeners {
            var address = Self.runningSomewhereAddress
            guard AudioObjectHasProperty(deviceID, &address) else {
                continue
            }
            AudioObjectRemovePropertyListenerBlock(deviceID, &address, queue, listener)
        }
        deviceRunningListeners.removeAll()
    }

    private func publishSnapshot() {
        let activeInputProcesses = canUseProcessInputState
            ? processObjectIDs.filter(readProcessIsRunningInput)
            : []
        let activeProcessInputDevices = Set(activeInputProcesses.flatMap(readInputDeviceIDsUsedByProcess))
        let fallbackActiveDeviceIDs = canUseProcessInputState
            ? []
            : Set(inputDeviceIDs.filter(readDeviceIsRunningSomewhere))

        let devices = inputDeviceIDs.map { deviceID in
            AudioInputDevice(
                id: deviceID,
                name: readStringProperty(
                    deviceID,
                    selector: kAudioObjectPropertyName,
                    scope: kAudioObjectPropertyScopeGlobal
                ) ?? "Input \(deviceID)",
                uid: readStringProperty(
                    deviceID,
                    selector: kAudioDevicePropertyDeviceUID,
                    scope: kAudioObjectPropertyScopeGlobal
                ),
                isRunning: activeProcessInputDevices.contains(deviceID)
                    || (!canUseProcessInputState && fallbackActiveDeviceIDs.contains(deviceID))
            )
        }

        let rawActivity: RawMicActivity
        if devices.isEmpty {
            rawActivity = .unknown
        } else if canUseProcessInputState {
            rawActivity = activeInputProcesses.isEmpty ? .inactive : .active
        } else {
            rawActivity = fallbackActiveDeviceIDs.isEmpty ? .inactive : .active
        }

        let snapshot = MicHardwareSnapshot(
            rawActivity: rawActivity,
            inputDevices: devices.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending },
            observedAt: Date.now,
            health: lastWarning.map(MonitorHealth.warning) ?? .ok
        )

        handler(snapshot)
    }

    private func setWarning(_ message: String) {
        lastWarning = message
        logger.warning("\(message, privacy: .public)")
    }

    private func readAllDeviceIDs() throws -> [AudioObjectID] {
        try readObjectIDArray(
            AudioObjectID(kAudioObjectSystemObject),
            selector: kAudioHardwarePropertyDevices,
            scope: kAudioObjectPropertyScopeGlobal
        )
    }

    private func readObjectIDArray(
        _ objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope
    ) throws -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(objectID, &address, 0, nil, &dataSize)
        guard status == noErr else {
            throw CoreAudioMonitorError.status("object array size", status)
        }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else {
            return []
        }

        var deviceIDs = Array(repeating: AudioObjectID(0), count: count)
        status = deviceIDs.withUnsafeMutableBufferPointer { buffer in
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &dataSize, buffer.baseAddress!)
        }
        guard status == noErr else {
            throw CoreAudioMonitorError.status("object array read", status)
        }

        return deviceIDs
    }

    private func deviceHasInputChannels(_ deviceID: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )

        guard AudioObjectHasProperty(deviceID, &address) else {
            return false
        }

        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize)
        guard status == noErr, dataSize > 0 else {
            return false
        }

        let rawPointer = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize),
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer {
            rawPointer.deallocate()
        }

        status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, rawPointer)
        guard status == noErr else {
            return false
        }

        let audioBufferList = rawPointer.assumingMemoryBound(to: AudioBufferList.self)
        let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
        return buffers.contains { $0.mNumberChannels > 0 }
    }

    private func readDeviceIsRunningSomewhere(_ deviceID: AudioObjectID) -> Bool {
        var address = Self.runningSomewhereAddress
        guard AudioObjectHasProperty(deviceID, &address) else {
            return false
        }

        var value: UInt32 = 0
        var dataSize = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, &value)
        return status == noErr && value != 0
    }

    private func readProcessIsRunningInput(_ processObjectID: AudioObjectID) -> Bool {
        readUInt32(
            processObjectID,
            selector: kAudioProcessPropertyIsRunningInput,
            scope: kAudioObjectPropertyScopeGlobal
        ) == 1
    }

    private func readInputDeviceIDsUsedByProcess(_ processObjectID: AudioObjectID) -> [AudioObjectID] {
        (try? readObjectIDArray(
            processObjectID,
            selector: kAudioProcessPropertyDevices,
            scope: kAudioObjectPropertyScopeInput
        )) ?? []
    }

    private func readUInt32(
        _ objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope
    ) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
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

    private func readStringProperty(
        _ objectID: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
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

    private static let devicesAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDevices,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    private static let runningSomewhereAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    private static let processObjectListAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyProcessObjectList,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    private static let processIsRunningInputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioProcessPropertyIsRunningInput,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )

    private static func describe(status: OSStatus) -> String {
        let unsignedStatus = UInt32(bitPattern: status)
        let bigEndian = unsignedStatus.bigEndian
        let bytes = [
            UInt8((bigEndian >> 24) & 0xff),
            UInt8((bigEndian >> 16) & 0xff),
            UInt8((bigEndian >> 8) & 0xff),
            UInt8(bigEndian & 0xff)
        ]
        let fourCC = String(bytes: bytes, encoding: .macOSRoman) ?? ""
        let printable = fourCC.allSatisfy { !$0.isWhitespace && $0.isASCII }
        return printable ? "\(status) (\(fourCC))" : "\(status)"
    }
}

private enum CoreAudioMonitorError: LocalizedError {
    case status(String, OSStatus)

    var errorDescription: String? {
        switch self {
        case .status(let operation, let status):
            "\(operation): \(status)"
        }
    }
}
