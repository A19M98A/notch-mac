import Foundation
import AppKit
import CoreAudio
import AudioToolbox
import AVFoundation
import Combine

enum PairPlayChannelMode: String, CaseIterable, Identifiable {
    case stereo = "Stereo"
    case mono = "Mono"
    case leftOnly = "Left Ear"
    case rightOnly = "Right Ear"
    case swapLR = "Swap L/R"

    var id: String { rawValue }

    var shortLabel: String {
        switch self {
        case .stereo: return "Stereo"
        case .mono: return "Mono"
        case .leftOnly: return "L Ear"
        case .rightOnly: return "R Ear"
        case .swapLR: return "L⇄R"
        }
    }

    var sfSymbol: String {
        switch self {
        case .stereo: return "speaker.wave.2.fill"
        case .mono: return "circle.lefthalf.filled"
        case .leftOnly: return "l.circle.fill"
        case .rightOnly: return "r.circle.fill"
        case .swapLR: return "arrow.left.arrow.right.circle.fill"
        }
    }
}

enum PairPlayEQPreset: String, CaseIterable, Identifiable {
    case flat = "Flat"
    case bassBoost = "Bass+"
    case vocal = "Vocal"
    case trebleBoost = "Treble+"
    case cinema = "Cinema"

    var id: String { rawValue }
}

/// Thread-safe stereo ring buffer supporting dynamic millisecond delay compensation (`0...400 ms`),
/// spatial ear / channel routing (`Stereo`, `Mono`, `Left Ear`, `Right Ear`, `Swap L/R`),
/// smooth software gain/mute, and automatic sample-rate adaptation across mixed 44.1kHz / 48kHz devices.
private final class PairPlayDelayRingBuffer {
    private let capacity: Int
    private var left: [Float]
    private var right: [Float]
    private var readPos: Double = 0
    private var writeIndex: Int = 0
    private var available: Double = 0
    private var primed: Bool = false

    private let outputSampleRate: Double
    private var inputSampleRate: Double
    private var delayMs: Int
    private var gain: Float
    private var muted: Bool
    private var channelMode: PairPlayChannelMode
    private let basePreRollFrames: Double = 1536
    private let lock = NSLock()

    init(outputSampleRate: Double, initialDelayMs: Int, initialGain: Float, initialMuted: Bool, initialChannelMode: PairPlayChannelMode) {
        self.outputSampleRate = max(8000, outputSampleRate)
        self.inputSampleRate = self.outputSampleRate
        self.capacity = 65536
        self.left = [Float](repeating: 0, count: capacity)
        self.right = [Float](repeating: 0, count: capacity)
        self.delayMs = max(0, min(400, initialDelayMs))
        self.gain = max(0, min(1, initialGain))
        self.muted = initialMuted
        self.channelMode = initialChannelMode
    }

    func updateParameters(delayMs: Int, gain: Float, muted: Bool, channelMode: PairPlayChannelMode) {
        lock.lock()
        let clampedDelay = max(0, min(400, delayMs))
        if self.delayMs != clampedDelay {
            self.delayMs = clampedDelay
            let targetLag = targetBufferedInputFrames
            if available >= targetLag {
                var newRead = Double(writeIndex) - targetLag
                while newRead < 0 { newRead += Double(capacity) }
                readPos = newRead
                available = targetLag
            } else {
                primed = false
            }
        }
        self.gain = max(0, min(1, gain))
        self.muted = muted
        self.channelMode = channelMode
        lock.unlock()
    }

    private var targetBufferedInputFrames: Double {
        let delayFrames = (Double(delayMs) / 1000.0) * inputSampleRate
        return basePreRollFrames + delayFrames
    }

    func write(leftSrc: UnsafePointer<Float>, rightSrc: UnsafePointer<Float>, frameCount: Int, sampleRate: Double) {
        guard frameCount > 0 else { return }
        lock.lock()
        if sampleRate > 8000 && abs(sampleRate - inputSampleRate) > 1.0 {
            inputSampleRate = sampleRate
        }

        let maxAllowed = Double(capacity - 1024)
        if available + Double(frameCount) > maxAllowed {
            let drop = (available + Double(frameCount)) - targetBufferedInputFrames
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

        if !primed && available >= targetBufferedInputFrames {
            var alignedRead = Double(writeIndex) - targetBufferedInputFrames
            while alignedRead < 0 { alignedRead += Double(capacity) }
            readPos = alignedRead
            available = targetBufferedInputFrames
            primed = true
        }
        lock.unlock()
    }

    func read(leftDst: UnsafeMutablePointer<Float>, rightDst: UnsafeMutablePointer<Float>, frameCount: Int) {
        lock.lock()
        let step = inputSampleRate / outputSampleRate
        let neededInput = Double(frameCount) * step + 1.0

        if !primed || available < neededInput {
            memset(leftDst, 0, frameCount * MemoryLayout<Float>.size)
            memset(rightDst, 0, frameCount * MemoryLayout<Float>.size)
            if available < neededInput { primed = false }
            lock.unlock()
            return
        }

        let target = targetBufferedInputFrames
        let driftError = available - target
        let driftAdjust = max(-0.002, min(0.002, driftError * 0.00002))
        let effectiveStep = step + driftAdjust
        let effectiveGain: Float = muted ? 0.0 : gain
        let mode = channelMode
        let cap = capacity

        for i in 0..<frameCount {
            let idx0 = Int(readPos) % cap
            let idx1 = (idx0 + 1) % cap
            let frac = Float(readPos - floor(readPos))

            let rawL = (left[idx0] + (left[idx1] - left[idx0]) * frac) * effectiveGain
            let rawR = (right[idx0] + (right[idx1] - right[idx0]) * frac) * effectiveGain

            switch mode {
            case .stereo:
                leftDst[i] = rawL
                rightDst[i] = rawR
            case .mono:
                let mid = (rawL + rawR) * 0.5
                leftDst[i] = mid
                rightDst[i] = mid
            case .leftOnly:
                leftDst[i] = (rawL + rawR) * 0.5
                rightDst[i] = 0
            case .rightOnly:
                leftDst[i] = 0
                rightDst[i] = (rawL + rawR) * 0.5
            case .swapLR:
                leftDst[i] = rawR
                rightDst[i] = rawL
            }

            readPos += effectiveStep
            if readPos >= Double(cap) {
                readPos -= Double(cap)
            }
        }
        available = max(0, available - Double(frameCount) * effectiveStep)
        lock.unlock()
    }
}

/// Dedicated per-device AVAudioEngine output bound to a specific physical AudioDeviceID,
/// including a real-time 3-band AVAudioUnitEQ for per-headphone sound shaping.
private final class DelayedDeviceOutput {
    let deviceID: AudioDeviceID
    let uid: String
    let ringBuffer: PairPlayDelayRingBuffer
    private let engine = AVAudioEngine()
    private let eqNode = AVAudioUnitEQ(numberOfBands: 3)
    private var sourceNode: AVAudioSourceNode?

    init?(deviceID: AudioDeviceID, uid: String, delayMs: Int, gain: Float, muted: Bool, channelMode: PairPlayChannelMode, eqPreset: PairPlayEQPreset) {
        self.deviceID = deviceID
        self.uid = uid

        let outNode = engine.outputNode
        guard let audioUnit = outNode.audioUnit else { return nil }

        var devID = deviceID
        let setStatus = AudioUnitSetProperty(
            audioUnit,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &devID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        )
        guard setStatus == noErr else { return nil }

        let hwFormat = outNode.outputFormat(forBus: 0)
        let sampleRate = hwFormat.sampleRate > 0 ? hwFormat.sampleRate : 48000.0
        guard let stereoFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 2) else {
            return nil
        }

        let rb = PairPlayDelayRingBuffer(
            outputSampleRate: sampleRate,
            initialDelayMs: delayMs,
            initialGain: gain,
            initialMuted: muted,
            initialChannelMode: channelMode
        )
        self.ringBuffer = rb

        let node = AVAudioSourceNode(format: stereoFormat) { _, _, frameCount, audioBufferList -> OSStatus in
            let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
            let count = Int(frameCount)
            if abl.count >= 2,
               let lPtr = abl[0].mData?.assumingMemoryBound(to: Float.self),
               let rPtr = abl[1].mData?.assumingMemoryBound(to: Float.self) {
                rb.read(leftDst: lPtr, rightDst: rPtr, frameCount: count)
            } else if abl.count == 1,
                      let ptr = abl[0].mData?.assumingMemoryBound(to: Float.self) {
                var tempR = [Float](repeating: 0, count: count)
                rb.read(leftDst: ptr, rightDst: &tempR, frameCount: count)
            }
            return noErr
        }
        self.sourceNode = node

        configureBands()
        applyEQ(eqPreset)

        engine.attach(node)
        engine.attach(eqNode)
        engine.connect(node, to: eqNode, format: stereoFormat)
        engine.connect(eqNode, to: engine.mainMixerNode, format: stereoFormat)
        engine.prepare()

        do {
            try engine.start()
        } catch {
            return nil
        }
    }

    private func configureBands() {
        let bands = eqNode.bands
        guard bands.count >= 3 else { return }
        bands[0].filterType = .lowShelf
        bands[0].frequency = 95
        bands[0].bypass = false

        bands[1].filterType = .parametric
        bands[1].frequency = 2400
        bands[1].bandwidth = 1.1
        bands[1].bypass = false

        bands[2].filterType = .highShelf
        bands[2].frequency = 6500
        bands[2].bypass = false
    }

    func applyEQ(_ preset: PairPlayEQPreset) {
        let bands = eqNode.bands
        guard bands.count >= 3 else { return }
        switch preset {
        case .flat:
            eqNode.bypass = true
            bands[0].gain = 0; bands[1].gain = 0; bands[2].gain = 0
        case .bassBoost:
            eqNode.bypass = false
            bands[0].gain = 6.5; bands[1].gain = 0.0; bands[2].gain = 1.5
        case .vocal:
            eqNode.bypass = false
            bands[0].gain = -2.0; bands[1].gain = 4.5; bands[2].gain = 2.0
        case .trebleBoost:
            eqNode.bypass = false
            bands[0].gain = 0.0; bands[1].gain = 2.0; bands[2].gain = 5.5
        case .cinema:
            eqNode.bypass = false
            bands[0].gain = 5.0; bands[1].gain = 2.0; bands[2].gain = 3.5
        }
    }

    func stop() {
        engine.stop()
        if let node = sourceNode {
            engine.detach(node)
            sourceNode = nil
        }
    }
}

/// PairPlay multi-output audio sharing & studio service:
/// - Stream macOS audio to 2+ Bluetooth/wired headphones or speakers simultaneously
/// - Per-device Volume & Mute
/// - Per-device Spatial Ear / Channel Mode (`Stereo`, `Mono`, `Left Ear`, `Right Ear`, `Swap L/R`)
/// - Per-device 5-Preset Equalizer (`Flat`, `Bass+`, `Vocal`, `Treble+`, `Cinema`)
/// - Per-device Millisecond Latency Calibration (`0...400 ms`, 1 ms precision) + Sync Click Metronome
final class PairPlayService: ObservableObject {
    static let aggregateUIDPrefix = "com.amin.notchpulse.pairplay"
    static let aggregateNamePrefix = "NotchPulse PairPlay"

    @Published var isPairPlayViewMode: Bool = false
    @Published var isActive: Bool = false
    @Published var selectedUIDs: Set<String> = []
    @Published var deviceVolumes: [String: Float] = [:]
    @Published var deviceMuted: [String: Bool] = [:]
    @Published var deviceDelayMs: [String: Int] = [:]
    @Published var deviceChannelModes: [String: PairPlayChannelMode] = [:]
    @Published var deviceEQPresets: [String: PairPlayEQPreset] = [:]
    @Published var isSyncTestPlaying: Bool = false
    @Published var statusMessage: String? = nil

    weak var systemAudio: SystemAudioManager?

    private var stackedAggregateID: AudioObjectID = kAudioObjectUnknown
    private var previousDefaultOutputUID: String? = nil

    // DSP Engine state (active when any selected device uses delay > 0, custom channel mode, or EQ)
    private var delayedOutputs: [String: DelayedDeviceOutput] = [:]
    private var globalTapID: AudioObjectID = kAudioObjectUnknown
    private var globalTapAggregateID: AudioObjectID = kAudioObjectUnknown
    private var globalTapIOProcID: AudioDeviceIOProcID?
    private var blackHoleCaptureEngine: AVAudioEngine?
    private var usingDelayDSPEngine: Bool = false
    private let stateLock = NSLock()
    private var termObserver: NSObjectProtocol?

    // Sync Click Metronome
    private var syncClickTimer: Timer?
    private var syncAutoStopWork: DispatchWorkItem?
    private var clickPlayer: AVAudioPlayer?

    init() {
        cleanupOrphanedPairPlayDevices()
        termObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.stopSyncTest()
            self?.stopPairPlay()
        }
    }

    deinit {
        if let termObserver {
            NotificationCenter.default.removeObserver(termObserver)
        }
        stopSyncTest()
        stopPairPlay()
    }

    // MARK: - Device Selection & Per-Device Controls

    func syncAvailableDevices(_ devices: [AudioOutputDevice]) {
        for dev in devices {
            if deviceVolumes[dev.uid] == nil {
                deviceVolumes[dev.uid] = readHardwareVolume(deviceID: dev.id) ?? 0.75
            }
            if deviceMuted[dev.uid] == nil {
                deviceMuted[dev.uid] = readHardwareMute(deviceID: dev.id)
            }
            if deviceDelayMs[dev.uid] == nil {
                deviceDelayMs[dev.uid] = 0
            }
            if deviceChannelModes[dev.uid] == nil {
                deviceChannelModes[dev.uid] = .stereo
            }
            if deviceEQPresets[dev.uid] == nil {
                deviceEQPresets[dev.uid] = .flat
            }
        }

        if selectedUIDs.isEmpty, let def = devices.first(where: { $0.isDefault }) {
            selectedUIDs.insert(def.uid)
        }

        if isActive {
            let connectedSelected = devices.filter { selectedUIDs.contains($0.uid) }
            if connectedSelected.count < 2 {
                statusMessage = "A paired device disconnected — PairPlay stopped."
                stopPairPlay()
            }
        }
    }

    func toggleDeviceSelection(_ device: AudioOutputDevice) {
        if selectedUIDs.contains(device.uid) {
            if isActive && selectedUIDs.count <= 2 {
                statusMessage = "Keep at least 2 devices active, or stop PairPlay."
                return
            }
            selectedUIDs.remove(device.uid)
        } else {
            selectedUIDs.insert(device.uid)
            if deviceVolumes[device.uid] == nil {
                deviceVolumes[device.uid] = readHardwareVolume(deviceID: device.id) ?? 0.75
            }
        }
        statusMessage = nil
        if isActive {
            rebuildActiveSession()
        }
    }

    private func requiresDSPEngine(for uids: Set<String>) -> Bool {
        for uid in uids {
            if (deviceDelayMs[uid] ?? 0) > 0 { return true }
            if (deviceChannelModes[uid] ?? .stereo) != .stereo { return true }
            if (deviceEQPresets[uid] ?? .flat) != .flat { return true }
        }
        return false
    }

    func setDeviceVolume(uid: String, volume: Float) {
        let clamped = max(0, min(1, volume))
        deviceVolumes[uid] = clamped
        if clamped > 0.001 && (deviceMuted[uid] == true) {
            deviceMuted[uid] = false
        }

        if let dev = systemAudio?.outputDevices.first(where: { $0.uid == uid }), !usingDelayDSPEngine {
            setHardwareVolume(deviceID: dev.id, volume: clamped)
            setHardwareMute(deviceID: dev.id, muted: deviceMuted[uid] ?? false)
        }

        pushBufferParams(for: uid)
    }

    func toggleDeviceMute(uid: String) {
        let newMuted = !(deviceMuted[uid] ?? false)
        deviceMuted[uid] = newMuted

        if let dev = systemAudio?.outputDevices.first(where: { $0.uid == uid }), !usingDelayDSPEngine {
            setHardwareMute(deviceID: dev.id, muted: newMuted)
        }

        pushBufferParams(for: uid)
    }

    func setDeviceDelay(uid: String, delayMs: Int) {
        let clamped = max(0, min(400, delayMs))
        guard (deviceDelayMs[uid] ?? 0) != clamped else { return }
        deviceDelayMs[uid] = clamped
        guard isActive else { return }

        let needsDSP = requiresDSPEngine(for: selectedUIDs)
        if needsDSP != usingDelayDSPEngine {
            rebuildActiveSession()
        } else {
            pushBufferParams(for: uid)
        }
    }

    func setDeviceChannelMode(uid: String, mode: PairPlayChannelMode) {
        guard (deviceChannelModes[uid] ?? .stereo) != mode else { return }
        deviceChannelModes[uid] = mode
        guard isActive else { return }

        let needsDSP = requiresDSPEngine(for: selectedUIDs)
        if needsDSP != usingDelayDSPEngine {
            rebuildActiveSession()
        } else {
            pushBufferParams(for: uid)
        }
    }

    func setDeviceEQPreset(uid: String, preset: PairPlayEQPreset) {
        guard (deviceEQPresets[uid] ?? .flat) != preset else { return }
        deviceEQPresets[uid] = preset
        guard isActive else { return }

        let needsDSP = requiresDSPEngine(for: selectedUIDs)
        if needsDSP != usingDelayDSPEngine {
            rebuildActiveSession()
        } else {
            stateLock.lock()
            let out = delayedOutputs[uid]
            stateLock.unlock()
            out?.applyEQ(preset)
        }
    }

    private func pushBufferParams(for uid: String) {
        stateLock.lock()
        if let out = delayedOutputs[uid] {
            out.ringBuffer.updateParameters(
                delayMs: deviceDelayMs[uid] ?? 0,
                gain: deviceVolumes[uid] ?? 0.75,
                muted: deviceMuted[uid] ?? false,
                channelMode: deviceChannelModes[uid] ?? .stereo
            )
        }
        stateLock.unlock()
    }

    func applyMasterVolume(_ masterVolume: Float) {
        guard isActive else { return }
        let clamped = max(0, min(1, masterVolume))
        for uid in selectedUIDs {
            setDeviceVolume(uid: uid, volume: clamped)
        }
    }

    func applyMasterMute(_ muted: Bool) {
        guard isActive else { return }
        for uid in selectedUIDs {
            deviceMuted[uid] = muted
            if let dev = systemAudio?.outputDevices.first(where: { $0.uid == uid }), !usingDelayDSPEngine {
                setHardwareMute(deviceID: dev.id, muted: muted)
            }
            pushBufferParams(for: uid)
        }
    }

    // MARK: - Rhythmic Sync Click Metronome (Align Bluetooth Latency by Ear)

    func toggleSyncTest() {
        if isSyncTestPlaying {
            stopSyncTest()
        } else {
            startSyncTest()
        }
    }

    func startSyncTest() {
        stopSyncTest()
        if clickPlayer == nil {
            clickPlayer = buildPercussiveClickPlayer()
        }
        isSyncTestPlaying = true
        playSingleSyncClick()

        syncClickTimer = Timer.scheduledTimer(withTimeInterval: 0.75, repeats: true) { [weak self] _ in
            self?.playSingleSyncClick()
        }

        let stopWork = DispatchWorkItem { [weak self] in
            self?.stopSyncTest()
        }
        syncAutoStopWork = stopWork
        DispatchQueue.main.asyncAfter(deadline: .now() + 30.0, execute: stopWork)
    }

    func stopSyncTest() {
        syncClickTimer?.invalidate()
        syncClickTimer = nil
        syncAutoStopWork?.cancel()
        syncAutoStopWork = nil
        clickPlayer?.stop()
        if isSyncTestPlaying {
            isSyncTestPlaying = false
        }
    }

    private func playSingleSyncClick() {
        clickPlayer?.currentTime = 0
        clickPlayer?.play()
    }

    /// Synthesizes a short, crisp 1000 Hz percussive woodblock tick in memory (WAV) for accurate ear-sync calibration.
    private func buildPercussiveClickPlayer() -> AVAudioPlayer? {
        let sampleRate = 48000
        let durationSec = 0.045
        let frameCount = Int(Double(sampleRate) * durationSec)
        var pcm = [Int16](repeating: 0, count: frameCount * 2)

        for i in 0..<frameCount {
            let t = Double(i) / Double(sampleRate)
            let env = exp(-t * 95.0)
            let wave = sin(2.0 * .pi * 1050.0 * t) + 0.4 * sin(2.0 * .pi * 2100.0 * t)
            let val = max(-1.0, min(1.0, wave * env * 0.65))
            let s16 = Int16(val * Double(Int16.max))
            pcm[i * 2] = s16
            pcm[i * 2 + 1] = s16
        }

        let dataBytes = pcm.count * 2
        var wav = Data()
        func appendU32(_ v: UInt32) { var le = v.littleEndian; wav.append(Data(bytes: &le, count: 4)) }
        func appendU16(_ v: UInt16) { var le = v.littleEndian; wav.append(Data(bytes: &le, count: 2)) }

        wav.append("RIFF".data(using: .ascii)!)
        appendU32(UInt32(36 + dataBytes))
        wav.append("WAVEfmt ".data(using: .ascii)!)
        appendU32(16)
        appendU16(1) // PCM
        appendU16(2) // Stereo
        appendU32(UInt32(sampleRate))
        appendU32(UInt32(sampleRate * 4))
        appendU16(4)
        appendU16(16)
        wav.append("data".data(using: .ascii)!)
        appendU32(UInt32(dataBytes))
        pcm.withUnsafeBytes { wav.append(contentsOf: $0) }

        let player = try? AVAudioPlayer(data: wav)
        player?.prepareToPlay()
        return player
    }

    // MARK: - Start / Stop PairPlay

    func togglePairPlay() {
        if isActive {
            stopPairPlay()
        } else {
            startPairPlay()
        }
    }

    func startPairPlay() {
        guard let systemAudio else { return }
        systemAudio.refreshAll()
        let devices = pairableDevices(from: systemAudio.outputDevices)
        let chosen = devices.filter { selectedUIDs.contains($0.uid) }

        guard chosen.count >= 2 else {
            statusMessage = "Select at least 2 headphones or speakers to start PairPlay."
            return
        }

        if previousDefaultOutputUID == nil {
            let currentDefID = systemAudio.fetchDefaultOutputDeviceID()
            if let currentUID = getDeviceUID(currentDefID), !currentUID.hasPrefix(Self.aggregateUIDPrefix) {
                previousDefaultOutputUID = currentUID
            } else {
                previousDefaultOutputUID = chosen.first?.uid
            }
        }

        statusMessage = nil
        if activateEngine(for: chosen) {
            isActive = true
            isPairPlayViewMode = true
            systemAudio.refreshAll()
        }
    }

    func stopPairPlay() {
        stopSyncTest()
        let wasActive = isActive || stackedAggregateID != kAudioObjectUnknown || usingDelayDSPEngine
        teardownEngines()
        isActive = false

        if wasActive {
            restorePreviousDefaultOutput()
            systemAudio?.refreshAll()
        }
        previousDefaultOutputUID = nil
    }

    func pairableDevices(from devices: [AudioOutputDevice]) -> [AudioOutputDevice] {
        devices.filter { dev in
            let lower = dev.name.lowercased()
            if dev.uid.hasPrefix(Self.aggregateUIDPrefix) || dev.name.hasPrefix(Self.aggregateNamePrefix) {
                return false
            }
            if lower.contains("blackhole") || lower.contains("camo microphone") {
                return false
            }
            return true
        }
    }

    // MARK: - Internal Engine Management

    private func rebuildActiveSession() {
        guard let systemAudio else { return }
        let chosen = pairableDevices(from: systemAudio.outputDevices).filter { selectedUIDs.contains($0.uid) }
        guard chosen.count >= 2 else {
            stopPairPlay()
            return
        }
        teardownEngines()
        if let first = chosen.first {
            setSystemDefaultOutput(deviceID: first.id)
        }
        if activateEngine(for: chosen) {
            isActive = true
            systemAudio.refreshAll()
        } else {
            isActive = false
            restorePreviousDefaultOutput()
        }
    }

    private func activateEngine(for devices: [AudioOutputDevice]) -> Bool {
        let chosenUIDs = Set(devices.map { $0.uid })
        if requiresDSPEngine(for: chosenUIDs) {
            if startSyncDelayEngine(for: devices) {
                usingDelayDSPEngine = true
                return true
            } else {
                statusMessage = "DSP mode requires macOS 14.2+ (Audio Capture permission) or BlackHole — using zero-delay PairPlay."
            }
        }
        usingDelayDSPEngine = false
        return startStackedAggregateEngine(for: devices)
    }

    private func startStackedAggregateEngine(for devices: [AudioOutputDevice]) -> Bool {
        cleanupOrphanedPairPlayDevices()
        guard let primary = devices.first else { return false }

        var subDevices: [[String: Any]] = []
        for (idx, dev) in devices.enumerated() {
            if idx == 0 {
                subDevices.append([
                    kAudioSubDeviceUIDKey as String: dev.uid
                ])
            } else {
                subDevices.append([
                    kAudioSubDeviceUIDKey as String: dev.uid,
                    kAudioSubDeviceDriftCompensationKey as String: 1
                ])
            }
        }

        let aggUID = "\(Self.aggregateUIDPrefix).\(UUID().uuidString)"
        let desc: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: Self.aggregateNamePrefix,
            kAudioAggregateDeviceUIDKey as String: aggUID,
            kAudioAggregateDeviceMainSubDeviceKey as String: primary.uid,
            kAudioAggregateDeviceIsPrivateKey as String: 0,
            kAudioAggregateDeviceIsStackedKey as String: 1,
            kAudioAggregateDeviceSubDeviceListKey as String: subDevices
        ]

        var aggID: AudioObjectID = kAudioObjectUnknown
        let status = AudioHardwareCreateAggregateDevice(desc as CFDictionary, &aggID)
        guard status == noErr, aggID != kAudioObjectUnknown else {
            statusMessage = "Failed to create Multi-Output device (\(status))."
            return false
        }

        stackedAggregateID = aggID
        setSystemDefaultOutput(deviceID: aggID)

        for dev in devices {
            let vol = deviceVolumes[dev.uid] ?? 0.75
            let muted = deviceMuted[dev.uid] ?? false
            setHardwareVolume(deviceID: dev.id, volume: vol)
            setHardwareMute(deviceID: dev.id, muted: muted)
        }
        return true
    }

    private func startSyncDelayEngine(for devices: [AudioOutputDevice]) -> Bool {
        var builtOutputs: [String: DelayedDeviceOutput] = [:]
        for dev in devices {
            let vol = deviceVolumes[dev.uid] ?? 0.75
            let muted = deviceMuted[dev.uid] ?? false
            let delay = deviceDelayMs[dev.uid] ?? 0
            let chMode = deviceChannelModes[dev.uid] ?? .stereo
            let eq = deviceEQPresets[dev.uid] ?? .flat
            setHardwareMute(deviceID: dev.id, muted: false)
            if let out = DelayedDeviceOutput(
                deviceID: dev.id,
                uid: dev.uid,
                delayMs: delay,
                gain: vol,
                muted: muted,
                channelMode: chMode,
                eqPreset: eq
            ) {
                builtOutputs[dev.uid] = out
            }
        }

        guard builtOutputs.count >= 2 else {
            for out in builtOutputs.values { out.stop() }
            return false
        }

        stateLock.lock()
        delayedOutputs = builtOutputs
        stateLock.unlock()

        if #available(macOS 14.2, *) {
            if startGlobalTapCapture() {
                return true
            }
        }

        if startBlackHoleFallbackCapture() {
            return true
        }

        teardownEngines()
        return false
    }

    @available(macOS 14.2, *)
    private func startGlobalTapCapture() -> Bool {
        guard let primaryUID = previousDefaultOutputUID ?? selectedUIDs.first else { return false }
        if let primaryID = findDeviceID(byUID: primaryUID) {
            setSystemDefaultOutput(deviceID: primaryID)
        }

        let ownExcluded = fetchOwnProcessObjectIDs()
        let tapDesc = CATapDescription(stereoGlobalTapButExcludeProcesses: ownExcluded)
        tapDesc.name = "NotchPulse-PairPlay-Tap"
        tapDesc.isPrivate = true
        tapDesc.muteBehavior = .mutedWhenTapped

        var tapID: AudioObjectID = kAudioObjectUnknown
        guard AudioHardwareCreateProcessTap(tapDesc, &tapID) == noErr, tapID != kAudioObjectUnknown else {
            return false
        }
        self.globalTapID = tapID

        let aggUID = "\(Self.aggregateUIDPrefix).tap.\(UUID().uuidString)"
        let desc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "NotchPulse-PairPlay-TapAgg",
            kAudioAggregateDeviceUIDKey: aggUID,
            kAudioAggregateDeviceMainSubDeviceKey: primaryUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: primaryUID]
            ],
            kAudioAggregateDeviceTapListKey: [
                [
                    kAudioSubTapDriftCompensationKey: true,
                    kAudioSubTapUIDKey: tapDesc.uuid.uuidString
                ]
            ]
        ]

        var aggID: AudioObjectID = kAudioObjectUnknown
        guard AudioHardwareCreateAggregateDevice(desc as CFDictionary, &aggID) == noErr,
              aggID != kAudioObjectUnknown else {
            AudioHardwareDestroyProcessTap(tapID)
            self.globalTapID = kAudioObjectUnknown
            return false
        }
        self.globalTapAggregateID = aggID

        let tapSampleRate = readNominalSampleRate(deviceID: aggID) ?? 48000.0

        var procID: AudioDeviceIOProcID?
        let ioStatus = AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, nil) { [weak self] _, inInputData, _, outOutputData, _ in
            guard let self else { return }
            let outList = UnsafeMutableAudioBufferListPointer(outOutputData)
            for i in 0..<outList.count {
                if let outPtr = outList[i].mData {
                    memset(outPtr, 0, Int(outList[i].mDataByteSize))
                }
            }

            let inList = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInputData))
            guard inList.count > 0 else { return }

            if inList.count >= 2,
               let lPtr = inList[0].mData?.assumingMemoryBound(to: Float.self),
               let rPtr = inList[1].mData?.assumingMemoryBound(to: Float.self) {
                let frames = Int(inList[0].mDataByteSize) / MemoryLayout<Float>.size
                self.broadcastSamples(left: lPtr, right: rPtr, frameCount: frames, sampleRate: tapSampleRate)
            } else if let interleaved = inList[0].mData?.assumingMemoryBound(to: Float.self) {
                let ch = max(1, Int(inList[0].mNumberChannels))
                let totalFloats = Int(inList[0].mDataByteSize) / MemoryLayout<Float>.size
                let frames = totalFloats / ch
                guard frames > 0 else { return }
                var left = [Float](repeating: 0, count: frames)
                var right = [Float](repeating: 0, count: frames)
                if ch >= 2 {
                    for f in 0..<frames {
                        left[f] = interleaved[f * ch]
                        right[f] = interleaved[f * ch + 1]
                    }
                } else {
                    for f in 0..<frames {
                        left[f] = interleaved[f]
                        right[f] = interleaved[f]
                    }
                }
                left.withUnsafeBufferPointer { lBuf in
                    right.withUnsafeBufferPointer { rBuf in
                        if let lBase = lBuf.baseAddress, let rBase = rBuf.baseAddress {
                            self.broadcastSamples(left: lBase, right: rBase, frameCount: frames, sampleRate: tapSampleRate)
                        }
                    }
                }
            }
        }

        guard ioStatus == noErr, let validProcID = procID,
              AudioDeviceStart(aggID, validProcID) == noErr else {
            if let procID { AudioDeviceDestroyIOProcID(aggID, procID) }
            AudioHardwareDestroyAggregateDevice(aggID)
            AudioHardwareDestroyProcessTap(tapID)
            globalTapAggregateID = kAudioObjectUnknown
            globalTapID = kAudioObjectUnknown
            return false
        }

        globalTapIOProcID = validProcID
        return true
    }

    private func startBlackHoleFallbackCapture() -> Bool {
        guard let bhID = findBlackHoleDeviceID() else { return false }
        setSystemDefaultOutput(deviceID: bhID)

        let capEngine = AVAudioEngine()
        let inputNode = capEngine.inputNode
        guard let au = inputNode.audioUnit else { return false }
        var devID = bhID
        guard AudioUnitSetProperty(
            au,
            kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global,
            0,
            &devID,
            UInt32(MemoryLayout<AudioDeviceID>.size)
        ) == noErr else { return false }

        let fmt = inputNode.inputFormat(forBus: 0)
        guard fmt.sampleRate > 0, fmt.channelCount > 0 else { return false }

        inputNode.installTap(onBus: 0, bufferSize: 512, format: fmt) { [weak self] buffer, _ in
            guard let self, let chData = buffer.floatChannelData else { return }
            let frames = Int(buffer.frameLength)
            let lPtr = chData[0]
            let rPtr = fmt.channelCount >= 2 ? chData[1] : chData[0]
            self.broadcastSamples(left: lPtr, right: rPtr, frameCount: frames, sampleRate: fmt.sampleRate)
        }

        do {
            try capEngine.start()
            blackHoleCaptureEngine = capEngine
            return true
        } catch {
            inputNode.removeTap(onBus: 0)
            return false
        }
    }

    private func broadcastSamples(left: UnsafePointer<Float>, right: UnsafePointer<Float>, frameCount: Int, sampleRate: Double) {
        stateLock.lock()
        let outputs = Array(delayedOutputs.values)
        stateLock.unlock()
        for out in outputs {
            out.ringBuffer.write(leftSrc: left, rightSrc: right, frameCount: frameCount, sampleRate: sampleRate)
        }
    }

    private func teardownEngines() {
        if let bh = blackHoleCaptureEngine {
            bh.inputNode.removeTap(onBus: 0)
            bh.stop()
            blackHoleCaptureEngine = nil
        }

        if globalTapAggregateID != kAudioObjectUnknown {
            if let procID = globalTapIOProcID {
                AudioDeviceStop(globalTapAggregateID, procID)
                AudioDeviceDestroyIOProcID(globalTapAggregateID, procID)
                globalTapIOProcID = nil
            }
            AudioHardwareDestroyAggregateDevice(globalTapAggregateID)
            globalTapAggregateID = kAudioObjectUnknown
        }

        if globalTapID != kAudioObjectUnknown {
            if #available(macOS 14.2, *) {
                AudioHardwareDestroyProcessTap(globalTapID)
            }
            globalTapID = kAudioObjectUnknown
        }

        stateLock.lock()
        let currentOutputs = Array(delayedOutputs.values)
        delayedOutputs.removeAll()
        stateLock.unlock()
        for out in currentOutputs {
            out.stop()
        }

        if stackedAggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(stackedAggregateID)
            stackedAggregateID = kAudioObjectUnknown
        }
        usingDelayDSPEngine = false
    }

    private func restorePreviousDefaultOutput() {
        if let prevUID = previousDefaultOutputUID, let prevID = findDeviceID(byUID: prevUID) {
            setSystemDefaultOutput(deviceID: prevID)
            return
        }
        for id in allAudioDeviceIDs() {
            let uid = getDeviceUID(id) ?? ""
            let name = getDeviceName(id) ?? ""
            if uid.hasPrefix(Self.aggregateUIDPrefix) || uid.hasPrefix("com.overlay.tap.") { continue }
            if name.lowercased().contains("blackhole") { continue }
            if hasOutputChannels(id) {
                setSystemDefaultOutput(deviceID: id)
                return
            }
        }
    }

    private func cleanupOrphanedPairPlayDevices() {
        let currentDef = fetchDefaultOutputID()
        var destroyedDefault = false

        for id in allAudioDeviceIDs() {
            let uid = getDeviceUID(id) ?? ""
            let name = getDeviceName(id) ?? ""
            if uid.hasPrefix(Self.aggregateUIDPrefix) || name.hasPrefix(Self.aggregateNamePrefix) {
                if id == currentDef { destroyedDefault = true }
                AudioHardwareDestroyAggregateDevice(id)
            }
        }

        if destroyedDefault {
            restorePreviousDefaultOutput()
        }
    }

    // MARK: - Low-Level CoreAudio Helpers

    private func setSystemDefaultOutput(deviceID: AudioDeviceID) {
        var devID = deviceID
        for selector in [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultSystemOutputDevice] {
            var addr = AudioObjectPropertyAddress(
                mSelector: selector,
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

    private func fetchDefaultOutputID() -> AudioDeviceID {
        var devID: AudioDeviceID = kAudioObjectUnknown
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &devID)
        return devID
    }

    private func allAudioDeviceIDs() -> [AudioDeviceID] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr, size > 0 else {
            return []
        }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &ids) == noErr else {
            return []
        }
        return ids
    }

    private func findDeviceID(byUID targetUID: String) -> AudioDeviceID? {
        allAudioDeviceIDs().first { getDeviceUID($0) == targetUID }
    }

    private func findBlackHoleDeviceID() -> AudioDeviceID? {
        allAudioDeviceIDs().first { id in
            let name = (getDeviceName(id) ?? "").lowercased()
            return name.contains("blackhole") && hasOutputChannels(id)
        }
    }

    @available(macOS 14.2, *)
    private func fetchOwnProcessObjectIDs() -> [AudioObjectID] {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size) == noErr, size > 0 else {
            return []
        }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        var procIDs = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &procIDs) == noErr else {
            return []
        }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        var matches: [AudioObjectID] = []
        for objID in procIDs {
            var pidAddr = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyPID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var pid: pid_t = 0
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            if AudioObjectGetPropertyData(objID, &pidAddr, 0, nil, &pidSize, &pid) == noErr, pid == ownPID {
                matches.append(objID)
            }
        }
        return matches
    }

    private func readNominalSampleRate(deviceID: AudioDeviceID) -> Double? {
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &rate) == noErr, rate > 0 else {
            return nil
        }
        return rate
    }

    private func getDeviceUID(_ id: AudioDeviceID) -> String? {
        getStringProperty(id, selector: kAudioDevicePropertyDeviceUID)
    }

    private func getDeviceName(_ id: AudioDeviceID) -> String? {
        getStringProperty(id, selector: kAudioObjectPropertyName)
    }

    private func getStringProperty(_ id: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var cfStr: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &cfStr) == noErr,
              let val = cfStr?.takeRetainedValue() else { return nil }
        return val as String
    }

    private func hasOutputChannels(_ deviceID: AudioDeviceID) -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(deviceID, &addr, 0, nil, &size) == noErr, size > 0 else { return false }
        let ptr = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { ptr.deallocate() }
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, ptr) == noErr else { return false }
        let abl = UnsafeMutableAudioBufferListPointer(ptr.assumingMemoryBound(to: AudioBufferList.self))
        return abl.reduce(0) { $0 + Int($1.mNumberChannels) } > 0
    }

    private func readHardwareVolume(deviceID: AudioDeviceID) -> Float? {
        var vol: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectHasProperty(deviceID, &addr),
           AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &vol) == noErr {
            return vol
        }
        for ch: UInt32 in [1, 2, 0] {
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
        return nil
    }

    private func setHardwareVolume(deviceID: AudioDeviceID, volume: Float) {
        var vol = max(0, min(1, volume))
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectHasProperty(deviceID, &addr) {
            AudioObjectSetPropertyData(deviceID, &addr, 0, nil, UInt32(MemoryLayout<Float32>.size), &vol)
            return
        }
        for ch: UInt32 in [0, 1, 2] {
            var chAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyVolumeScalar,
                mScope: kAudioDevicePropertyScopeOutput,
                mElement: ch
            )
            if AudioObjectHasProperty(deviceID, &chAddr) {
                AudioObjectSetPropertyData(deviceID, &chAddr, 0, nil, UInt32(MemoryLayout<Float32>.size), &vol)
            }
        }
    }

    private func readHardwareMute(deviceID: AudioDeviceID) -> Bool {
        var muted: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectHasProperty(deviceID, &addr),
           AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, &muted) == noErr {
            return muted != 0
        }
        return false
    }

    private func setHardwareMute(deviceID: AudioDeviceID, muted: Bool) {
        var val: UInt32 = muted ? 1 : 0
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain
        )
        if AudioObjectHasProperty(deviceID, &addr) {
            AudioObjectSetPropertyData(deviceID, &addr, 0, nil, UInt32(MemoryLayout<UInt32>.size), &val)
        }
    }
}
