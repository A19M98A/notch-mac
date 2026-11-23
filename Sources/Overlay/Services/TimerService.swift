import Foundation
import AppKit
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

    let presets: [TimerPreset] = [
        TimerPreset(label: "5m Break", minutes: 5, isBreak: true),
        TimerPreset(label: "10m", minutes: 10, isBreak: false),
        TimerPreset(label: "15m", minutes: 15, isBreak: false),
        TimerPreset(label: "25m Focus", minutes: 25, isBreak: false),
        TimerPreset(label: "45m Deep", minutes: 45, isBreak: false)
    ]

    private var timer: Timer?

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
        remainingSeconds = totalSeconds
        finishedFlash = false
    }

    private func finish() {
        pause()
        finishedFlash = true
        NSSound(named: "Glass")?.play()
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            self?.finishedFlash = false
        }
    }
}
