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
                        .foregroundColor(.cyan)
                    Text(msg)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(Color.white.opacity(0.75))
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

    // MARK: - Header Bar

    private var headerBar: some View {
        let canStart = pairPlay.isActive || selectedConnectedCount >= 2
        let startBg: Color = pairPlay.isActive ? .green : (selectedConnectedCount >= 2 ? .cyan : Color.white.opacity(0.10))
        let startFg: Color = canStart ? .black : Color.white.opacity(0.45)

        return HStack(spacing: 6) {
            modeSwitcherPill

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
                    .background(Capsule().fill(startBg))
                    .foregroundColor(startFg)
                }
                .buttonStyle(.plain)
                .disabled(!canStart)
            }

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
                .foregroundColor(.white)
            }
            .buttonStyle(.plain)
            .help("Open PairPlay Studio")

            Button {
                systemAudio.refreshAll()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color.white.opacity(0.6))
            }
            .buttonStyle(.plain)
        }
    }

    private var modeSwitcherPill: some View {
        let isPP = pairPlay.isPairPlayViewMode
        let singleBg: Color = !isPP ? Color.white.opacity(0.16) : .clear
        let singleFg: Color = !isPP ? .white : Color.white.opacity(0.55)
        let ppBg: Color = isPP ? Color.cyan.opacity(0.22) : .clear
        let ppStroke: Color = isPP ? Color.cyan.opacity(0.55) : .clear
        let ppFg: Color = isPP ? .cyan : Color.white.opacity(0.55)

        return HStack(spacing: 3) {
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
                .background(Capsule().fill(singleBg))
                .foregroundColor(singleFg)
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
                .background(Capsule().fill(ppBg))
                .overlay(Capsule().stroke(ppStroke, lineWidth: 1))
                .foregroundColor(ppFg)
            }
            .buttonStyle(.plain)
        }
        .padding(2)
        .background(Capsule().fill(Color.white.opacity(0.06)))
    }

    // MARK: - Single Output Mode

    @ViewBuilder
    private var singleOutputListView: some View {
        if systemAudio.outputDevices.isEmpty {
            Text("No output devices found")
                .font(.system(size: 12))
                .foregroundColor(Color.white.opacity(0.5))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 6) {
                    ForEach(systemAudio.outputDevices) { device in
                        singleDeviceRow(device)
                    }
                }
            }
        }
    }

    private func singleDeviceRow(_ device: AudioOutputDevice) -> some View {
        let isSelectedSingle = !pairPlay.isActive && device.isDefault
        let isPairedNow = pairPlay.isActive && pairPlay.selectedUIDs.contains(device.uid)
        let circleBg: Color = isSelectedSingle ? Color.blue.opacity(0.25) : (isPairedNow ? Color.cyan.opacity(0.22) : Color.white.opacity(0.08))
        let iconFg: Color = isSelectedSingle ? .blue : (isPairedNow ? .cyan : Color.white.opacity(0.75))
        let rowBg: Color = isSelectedSingle ? Color.blue.opacity(0.12) : (isPairedNow ? Color.cyan.opacity(0.10) : Color.white.opacity(0.05))

        return Button {
            systemAudio.setDefaultOutputDevice(device.id)
        } label: {
            HStack(spacing: 12) {
                ZStack {
                    Circle().fill(circleBg)
                    Image(systemName: device.sfSymbol)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(iconFg)
                }
                .frame(width: 30, height: 30)

                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    if isSelectedSingle {
                        Text("Active Output")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.blue)
                    } else if isPairedNow {
                        Text("Streaming via PairPlay")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(.cyan)
                    }
                }

                Spacer()

                if isSelectedSingle {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundColor(.blue)
                } else if isPairedNow {
                    Image(systemName: "person.2.wave.2.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(.cyan)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 10).fill(rowBg))
        }
        .buttonStyle(.plain)
    }

    // MARK: - PairPlay Inline Multi-Output Mode

    @ViewBuilder
    private var pairPlayListView: some View {
        if pairableDevices.count < 2 {
            VStack(spacing: 6) {
                Image(systemName: "person.2.wave.2.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(Color.cyan.opacity(0.75))
                Text("Connect 2+ headphones or speakers for Multi-Output")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(Color.white.opacity(0.85))
                Text("Or click Studio above for Per-App Routing, Spatial Ear split, EQ & Sync tools.")
                    .font(.system(size: 10.5))
                    .foregroundColor(Color.white.opacity(0.5))
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
        let fill: Color = isStreaming ? Color.green.opacity(0.11) : (isSelected ? Color.cyan.opacity(0.09) : Color.white.opacity(0.05))
        let stroke: Color = isStreaming ? Color.green.opacity(0.35) : (isSelected ? Color.cyan.opacity(0.25) : .clear)

        return VStack(spacing: 6) {
            pairPlayCardTopRow(device, isSelected: isSelected, isStreaming: isStreaming)

            if isSelected {
                pairPlayCardControlsRow(device, isStreaming: isStreaming)
                    .padding(.leading, 24)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 10).fill(fill))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(stroke, lineWidth: 1))
    }

    private func pairPlayCardTopRow(_ device: AudioOutputDevice, isSelected: Bool, isStreaming: Bool) -> some View {
        let chMode = pairPlay.deviceChannelModes[device.uid] ?? .stereo
        let eq = pairPlay.deviceEQPresets[device.uid] ?? .flat
        let checkColor: Color = isStreaming ? .green : (isSelected ? .cyan : Color.white.opacity(0.35))
        let iconBg: Color = isSelected ? Color.cyan.opacity(0.20) : Color.white.opacity(0.08)
        let iconFg: Color = isSelected ? .cyan : Color.white.opacity(0.75)
        let chBg: Color = chMode != .stereo ? Color.cyan.opacity(0.22) : Color.white.opacity(0.08)
        let chFg: Color = chMode != .stereo ? .cyan : Color.white.opacity(0.7)
        let eqBg: Color = eq != .flat ? Color.purple.opacity(0.25) : Color.white.opacity(0.08)
        let eqFg: Color = eq != .flat ? Color(red: 0.85, green: 0.65, blue: 1.0) : Color.white.opacity(0.7)

        return HStack(spacing: 8) {
            Button {
                pairPlay.toggleDeviceSelection(device)
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(checkColor)

                    ZStack {
                        Circle().fill(iconBg)
                        Image(systemName: device.sfSymbol)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundColor(iconFg)
                    }
                    .frame(width: 26, height: 26)

                    Text(device.name)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)

                    Spacer()
                }
            }
            .buttonStyle(.plain)

            if isSelected {
                Menu {
                    ForEach(PairPlayChannelMode.allCases) { m in
                        Button(m.rawValue) { pairPlay.setDeviceChannelMode(uid: device.uid, mode: m) }
                    }
                } label: {
                    Text(chMode.shortLabel)
                        .font(.system(size: 9.5, weight: .bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(chBg))
                        .foregroundColor(chFg)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Menu {
                    ForEach(PairPlayEQPreset.allCases) { p in
                        Button(p.rawValue) { pairPlay.setDeviceEQPreset(uid: device.uid, preset: p) }
                    }
                } label: {
                    Text(eq.rawValue)
                        .font(.system(size: 9.5, weight: .bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(eqBg))
                        .foregroundColor(eqFg)
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
                    .foregroundColor(.green)
            }
        }
    }

    private func pairPlayCardControlsRow(_ device: AudioOutputDevice, isStreaming: Bool) -> some View {
        let vol = pairPlay.deviceVolumes[device.uid] ?? 0.75
        let isMuted = pairPlay.deviceMuted[device.uid] ?? false
        let delayMs = pairPlay.deviceDelayMs[device.uid] ?? 0
        let muteColor: Color = isMuted ? .red : Color.white.opacity(0.75)
        let sliderTint: Color = isStreaming ? .green : .cyan
        let delayIconColor: Color = delayMs > 0 ? .orange : Color.white.opacity(0.5)
        let delayTextColor: Color = delayMs > 0 ? .orange : Color.white.opacity(0.65)
        let minusFg: Color = Color.white.opacity(delayMs > 0 ? 0.85 : 0.3)
        let plusFg: Color = Color.white.opacity(delayMs < 400 ? 0.85 : 0.3)

        return HStack(spacing: 8) {
            Button {
                pairPlay.toggleDeviceMute(uid: device.uid)
            } label: {
                Image(systemName: isMuted || vol <= 0.001 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundColor(muteColor)
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
            .tint(sliderTint)
            .controlSize(.mini)

            Text(isMuted ? "Mute" : "\(Int(round(vol * 100)))%")
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .foregroundColor(muteColor)
                .frame(width: 32, alignment: .trailing)

            Rectangle()
                .fill(Color.white.opacity(0.12))
                .frame(width: 1, height: 12)

            HStack(spacing: 4) {
                Image(systemName: "clock.arrow.circlepath")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundColor(delayIconColor)

                Button {
                    pairPlay.setDeviceDelay(uid: device.uid, delayMs: max(0, delayMs - 10))
                } label: {
                    Image(systemName: "minus")
                        .font(.system(size: 8.5, weight: .bold))
                        .frame(width: 16, height: 16)
                        .background(Circle().fill(Color.white.opacity(0.10)))
                        .foregroundColor(minusFg)
                }
                .buttonStyle(.plain)
                .disabled(delayMs == 0)

                Button {
                    pairPlay.setDeviceDelay(uid: device.uid, delayMs: 0)
                } label: {
                    Text("\(delayMs)ms")
                        .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                        .monospacedDigit()
                        .foregroundColor(delayTextColor)
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
                        .foregroundColor(plusFg)
                }
                .buttonStyle(.plain)
                .disabled(delayMs >= 400)
            }
        }
    }
}
