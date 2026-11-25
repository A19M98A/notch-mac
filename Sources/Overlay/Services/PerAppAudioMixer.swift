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
    var targetDeviceUID: String? // nil = System Default
    var channelMode: PairPlayChannelMode
    var tapActive: Bool
}

/// Manages real-time per-app volume mixing, per-app output device routing (e.g. Discord -> AirPods, Spotify -> Speakers),
/// and Spatial Ear Separation (`Stereo`, `Left Ear`, `Right Ear`, `Mono`, `Swap L/R`) on macOS 14.2+ using CoreAudio Process Taps.
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
    private var savedRoutes: [String: String] = [:] // bundleKey -> targetDeviceUID
    private var savedChannels: [String: PairPlayChannelMode] = [:]
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
            let route = savedRoutes[key]
            let chMode = savedChannels[key] ?? .stereo
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
                targetDeviceUID: route,
                channelMode: chMode,
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

        syncTapForApp(at: idx, forceRecreate: false)
    }

    func toggleMute(for appID: AudioObjectID) {
        guard let idx = apps.firstIndex(where: { $0.id == appID }) else { return }
        let newMuted = !apps[idx].isMuted
        let key = apps[idx].bundleID
        savedMutes[key] = newMuted
        apps[idx].isMuted = newMuted

        syncTapForApp(at: idx, forceRecreate: false)
    }

    func setTargetDevice(for appID: AudioObjectID, deviceUID: String?) {
        guard let idx = apps.firstIndex(where: { $0.id == appID }) else { return }
        let key = apps[idx].bundleID
        if let uid = deviceUID, !uid.isEmpty {
            savedRoutes[key] = uid
            apps[idx].targetDeviceUID = uid
        } else {
            savedRoutes.removeValue(forKey: key)
            apps[idx].targetDeviceUID = nil
        }

        syncTapForApp(at: idx, forceRecreate: true)
    }

    func setChannelMode(for appID: AudioObjectID, mode: PairPlayChannelMode) {
        guard let idx = apps.firstIndex(where: { $0.id == appID }) else { return }
        let key = apps[idx].bundleID
        savedChannels[key] = mode
        apps[idx].channelMode = mode

        syncTapForApp(at: idx, forceRecreate: false)
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

    private func syncTapForApp(at idx: Int, forceRecreate: Bool) {
        guard #available(macOS 14.2, *), apps.indices.contains(idx) else { return }
        let app = apps[idx]
        let appID = app.id
        let effectiveGain: Float = app.isMuted ? 0.0 : app.volume
        let needsTap = effectiveGain < 0.995 || app.targetDeviceUID != nil || app.channelMode != .stereo

        if !needsTap {
            if let existing = activeTaps.removeValue(forKey: appID) as? AppAudioTap {
                existing.stop()
            }
            apps[idx].tapActive = false
            return
        }

        if !forceRecreate, let existing = activeTaps[appID] as? AppAudioTap {
            existing.update(gain: effectiveGain, channelMode: app.channelMode)
            return
        }

        if let existing = activeTaps.removeValue(forKey: appID) as? AppAudioTap {
            existing.stop()
        }

        do {
            let tap = try AppAudioTap(
                processObjectID: appID,
                initialGain: effectiveGain,
                targetDeviceUID: app.targetDeviceUID,
                channelMode: app.channelMode
            )
            try tap.start()
            activeTaps[appID] = tap
            DispatchQueue.main.async {
                self.permissionError = nil
                if let currentIdx = self.apps.firstIndex(where: { $0.id == appID }) {
                    self.apps[currentIdx].tapActive = true
                }
            }
        } catch {
            DispatchQueue.main.async {
                self.permissionError = "Grant 'System Audio Recording Only' permission in System Settings to control per-app audio."
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

// MARK: - Real-Time Process Tap Engine (Gain + Target Output Routing + Spatial Ear Mode)

private final class TapRenderState {
    var gain: Float
    var channelMode: PairPlayChannelMode

    init(gain: Float, channelMode: PairPlayChannelMode) {
        self.gain = gain
        self.channelMode = channelMode
    }
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
    private let requestedOutputUID: String?
    private var tapID: AudioObjectID = kAudioObjectUnknown
    private var aggregateDeviceID: AudioObjectID = kAudioObjectUnknown
    private var ioProcID: AudioDeviceIOProcID?
    private let renderState: TapRenderState

    init(processObjectID: AudioObjectID, initialGain: Float, targetDeviceUID: String?, channelMode: PairPlayChannelMode) throws {
        self.processObjectID = processObjectID
        self.requestedOutputUID = targetDeviceUID
        self.renderState = TapRenderState(gain: max(0, min(1, initialGain)), channelMode: channelMode)
    }

    func update(gain: Float, channelMode: PairPlayChannelMode) {
        renderState.gain = max(0, min(1, gain))
        renderState.channelMode = channelMode
    }

    func start() throws {
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

        let outputUID: String? = {
            if let custom = requestedOutputUID, !custom.isEmpty { return custom }
            return getDefaultOutputDeviceUID()
        }()

        guard let outputUID else {
            stop()
            throw TapError.failedToGetOutputDevice
        }

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

        let state = self.renderState
        var procID: AudioDeviceIOProcID?
        let ioStatus = AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, nil) { _, inInputData, _, outOutputData, _ in
            let gain = state.gain
            let mode = state.channelMode
            let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
            let outList = UnsafeMutableAudioBufferListPointer(outOutputData)

            if gain <= 0.0001 {
                for i in 0..<outList.count {
                    if let outPtr = outList[i].mData {
                        memset(outPtr, 0, Int(outList[i].mDataByteSize))
                    }
                }
                return
            }

            // Non-interleaved stereo (2 separate buffers)
            if inList.count >= 2 && outList.count >= 2,
               let inL = inList[0].mData?.assumingMemoryBound(to: Float32.self),
               let inR = inList[1].mData?.assumingMemoryBound(to: Float32.self),
               let outL = outList[0].mData?.assumingMemoryBound(to: Float32.self),
               let outR = outList[1].mData?.assumingMemoryBound(to: Float32.self) {
                let frames = min(Int(inList[0].mDataByteSize), Int(outList[0].mDataByteSize)) / MemoryLayout<Float32>.size
                for f in 0..<frames {
                    let l = inL[f] * gain
                    let r = inR[f] * gain
                    switch mode {
                    case .stereo:   outL[f] = l; outR[f] = r
                    case .mono:     let m = (l + r) * 0.5; outL[f] = m; outR[f] = m
                    case .leftOnly: outL[f] = (l + r) * 0.5; outR[f] = 0
                    case .rightOnly: outL[f] = 0; outR[f] = (l + r) * 0.5
                    case .swapLR:   outL[f] = r; outR[f] = l
                    }
                }
                return
            }

            // Interleaved stereo (1 buffer with mNumberChannels == 2)
            if inList.count >= 1 && outList.count >= 1,
               let inPtr = inList[0].mData?.assumingMemoryBound(to: Float32.self),
               let outPtr = outList[0].mData?.assumingMemoryBound(to: Float32.self) {
                let ch = max(1, Int(outList[0].mNumberChannels))
                let sampleCount = min(Int(inList[0].mDataByteSize), Int(outList[0].mDataByteSize)) / MemoryLayout<Float32>.size
                if ch == 2 {
                    let frames = sampleCount / 2
                    for f in 0..<frames {
                        let l = inPtr[f * 2] * gain
                        let r = inPtr[f * 2 + 1] * gain
                        switch mode {
                        case .stereo:
                            outPtr[f * 2] = l; outPtr[f * 2 + 1] = r
                        case .mono:
                            let m = (l + r) * 0.5
                            outPtr[f * 2] = m; outPtr[f * 2 + 1] = m
                        case .leftOnly:
                            outPtr[f * 2] = (l + r) * 0.5; outPtr[f * 2 + 1] = 0
                        case .rightOnly:
                            outPtr[f * 2] = 0; outPtr[f * 2 + 1] = (l + r) * 0.5
                        case .swapLR:
                            outPtr[f * 2] = r; outPtr[f * 2 + 1] = l
                        }
                    }
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
