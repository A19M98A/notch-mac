import SwiftUI

struct MixerTabView: View {
    @EnvironmentObject var systemAudio: SystemAudioManager
    @EnvironmentObject var perAppMixer: PerAppAudioMixer

    var body: some View {
        VStack(spacing: 10) {
            // Master Volume Row
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 7)
                        .fill(Color.blue.opacity(0.22))
                    Image(systemName: systemAudio.isMuted ? "speaker.slash.fill" : "speaker.wave.3.fill")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(systemAudio.isMuted ? .red : .blue)
                }
                .frame(width: 26, height: 26)

                Text("Master")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 82, alignment: .leading)

                Slider(
                    value: Binding(
                        get: { Double(systemAudio.isMuted ? 0 : systemAudio.volume) },
                        set: { systemAudio.setVolume(Float($0)) }
                    ),
                    in: 0...1
                )
                .tint(.blue)

                Text("\(Int(round((systemAudio.isMuted ? 0 : systemAudio.volume) * 100)))%")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.8))
                    .frame(width: 34, alignment: .trailing)

                Button {
                    systemAudio.toggleMute()
                } label: {
                    Image(systemName: systemAudio.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(systemAudio.isMuted ? .red : .white.opacity(0.7))
                        .frame(width: 22, height: 22)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.white.opacity(0.08))
            )

            // Permission Banner if needed
            if let errorMsg = perAppMixer.permissionError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                        .font(.system(size: 12))
                    Text(errorMsg)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(2)
                    Spacer()
                    Button("Settings") {
                        perAppMixer.openAudioPermissionSettings()
                    }
                    .font(.system(size: 10, weight: .bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.yellow.opacity(0.25)))
                    .foregroundStyle(.yellow)
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.yellow.opacity(0.12)))
            }

            // Per-App Audio Sources List
            if !perAppMixer.supportsPerAppMixing {
                VStack(spacing: 6) {
                    Image(systemName: "slider.vertical.3")
                        .font(.system(size: 18))
                        .foregroundStyle(.white.opacity(0.45))
                    Text("Per-app volume mixing requires macOS 14.2+")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                    Text("Master volume above and all other Overlay features work on macOS 12 Monterey.")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.45))
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if perAppMixer.apps.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "waveform.slash")
                        .font(.system(size: 20))
                        .foregroundStyle(.white.opacity(0.4))
                    Text("No active audio apps detected")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                    Text("Play audio in Chrome, Spotify, Music, or Discord to mix individually.")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.4))
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 6) {
                        ForEach(perAppMixer.apps) { app in
                            HStack(spacing: 10) {
                                Image(nsImage: app.icon)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(width: 24, height: 24)
                                    .clipShape(RoundedRectangle(cornerRadius: 5))

                                VStack(alignment: .leading, spacing: 1) {
                                    HStack(spacing: 4) {
                                        Text(app.name)
                                            .font(.system(size: 12, weight: .semibold))
                                            .foregroundStyle(.white)
                                            .lineLimit(1)
                                        if app.isRunningOutput {
                                            Circle()
                                                .fill(Color.green)
                                                .frame(width: 5, height: 5)
                                        }
                                    }
                                    if app.tapActive {
                                        Text("Mixed")
                                            .font(.system(size: 9, weight: .medium))
                                            .foregroundStyle(.green.opacity(0.85))
                                    }
                                }
                                .frame(width: 84, alignment: .leading)

                                Slider(
                                    value: Binding(
                                        get: { Double(app.isMuted ? 0 : app.volume) },
                                        set: { perAppMixer.setVolume(for: app.id, volume: Float($0)) }
                                    ),
                                    in: 0...1
                                )
                                .tint(app.isRunningOutput ? .green : .white.opacity(0.7))

                                Text("\(Int(round((app.isMuted ? 0 : app.volume) * 100)))%")
                                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                                    .foregroundStyle(.white.opacity(0.75))
                                    .frame(width: 34, alignment: .trailing)

                                Button {
                                    perAppMixer.toggleMute(for: app.id)
                                } label: {
                                    Image(systemName: app.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                        .font(.system(size: 12))
                                        .foregroundStyle(app.isMuted ? .red : .white.opacity(0.65))
                                        .frame(width: 22, height: 22)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 9)
                                    .fill(Color.white.opacity(app.isRunningOutput ? 0.06 : 0.03))
                            )
                        }
                    }
                }
            }
        }
    }
}
