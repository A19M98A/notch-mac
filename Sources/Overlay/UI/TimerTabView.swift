import SwiftUI

struct TimerTabView: View {
    @EnvironmentObject var timerService: TimerService

    var body: some View {
        VStack(spacing: 10) {
            // Presets Row
            HStack(spacing: 6) {
                ForEach(timerService.presets) { preset in
                    Button {
                        timerService.selectPreset(preset)
                    } label: {
                        Text(preset.label)
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(
                                Capsule()
                                    .fill(timerService.label == preset.label ? Color.orange.opacity(0.26) : Color.white.opacity(0.08))
                            )
                            .foregroundStyle(timerService.label == preset.label ? .orange : .white.opacity(0.75))
                    }
                    .buttonStyle(.plain)
                }
            }

            // Countdown Display + +/-1m Adjust
            HStack(spacing: 20) {
                Button {
                    timerService.adjustMinutes(-1)
                } label: {
                    Image(systemName: "minus")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Color.white.opacity(0.09)))
                }
                .buttonStyle(.plain)

                VStack(spacing: 1) {
                    Text(timerService.formattedRemaining)
                        .font(.system(size: 32, weight: .bold, design: .monospaced))
                        .foregroundStyle(timerService.finishedFlash ? .green : .white)
                    Text(timerService.finishedFlash ? "Time's up!" : timerService.label)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(timerService.finishedFlash ? .green : .white.opacity(0.55))
                }
                .frame(minWidth: 140)

                Button {
                    timerService.adjustMinutes(1)
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white.opacity(0.8))
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Color.white.opacity(0.09)))
                }
                .buttonStyle(.plain)
            }

            // Progress Bar
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.14))
                        .frame(height: 5)
                    Capsule()
                        .fill(Color.orange)
                        .frame(width: max(0, geo.size.width * CGFloat(timerService.progress)), height: 5)
                        .animation(.linear(duration: 0.4), value: timerService.progress)
                }
            }
            .frame(height: 5)
            .padding(.horizontal, 12)

            // Action Buttons
            HStack(spacing: 12) {
                Button {
                    timerService.toggleStartPause()
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: timerService.isRunning ? "pause.fill" : "play.fill")
                        Text(timerService.isRunning ? "Pause" : "Start")
                    }
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 24)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(timerService.isRunning ? Color.orange : Color.white))
                }
                .buttonStyle(.plain)

                Button {
                    timerService.stop()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.counterclockwise")
                        Text("Reset")
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Color.white.opacity(0.1)))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, 4)
    }
}
