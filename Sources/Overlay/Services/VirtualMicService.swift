import Foundation
import AppKit
import CoreAudio
import AudioToolbox
import AVFoundation
import Combine

/// Thread-safe stereo ring buffer with fractional resampling & drift compensation
/// for mixing asynchronous hardware microphones and CoreAudio process taps onto a single Virtual Mic clock.
private final class VirtualMixRingBuffer {
    private let capacity: Int = 49152
    private var left: [Float]
    private var right: [Float]
    private var readPos: Double = 0
    private var writeIndex: Int = 0
    private var available: Double = 0
    private var primed: Bool = false

    private let outputSampleRate: Double
    private var inputSampleRate: Double
    private let targetPreRoll: Double = 1536
    private var gain: Float
    private var muted: Bool
    private let lock = NSLock()

    init(outputSampleRate: Double, initialGain: Float, initialMuted: Bool) {
        self.outputSampleRate = max(8000, outputSampleRate)
        self.inputSampleRate = self.outputSampleRate
        self.left = [Float](repeating: 0, count: capacity)
        self.right = [Float](repeating: 0, count: capacity)
        self.gain = initialGain
        self.muted = initialMuted
    }

    func setGain(_ newGain: Float, muted newMuted: Bool) {
        lock.lock()
        gain = max(0, min(2.0, newGain))
        muted = newMuted
        lock.unlock()
    }

    func write(leftSrc: UnsafePointer<Float>, rightSrc: UnsafePointer<Float>, frameCount: Int, sampleRate: Double) {
        guard frameCount > 0 else { return }
        lock.lock()
        if sampleRate > 8000 && abs(sampleRate - inputSampleRate) > 1.0 {
            inputSampleRate = sampleRate
        }

        let maxAllowed = Double(capacity - 1024)
        if available + Double(frameCount) > maxAllowed {
            let drop = (available + Double(frameCount)) - targetPreRoll
            if drop > 0 {
                readPos += drop
                while readPos >= Double(capacity) { readPos -= Double(capacity) }
                available = max(0, available - drop)
            }
        }

        for i in 0..<frameCount {
            left[writeIndex] = leftSrc[i]
            right[writeIndex] = rightSrc[i]
            writeIndex = (writeIndex + 1) % capacity
        }
        available += Double(frameCount)

        if !primed && available >= targetPreRoll {
            var aligned = Double(writeIndex) - targetPreRoll
            while aligned < 0 { aligned += Double(capacity) }
            readPos = aligned
            available = targetPreRoll
            primed = true
        }
        lock.unlock()
    }

    /// Accumulates (`+=`) scaled samples into `leftAcc` and `rightAcc` so multiple sources sum cleanly.
    func mixInto(leftAcc: UnsafeMutablePointer<Float>, rightAcc: UnsafeMutablePointer<Float>, frameCount: Int, extraMultiplier: Float = 1.0) {
        lock.lock()
        let step = inputSampleRate / outputSampleRate
        let needed = Double(frameCount) * step + 1.0

        if !primed || available < needed {
            if available < needed { primed = false }
            lock.unlock()
            return
        }

        let driftError = available - targetPreRoll
        let driftAdjust = max(-0.002, min(0.002, driftError * 0.00002))
        let effectiveStep = step + driftAdjust
        let totalGain: Float = muted ? 0.0 : (gain * extraMultiplier)
        let cap = capacity

        if totalGain <= 0.0001 {
            readPos += Double(frameCount) * effectiveStep
            while readPos >= Double(cap) { readPos -= Double(cap) }
            available = max(0, available - Double(frameCount) * effectiveStep)
            lock.unlock()
            return
        }

        for i in 0..<frameCount {
            let idx0 = Int(readPos) % cap
            let idx1 = (idx0 + 1) % cap
            let frac = Float(readPos - floor(readPos))

            let l = left[idx0] + (left[idx1] - left[idx0]) * frac
            let r = right[idx0] + (right[idx1] - right[idx0]) * frac

            leftAcc[i] += l * totalGain
            rightAcc[i] += r * totalGain

            readPos += effectiveStep
            if readPos >= Double(cap) { readPos -= Double(cap) }
        }
        available = max(0, available - Double(frameCount) * effectiveStep)
        lock.unlock()
    }
}

/// Captures a single physical microphone (with optional 1-pole 90Hz high-pass rumble/noise-cut filter & voice tone EQ)
/// and writes centered dual-mono audio into its `VirtualMixRingBuffer`.
private final class PhysicalMicCaptureUnit {
    let uid: String
    let ringBuffer: VirtualMixRingBuffer
    private let engine = AVAudioEngine()
    private var isRunning = false
    var noiseCutEnabled: Bool
    private var hpPrevIn: Float = 0
    private var hpPrevOut: Float = 0
    var latestRMS: Float = 0

    init?(deviceID: AudioDeviceID, uid: String, outputSampleRate: Double, gain: Float, muted: Bool, noiseCut: Bool, onLevel: @escaping (Float) -> Void) {
        self.uid = uid
        self.noiseCutEnabled = noiseCut
        self.ringBuffer = VirtualMixRingBuffer(outputSampleRate: outputSampleRate, initialGain: gain, initialMuted: muted)

        let inNode = engine.inputNode
        guard let inAU = inNode.audioUnit else { return nil }

        var devID = deviceID
        let bindStatus = AudioUnitSetProperty(
            inAU,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &devID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard bindStatus == noErr else { return nil }

        let fmt = inNode.outputFormat(forBus: 0)
        guard fmt.sampleRate > 0, fmt.channelCount > 0 else { return nil }

        let rc = 1.0 / (2.0 * Float.pi * 90.0)
        let dt = 1.0 / Float(fmt.sampleRate)
        let hpAlpha = rc / (rc + dt)

        isRunning = true
        inNode.installTap(onBus: 0, bufferSize: 512, format: nil) { [weak self] buffer, _ in
            guard let self, self.isRunning, let chData = buffer.floatChannelData else { return }
            let n = Int(buffer.frameLength)
            guard n > 0 else { return }

            // Pick active mic channel if stereo USB interface only populates one side
            let srcPtr: UnsafeMutablePointer<Float>
            if buffer.format.channelCount >= 2 {
                let c0 = chData[0]
                let c1 = chData[1]
                var s0: Float = 0
                var s1: Float = 0
                for i in stride(from: 0, to: n, by: 4) {
                    s0 += abs(c0[i])
                    s1 += abs(c1[i])
                }
                srcPtr = (s1 > s0 * 1.2) ? c1 : c0
            } else {
                srcPtr = chData[0]
            }

            var processed = [Float](repeating: 0, count: n)
            var sumSq: Float = 0
            let cut = self.noiseCutEnabled
            var prevIn = self.hpPrevIn
            var prevOut = self.hpPrevOut

            for i in 0..<n {
                var x = srcPtr[i]
                if cut {
                    let y = hpAlpha * (prevOut + x - prevIn)
                    prevIn = x
                    prevOut = y
                    x = y
                }
                processed[i] = x
                sumSq += x * x
            }
            self.hpPrevIn = prevIn
            self.hpPrevOut = prevOut

            let rms = sqrt(sumSq / Float(n))
            self.latestRMS = rms
            let vu = min(1.0, max(0.0, rms * 8.0))
            onLevel(vu)

            processed.withUnsafeBufferPointer { buf in
                if let base = buf.baseAddress {
                    self.ringBuffer.write(leftSrc: base, rightSrc: base, frameCount: n, sampleRate: buffer.format.sampleRate)
                }
            }
        }

        do {
            try engine.start()
        } catch {
            inNode.removeTap(onBus: 0)
            isRunning = false
            return nil
        }
    }

    func stop() {
        isRunning = false
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
    }
}

/// Captures a specific application's stereo audio via CoreAudio Process Tap (macOS 14.2+)
/// without muting the app locally (unless `muteLocalPlayback` is enabled) and feeds `VirtualMixRingBuffer`.
@available(macOS 14.2, *)
private final class AppMixCaptureUnit {
    let bundleKey: String
    let processObjectID: AudioObjectID
    let ringBuffer: VirtualMixRingBuffer
    private var tapID: AudioObjectID = kAudioObjectUnknown
    private var aggregateID: AudioObjectID = kAudioObjectUnknown
    private var ioProcID: AudioDeviceIOProcID?

    init?(processObjectID: AudioObjectID, bundleKey: String, outputSampleRate: Double, gain: Float, muted: Bool, muteLocalPlayback: Bool, clockDeviceUID: String, onLevel: @escaping (Float) -> Void) {
        self.processObjectID = processObjectID
        self.bundleKey = bundleKey
        self.ringBuffer = VirtualMixRingBuffer(outputSampleRate: outputSampleRate, initialGain: gain, initialMuted: muted)

        let tapDesc = CATapDescription(stereoMixdownOfProcesses: [processObjectID])
        tapDesc.name = "NotchPulse-MicMix-\(processObjectID)"
        tapDesc.isPrivate = true
        tapDesc.muteBehavior = muteLocalPlayback ? .mutedWhenTapped : .unmuted

        var newTapID: AudioObjectID = kAudioObjectUnknown
        guard AudioHardwareCreateProcessTap(tapDesc, &newTapID) == noErr, newTapID != kAudioObjectUnknown else {
            return nil
        }
        self.tapID = newTapID

        let aggUID = "com.overlay.tap.micmix.\(processObjectID).\(UUID().uuidString)"
        let desc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "OverlayTap-MicMix-\(processObjectID)",
            kAudioAggregateDeviceUIDKey: aggUID,
            kAudioAggregateDeviceMainSubDeviceKey: clockDeviceUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: clockDeviceUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: tapDesc.uuid.uuidString
                ]
            ]
        ]

        var aggID: AudioObjectID = kAudioObjectUnknown
        guard AudioHardwareCreateAggregateDevice(desc as CFDictionary, &aggID) == noErr, aggID != kAudioObjectUnknown else {
            AudioHardwareDestroyProcessTap(newTapID)
            return nil
        }
        self.aggregateID = aggID

        let tapRate = Self.readSampleRate(aggID) ?? 48000.0
        let rb = self.ringBuffer

        var procID: AudioDeviceIOProcID?
        let status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, nil) { _, inInputData, _, outOutputData, _ in
            // Always zero the private aggregate's output buffers so we never double-play locally
            let outList = UnsafeMutableAudioBufferListPointer(outOutputData)
            for i in 0..<outList.count {
                if let ptr = outList[i].mData {
                    memset(ptr, 0, Int(outList[i].mDataByteSize))
                }
            }

            let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
            guard inList.count > 0 else { return }

            if inList.count >= 2,
               let lPtr = inList[0].mData?.assumingMemoryBound(to: Float.self),
               let rPtr = inList[1].mData?.assumingMemoryBound(to: Float.self) {
                let frames = Int(inList[0].mDataByteSize) / MemoryLayout<Float>.size
                guard frames > 0 else { return }
                var sumSq: Float = 0
                for i in stride(from: 0, to: frames, by: 4) {
                    let s = (lPtr[i] + rPtr[i]) * 0.5
                    sumSq += s * s
                }
                let rms = sqrt(sumSq / Float(max(1, frames / 4)))
                onLevel(min(1.0, rms * 5.0))
                rb.write(leftSrc: lPtr, rightSrc: rPtr, frameCount: frames, sampleRate: tapRate)
            } else if let interleaved = inList[0].mData?.assumingMemoryBound(to: Float.self) {
                let ch = max(1, Int(inList[0].mNumberChannels))
                let total = Int(inList[0].mDataByteSize) / MemoryLayout<Float>.size
                let frames = total / ch
                guard frames > 0 else { return }
                var left = [Float](repeating: 0, count: frames)
                var right = [Float](repeating: 0, count: frames)
                var sumSq: Float = 0
                if ch >= 2 {
                    for f in 0..<frames {
                        let l = interleaved[f * ch]
                        let r = interleaved[f * ch + 1]
                        left[f] = l
                        right[f] = r
                        sumSq += ((l + r) * 0.5) * ((l + r) * 0.5)
                    }
                } else {
                    for f in 0..<frames {
                        let s = interleaved[f]
                        left[f] = s
                        right[f] = s
                        sumSq += s * s
                    }
                }
                let rms = sqrt(sumSq / Float(frames))
                onLevel(min(1.0, rms * 5.0))
                left.withUnsafeBufferPointer { lBuf in
                    right.withUnsafeBufferPointer { rBuf in
                        if let lb = lBuf.baseAddress, let rbPtr = rBuf.baseAddress {
                            rb.write(leftSrc: lb, rightSrc: rbPtr, frameCount: frames, sampleRate: tapRate)
                        }
                    }
                }
            }
        }

        guard status == noErr, let validProc = procID, AudioDeviceStart(aggID, validProc) == noErr else {
            if let procID { AudioDeviceDestroyIOProcID(aggID, procID) }
            AudioHardwareDestroyAggregateDevice(aggID)
            AudioHardwareDestroyProcessTap(newTapID)
            return nil
        }
        self.ioProcID = validProc
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let proc = ioProcID {
                AudioDeviceStop(aggregateID, proc)
                AudioDeviceDestroyIOProcID(aggregateID, proc)
                ioProcID = nil
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
    }

    private static func readSampleRate(_ id: AudioDeviceID) -> Double? {
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &rate) == noErr, rate > 0 else { return nil }
        return rate
    }
}

/// Virtual Mic Mixer ("MicMix") Service:
/// Combines 1+ physical microphones AND 1+ running application audio streams into a single
/// Virtual Microphone output (e.g. `BlackHole 2ch`, `Microsoft Teams Audio`, `VB-Cable`)
/// that you can select inside Zoom, Google Meet, Telegram, Discord, Teams, or OBS.
final class VirtualMicService: ObservableObject {
    @Published var isMicMixViewMode: Bool = false
    @Published var isActive: Bool = false

    // Target Virtual Loopback Cable (e.g. BlackHole 2ch)
    @Published var selectedVirtualCableUID: String = ""

    // Selected Physical Microphones & Per-Mic Settings
    @Published var selectedMicUIDs: Set<String> = []
    @Published var micVolumes: [String: Float] = [:]     // 0.0 ... 2.0 (up to 200% boost)
    @Published var micMuted: [String: Bool] = [:]
    @Published var micNoiseCut: [String: Bool] = [:]
    @Published var micLevels: [String: Float] = [:]

    // Selected Application Audio Sources & Per-App Settings
    @Published var selectedAppKeys: Set<String> = []    // AudioAppSource.bundleID
    @Published var appVolumes: [String: Float] = [:]    // 0.0 ... 1.5
    @Published var appMuted: [String: Bool] = [:]
    @Published var appMuteLocal: [String: Bool] = [:]   // false = Hear + Send to Call; true = Send to Call Only
    @Published var appLevels: [String: Float] = [:]

    // Master Broadcast Controls
    @Published var masterVolume: Float = 1.0
    @Published var isMasterMuted: Bool = false          // Quick "Cough / Mute All to Call" button
    @Published var autoDuckApps: Bool = true            // Lowers app music automatically while speaking
    @Published var setAsSystemDefaultMic: Bool = false  // Optional: leave OFF to pick virtual mic only inside Zoom/Meet
    @Published var monitorInHeadphones: Bool = false    // Listen to exact broadcast mix locally
    @Published var masterLevel: Float = 0.0
    @Published var statusMessage: String? = nil

    weak var inputAudio: InputAudioManager?
    weak var systemAudio: SystemAudioManager?
    weak var perAppMixer: PerAppAudioMixer?

    private var mixOutEngine: AVAudioEngine?
    private var monitorOutEngine: AVAudioEngine?
    private var monitorRing: VirtualMixRingBuffer?
    private var micUnits: [String: PhysicalMicCaptureUnit] = [:]
    private var appUnits: [String: AnyObject] = [:] // bundleKey -> AppMixCaptureUnit
    private let mixLock = NSLock()
    private var duckEnvelope: Float = 1.0
    private var previousDefaultInputID: AudioDeviceID? = nil
    private var appSyncTimer: Timer?
    private var termObserver: NSObjectProtocol?

    init() {
        termObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.stopMix()
        }
    }

    deinit {
        if let termObserver {
            NotificationCenter.default.removeObserver(termObserver)
        }
        stopMix()
    }

    // MARK: - Device Discovery Helpers

    /// Physical microphones only (excludes virtual loopback cables so a virtual cable never feeds into itself).
    var physicalMics: [AudioInputDevice] {
        guard let inputAudio else { return [] }
        let virtualUIDs = Set(virtualCables.map { $0.uid })
        return inputAudio.inputDevices.filter { dev in
            if virtualUIDs.contains(dev.uid) { return false }
            let lower = dev.name.lowercased()
            if lower.contains("blackhole") || lower.contains("vb-cable") || lower.contains("soundflower") {
                return false
            }
            return true
        }
    }

    /// Installed virtual loopback cables that have BOTH output & input streams (e.g. BlackHole 2ch, Teams Audio, Camo).
    var virtualCables: [AudioInputDevice] {
        guard let inputAudio else { return [] }
        return inputAudio.virtualOutputDevices
    }

    var activeVirtualCableName: String {
        virtualCables.first(where: { $0.uid == selectedVirtualCableUID })?.name
            ?? virtualCables.first?.name
            ?? "Virtual Mic"
    }

    var totalSelectedSourcesCount: Int {
        let validMics = physicalMics.filter { selectedMicUIDs.contains($0.uid) }.count
        let validApps = selectedAppKeys.count
        return validMics + validApps
    }

    func syncDevices() {
        let cables = virtualCables
        if selectedVirtualCableUID.isEmpty || !cables.contains(where: { $0.uid == selectedVirtualCableUID }) {
            // Prefer BlackHole first, otherwise first virtual loopback cable
            if let bh = cables.first(where: { $0.name.lowercased().contains("blackhole") }) {
                selectedVirtualCableUID = bh.uid
            } else if let first = cables.first {
                selectedVirtualCableUID = first.uid
            }
        }

        let mics = physicalMics
        for mic in mics {
            if micVolumes[mic.uid] == nil { micVolumes[mic.uid] = 1.0 }
            if micMuted[mic.uid] == nil { micMuted[mic.uid] = false }
            if micNoiseCut[mic.uid] == nil { micNoiseCut[mic.uid] = true }
        }

        if selectedMicUIDs.isEmpty, let firstMic = mics.first(where: { $0.id == inputAudio?.selectedSourceMicID }) ?? mics.first {
            selectedMicUIDs.insert(firstMic.uid)
        }
    }

    // MARK: - Source Toggles & Sliders

    func selectVirtualCable(uid: String) {
        guard selectedVirtualCableUID != uid else { return }
        selectedVirtualCableUID = uid
        if isActive {
            restartMix()
        }
    }

    func toggleMic(_ mic: AudioInputDevice) {
        if selectedMicUIDs.contains(mic.uid) {
            selectedMicUIDs.remove(mic.uid)
        } else {
            selectedMicUIDs.insert(mic.uid)
            if micVolumes[mic.uid] == nil { micVolumes[mic.uid] = 1.0 }
            if micNoiseCut[mic.uid] == nil { micNoiseCut[mic.uid] = true }
        }
        statusMessage = nil
        if isActive {
            rebuildSources()
        }
    }

    func setMicVolume(uid: String, volume: Float) {
        let clamped = max(0, min(2.0, volume))
        micVolumes[uid] = clamped
        if clamped > 0.001 && (micMuted[uid] == true) {
            micMuted[uid] = false
        }
        mixLock.lock()
        let unit = micUnits[uid]
        mixLock.unlock()
        unit?.ringBuffer.setGain(clamped, muted: micMuted[uid] ?? false)
    }

    func toggleMicMute(uid: String) {
        let next = !(micMuted[uid] ?? false)
        micMuted[uid] = next
        mixLock.lock()
        let unit = micUnits[uid]
        mixLock.unlock()
        unit?.ringBuffer.setGain(micVolumes[uid] ?? 1.0, muted: next)
    }

    func toggleMicNoiseCut(uid: String) {
        let next = !(micNoiseCut[uid] ?? true)
        micNoiseCut[uid] = next
        mixLock.lock()
        let unit = micUnits[uid]
        mixLock.unlock()
        unit?.noiseCutEnabled = next
    }

    func toggleApp(_ app: AudioAppSource) {
        let key = app.bundleID
        if selectedAppKeys.contains(key) {
            selectedAppKeys.remove(key)
        } else {
            selectedAppKeys.insert(key)
            if appVolumes[key] == nil { appVolumes[key] = 0.45 } // Safe 45% default so music doesn't overpower voice!
            if appMuted[key] == nil { appMuted[key] = false }
            if appMuteLocal[key] == nil { appMuteLocal[key] = false }
        }
        statusMessage = nil
        if isActive {
            rebuildSources()
        }
    }

    func setAppVolume(key: String, volume: Float) {
        let clamped = max(0, min(1.5, volume))
        appVolumes[key] = clamped
        if clamped > 0.001 && (appMuted[key] == true) {
            appMuted[key] = false
        }
        if #available(macOS 14.2, *) {
            mixLock.lock()
            let unit = appUnits[key] as? AppMixCaptureUnit
            mixLock.unlock()
            unit?.ringBuffer.setGain(clamped, muted: appMuted[key] ?? false)
        }
    }

    func toggleAppMute(key: String) {
        let next = !(appMuted[key] ?? false)
        appMuted[key] = next
        if #available(macOS 14.2, *) {
            mixLock.lock()
            let unit = appUnits[key] as? AppMixCaptureUnit
            mixLock.unlock()
            unit?.ringBuffer.setGain(appVolumes[key] ?? 0.45, muted: next)
        }
    }

    func toggleAppMuteLocal(key: String) {
        let next = !(appMuteLocal[key] ?? false)
        appMuteLocal[key] = next
        if isActive {
            rebuildSources()
        }
    }

    func toggleMonitorInHeadphones() {
        monitorInHeadphones.toggle()
        if isActive {
            if monitorInHeadphones {
                startMonitorOutputIfNeeded()
            } else {
                stopMonitorOutput()
            }
        }
    }

    func toggleSystemDefaultMic(_ enabled: Bool) {
        setAsSystemDefaultMic = enabled
        guard isActive else { return }
        if enabled, let cable = virtualCables.first(where: { $0.uid == selectedVirtualCableUID }) {
            if previousDefaultInputID == nil {
                previousDefaultInputID = inputAudio?.fetchDefaultInputDeviceID()
            }
            setDefaultInputDeviceSilent(cable.id)
        } else if let prev = previousDefaultInputID {
            setDefaultInputDeviceSilent(prev)
            previousDefaultInputID = nil
        }
    }

    // MARK: - Start / Stop Virtual Mic Mix

    func toggleMix() {
        if isActive {
            stopMix()
        } else {
            startMix()
        }
    }

    func startMix() {
        inputAudio?.refreshAll()
        perAppMixer?.refreshAudioProcesses()
        syncDevices()

        guard let cable = virtualCables.first(where: { $0.uid == selectedVirtualCableUID }) ?? virtualCables.first else {
            statusMessage = "Install BlackHole 2ch (`brew install blackhole-2ch`) to create a Virtual Mic bus."
            return
        }
        selectedVirtualCableUID = cable.uid

        guard totalSelectedSourcesCount >= 1 else {
            statusMessage = "Select at least 1 microphone or app audio source to mix."
            return
        }

        // Stop single-mic FX if it was using the same virtual cable to avoid contention
        if inputAudio?.fxEnabled == true {
            inputAudio?.stopFXEngine()
        }

        if setAsSystemDefaultMic {
            let currentDef = inputAudio?.fetchDefaultInputDeviceID() ?? kAudioObjectUnknown
            if currentDef != cable.id {
                previousDefaultInputID = currentDef
                setDefaultInputDeviceSilent(cable.id)
            }
        }

        // Build master output engine bound directly to the Virtual Loopback Cable
        let outEngine = AVAudioEngine()
        guard let outAU = outEngine.outputNode.audioUnit else {
            statusMessage = "Failed to initialize Virtual Mic output unit."
            return
        }

        var cableID = cable.id
        guard AudioUnitSetProperty(
            outAU,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &cableID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        ) == noErr else {
            statusMessage = "Could not bind Virtual Mic bus to \(cable.name)."
            return
        }

        let hwOutFmt = outEngine.outputNode.outputFormat(forBus: 0)
        let outRate = hwOutFmt.sampleRate > 0 ? hwOutFmt.sampleRate : 48000.0
        guard let stereoFmt = AVAudioFormat(standardFormatWithSampleRate: outRate, channels: 2) else {
            statusMessage = "Unsupported sample rate on \(cable.name)."
            return
        }

        let mixSource = AVAudioSourceNode(format: stereoFmt) { [weak self] _, _, frameCount, audioBufferList -> OSStatus in
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let count = Int(frameCount)
            guard abl.count >= 2,
                  let outL = abl[0].mData?.assumingMemoryBound(to: Float.self),
                  let outR = abl[1].mData?.assumingMemoryBound(to: Float.self) else {
                return noErr
            }
            memset(outL, 0, count * MemoryLayout<Float>.size)
            memset(outR, 0, count * MemoryLayout<Float>.size)

            guard let self else { return noErr }
            self.renderMasterMix(outL: outL, outR: outR, frameCount: count, sampleRate: outRate)
            return noErr
        }

        outEngine.attach(mixSource)
        outEngine.connect(mixSource, to: outEngine.mainMixerNode, format: stereoFmt)
        outEngine.prepare()

        do {
            try outEngine.start()
            mixOutEngine = outEngine
            isActive = true
            isMicMixViewMode = true
            statusMessage = nil

            rebuildSources()
            if monitorInHeadphones {
                startMonitorOutputIfNeeded()
            }

            // Re-attach tapped apps automatically if an app starts outputting audio mid-call
            appSyncTimer?.invalidate()
            appSyncTimer = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in
                self?.syncDynamicAppSourcesIfNeeded()
            }
        } catch {
            outEngine.stop()
            statusMessage = "Failed to start Virtual Mic: \(error.localizedDescription)"
            isActive = false
        }
    }

    func stopMix() {
        appSyncTimer?.invalidate()
        appSyncTimer = nil

        stopMonitorOutput()
        teardownAllSources()

        if let outEngine = mixOutEngine {
            outEngine.stop()
            mixOutEngine = nil
        }

        if let prev = previousDefaultInputID {
            setDefaultInputDeviceSilent(prev)
            previousDefaultInputID = nil
        }

        isActive = false
        masterLevel = 0.0
        micLevels.removeAll()
        appLevels.removeAll()
    }

    private func restartMix() {
        let wasActive = isActive
        stopMix()
        if wasActive {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
                self?.startMix()
            }
        }
    }

    // MARK: - Source Lifecycle & Real-Time Summing + Auto-Ducking

    private func rebuildSources() {
        guard isActive, let outEngine = mixOutEngine else { return }
        let outRate = outEngine.outputNode.outputFormat(forBus: 0).sampleRate > 0
            ? outEngine.outputNode.outputFormat(forBus: 0).sampleRate
            : 48000.0

        teardownAllSources()

        var newMics: [String: PhysicalMicCaptureUnit] = [:]
        for mic in physicalMics where selectedMicUIDs.contains(mic.uid) {
            let uid = mic.uid
            let vol = micVolumes[uid] ?? 1.0
            let muted = micMuted[uid] ?? false
            let cut = micNoiseCut[uid] ?? true
            if let unit = PhysicalMicCaptureUnit(
                deviceID: mic.id,
                uid: uid,
                outputSampleRate: outRate,
                gain: vol,
                muted: muted,
                noiseCut: cut,
                onLevel: { [weak self] lvl in
                    DispatchQueue.main.async { self?.micLevels[uid] = lvl }
                }
            ) {
                newMics[uid] = unit
            }
        }

        var newApps: [String: AnyObject] = [:]
        if #available(macOS 14.2, *), let apps = perAppMixer?.apps, let clockUID = resolvePhysicalClockOutputUID() {
            for app in apps where selectedAppKeys.contains(app.bundleID) {
                let key = app.bundleID
                let vol = appVolumes[key] ?? 0.45
                let muted = appMuted[key] ?? false
                let muteLocal = appMuteLocal[key] ?? false
                if let unit = AppMixCaptureUnit(
                    processObjectID: app.id,
                    bundleKey: key,
                    outputSampleRate: outRate,
                    gain: vol,
                    muted: muted,
                    muteLocalPlayback: muteLocal,
                    clockDeviceUID: clockUID,
                    onLevel: { [weak self] lvl in
                        DispatchQueue.main.async { self?.appLevels[key] = lvl }
                    }
                ) {
                    newApps[key] = unit
                }
            }
        }

        mixLock.lock()
        micUnits = newMics
        appUnits = newApps
        mixLock.unlock()

        if totalSelectedSourcesCount == 0 {
            stopMix()
        }
    }

    private func syncDynamicAppSourcesIfNeeded() {
        guard isActive, #available(macOS 14.2, *), !selectedAppKeys.isEmpty else { return }
        perAppMixer?.refreshAudioProcesses()
        guard let apps = perAppMixer?.apps else { return }

        mixLock.lock()
        let activeAppKeys = Set(appUnits.keys)
        mixLock.unlock()

        for app in apps where selectedAppKeys.contains(app.bundleID) && !activeAppKeys.contains(app.bundleID) {
            rebuildSources()
            return
        }
    }

    private func teardownAllSources() {
        mixLock.lock()
        let oldMics = Array(micUnits.values)
        let oldApps = Array(appUnits.values)
        micUnits.removeAll()
        appUnits.removeAll()
        mixLock.unlock()

        for m in oldMics { m.stop() }
        if #available(macOS 14.2, *) {
            for a in oldApps { (a as? AppMixCaptureUnit)?.stop() }
        }
    }

    private func renderMasterMix(outL: UnsafeMutablePointer<Float>, outR: UnsafeMutablePointer<Float>, frameCount: Int, sampleRate: Double) {
        if isMasterMuted || masterVolume <= 0.0001 {
            DispatchQueue.main.async { self.masterLevel = 0 }
            return
        }

        mixLock.lock()
        let mics = Array(micUnits.values)
        let apps = Array(appUnits.values)
        let monRing = monitorRing
        mixLock.unlock()

        // 1. Sum all selected microphones & detect voice activity for Auto-Ducking
        var voiceSpeaking = false
        for mic in mics {
            if mic.latestRMS > 0.018 && !(micMuted[mic.uid] ?? false) {
                voiceSpeaking = true
            }
            mic.ringBuffer.mixInto(leftAcc: outL, rightAcc: outR, frameCount: frameCount)
        }

        // 2. Smooth Voice-Priority Auto-Ducking envelope for background app audio
        let targetDuck: Float = (autoDuckApps && voiceSpeaking) ? 0.25 : 1.0
        let coeff: Float = targetDuck < duckEnvelope ? 0.22 : 0.035
        duckEnvelope += (targetDuck - duckEnvelope) * coeff

        // 3. Sum all selected application audio streams (scaled by duckEnvelope)
        if #available(macOS 14.2, *) {
            for obj in apps {
                if let appUnit = obj as? AppMixCaptureUnit {
                    appUnit.ringBuffer.mixInto(leftAcc: outL, rightAcc: outR, frameCount: frameCount, extraMultiplier: duckEnvelope)
                }
            }
        }

        // 4. Master gain + soft-clip limiter (`tanh`) + Master VU Meter
        let mGain = masterVolume
        var sumSq: Float = 0
        for i in 0..<frameCount {
            let l = tanh(outL[i] * mGain)
            let r = tanh(outR[i] * mGain)
            outL[i] = l
            outR[i] = r
            let mid = (l + r) * 0.5
            sumSq += mid * mid
        }

        let rms = sqrt(sumSq / Float(max(1, frameCount)))
        let vu = min(1.0, rms * 6.5)
        DispatchQueue.main.async {
            if self.isActive {
                self.masterLevel = vu
            }
        }

        // 5. Optional local headphone monitor
        monRing?.write(leftSrc: outL, rightSrc: outR, frameCount: frameCount, sampleRate: sampleRate)
    }

    // MARK: - Local Headphone Monitor

    private func startMonitorOutputIfNeeded() {
        stopMonitorOutput()
        guard let physOutID = resolvePhysicalOutputDeviceID() else { return }

        let monEngine = AVAudioEngine()
        guard let outAU = monEngine.outputNode.audioUnit else { return }
        var devID = physOutID
        guard AudioUnitSetProperty(
            outAU,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &devID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        ) == noErr else { return }

        let hwFmt = monEngine.outputNode.outputFormat(forBus: 0)
        let rate = hwFmt.sampleRate > 0 ? hwFmt.sampleRate : 48000.0
        guard let stereoFmt = AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2) else { return }

        let rb = VirtualMixRingBuffer(outputSampleRate: rate, initialGain: 0.85, initialMuted: false)
        let node = AVAudioSourceNode(format: stereoFmt) { _, _, frameCount, audioBufferList -> OSStatus in
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let n = Int(frameCount)
            guard abl.count >= 2,
                  let l = abl[0].mData?.assumingMemoryBound(to: Float.self),
                  let r = abl[1].mData?.assumingMemoryBound(to: Float.self) else { return noErr }
            memset(l, 0, n * MemoryLayout<Float>.size)
            memset(r, 0, n * MemoryLayout<Float>.size)
            rb.mixInto(leftAcc: l, rightAcc: r, frameCount: n)
            return noErr
        }

        monEngine.attach(node)
        monEngine.connect(node, to: monEngine.mainMixerNode, format: stereoFmt)
        monEngine.prepare()

        if (try? monEngine.start()) != nil {
            mixLock.lock()
            monitorRing = rb
            mixLock.unlock()
            monitorOutEngine = monEngine
        }
    }

    private func stopMonitorOutput() {
        mixLock.lock()
        monitorRing = nil
        mixLock.unlock()
        monitorOutEngine?.stop()
        monitorOutEngine = nil
    }

    // MARK: - CoreAudio Helpers

    private func resolvePhysicalClockOutputUID() -> String? {
        if let defOut = systemAudio?.outputDevices.first(where: { $0.isDefault && !$0.name.lowercased().contains("blackhole") }) {
            return defOut.uid
        }
        return systemAudio?.outputDevices.first(where: { !$0.name.lowercased().contains("blackhole") })?.uid
    }

    private func resolvePhysicalOutputDeviceID() -> AudioDeviceID? {
        if let defOut = systemAudio?.outputDevices.first(where: { $0.isDefault && !$0.name.lowercased().contains("blackhole") }) {
            return defOut.id
        }
        return systemAudio?.outputDevices.first(where: { !$0.name.lowercased().contains("blackhole") })?.id
    }

    private func setDefaultInputDeviceSilent(_ deviceID: AudioDeviceID) {
        var devID = deviceID
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &addr,
            0,
            nil,
            UInt32(MemoryLayout<AudioDeviceID>.size),
            &devID
        )
    }
}
