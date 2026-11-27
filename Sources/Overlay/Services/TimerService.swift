import Foundation
import AppKit
import AVFoundation
import Combine

struct TimerPreset: Identifiable {
    let id = UUID()
    let label: String
    let minutes: Int
    let isBreak: Bool
}

final class TimerService: ObservableObject {
    @Published var totalSeconds: Int = 25 * 60
    @Published var remainingSeconds: Int = 25 * 60
    @Published var isRunning: Bool = false
    @Published var label: String = "Pomodoro"
    @Published var finishedFlash: Bool = false
    @Published var isAlarmRinging: Bool = false

    let presets: [TimerPreset] = [
        TimerPreset(label: "5m Break", minutes: 5, isBreak: true),
        TimerPreset(label: "10m", minutes: 10, isBreak: false),
        TimerPreset(label: "15m", minutes: 15, isBreak: false),
        TimerPreset(label: "25m Focus", minutes: 25, isBreak: false),
        TimerPreset(label: "45m Deep", minutes: 45, isBreak: false)
    ]

    private var timer: Timer?
    private var chimeTimer: Timer?
    private var alarmPlayer: AVAudioPlayer?

    var progress: Double {
        guard totalSeconds > 0 else { return 0 }
        return 1.0 - (Double(remainingSeconds) / Double(totalSeconds))
    }

    var formattedRemaining: String {
        let mins = remainingSeconds / 60
        let secs = remainingSeconds % 60
        return String(format: "%02d:%02d", mins, secs)
    }

    var isActiveInNotch: Bool {
        isRunning || (remainingSeconds > 0 && remainingSeconds < totalSeconds)
    }

    func selectPreset(_ preset: TimerPreset) {
        stop()
        totalSeconds = preset.minutes * 60
        remainingSeconds = preset.minutes * 60
        label = preset.label
        finishedFlash = false
    }

    func adjustMinutes(_ delta: Int) {
        let newTotal = max(60, min(180 * 60, totalSeconds + delta * 60))
        totalSeconds = newTotal
        if !isRunning {
            remainingSeconds = newTotal
        } else {
            remainingSeconds = max(1, min(newTotal, remainingSeconds + delta * 60))
        }
    }

    func toggleStartPause() {
        if isRunning {
            pause()
        } else {
            start()
        }
    }

    func start() {
        if remainingSeconds <= 0 {
            remainingSeconds = totalSeconds
        }
        finishedFlash = false
        isRunning = true
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.remainingSeconds > 1 {
                self.remainingSeconds -= 1
            } else {
                self.remainingSeconds = 0
                self.finish()
            }
        }
    }

    func pause() {
        isRunning = false
        timer?.invalidate()
        timer = nil
    }

    func stop() {
        pause()
        dismissAlarm()
        remainingSeconds = totalSeconds
        finishedFlash = false
    }

    func dismissAlarm() {
        isAlarmRinging = false
        finishedFlash = false
        chimeTimer?.invalidate()
        chimeTimer = nil
        alarmPlayer?.stop()
    }

    func snooze(minutes: Int = 5) {
        dismissAlarm()
        totalSeconds = minutes * 60
        remainingSeconds = minutes * 60
        label = "+\(minutes)m Snooze"
        start()
    }

    func restartTimer() {
        dismissAlarm()
        remainingSeconds = totalSeconds
        start()
    }

    private func finish() {
        pause()
        finishedFlash = true
        isAlarmRinging = true
        playNiceChime()
        chimeTimer?.invalidate()
        chimeTimer = Timer.scheduledTimer(withTimeInterval: 2.6, repeats: true) { [weak self] _ in
            guard let self, self.isAlarmRinging else { return }
            self.playNiceChime()
        }
    }

    private func playNiceChime() {
        if alarmPlayer == nil {
            alarmPlayer = Self.buildTimerChimePlayer()
        }
        alarmPlayer?.currentTime = 0
        alarmPlayer?.volume = 0.65
        alarmPlayer?.play()
    }

    private static func buildTimerChimePlayer() -> AVAudioPlayer? {
        let sampleRate = 48000
        let durationSec = 1.25
        let frameCount = Int(Double(sampleRate) * durationSec)
        var pcm = [Int16](repeating: 0, count: frameCount * 2)

        let notes: [(offset: Double, freq: Double)] = [
            (0.00, 523.25), // C5
            (0.14, 659.25), // E5
            (0.28, 783.99), // G5
            (0.42, 1046.50) // C6
        ]

        for i in 0..<frameCount {
            let t = Double(i) / Double(sampleRate)
            var mix = 0.0
            for note in notes {
                let dt = t - note.offset
                if dt > 0 {
                    let env = min(1.0, dt / 0.018) * exp(-dt * 4.5)
                    mix += (sin(2.0 * .pi * note.freq * dt) + 0.25 * sin(2.0 * .pi * (note.freq * 2.0) * dt)) * env
                }
            }
            let val = max(-1.0, min(1.0, mix * 0.25))
            let s16 = Int16(val * Double(Int16.max))
            pcm[i * 2] = s16
            pcm[i * 2 + 1] = s16
        }

        let dataBytes = pcm.count * 2
        var wav = Data()
        func u32(_ v: UInt32) { var le = v.littleEndian; wav.append(Data(bytes: &le, count: 4)) }
        func u16(_ v: UInt16) { var le = v.littleEndian; wav.append(Data(bytes: &le, count: 2)) }
        wav.append("RIFF".data(using: .ascii)!); u32(UInt32(36 + dataBytes))
        wav.append("WAVEfmt ".data(using: .ascii)!); u32(16); u16(1); u16(2)
        u32(UInt32(sampleRate)); u32(UInt32(sampleRate * 4)); u16(4); u16(16)
        wav.append("data".data(using: .ascii)!); u32(UInt32(dataBytes))
        pcm.withUnsafeBytes { wav.append(contentsOf: $0) }

        let player = try? AVAudioPlayer(data: wav)
        player?.prepareToPlay()
        return player
    }
}
