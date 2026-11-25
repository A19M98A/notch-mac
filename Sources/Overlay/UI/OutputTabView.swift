import SwiftUI

struct OutputTabView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var systemAudio: SystemAudioManager
    @EnvironmentObject var pairPlay: PairPlayService

    private var pairableDevices: [AudioOutputDevice] {
        pairPlay.pairableDevices(from: systemAudio.outputDevices)
    }

    private var selectedConnectedCount: Int {
        pairableDevices.filter { pairPlay.selectedUIDs.contains($0.uid) }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            headerBar

            if let msg = pairPlay.statusMessage, pairPlay.isPairPlayViewMode {
                HStack(spacing: 5) {
                    Image(systemName: "info.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.cyan)
                    Text(msg)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                    Spacer()
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.cyan.opacity(0.10)))
            }

            if pairPlay.isPairPlayViewMode {
                pairPlayListView
            } else {
                singleOutputListView
            }
        }
    }

    // MARK: - Header Bar (Single vs PairPlay + Studio Button)

    private var headerBar: some View {
        HStack(spacing: 6) {
            // Mode Picker: Single vs PairPlay
            HStack(spacing: 3) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        pairPlay.isPairPlayViewMode = false
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "speaker.wave.2.fill")
                            .font(.system(size: 9.5, weight: .semibold))
                        Text("Single")
                            .font(.system(size: 10.5, weight: .semibold))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(!pairPlay.isPairPlayViewMode ? Color.white.opacity(0.16) : Color.clear))
                    .foregroundStyle(!pairPlay.isPairPlayViewMode ? .white : .white.opacity(0.55))
                }
                .buttonStyle(.plain)

                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        pairPlay.isPairPlayViewMode = true
                        systemAudio.refreshAll()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "person.2.wave.2.fill")
                            .font(.system(size: 9.5, weight: .semibold))
                        Text("PairPlay")
                            .font(.system(size: 10.5, weight: .semibold))
                        if pairPlay.isActive {
                            Circle()
                                .fill(Color.green)
                                .frame(width: 5.5, height: 5.5)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(pairPlay.isPairPlayViewMode ? Color.cyan.opacity(0.22) : Color.clear))
                    .overlay(
                        Capsule()
                            .stroke(pairPlay.isPairPlayViewMode ? Color.cyan.opacity(0.55) : Color.clear, lineWidth: 1)
                    )
                    .foregroundStyle(pairPlay.isPairPlayViewMode ? .cyan : .white.opacity(0.55))
                }
                .buttonStyle(.plain)
            }
            .padding(2)
            .background(Capsule().fill(Color.white.opacity(0.06)))

            Spacer()

            if pairPlay.isPairPlayViewMode {
                Button {
                    pairPlay.togglePairPlay()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: pairPlay.isActive ? "stop.fill" : "play.fill")
                            .font(.system(size: 8.5, weight: .bold))
                        Text(pairPlay.isActive ? "Stop (\(selectedConnectedCount))" : "Start (\(selectedConnectedCount))")
                            .font(.system(size: 10, weight: .bold))
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(
                        Capsule().fill(
                            pairPlay.isActive
                                ? Color.green
                                : (selectedConnectedCount >= 2 ? Color.cyan : Color.white.opacity(0.10))
                        )
                    )
                    .foregroundStyle(
                        pairPlay.isActive || selectedConnectedCount >= 2
                            ? Color.black
                            : Color.white.opacity(0.45)
                    )
                }
                .buttonStyle(.plain)
                .disabled(!pairPlay.isActive && selectedConnectedCount < 2)
            }

            // Opens Full PairPlay Audio Studio Window (Multi-Output, Per-App Router, Latency Sync, EQ, Spatial Ear)
            Button {
                PairPlayWindowController.show(appState: appState)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 9.5, weight: .bold))
                    Text("Studio")
                        .font(.system(size: 10, weight: .bold))
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.white.opacity(0.12)))
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .help("Open PairPlay Studio (Multi-Output, App Router, EQ, Spatial Ear & Sync)")

            Button {
                systemAudio.refreshAll()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
            }
            .buttonStyle(.plain)
        }
    }

    // MARK: - Single Output Mode

    @ViewBuilder
    private var singleOutputListView: some View {
        if systemAudio.outputDevices.isEmpty {
            Text("No output devices found")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.5))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 6) {
                    ForEach(systemAudio.outputDevices) { device in
                        let isSelectedSingle = !pairPlay.isActive && device.isDefault
                        let isPairedNow = pairPlay.isActive && pairPlay.selectedUIDs.contains(device.uid)

                        Button {
                            systemAudio.setDefaultOutputDevice(device.id)
                        } label: {
                            HStack(spacing: 12) {
                                ZStack {
                                    Circle()
                                        .fill(
                                            isSelectedSingle
                                                ? Color.blue.opacity(0.25)
                                                : (isPairedNow ? Color.cyan.opacity(0.22) : Color.white.opacity(0.08))
                                        )
                                    Image(systemName: device.sfSymbol)
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(
                                            isSelectedSingle ? .blue : (isPairedNow ? .cyan : .white.opacity(0.75))
                                        )
                                }
                                .frame(width: 30, height: 30)

                                VStack(alignment: .leading, spacing: 2) {
                                    Text(device.name)
                                        .font(.system(size: 13, weight: .semibold))
                                        .foregroundStyle(.white)
                                        .lineLimit(1)
                                    if isSelectedSingle {
                                        Text("Active Output")
                                            .font(.system(size: 10, weight: .medium))
                                            .foregroundStyle(.blue)
                                    } else if isPairedNow {
                                        Text("Streaming via PairPlay")
                                            .font(.system(size: 10, weight: .medium))
                                            .foregroundStyle(.cyan)
                                    }
                                }

                                Spacer()

                                if isSelectedSingle {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.system(size: 15))
                                        .foregroundStyle(.blue)
                                } else if isPairedNow {
                                    Image(systemName: "person.2.wave.2.fill")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(.cyan)
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(
                                        isSelectedSingle
                                            ? Color.blue.opacity(0.12)
                                            : (isPairedNow ? Color.cyan.opacity(0.10) : Color.white.opacity(0.05))
                                    )
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: - PairPlay Inline Multi-Output Mode

    @ViewBuilder
    private var pairPlayListView: some View {
        if pairableDevices.count < 2 {
            VStack(spacing: 6) {
                Image(systemName: "person.2.wave.2.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.cyan.opacity(0.75))
                Text("Connect 2+ headphones or speakers for Multi-Output")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.85))
                Text("Or click Studio above for Per-App Routing, Spatial Ear split, EQ & Sync tools.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.5))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 18)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 6) {
                    ForEach(pairableDevices) { device in
                        pairPlayDeviceCard(device)
                    }
                }
            }
        }
    }

    private func pairPlayDeviceCard(_ device: AudioOutputDevice) -> some View {
        let isSelected = pairPlay.selectedUIDs.contains(device.uid)
        let isStreaming = pairPlay.isActive && isSelected
        let vol = pairPlay.deviceVolumes[device.uid] ?? 0.75
        let isMuted = pairPlay.deviceMuted[device.uid] ?? false
        let delayMs = pairPlay.deviceDelayMs[device.uid] ?? 0
        let chMode = pairPlay.deviceChannelModes[device.uid] ?? .stereo
        let eq = pairPlay.deviceEQPresets[device.uid] ?? .flat

        return VStack(spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    pairPlay.toggleDeviceSelection(device)
                } label: {
                    HStack(spacing: 9) {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(isStreaming ? .green : (isSelected ? .cyan : .white.opacity(0.35)))

                        ZStack {
                            Circle()
                                .fill(isSelected ? Color.cyan.opacity(0.20) : Color.white.opacity(0.08))
                            Image(systemName: device.sfSymbol)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(isSelected ? .cyan : .white.opacity(0.75))
                        }
                        .frame(width: 26, height: 26)

                        Text(device.name)
                            .font(.system(size: 12.5, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)

                        Spacer()
                    }
                }
                .buttonStyle(.plain)

                if isSelected {
                    // Quick Channel Mode Menu
                    Menu {
                        ForEach(PairPlayChannelMode.allCases) { m in
                            Button(m.rawValue) { pairPlay.setDeviceChannelMode(uid: device.uid, mode: m) }
                        }
                    } label: {
                        Text(chMode.shortLabel)
                            .font(.system(size: 9.5, weight: .bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(chMode != .stereo ? Color.cyan.opacity(0.22) : Color.white.opacity(0.08)))
                            .foregroundStyle(chMode != .stereo ? .cyan : .white.opacity(0.7))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()

                    // Quick EQ Preset Menu
                    Menu {
                        ForEach(PairPlayEQPreset.allCases) { p in
                            Button(p.rawValue) { pairPlay.setDeviceEQPreset(uid: device.uid, preset: p) }
                        }
                    } label: {
                        Text(eq.rawValue)
                            .font(.system(size: 9.5, weight: .bold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(eq != .flat ? Color.purple.opacity(0.25) : Color.white.opacity(0.08)))
                            .foregroundStyle(eq != .flat ? Color(red: 0.85, green: 0.65, blue: 1.0) : .white.opacity(0.7))
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                }

                if isStreaming {
                    Text("LIVE")
                        .font(.system(size: 9, weight: .heavy))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.green.opacity(0.20)))
                        .foregroundStyle(.green)
                }
            }

            if isSelected {
                HStack(spacing: 8) {
                    Button {
                        pairPlay.toggleDeviceMute(uid: device.uid)
                    } label: {
                        Image(systemName: isMuted || vol <= 0.001 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(isMuted ? .red : .white.opacity(0.75))
                            .frame(width: 16)
                    }
                    .buttonStyle(.plain)

                    Slider(
                        value: Binding(
                            get: { Double(pairPlay.deviceVolumes[device.uid] ?? 0.75) },
                            set: { v in pairPlay.setDeviceVolume(uid: device.uid, volume: Float(v)) }
                        ),
                        in: 0...1
                    )
                    .tint(isStreaming ? .green : .cyan)
                    .controlSize(.mini)

                    Text(isMuted ? "Mute" : "\(Int(round(vol * 100)))%")
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(isMuted ? .red : .white.opacity(0.75))
                        .frame(width: 32, alignment: .trailing)

                    Rectangle()
                        .fill(Color.white.opacity(0.12))
                        .frame(width: 1, height: 12)

                    HStack(spacing: 4) {
                        Image(systemName: "clock.arrow.circlepath")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(delayMs > 0 ? .orange : .white.opacity(0.5))

                        Button {
                            pairPlay.setDeviceDelay(uid: device.uid, delayMs: max(0, delayMs - 10))
                        } label: {
                            Image(systemName: "minus")
                                .font(.system(size: 8.5, weight: .bold))
                                .frame(width: 16, height: 16)
                                .background(Circle().fill(Color.white.opacity(0.10)))
                                .foregroundStyle(.white.opacity(delayMs > 0 ? 0.85 : 0.3))
                        }
                        .buttonStyle(.plain)
                        .disabled(delayMs == 0)

                        Button {
                            pairPlay.setDeviceDelay(uid: device.uid, delayMs: 0)
                        } label: {
                            Text("\(delayMs)ms")
                                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                                .monospacedDigit()
                                .foregroundStyle(delayMs > 0 ? .orange : .white.opacity(0.65))
                                .frame(width: 38, alignment: .center)
                        }
                        .buttonStyle(.plain)

                        Button {
                            pairPlay.setDeviceDelay(uid: device.uid, delayMs: min(400, delayMs + 10))
                        } label: {
                            Image(systemName: "plus")
                                .font(.system(size: 8.5, weight: .bold))
                                .frame(width: 16, height: 16)
                                .background(Circle().fill(Color.white.opacity(0.10)))
                                .foregroundStyle(.white.opacity(delayMs < 400 ? 0.85 : 0.3))
                        }
                        .buttonStyle(.plain)
                        .disabled(delayMs >= 400)
                    }
                }
                .padding(.leading, 24)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(
                    isStreaming
                        ? Color.green.opacity(0.11)
                        : (isSelected ? Color.cyan.opacity(0.09) : Color.white.opacity(0.05))
                )
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(
                    isStreaming
                        ? Color.green.opacity(0.35)
                        : (isSelected ? Color.cyan.opacity(0.25) : Color.clear),
                    lineWidth: 1
                )
        )
    }
}
