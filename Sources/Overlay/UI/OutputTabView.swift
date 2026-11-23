import SwiftUI

struct OutputTabView: View {
    @EnvironmentObject var systemAudio: SystemAudioManager

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Audio Output Devices")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
                Spacer()
                Button {
                    systemAudio.refreshAll()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.6))
                }
                .buttonStyle(.plain)
            }

            if systemAudio.outputDevices.isEmpty {
                Text("No output devices found")
                    .font(.system(size: 12))
                    .foregroundStyle(.white.opacity(0.5))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 6) {
                        ForEach(systemAudio.outputDevices) { device in
                            Button {
                                systemAudio.setDefaultOutputDevice(device.id)
                            } label: {
                                HStack(spacing: 12) {
                                    ZStack {
                                        Circle()
                                            .fill(device.isDefault ? Color.blue.opacity(0.25) : Color.white.opacity(0.08))
                                        Image(systemName: device.sfSymbol)
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundStyle(device.isDefault ? .blue : .white.opacity(0.75))
                                    }
                                    .frame(width: 30, height: 30)

                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(device.name)
                                            .font(.system(size: 13, weight: .semibold))
                                            .foregroundStyle(.white)
                                            .lineLimit(1)
                                        if device.isDefault {
                                            Text("Active Output")
                                                .font(.system(size: 10, weight: .medium))
                                                .foregroundStyle(.blue)
                                        }
                                    }

                                    Spacer()

                                    if device.isDefault {
                                        Image(systemName: "checkmark.circle.fill")
                                            .font(.system(size: 15))
                                            .foregroundStyle(.blue)
                                    }
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 7)
                                .background(
                                    RoundedRectangle(cornerRadius: 10)
                                        .fill(device.isDefault ? Color.blue.opacity(0.12) : Color.white.opacity(0.05))
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
        }
    }
}
