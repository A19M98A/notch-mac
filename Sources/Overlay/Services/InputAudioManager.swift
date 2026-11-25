import Foundation
import CoreAudio
import AudioToolbox
import AVFoundation
import Combine

struct AudioInputDevice: Identifiable, Equatable {
    let id: AudioDeviceID
    let name: String
    let uid: String
    let transportType: UInt32
    let isDefault: Bool

    var sfSymbol: String {
        let lower = name.lowercased()
        if lower.contains("airpods") { return "airpodspro" }
        if lower.contains("iphone") || lower.contains("continuity") { return "iphone" }
        if lower.contains("blackhole") || lower.contains("virtual") || lower.contains("loopback") { return "waveform.circle" }
        switch transportType {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE:
            return "headphones"
        case kAudioDeviceTransportTypeUSB:
            return "cable.connector"
        case kAudioDeviceTransportTypeBuiltIn:
            return "mic.fill"
        default:
            return "mic.circle.fill"
        }
    }
}

enum VoiceEffectPreset: String, CaseIterable, Identifiable {
    case clean = "Clean"
    case studio = "Studio"
    case podcast = "Podcast"
    case radio = "Radio"
    case deep = "Deep"
    case chipmunk = "High"
    case robot = "Robot"
    case reverb = "Hall"
    case echo = "Echo"

    var id: String { rawValue }

    var sfSymbol: String {
        switch self {
        case .clean: return "waveform"
        case .studio: return "mic.badge.plus"
        case .podcast: return "radio"
        case .radio: return "antenna.radiowaves.left.and.right"
        case .deep: return "arrow.down.circle"
        case .chipmunk: return "arrow.up.circle"
        case .robot: return "cpu"
        case .reverb: return "building.columns"
        case .echo: return "dot.radiowaves.right"
        }
    }
}

/// Thread-safe stereo audio ring buffer for glitch-free, zero-crackle bridging between
/// hardware capture and real-time AVAudioSourceNode playback.
private final class StereoRingBuffer {
    private let capacity: Int
    private var left: [Float]
    private var right: [Float]
    private var readIndex: Int = 0
    private var writeIndex: Int = 0
    private var available: Int = 0
    private var primed: Bool = false
    private let preRollFrames: Int
    private let lock = NSLock()

    init(capacity: Int = 32768, preRollFrames: Int = 1536) {
        self.capacity = capacity
        self.preRollFrames = preRollFrames
        self.left = [Float](repeating: 0, count: capacity)
        self.right = [Float](repeating: 0, count: capacity)
    }

    func reset() {
        lock.lock()
        readIndex = 0
        writeIndex = 0
        available = 0
        primed = false
        lock.unlock()
    }

    func write(leftSrc: UnsafePointer<Float>, rightSrc: UnsafePointer<Float>, count: Int) {
        guard count > 0 else { return }
        lock.lock()
        // If consumer fell way behind, drop oldest frames smoothly to keep latency low
        if available + count > capacity {
            let drop = (available + count) - capacity
            readIndex = (readIndex + drop) % capacity
            available -= drop
        }
        for i in 0..<count {
            left[writeIndex] = leftSrc[i]
            right[writeIndex] = rightSrc[i]
            writeIndex = (writeIndex + 1) % capacity
        }
        available += count
        if !primed && available >= preRollFrames {
            primed = true
        }
        lock.unlock()
    }

    func read(leftDst: UnsafeMutablePointer<Float>, rightDst: UnsafeMutablePointer<Float>, count: Int) {
        lock.lock()
        if !primed || available < count {
            // Output smooth silence while priming or on underrun (no garbage / pops)
            memset(leftDst, 0, count * MemoryLayout<Float>.size)
            memset(rightDst, 0, count * MemoryLayout<Float>.size)
            if available < count { primed = false }
            lock.unlock()
            return
        }
        for i in 0..<count {
            leftDst[i] = left[readIndex]
            rightDst[i] = right[readIndex]
            readIndex = (readIndex + 1) % capacity
        }
        available -= count
        lock.unlock()
    }
}

/// Manages macOS audio input devices (selection, gain, mute) plus a real-time AVAudioEngine DSP
/// voice effects chain (EQ / Voice Clarity, Pitch Shift, Delay, Reverb, Distortion, Live VU Meter).
final class InputAudioManager: ObservableObject {
    @Published var inputDevices: [AudioInputDevice] = []
    @Published var defaultInputDeviceID: AudioDeviceID = kAudioObjectUnknown
    @Published var selectedSourceMicID: AudioDeviceID = kAudioObjectUnknown // Raw physical mic Overlay captures from
    @Published var inputVolume: Float = 0.8
    @Published var isMuted: Bool = false

    // Real-Time Effects Engine State
    @Published var fxEnabled: Bool = false
    @Published var monitorEnabled: Bool = false   // OFF by default so you don't hear yourself in headphones
    @Published var fxTargetDeviceID: AudioDeviceID? = nil // Optional virtual loopback (e.g. BlackHole)
    @Published var virtualOutputDevices: [AudioInputDevice] = []
    @Published var selectedPreset: VoiceEffectPreset = .clean
    @Published var noiseCutEnabled: Bool = true   // 90Hz high-pass rumble/fan filter
    @Published var pitchSemitones: Float = 0.0    // -12 ... +12
    @Published var reverbWetDry: Float = 0.0      // 0 ... 100
    @Published var echoWetDry: Float = 0.0        // 0 ... 100
    @Published var liveLevel: Float = 0.0         // 0.0 ... 1.0 VU meter
    @Published var statusError: String? = nil

    private var captureEngine: AVAudioEngine?
    private var fxEngine: AVAudioEngine?
    private var monitorEngine: AVAudioEngine?
    private var fxRingBuffer: StereoRingBuffer?
    private var monitorRingBuffer: StereoRingBuffer?
    private var eqNode: AVAudioUnitEQ?
    private var pitchNode: AVAudioUnitTimePitch?
    private var distortionNode: AVAudioUnitDistortion?
    private var delayNode: AVAudioUnitDelay?
    private var reverbNode: AVAudioUnitReverb?
    private var isEngineActive: Bool = false
    private var routedToVirtualSuccessfully: Bool = false
    private var previousSystemInputDeviceID: AudioDeviceID? = nil

    private var devicesListenerBlock: AudioObjectPropertyListenerBlock?
    private var defaultInputListenerBlock: AudioObjectPropertyListenerBlock?

    init() {
        refreshAll()
        installSystemListeners()
    }

    deinit {
        stopFXEngine()
    }

    var currentInputDevice: AudioInputDevice? {
        if let chosen = inputDevices.first(where: { $0.id == selectedSourceMicID }) {
            return chosen
        }
        return inputDevices.first(where: { $0.id == defaultInputDeviceID })
    }

    var currentFXTargetDevice: AudioInputDevice? {
        guard let id = fxTargetDeviceID else { return nil }
        return virtualOutputDevices.first(where: { $0.id == id })
    }

    // MARK: - CoreAudio Input Device Management

    func refreshAll() {
        let defID = fetchDefaultInputDeviceID()
        let devices = fetchInputDevices(defaultID: defID)
        let virtuals = fetchVirtualOutputDevices()
        let vol = fetchInputVolume(deviceID: defID)
        let muted = fetchInputMute(deviceID: defID)

        DispatchQueue.main.async {
            self.defaultInputDeviceID = defID
            self.inputDevices = devices
            self.virtualOutputDevices = virtuals
            self.inputVolume = vol
            self.isMuted = muted
            if self.selectedSourceMicID == kAudioObjectUnknown || !devices.contains(where: { $0.id == self.selectedSourceMicID }) {
                // Prefer a real physical mic (not BlackHole) as capture source
                self.selectedSourceMicID = devices.first(where: { !$0.name.lowercased().contains("blackhole") && $0.id == defID })?.id
                    ?? devices.first(where: { !$0.name.lowercased().contains("blackhole") })?.id
                    ?? defID
            }
            // Auto-pick BlackHole if installed as the virtual FX output target
            if self.fxTargetDeviceID == nil,
               let bh = virtuals.first(where: { $0.name.lowercased().contains("blackhole") }) {
                self.fxTargetDeviceID = bh.id
            }
        }
    }

    func selectSourceMic(_ deviceID: AudioDeviceID) {
        selectedSourceMicID = deviceID
        // Also set as macOS default input if we're not routing to a virtual mic
        if fxTargetDeviceID == nil {
            setDefaultInputDevice(deviceID)
        } else if fxEnabled {
            restartFXEngine()
        }
    }

    func setDefaultInputDevice(_ deviceID: AudioDeviceID) {
        var devID = deviceID
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
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
            if fxEnabled {
                restartFXEngine()
            }
        }
    }

    func setInputVolume(_ newVolume: Float) {
        let clamped = max(0, min(1, newVolume))
        let devID = defaultInputDeviceID != kAudioObjectUnknown ? defaultInputDeviceID : fetchDefaultInputDeviceID()
        guard devID != kAudioObjectUnknown else { return }

        var vol = clamped
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectHasProperty(devID, &address) {
            AudioObjectSetPropertyData(devID, &address, 0, nil, UInt32(MemoryLayout<Float32>.size), &vol)
        } else {
            for ch: UInt32 in [0, 1, 2] {
                var chAddr = AudioObjectPropertyAddress(
                    mSelector: kAudioDevicePropertyVolumeScalar,
                    mScope: kAudioDevicePropertyScopeInput,
                    mElement: ch
                )
                if AudioObjectHasProperty(devID, &chAddr) {
                    AudioObjectSetPropertyData(devID, &chAddr, 0, nil, UInt32(MemoryLayout<Float32>.size), &vol)
                }
            }
        }

        if clamped > 0.001 && isMuted {
            setInputMuted(false)
        }

        DispatchQueue.main.async {
            self.inputVolume = clamped
        }
    }

    func setInputMuted(_ muted: Bool) {
        let devID = defaultInputDeviceID != kAudioObjectUnknown ? defaultInputDeviceID : fetchDefaultInputDeviceID()
        guard devID != kAudioObjectUnknown else { return }

        var muteVal: UInt32 = muted ? 1 : 0
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectHasProperty(devID, &address) {
            AudioObjectSetPropertyData(devID, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &muteVal)
        }
        DispatchQueue.main.async {
            self.isMuted = muted
        }
    }

    func toggleMute() {
        setInputMuted(!isMuted)
    }

    // MARK: - Real-Time DSP Effects Engine

    func toggleMonitor() {
        monitorEnabled.toggle()
        if monitorEnabled && !fxEnabled {
            startFXEngine()
            return
        }
        if monitorEnabled {
            startMonitorTapIfNeeded()
        } else {
            stopMonitorEngine()
        }
        updateOutputVolume()
    }

    func setFXTargetDevice(_ deviceID: AudioDeviceID?) {
        fxTargetDeviceID = deviceID
        if fxEnabled {
            restartFXEngine()
        }
    }

    private func updateOutputVolume() {
        let audible = monitorEnabled || routedToVirtualSuccessfully
        let vol: Float = audible ? 1.0 : 0.0
        fxEngine?.mainMixerNode.outputVolume = vol
    }
    func toggleFXEngine() {
        if fxEnabled {
            stopFXEngine()
        } else {
            startFXEngine()
        }
    }

    func applyPreset(_ preset: VoiceEffectPreset) {
        selectedPreset = preset
        switch preset {
        case .clean:
            noiseCutEnabled = false
            pitchSemitones = 0
            reverbWetDry = 0
            echoWetDry = 0
        case .studio:
            noiseCutEnabled = true
            pitchSemitones = 0
            reverbWetDry = 6
            echoWetDry = 0
        case .podcast:
            noiseCutEnabled = true
            pitchSemitones = -0.8
            reverbWetDry = 4
            echoWetDry = 0
        case .radio:
            noiseCutEnabled = true
            pitchSemitones = 0
            reverbWetDry = 8
            echoWetDry = 0
        case .deep:
            noiseCutEnabled = true
            pitchSemitones = -4.5
            reverbWetDry = 10
            echoWetDry = 0
        case .chipmunk:
            noiseCutEnabled = true
            pitchSemitones = 6.5
            reverbWetDry = 5
            echoWetDry = 0
        case .robot:
            noiseCutEnabled = true
            pitchSemitones = -2.0
            reverbWetDry = 18
            echoWetDry = 45
        case .reverb:
            noiseCutEnabled = true
            pitchSemitones = 0
            reverbWetDry = 55
            echoWetDry = 0
        case .echo:
            noiseCutEnabled = true
            pitchSemitones = 0
            reverbWetDry = 15
            echoWetDry = 48
        }
        updateDSPParameters()
    }

    func updateDSPParameters() {
        // Band 0: High-pass rumble / fan noise filter
        if let eqNode {
            let hp = eqNode.bands[0]
            hp.filterType = .highPass
            hp.frequency = selectedPreset == .radio ? 320 : 95
            hp.bypass = !noiseCutEnabled && selectedPreset != .radio

            // Band 1: Warmth / Body (180 Hz)
            let low = eqNode.bands[1]
            low.filterType = .parametric
            low.frequency = 180
            low.bandwidth = 1.2
            switch selectedPreset {
            case .podcast: low.gain = 4.5
            case .studio: low.gain = 2.0
            case .radio: low.gain = -6.0
            default: low.gain = 0
            }
            low.bypass = low.gain == 0

            // Band 2: Presence / Clarity (3.2 kHz)
            let high = eqNode.bands[2]
            high.filterType = selectedPreset == .radio ? .lowPass : .parametric
            high.frequency = selectedPreset == .radio ? 3400 : 3200
            high.bandwidth = 1.0
            switch selectedPreset {
            case .studio: high.gain = 3.5
            case .podcast: high.gain = 2.5
            default: high.gain = 0
            }
            high.bypass = (selectedPreset != .radio && high.gain == 0)
        }

        // Pitch Shift (-1200 ... +1200 cents)
        if let pitchNode {
            pitchNode.pitch = pitchSemitones * 100.0
            pitchNode.bypass = abs(pitchSemitones) < 0.05
        }

        // Distortion (for Radio / Robot character)
        if let distortionNode {
            if selectedPreset == .radio {
                distortionNode.loadFactoryPreset(.speechRadioTower)
                distortionNode.wetDryMix = 28
                distortionNode.bypass = false
            } else if selectedPreset == .robot {
                distortionNode.loadFactoryPreset(.speechCosmicInterference)
                distortionNode.wetDryMix = 32
                distortionNode.bypass = false
            } else {
                distortionNode.wetDryMix = 0
                distortionNode.bypass = true
            }
        }

        // Delay / Echo
        if let delayNode {
            delayNode.delayTime = selectedPreset == .robot ? 0.025 : 0.28
            delayNode.feedback = selectedPreset == .robot ? 65 : 38
            delayNode.wetDryMix = echoWetDry
            delayNode.bypass = echoWetDry < 1.0
        }

        // Reverb
        if let reverbNode {
            reverbNode.loadFactoryPreset(selectedPreset == .reverb ? .largeHall2 : .mediumRoom)
            reverbNode.wetDryMix = reverbWetDry
            reverbNode.bypass = reverbWetDry < 1.0
        }
    }

    private func startFXEngine() {
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
            DispatchQueue.main.async {
                guard let self else { return }
                if !granted {
                    self.statusError = "Grant Microphone permission in System Settings."
                    self.fxEnabled = false
                    return
                }
                self.bootAudioEngine()
            }
        }
    }

    @Published var autoSwitchSystemMic: Bool = true

    private func bootAudioEngine() {
        // Teardown synchronously WITHOUT queuing async fxEnabled = false
        teardownEnginesSync(restoreSystemInput: false)

        let physicalSourceID = (selectedSourceMicID != kAudioObjectUnknown) ? selectedSourceMicID : fetchDefaultInputDeviceID()
        guard physicalSourceID != kAudioObjectUnknown else {
            statusError = "No input microphone found."
            fxEnabled = false
            return
        }

        // 1. Switch macOS default input to BlackHole FIRST (before starting captureEngine!)
        //    so macOS does NOT send a configuration-change event that disconnects captureEngine afterwards!
        if autoSwitchSystemMic, let virtualID = fxTargetDeviceID, virtualID != physicalSourceID {
            let currentDefault = fetchDefaultInputDeviceID()
            if currentDefault != virtualID {
                self.previousSystemInputDeviceID = currentDefault
                setDefaultInputDeviceSilent(virtualID)
            }
        }

        let capEngine = AVAudioEngine()
        let inNode = capEngine.inputNode

        // 2. Explicitly bind captureEngine.inputNode to the chosen physical mic (e.g. PD100U / Maono)
        var srcID = physicalSourceID
        if let inAU = inNode.audioUnit {
            AudioUnitSetProperty(
                inAU,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &srcID,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
        }

        // Read the outputFormat of inputNode AFTER binding the hardware device
        let inFormat = inNode.outputFormat(forBus: 0)
        guard inFormat.sampleRate > 0, inFormat.channelCount > 0 else {
            if let prev = previousSystemInputDeviceID {
                setDefaultInputDeviceSilent(prev)
                previousSystemInputDeviceID = nil
            }
            statusError = "Selected microphone has no active stream."
            fxEnabled = false
            return
        }

        let outEngine = AVAudioEngine()
        var didRouteVirtual = false

        // 3. Route fxEngine output to BlackHole (if selected)
        if var targetID = fxTargetDeviceID, let audioUnit = outEngine.outputNode.audioUnit {
            let status = AudioUnitSetProperty(
                audioUnit,
                kAudioOutputUnitProperty_CurrentDevice,
                kAudioUnitScope_Global,
                0,
                &targetID,
                UInt32(MemoryLayout<AudioDeviceID>.size)
            )
            didRouteVirtual = (status == noErr)
        }
        self.routedToVirtualSuccessfully = didRouteVirtual

        let outFormat = outEngine.mainMixerNode.outputFormat(forBus: 0)
        let targetRate = outFormat.sampleRate > 0 ? outFormat.sampleRate : 48000
        guard let stereoFormat = AVAudioFormat(standardFormatWithSampleRate: targetRate, channels: 2) else {
            statusError = "Could not create stereo audio format."
            fxEnabled = false
            return
        }

        let ring = StereoRingBuffer(capacity: 32768, preRollFrames: 1536)
        self.fxRingBuffer = ring

        let sourceNode = AVAudioSourceNode(format: stereoFormat) { _, _, frameCount, audioBufferList -> OSStatus in
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let n = Int(frameCount)
            guard abl.count >= 2,
                  let lPtr = abl[0].mData?.assumingMemoryBound(to: Float.self),
                  let rPtr = abl[1].mData?.assumingMemoryBound(to: Float.self) else {
                return noErr
            }
            ring.read(leftDst: lPtr, rightDst: rPtr, count: n)
            return noErr
        }

        let eq = AVAudioUnitEQ(numberOfBands: 3)
        let pitch = AVAudioUnitTimePitch()
        let dist = AVAudioUnitDistortion()
        let delay = AVAudioUnitDelay()
        let reverb = AVAudioUnitReverb()

        self.eqNode = eq
        self.pitchNode = pitch
        self.distortionNode = dist
        self.delayNode = delay
        self.reverbNode = reverb

        outEngine.attach(sourceNode)
        outEngine.attach(eq)
        outEngine.attach(pitch)
        outEngine.attach(dist)
        outEngine.attach(delay)
        outEngine.attach(reverb)

        outEngine.connect(sourceNode, to: eq, format: stereoFormat)
        outEngine.connect(eq, to: pitch, format: stereoFormat)
        outEngine.connect(pitch, to: dist, format: stereoFormat)
        outEngine.connect(dist, to: delay, format: stereoFormat)
        outEngine.connect(delay, to: reverb, format: stereoFormat)
        outEngine.connect(reverb, to: outEngine.mainMixerNode, format: stereoFormat)

        let initialVol: Float = (monitorEnabled || didRouteVirtual) ? 1.0 : 0.0
        outEngine.mainMixerNode.outputVolume = initialVol

        updateDSPParameters()

        // Create ONE persistent converter (reused across callbacks to prevent periodic filter-reset crackle!)
        var cachedConverter: AVAudioConverter? = nil
        var cachedSrcFormat: AVAudioFormat? = nil
        self.isEngineActive = true

        // Capture-only tap on inputNode: computes VU level + feeds smooth ring buffer
        inNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            guard let self, self.isEngineActive else { return }
            let n = Int(buffer.frameLength)
            guard n > 0, let rawChannels = buffer.floatChannelData else { return }

            // 1. Live VU meter from raw mic input
            let ch0 = rawChannels[0]
            var sum: Float = 0
            for i in 0..<n {
                let s = ch0[i]
                sum += s * s
            }
            let rms = sqrt(sum / Float(n))
            let level = min(1.0, max(0.0, rms * 8.0))
            DispatchQueue.main.async {
                if self.isEngineActive {
                    self.liveLevel = level
                }
            }

            // 2. Skip audio feed when muted or neither Monitor nor Virtual Mic is active
            guard !self.isMuted, (self.monitorEnabled || self.routedToVirtualSuccessfully) else { return }

            // Fast lossless path when sample rates match (zero resampling artifacts!)
            // Always center microphone voice to exact dual-mono (identical Left & Right)
            if abs(buffer.format.sampleRate - stereoFormat.sampleRate) < 1.0 {
                let leftPtr = rawChannels[0]
                if buffer.format.channelCount >= 2 {
                    let rightPtr = rawChannels[1]
                    var sumL: Float = 0
                    var sumR: Float = 0
                    for i in stride(from: 0, to: n, by: 4) {
                        sumL += abs(leftPtr[i])
                        sumR += abs(rightPtr[i])
                    }
                    // Pick the active mic channel and mirror identically to both L and R
                    let monoPtr = (sumR > sumL * 1.2) ? rightPtr : leftPtr
                    ring.write(leftSrc: monoPtr, rightSrc: monoPtr, count: n)
                } else {
                    ring.write(leftSrc: leftPtr, rightSrc: leftPtr, count: n)
                }
                return
            }

            // Resampling path using a single persistent AVAudioConverter
            if cachedConverter == nil || cachedSrcFormat != buffer.format {
                cachedSrcFormat = buffer.format
                cachedConverter = AVAudioConverter(from: buffer.format, to: stereoFormat)
                if buffer.format.channelCount == 1 {
                    cachedConverter?.channelMap = [0, 0]
                }
            }
            guard let converter = cachedConverter else { return }
            let ratio = stereoFormat.sampleRate / max(1.0, buffer.format.sampleRate)
            let capacity = AVAudioFrameCount(Double(n) * ratio) + 64
            guard let outBuf = AVAudioPCMBuffer(pcmFormat: stereoFormat, frameCapacity: capacity) else { return }

            var fed = false
            var convErr: NSError?
            let status = converter.convert(to: outBuf, error: &convErr) { _, outStatus in
                if fed {
                    outStatus.pointee = .noDataNow
                    return nil
                }
                fed = true
                outStatus.pointee = .haveData
                return buffer
            }

            if (status == .haveData || status == .inputRanDry),
               outBuf.frameLength > 0,
               let dstCh = outBuf.floatChannelData {
                let outCount = Int(outBuf.frameLength)
                // Mirror channel 0 identically to both Left and Right for 100% centered dual-mono voice
                ring.write(leftSrc: dstCh[0], rightSrc: dstCh[0], count: outCount)
            }
        }

        do {
            try outEngine.start()
            try capEngine.start()
            self.captureEngine = capEngine
            self.fxEngine = outEngine
            self.fxEnabled = true
            self.statusError = nil

            if self.monitorEnabled {
                self.startMonitorTapIfNeeded()
            }
        } catch {
            inNode.removeTap(onBus: 0)
            capEngine.stop()
            outEngine.stop()
            self.isEngineActive = false
            if let prev = previousSystemInputDeviceID {
                setDefaultInputDeviceSilent(prev)
                previousSystemInputDeviceID = nil
            }
            self.statusError = "Could not start FX engine: \(error.localizedDescription)"
            self.fxEnabled = false
        }
    }

    private func setDefaultInputDeviceSilent(_ deviceID: AudioDeviceID) {
        var devID = deviceID
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            0,
            nil,
            UInt32(MemoryLayout<AudioDeviceID>.size),
            &devID
        )
    }

    private func restartFXEngine() {
        teardownEnginesSync(restoreSystemInput: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            self?.bootAudioEngine()
        }
    }

    private func startMonitorTapIfNeeded() {
        guard routedToVirtualSuccessfully, let fx = fxEngine else {
            updateOutputVolume()
            return
        }
        stopMonitorEngine()

        let monEngine = AVAudioEngine()
        let fxFormat = fx.mainMixerNode.outputFormat(forBus: 0)
        guard fxFormat.sampleRate > 0, fxFormat.channelCount >= 2 else { return }

        let monRing = StereoRingBuffer(capacity: 32768, preRollFrames: 1536)
        self.monitorRingBuffer = monRing

        let monSource = AVAudioSourceNode(format: fxFormat) { _, _, frameCount, audioBufferList -> OSStatus in
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let n = Int(frameCount)
            guard abl.count >= 2,
                  let lPtr = abl[0].mData?.assumingMemoryBound(to: Float.self),
                  let rPtr = abl[1].mData?.assumingMemoryBound(to: Float.self) else {
                return noErr
            }
            monRing.read(leftDst: lPtr, rightDst: rPtr, count: n)
            return noErr
        }

        monEngine.attach(monSource)
        monEngine.connect(monSource, to: monEngine.mainMixerNode, format: fxFormat)
        monEngine.mainMixerNode.outputVolume = 1.0

        do {
            try monEngine.start()
            self.monitorEngine = monEngine

            fx.mainMixerNode.removeTap(onBus: 0)
            fx.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: fxFormat) { [weak self] buf, _ in
                guard let self, self.monitorEnabled, self.isEngineActive,
                      let ch = buf.floatChannelData, buf.frameLength > 0 else { return }
                monRing.write(leftSrc: ch[0], rightSrc: ch[1], count: Int(buf.frameLength))
            }
        } catch {
            stopMonitorEngine()
        }
    }

    private func stopMonitorEngine() {
        fxEngine?.mainMixerNode.removeTap(onBus: 0)
        monitorRingBuffer?.reset()
        monitorRingBuffer = nil
        monitorEngine?.stop()
        monitorEngine?.reset()
        monitorEngine = nil
    }

    private func teardownEnginesSync(restoreSystemInput: Bool) {
        isEngineActive = false
        stopMonitorEngine()
        routedToVirtualSuccessfully = false
        fxRingBuffer?.reset()
        fxRingBuffer = nil
        if let cap = captureEngine {
            cap.inputNode.removeTap(onBus: 0)
            cap.stop()
            cap.reset()
            captureEngine = nil
        }
        if let fx = fxEngine {
            fx.mainMixerNode.outputVolume = 0.0
            fx.stop()
            fx.reset()
            fxEngine = nil
        }
        eqNode = nil
        pitchNode = nil
        distortionNode = nil
        delayNode = nil
        reverbNode = nil

        if restoreSystemInput, let prevID = previousSystemInputDeviceID {
            setDefaultInputDeviceSilent(prevID)
            previousSystemInputDeviceID = nil
        }
    }

    func stopFXEngine() {
        teardownEnginesSync(restoreSystemInput: true)
        if Thread.isMainThread {
            self.fxEnabled = false
            self.liveLevel = 0
        } else {
            DispatchQueue.main.async {
                self.fxEnabled = false
                self.liveLevel = 0
            }
        }
    }

    // MARK: - CoreAudio Input Queries

    func fetchDefaultInputDeviceID() -> AudioDeviceID {
        var devID: AudioDeviceID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &devID)
        return devID
    }

    private func fetchVirtualOutputDevices() -> [AudioInputDevice] {
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

        var result: [AudioInputDevice] = []
        for id in deviceIDs {
            let name = getDeviceStringProperty(id, selector: kAudioObjectPropertyName) ?? ""
            let uid = getDeviceStringProperty(id, selector: kAudioDevicePropertyDeviceUID) ?? "\(id)"
            if uid.hasPrefix("com.overlay.tap.") || name.hasPrefix("OverlayTap-") ||
               uid.hasPrefix(PairPlayService.aggregateUIDPrefix) || name.hasPrefix(PairPlayService.aggregateNamePrefix) {
                continue
            }
            let transport = getDeviceUInt32Property(id, selector: kAudioDevicePropertyTransportType) ?? 0
            let lower = name.lowercased()
            let isVirtual = transport == kAudioDeviceTransportTypeVirtual ||
                            lower.contains("blackhole") || lower.contains("vb-cable") ||
                            lower.contains("loopback") || lower.contains("soundflower")
            guard isVirtual, hasInputStreams(deviceID: id) else { continue }
            // Verify it also has output channels so we can write mixed audio into it
            var outAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: kAudioObjectPropertyElementMain
            )
            var outSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(id, &outAddr, 0, nil, &outSize) == noErr, outSize > 0 else { continue }
            let rawPtr = UnsafeMutableRawPointer.allocate(byteCount: Int(outSize), alignment: MemoryLayout<AudioBufferList>.alignment)
            defer { rawPtr.deallocate() }
            guard AudioObjectGetPropertyData(id, &outAddr, 0, nil, &outSize, rawPtr) == noErr else { continue }
            let outBufs = UnsafeMutableAudioBufferListPointer(rawPtr.assumingMemoryBound(to: AudioBufferList.self))
            guard outBufs.reduce(0, { $0 + Int($1.mNumberChannels) }) > 0 else { continue }
            result.append(AudioInputDevice(id: id, name: name, uid: uid, transportType: kAudioDeviceTransportTypeVirtual, isDefault: false))
        }
        return result.sorted { a, b in
            let aBH = a.name.lowercased().contains("blackhole")
            let bBH = b.name.lowercased().contains("blackhole")
            if aBH != bBH { return aBH }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    private func fetchInputDevices(defaultID: AudioDeviceID) -> [AudioInputDevice] {
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

        var result: [AudioInputDevice] = []
        for id in deviceIDs {
            let name = getDeviceStringProperty(id, selector: kAudioObjectPropertyName) ?? "Unknown Mic"
            let uid = getDeviceStringProperty(id, selector: kAudioDevicePropertyDeviceUID) ?? "\(id)"
            if uid.hasPrefix("com.overlay.tap.") || name.hasPrefix("OverlayTap-") { continue }
            guard hasInputStreams(deviceID: id) else { continue }

            let transport = getDeviceUInt32Property(id, selector: kAudioDevicePropertyTransportType) ?? 0
            result.append(AudioInputDevice(
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

    private func hasInputStreams(deviceID: AudioDeviceID) -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
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
        return bufferList.reduce(0) { $0 + Int($1.mNumberChannels) } > 0
    }

    private func fetchInputVolume(deviceID: AudioDeviceID) -> Float {
        guard deviceID != kAudioObjectUnknown else { return 0.8 }
        var vol: Float32 = 0.8
        var size = UInt32(MemoryLayout<Float32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectHasProperty(deviceID, &address),
           AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &vol) == noErr {
            return vol
        }
        for ch: UInt32 in [0, 1] {
            var chAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: ch
            )
            if AudioObjectHasProperty(deviceID, &chAddr),
               AudioObjectGetPropertyData(deviceID, &chAddr, 0, nil, &size, &vol) == noErr {
                return vol
            }
        }
        return 0.8
    }

    private func fetchInputMute(deviceID: AudioDeviceID) -> Bool {
        guard deviceID != kAudioObjectUnknown else { return false }
        var muted: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeInput,
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
        guard AudioObjectGetPropertyData(deviceID, &address, 0, nil, &size, &cfStr) == noErr,
              let str = cfStr?.takeRetainedValue() else { return nil }
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

    private func installSystemListeners() {
        var defAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let defBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.refreshAll()
        }
        defaultInputListenerBlock = defBlock
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &defAddr, DispatchQueue.main, defBlock)

        var devAddr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let devBlock: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.refreshAll()
        }
        devicesListenerBlock = devBlock
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &devAddr, DispatchQueue.main, devBlock)
    }
}
