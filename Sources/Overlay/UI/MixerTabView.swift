import SwiftUI

struct MixerTabView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var systemAudio: SystemAudioManager
    @EnvironmentObject var pairPlay: PairPlayService
    @EnvironmentObject var perAppMixer: PerAppAudioMixer

    private var routableDevices: [AudioOutputDevice] {
        pairPlay.pairableDevices(from: systemAudio.outputDevices)
    }

    var body: some View {
        VStack(spacing: 8) {
            // Master Volume Row + PairPlay Studio Shortcut
            HStack(spacing: 8) {
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
                    .frame(width: 52, alignment: .leading)

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
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)

                Button {
                    PairPlayWindowController.show(appState: appState)
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "person.2.wave.2.fill")
                            .font(.system(size: 9.5, weight: .bold))
                        Text("PairPlay")
                            .font(.system(size: 10, weight: .bold))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(pairPlay.isActive ? Color.green.opacity(0.24) : Color.cyan.opacity(0.18)))
                    .foregroundStyle(pairPlay.isActive ? .green : .cyan)
                }
                .buttonStyle(.plain)
                .help("Open PairPlay Audio Studio")
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

            // Per-App Audio Sources List (Volume + Output Device Route + Spatial Ear Mode)
            if !perAppMixer.supportsPerAppMixing {
                VStack(spacing: 6) {
                    Image(systemName: "slider.vertical.3")
                        .font(.system(size: 18))
                        .foregroundStyle(.white.opacity(0.45))
                    Text("Per-app volume & routing requires macOS 14.2+")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
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
                    Text("Play audio in Chrome, Spotify, Music, or Discord to mix & route individually.")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.4))
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 6) {
                        ForEach(perAppMixer.apps) { app in
                            appRow(app)
                        }
                    }
                }
            }
        }
    }

    private func appRow(_ app: AudioAppSource) -> some View {
        let shortRoute: String = {
            guard let uid = app.targetDeviceUID else { return "Default" }
            let full = systemAudio.outputDevices.first(where: { $0.uid == uid })?.name ?? "Custom"
            return full.count > 11 ? String(full.prefix(10)) + "…" : full
        }()

        return HStack(spacing: 8) {
            Image(nsImage: app.icon)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 22, height: 22)
                .clipShape(RoundedRectangle(cornerRadius: 5))

            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(app.name)
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    if app.isRunningOutput {
                        Circle()
                            .fill(Color.green)
                            .frame(width: 5, height: 5)
                    }
                }
                if app.channelMode != .stereo {
                    Text(app.channelMode.rawValue)
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.cyan)
                }
            }
            .frame(width: 78, alignment: .leading)

            Slider(
                value: Binding(
                    get: { Double(app.isMuted ? 0 : app.volume) },
                    set: { perAppMixer.setVolume(for: app.id, volume: Float($0)) }
                ),
                in: 0...1
            )
            .tint(app.isRunningOutput ? .green : .white.opacity(0.7))
            .controlSize(.small)

            Text("\(Int(round((app.isMuted ? 0 : app.volume) * 100)))%")
                .font(.system(size: 10.5, weight: .medium, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.75))
                .frame(width: 32, alignment: .trailing)

            // Per-App Output Device & Spatial Ear Menu
            Menu {
                Section("Output Destination") {
                    Button {
                        perAppMixer.setTargetDevice(for: app.id, deviceUID: nil)
                    } label: {
                        HStack {
                            Text("System Default")
                            if app.targetDeviceUID == nil { Image(systemName: "checkmark") }
                        }
                    }
                    ForEach(routableDevices) { dev in
                        Button {
                            perAppMixer.setTargetDevice(for: app.id, deviceUID: dev.uid)
                        } label: {
                            HStack {
                                Text(dev.name)
                                if app.targetDeviceUID == dev.uid { Image(systemName: "checkmark") }
                            }
                        }
                    }
                }
                Divider()
                Section("Spatial Ear / Channel") {
                    ForEach(PairPlayChannelMode.allCases) { mode in
                        Button {
                            perAppMixer.setChannelMode(for: app.id, mode: mode)
                        } label: {
                            HStack {
                                Text(mode.rawValue)
                                if app.channelMode == mode { Image(systemName: "checkmark") }
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: app.targetDeviceUID != nil ? "hifispeaker.fill" : "speaker.wave.2")
                        .font(.system(size: 9))
                    Text(shortRoute)
                        .font(.system(size: 9.5, weight: .semibold))
                        .lineLimit(1)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 3)
                .background(
                    Capsule().fill(
                        (app.targetDeviceUID != nil || app.channelMode != .stereo)
                            ? Color.cyan.opacity(0.20)
                            : Color.white.opacity(0.08)
                    )
                )
                .foregroundStyle(
                    (app.targetDeviceUID != nil || app.channelMode != .stereo) ? .cyan : .white.opacity(0.7)
                )
            }
            .menuStyle(.borderlessButton)
            .fixedSize()

            Button {
                perAppMixer.toggleMute(for: app.id)
            } label: {
                Image(systemName: app.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 11.5))
                    .foregroundStyle(app.isMuted ? .red : .white.opacity(0.65))
                    .frame(width: 20, height: 20)
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
