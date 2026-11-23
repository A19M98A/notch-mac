import Foundation
import AppKit
import CoreAudio
import AudioToolbox
import Combine

struct AudioAppSource: Identifiable {
    let id: AudioObjectID // CoreAudio Process Object ID
    let pid: pid_t
    let name: String
    let bundleID: String
    let icon: NSImage
    var isRunningOutput: Bool
    var volume: Float // 0.0 ... 1.0
    var isMuted: Bool
    var tapActive: Bool
}

/// Manages real-time per-app volume mixing on macOS 14.2+ using CoreAudio Process Taps
/// (`CATapDescription` + `AudioHardwareCreateProcessTap` + Aggregate Device + IOProc gain scaling).
/// On macOS 12–14.1, gracefully reports unavailability while keeping Master volume fully functional.
final class PerAppAudioMixer: ObservableObject {
    @Published var apps: [AudioAppSource] = []
    @Published var permissionError: String? = nil

    var supportsPerAppMixing: Bool {
        if #available(macOS 14.2, *) { return true }
        return false
    }

    private var activeTaps: [AudioObjectID: AnyObject] = [:]
    private var savedVolumes: [String: Float] = [:]
    private var savedMutes: [String: Bool] = [:]
    private var pollTimer: Timer?
    private let ownPID = ProcessInfo.processInfo.processIdentifier

    init() {
        if #available(macOS 14.2, *) {
            refreshAudioProcesses()
            pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
                self?.refreshAudioProcesses()
            }
        }
    }

    deinit {
        pollTimer?.invalidate()
        teardownAllTaps()
    }

    func refreshAudioProcesses() {
        guard #available(macOS 14.2, *) else { return }
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize) == noErr,
              dataSize > 0 else {
            return
        }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var processIDs = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &processIDs) == noErr else {
            return
        }

        var discovered: [AudioAppSource] = []
        var activeIDs = Set<AudioObjectID>()

        for procObjID in processIDs {
            guard let pid = getProcessPID(procObjID), pid != ownPID else { continue }
            let isRunning = getProcessIsRunningOutput(procObjID)
            let bundleID = getProcessBundleID(procObjID) ?? ""

            let runningApp = NSRunningApplication(processIdentifier: pid)
            let appName = runningApp?.localizedName ?? fallbackName(for: bundleID, pid: pid)

            let isRegularApp = runningApp?.activationPolicy == .regular
            let isHelperWithAudio = isRunning && !appName.isEmpty
            if !isRegularApp && !isHelperWithAudio {
                continue
            }

            if bundleID.contains("coreaudiod") || appName.lowercased() == "coreaudiod" {
                continue
            }

            let key = bundleID.isEmpty ? "pid-\(pid)" : bundleID
            let vol = savedVolumes[key] ?? 1.0
            let muted = savedMutes[key] ?? false
            let icon = runningApp?.icon ?? NSImage(systemSymbolName: "app.fill", accessibilityDescription: nil) ?? NSImage()

            activeIDs.insert(procObjID)
            discovered.append(AudioAppSource(
                id: procObjID,
                pid: pid,
                name: appName,
                bundleID: key,
                icon: icon,
                isRunningOutput: isRunning,
                volume: vol,
                isMuted: muted,
                tapActive: activeTaps[procObjID] != nil
            ))
        }

        for (procID, tapObj) in activeTaps where !activeIDs.contains(procID) {
            if let tap = tapObj as? AppAudioTap {
                tap.stop()
            }
            activeTaps.removeValue(forKey: procID)
        }

        discovered.sort { lhs, rhs in
            if lhs.isRunningOutput != rhs.isRunningOutput { return lhs.isRunningOutput }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }

        DispatchQueue.main.async {
            self.apps = discovered
        }
    }

    func setVolume(for appID: AudioObjectID, volume: Float) {
        let clamped = max(0, min(1, volume))
        guard let idx = apps.firstIndex(where: { $0.id == appID }) else { return }

        let key = apps[idx].bundleID
        savedVolumes[key] = clamped
        apps[idx].volume = clamped
        if clamped > 0.001 && apps[idx].isMuted {
            savedMutes[key] = false
            apps[idx].isMuted = false
        }

        applyGainToProcess(appID: appID, gain: apps[idx].isMuted ? 0.0 : clamped)
    }

    func toggleMute(for appID: AudioObjectID) {
        guard let idx = apps.firstIndex(where: { $0.id == appID }) else { return }
        let newMuted = !apps[idx].isMuted
        let key = apps[idx].bundleID
        savedMutes[key] = newMuted
        apps[idx].isMuted = newMuted

        applyGainToProcess(appID: appID, gain: newMuted ? 0.0 : apps[idx].volume)
    }

    func toggleMuteByPID(_ pid: pid_t) -> Bool {
        if let app = apps.first(where: { $0.pid == pid }) {
            toggleMute(for: app.id)
            return true
        }
        refreshAudioProcesses()
        if let app = apps.first(where: { $0.pid == pid }) {
            toggleMute(for: app.id)
            return true
        }
        return false
    }

    func openAudioPermissionSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    func teardownAllTaps() {
        if #available(macOS 14.2, *) {
            for (_, tapObj) in activeTaps {
                (tapObj as? AppAudioTap)?.stop()
            }
        }
        activeTaps.removeAll()
    }

    // MARK: - Tap Lifecycle

    private func applyGainToProcess(appID: AudioObjectID, gain: Float) {
        guard #available(macOS 14.2, *) else { return }

        if gain >= 0.995 {
            if let existing = activeTaps.removeValue(forKey: appID) as? AppAudioTap {
                existing.stop()
            }
            if let idx = apps.firstIndex(where: { $0.id == appID }) {
                apps[idx].tapActive = false
            }
            return
        }

        if let existing = activeTaps[appID] as? AppAudioTap {
            existing.setGain(gain)
            return
        }

        do {
            let tap = try AppAudioTap(processObjectID: appID, initialGain: gain)
            try tap.start()
            activeTaps[appID] = tap
            DispatchQueue.main.async {
                self.permissionError = nil
                if let idx = self.apps.firstIndex(where: { $0.id == appID }) {
                    self.apps[idx].tapActive = true
                }
            }
        } catch {
            DispatchQueue.main.async {
                self.permissionError = "Grant 'System Audio Recording Only' permission in System Settings to control per-app volume."
            }
        }
    }

    // MARK: - CoreAudio Process Helpers

    @available(macOS 14.2, *)
    private func getProcessPID(_ objectID: AudioObjectID) -> pid_t? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyPID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var pid: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &pid) == noErr else { return nil }
        return pid
    }

    @available(macOS 14.2, *)
    private func getProcessIsRunningOutput(_ objectID: AudioObjectID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningOutput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &running) == noErr else { return false }
        return running != 0
    }

    @available(macOS 14.2, *)
    private func getProcessBundleID(_ objectID: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyBundleID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfStr: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(objectID, &address, 0, nil, &size, &cfStr) == noErr,
              let str = cfStr?.takeRetainedValue() else {
            return nil
        }
        return str as String
    }

    private func fallbackName(for bundleID: String, pid: pid_t) -> String {
        if let last = bundleID.split(separator: ".").last, !last.isEmpty {
            return String(last).capitalized
        }
        return "App (\(pid))"
    }
}

// MARK: - Real-Time Process Tap Engine

private final class GainState {
    var gain: Float
    init(_ gain: Float) { self.gain = gain }
}

private enum TapError: Error {
    case failedToCreateTap(OSStatus)
    case failedToGetOutputDevice
    case failedToCreateAggregate(OSStatus)
    case failedToCreateIOProc(OSStatus)
    case failedToStartDevice(OSStatus)
}

@available(macOS 14.2, *)
private final class AppAudioTap {
    private let processObjectID: AudioObjectID
    private var tapID: AudioObjectID = kAudioObjectUnknown
    private var aggregateDeviceID: AudioObjectID = kAudioObjectUnknown
    private var ioProcID: AudioDeviceIOProcID?
    private let gainState: GainState

    init(processObjectID: AudioObjectID, initialGain: Float) throws {
        self.processObjectID = processObjectID
        self.gainState = GainState(initialGain)
    }

    func setGain(_ gain: Float) {
        gainState.gain = max(0, min(1, gain))
    }

    func start() throws {
        // 1. Create a stereo mixdown process tap that mutes the original app output
        let tapDesc = CATapDescription(stereoMixdownOfProcesses: [processObjectID])
        tapDesc.name = "OverlayTap-\(processObjectID)"
        tapDesc.isPrivate = true
        tapDesc.muteBehavior = .mutedWhenTapped

        var newTapID: AudioObjectID = kAudioObjectUnknown
        let tapStatus = AudioHardwareCreateProcessTap(tapDesc, &newTapID)
        guard tapStatus == noErr, newTapID != kAudioObjectUnknown else {
            throw TapError.failedToCreateTap(tapStatus)
        }
        self.tapID = newTapID

        // 2. Get default output device UID
        guard let outputUID = getDefaultOutputDeviceUID() else {
            stop()
            throw TapError.failedToGetOutputDevice
        }

        // 3. Create an Aggregate Device combining the default output device and our tap
        let aggUID = "com.overlay.tap.\(processObjectID).\(UUID().uuidString)"
        let desc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "OverlayTap-\(processObjectID)",
            kAudioAggregateDeviceUIDKey: aggUID,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: tapDesc.uuid.uuidString
                ]
            ]
        ]

        var aggID: AudioObjectID = kAudioObjectUnknown
        let aggStatus = AudioHardwareCreateAggregateDevice(desc as CFDictionary, &aggID)
        guard aggStatus == noErr, aggID != kAudioObjectUnknown else {
            stop()
            throw TapError.failedToCreateAggregate(aggStatus)
        }
        self.aggregateDeviceID = aggID

        // 4. Attach real-time IOProc that copies tapped input buffers to output buffers with gain scaling
        let state = self.gainState
        var procID: AudioDeviceIOProcID?
        let ioStatus = AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, nil) { _, inInputData, _, outOutputData, _ in
            let gain = state.gain
            let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
            let outList = UnsafeMutableAudioBufferListPointer(outOutputData)

            let bufferCount = min(inList.count, outList.count)
            for i in 0..<bufferCount {
                let inBuf = inList[i]
                let outBuf = outList[i]
                guard let inPtr = inBuf.mData?.assumingMemoryBound(to: Float32.self),
                      let outPtr = outBuf.mData?.assumingMemoryBound(to: Float32.self) else {
                    continue
                }
                let sampleCount = min(Int(inBuf.mDataByteSize), Int(outBuf.mDataByteSize)) / MemoryLayout<Float32>.size
                if gain <= 0.0001 {
                    memset(outPtr, 0, sampleCount * MemoryLayout<Float32>.size)
                } else {
                    for s in 0..<sampleCount {
                        outPtr[s] = inPtr[s] * gain
                    }
                }
            }
        }

        guard ioStatus == noErr, let validProcID = procID else {
            stop()
            throw TapError.failedToCreateIOProc(ioStatus)
        }
        self.ioProcID = validProcID

        let startStatus = AudioDeviceStart(aggID, validProcID)
        guard startStatus == noErr else {
            stop()
            throw TapError.failedToStartDevice(startStatus)
        }
    }

    func stop() {
        if aggregateDeviceID != kAudioObjectUnknown {
            if let procID = ioProcID {
                AudioDeviceStop(aggregateDeviceID, procID)
                AudioDeviceDestroyIOProcID(aggregateDeviceID, procID)
                ioProcID = nil
            }
            AudioHardwareDestroyAggregateDevice(aggregateDeviceID)
            aggregateDeviceID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
    }

    private func getDefaultOutputDeviceUID() -> String? {
        var devID: AudioDeviceID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &devID) == noErr,
              devID != kAudioObjectUnknown else {
            return nil
        }

        var uidAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfStr: Unmanaged<CFString>?
        var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(devID, &uidAddr, 0, nil, &uidSize, &cfStr) == noErr,
              let str = cfStr?.takeRetainedValue() else {
            return nil
        }
        return str as String
    }
}
