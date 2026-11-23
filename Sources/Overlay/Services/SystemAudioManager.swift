import Foundation
import CoreAudio
import AudioToolbox
import Combine

struct AudioOutputDevice: Identifiable, Equatable {
    let id: AudioDeviceID
    let name: String
    let uid: String
    let transportType: UInt32
    let isDefault: Bool

    var sfSymbol: String {
        let lower = name.lowercased()
        if lower.contains("airpods max") {
            return "airpodsmax"
        } else if lower.contains("airpods pro") {
            return "airpodspro"
        } else if lower.contains("airpods") {
            return "airpods"
        } else if lower.contains("headphone") || lower.contains("beats") || lower.contains("bose") || lower.contains("sony") {
            return "headphones"
        }

        switch transportType {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return "headphones"
        case kAudioDeviceTransportTypeBuiltIn:
            return "laptopcomputer"
        case kAudioDeviceTransportTypeUSB:
            return "cable.connector"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort:
            return "display"
        case kAudioDeviceTransportTypeAirPlay:
            return "airplayaudio"
        case kAudioDeviceTransportTypeVirtual, kAudioDeviceTransportTypeAggregate:
            return "waveform.circle"
        default:
            return "hifispeaker.fill"
        }
    }
}

final class SystemAudioManager: ObservableObject {
    @Published var volume: Float = 0.5
    @Published var isMuted: Bool = false
    @Published var outputDevices: [AudioOutputDevice] = []
    @Published var defaultOutputDeviceID: AudioDeviceID = kAudioObjectUnknown
    @Published var lastVolumeChangeDate: Date = .distantPast

    private var monitoredDeviceID: AudioDeviceID = kAudioObjectUnknown
    private var defaultDeviceListenerBlock: AudioObjectPropertyListenerBlock?
    private var devicesListListenerBlock: AudioObjectPropertyListenerBlock?
    private var volumeListenerBlock: AudioObjectPropertyListenerBlock?
    private var muteListenerBlock: AudioObjectPropertyListenerBlock?

    init() {
        refreshAll()
        installSystemListeners()
    }

    deinit {
        removeDeviceListeners(for: monitoredDeviceID)
    }

    func refreshAll() {
        let defID = fetchDefaultOutputDeviceID()
        let devices = fetchOutputDevices(defaultID: defID)
        let vol = fetchVolume(deviceID: defID)
        let muted = fetchMute(deviceID: defID)

        DispatchQueue.main.async {
            self.defaultOutputDeviceID = defID
            self.outputDevices = devices
            self.volume = vol
            self.isMuted = muted
        }

        if defID != monitoredDeviceID {
            removeDeviceListeners(for: monitoredDeviceID)
            monitoredDeviceID = defID
            installDeviceListeners(for: defID)
        }
    }

    var currentOutputDevice: AudioOutputDevice? {
        outputDevices.first(where: { $0.id == defaultOutputDeviceID })
    }

    func setVolume(_ newVolume: Float) {
        let clamped = max(0, min(1, newVolume))
        let devID = defaultOutputDeviceID != kAudioObjectUnknown ? defaultOutputDeviceID : fetchDefaultOutputDeviceID()
        guard devID != kAudioObjectUnknown else { return }

        var vol = clamped
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )

        if AudioObjectHasProperty(devID, &address) {
            AudioObjectSetPropertyData(devID, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &vol)
        } else {
            // Fallback to setting channel 1 and 2
            for ch: UInt32 in [0, 1, 2] {
                var chAddr = AudioObjectPropertyAddress(
                    mSelector: kAudioDevicePropertyVolumeScalar,
                    mScope: kAudioDevicePropertyScopeOutput,
                    mElement: ch
                )
                if AudioObjectHasProperty(devID, &chAddr) {
                    AudioObjectSetPropertyData(devID, &chAddr, 0, nil, UInt32(MemoryLayout<Float32>.size), &vol)
                }
            }
        }

        if clamped > 0.001 && isMuted {
            setMuted(false)
        }

        DispatchQueue.main.async {
            self.volume = clamped
            self.lastVolumeChangeDate = Date()
        }
    }

    func setMuted(_ muted: Bool) {
        let devID = defaultOutputDeviceID != kAudioObjectUnknown ? defaultOutputDeviceID : fetchDefaultOutputDeviceID()
        guard devID != kAudioObjectUnknown else { return }

        var muteVal: UInt32 = muted ? 1 : 0
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectHasProperty(devID, &address) {
            AudioObjectSetPropertyData(devID, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &muteVal)
        }

        DispatchQueue.main.async {
            self.isMuted = muted
            self.lastVolumeChangeDate = Date()
        }
    }

    func toggleMute() {
        setMuted(!isMuted)
    }

    func setDefaultOutputDevice(_ deviceID: AudioDeviceID) {
        var devID = deviceID
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            UInt32(MemoryLayout<AudioDeviceID>.size),
            &devID
        )
        if status == noErr {
            refreshAll()
        }
    }

    // MARK: - CoreAudio Queries

    func fetchDefaultOutputDeviceID() -> AudioDeviceID {
        var deviceID: AudioDeviceID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID)
        return deviceID
    }

    private func fetchOutputDevices(defaultID: AudioDeviceID) -> [AudioOutputDevice] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize) == noErr else {
            return []
        }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var deviceIDs = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &deviceIDs) == noErr else {
            return []
        }

        var result: [AudioOutputDevice] = []
        for id in deviceIDs {
            // Skip our own internal aggregate devices created for per-app taps
            let name = getDeviceStringProperty(id, selector: kAudioObjectPropertyName) ?? "Unknown Device"
            let uid = getDeviceStringProperty(id, selector: kAudioDevicePropertyDeviceUID) ?? "\(id)"
            if uid.hasPrefix("com.overlay.tap.") || name.hasPrefix("OverlayTap-") {
                continue
            }

            guard hasOutputStreams(deviceID: id) else { continue }

            let transport = getDeviceUInt32Property(id, selector: kAudioDevicePropertyTransportType) ?? 0
            result.append(AudioOutputDevice(
                id: id,
                name: name,
                uid: uid,
                transportType: transport,
                isDefault: id == defaultID
            ))
        }
        return result.sorted { lhs, rhs in
            if lhs.isDefault != rhs.isDefault { return lhs.isDefault }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private func hasOutputStreams(deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &address, 0, nil, &dataSize) == noErr, dataSize > 0 else {
            return false
        }
        let rawPtr = UnsafeMutableRawPointer.allocate(byteCount: Int(dataSize), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { rawPtr.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &dataSize, rawPtr) == noErr else {
            return false
        }
        let bufferList = UnsafeMutableAudioBufferListPointer(rawPtr.assumingMemoryBound(to: AudioBufferList.self))
        let channels = bufferList.reduce(0) { $0 + Int($1.mNumberChannels) }
        return channels > 0
    }

    private func fetchVolume(deviceID: AudioDeviceID) -> Float {
        guard deviceID != kAudioObjectUnknown else { return 0.5 }
        var vol: Float32 = 0.5
        var size = UInt32(MemoryLayout<Float32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectHasProperty(deviceID, &address),
           AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &vol) == noErr {
            return vol
        }

        for ch: UInt32 in [0, 1] {
            var chAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: ch
            )
            if AudioObjectHasProperty(deviceID, &chAddr),
               AudioObjectGetPropertyData(deviceID, &chAddr, 0, nil, &size, &vol) == noErr {
                return vol
            }
        }
        return 0.5
    }

    private func fetchMute(deviceID: AudioDeviceID) -> Bool {
        guard deviceID != kAudioObjectUnknown else { return false }
        var muted: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectHasProperty(deviceID, &address),
           AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &muted) == noErr {
            return muted != 0
        }
        return false
    }

    private func getDeviceStringProperty(_ deviceID: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfStr: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &cfStr)
        guard status == noErr, let str = cfStr?.takeRetainedValue() else { return nil }
        return str as String
    }

    private func getDeviceUInt32Property(_ deviceID: AudioDeviceID, selector: AudioObjectPropertySelector) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    // MARK: - Listeners

    private func installSystemListeners() {
        var defaultAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let defBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.refreshAll()
        }
        self.defaultDeviceListenerBlock = defBlock
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &defaultAddr, DispatchQueue.main, defBlock)

        var devicesAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let devBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.refreshAll()
        }
        self.devicesListListenerBlock = devBlock
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &devicesAddr, DispatchQueue.main, devBlock)
    }

    private func installDeviceListeners(for deviceID: AudioDeviceID) {
        guard deviceID != kAudioObjectUnknown else { return }

        var volAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        let volBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            let newVol = self.fetchVolume(deviceID: deviceID)
            DispatchQueue.main.async {
                if abs(self.volume - newVol) > 0.005 {
                    self.volume = newVol
                    self.lastVolumeChangeDate = Date()
                }
            }
        }
        self.volumeListenerBlock = volBlock
        if AudioObjectHasProperty(deviceID, &volAddr) {
            AudioObjectAddPropertyListenerBlock(deviceID, &volAddr, DispatchQueue.main, volBlock)
        }

        var muteAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        let muteBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            guard let self else { return }
            let muted = self.fetchMute(deviceID: deviceID)
            DispatchQueue.main.async {
                if self.isMuted != muted {
                    self.isMuted = muted
                    self.lastVolumeChangeDate = Date()
                }
            }
        }
        self.muteListenerBlock = muteBlock
        if AudioObjectHasProperty(deviceID, &muteAddr) {
            AudioObjectAddPropertyListenerBlock(deviceID, &muteAddr, DispatchQueue.main, muteBlock)
        }
    }

    private func removeDeviceListeners(for deviceID: AudioDeviceID) {
        guard deviceID != kAudioObjectUnknown else { return }
        if let volBlock = volumeListenerBlock {
            var volAddr = AudioObjectPropertyAddress(
                mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(deviceID, &volAddr, DispatchQueue.main, volBlock)
        }
        if let muteBlock = muteListenerBlock {
            var muteAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyMute,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            AudioObjectRemovePropertyListenerBlock(deviceID, &muteAddr, DispatchQueue.main, muteBlock)
        }
    }
}
