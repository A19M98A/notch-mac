import SwiftUI
import Combine

struct EqualizerView: View {
    let isPlaying: Bool
    var barCount: Int = 4
    var color: Color = .green
    var maxHeight: CGFloat = 14

    @State private var phase: Double = 0
    private let timer = Timer.publish(every: 0.16, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<barCount, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1.5)
                    .fill(color)
                    .frame(width: 2.5, height: barHeight(for: index))
                    .animation(.easeInOut(duration: 0.16), value: phase)
            }
        }
        .frame(height: maxHeight)
        .onReceive(timer) { _ in
            guard isPlaying else { return }
            phase += 1
        }
    }

    private func barHeight(for index: Int) -> CGFloat {
        guard isPlaying else { return 3 }
        let wave = abs(sin(phase * 0.9 + Double(index) * 1.15))
        return max(3, CGFloat(wave) * maxHeight)
    }
}
