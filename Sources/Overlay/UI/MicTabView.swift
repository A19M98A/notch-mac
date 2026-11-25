import SwiftUI

struct MicTabView: View {
    var showModeBar: Bool = true

    @EnvironmentObject var appState: AppState
    @EnvironmentObject var inputAudio: InputAudioManager
    @EnvironmentObject var virtualMic: VirtualMicService
    @EnvironmentObject var perAppMixer: PerAppAudioMixer

    var body: some View {
        VStack(spacing: 6) {
            if showModeBar {
                micTopModeBar
            }

            if showModeBar && virtualMic.isMicMixViewMode {
                inlineVirtualMicMixView
            } else {
                singleMicFXView
            }
        }
    }

    // MARK: - Top Mode Switcher (Single FX vs MicMix + Studio Window Button)

    private var micTopModeBar: some View {
        let isMix = virtualMic.isMicMixViewMode
        let singleBg: Color = !isMix ? Color.white.opacity(0.16) : .clear
        let singleFg: Color = !isMix ? .white : Color.white.opacity(0.55)
        let mixBg: Color = isMix ? Color.mint.opacity(0.22) : .clear
        let mixStroke: Color = isMix ? Color.mint.opacity(0.55) : .clear
        let mixFg: Color = isMix ? .mint : Color.white.opacity(0.55)
        let count = virtualMic.totalSelectedSourcesCount
        let canStart = virtualMic.isActive || count >= 1
        let startBg: Color = virtualMic.isActive ? .green : (count >= 1 ? .mint : Color.white.opacity(0.10))
        let startFg: Color = canStart ? .black : Color.white.opacity(0.45)

        return HStack(spacing: 6) {
            HStack(spacing: 3) {
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        virtualMic.isMicMixViewMode = false
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "waveform.badge.mic")
                            .font(.system(size: 9.5, weight: .semibold))
                        Text("Single FX")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3.5)
                    .background(Capsule().fill(singleBg))
                    .foregroundColor(singleFg)
                }
                .buttonStyle(.plain)

                Button {
                    withAnimation(.easeInOut(duration: 0.15)) {
                        virtualMic.isMicMixViewMode = true
                        inputAudio.refreshAll()
                        perAppMixer.refreshAudioProcesses()
                        virtualMic.syncDevices()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "mic.and.signal.meter.fill")
                            .font(.system(size: 9.5, weight: .semibold))
                        Text("MicMix")
                            .font(.system(size: 10, weight: .semibold))
                        if virtualMic.isActive {
                            Circle()
                                .fill(Color.green)
                                .frame(width: 5.5, height: 5.5)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3.5)
                    .background(Capsule().fill(mixBg))
                    .overlay(Capsule().stroke(mixStroke, lineWidth: 1))
                    .foregroundColor(mixFg)
                }
                .buttonStyle(.plain)
            }
            .padding(2)
            .background(Capsule().fill(Color.white.opacity(0.06)))

            if isMix {
                virtualCablePickerMenu
            }

            Spacer()

            if isMix {
                Button {
                    virtualMic.autoDuckApps.toggle()
                } label: {
                    Text("Duck")
                        .font(.system(size: 9.5, weight: .bold))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3.5)
                        .background(Capsule().fill(virtualMic.autoDuckApps ? Color.cyan.opacity(0.22) : Color.white.opacity(0.08)))
                        .foregroundColor(virtualMic.autoDuckApps ? .cyan : Color.white.opacity(0.55))
                }
                .buttonStyle(.plain)
                .help("Auto-lower app audio while you speak")

                Button {
                    virtualMic.toggleMix()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: virtualMic.isActive ? "stop.fill" : "play.fill")
                            .font(.system(size: 8.5, weight: .bold))
                        Text(virtualMic.isActive ? "Live (\(count))" : "Mix (\(count))")
                            .font(.system(size: 10, weight: .bold))
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3.5)
                    .background(Capsule().fill(startBg))
                    .foregroundColor(startFg)
                }
                .buttonStyle(.plain)
                .disabled(!canStart)
            }

            Button {
                PairPlayWindowController.show(appState: appState, initialSection: .virtualMicMix)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 9.5, weight: .bold))
                    Text("Studio")
                        .font(.system(size: 10, weight: .bold))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 3.5)
                .background(Capsule().fill(Color.white.opacity(0.12)))
                .foregroundColor(.white)
            }
            .buttonStyle(.plain)
            .help("Open Virtual Mic & PairPlay Studio")
        }
    }

    @ViewBuilder
    private var virtualCablePickerMenu: some View {
        if virtualMic.virtualCables.isEmpty {
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("brew install blackhole-2ch", forType: .string)
                virtualMic.statusMessage = "Copied 'brew install blackhole-2ch'"
            } label: {
                Text("→ Install Virtual Mic")
                    .font(.system(size: 9.5, weight: .bold))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3.5)
                    .background(Capsule().fill(Color.orange.opacity(0.22)))
                    .foregroundColor(.orange)
            }
            .buttonStyle(.plain)
        } else {
            Menu {
                ForEach(virtualMic.virtualCables) { cable in
                    Button {
                        virtualMic.selectVirtualCable(uid: cable.uid)
                    } label: {
                        HStack {
                            Text(cable.name)
                            if cable.uid == virtualMic.selectedVirtualCableUID {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                Text("→ \(virtualMic.activeVirtualCableName)")
                    .font(.system(size: 9.5, weight: .bold))
                    .lineLimit(1)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3.5)
                    .background(Capsule().fill(Color.mint.opacity(0.16)))
                    .foregroundColor(.mint)
            }
            .menuStyle(.borderlessButton)
            .frame(maxWidth: 135, alignment: .leading)
        }
    }

    // MARK: - Mode 2: Inline Virtual Mic Mixer (Mics + Apps -> Virtual Mic for Calls)

    private var inlineVirtualMicMixView: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 5) {
                if let msg = virtualMic.statusMessage {
                    Text(msg)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundColor(.orange)
                        .lineLimit(1)
                }

                ForEach(virtualMic.physicalMics) { mic in
                    inlineMicMixRow(mic)
                }

                ForEach(perAppMixer.apps) { app in
                    inlineAppMixRow(app)
                }

                if virtualMic.physicalMics.isEmpty && perAppMixer.apps.isEmpty {
                    Text("No microphones or active audio apps detected.")
                        .font(.system(size: 11))
                        .foregroundColor(Color.white.opacity(0.5))
                        .frame(maxWidth: .infinity)
                        .padding(.top, 16)
                }
            }
        }
    }

    private func inlineMicMixRow(_ mic: AudioInputDevice) -> some View {
        let selected = virtualMic.selectedMicUIDs.contains(mic.uid)
        let vol = virtualMic.micVolumes[mic.uid] ?? 1.0
        let muted = virtualMic.micMuted[mic.uid] ?? false
        let checkFg: Color = (virtualMic.isActive && selected) ? .green : (selected ? .mint : Color.white.opacity(0.35))
        let rowBg: Color = selected ? Color.mint.opacity(0.09) : Color.white.opacity(0.04)

        return HStack(spacing: 8) {
            Button {
                virtualMic.toggleMic(mic)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(checkFg)
                    Image(systemName: mic.sfSymbol)
                        .font(.system(size: 10.5))
                        .foregroundColor(.mint)
                    Text(mic.name)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                }
                .frame(width: 155, alignment: .leading)
            }
            .buttonStyle(.plain)

            if selected {
                Slider(
                    value: Binding(
                        get: { Double(virtualMic.micVolumes[mic.uid] ?? 1.0) },
                        set: { v in virtualMic.setMicVolume(uid: mic.uid, volume: Float(v)) }
                    ),
                    in: 0...2.0
                )
                .tint(.mint)
                .controlSize(.mini)

                Text(muted ? "Mute" : "\(Int(round(vol * 100)))%")
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundColor(muted ? .red : Color.white.opacity(0.75))
                    .frame(width: 36, alignment: .trailing)

                Button {
                    virtualMic.toggleMicMute(uid: mic.uid)
                } label: {
                    Image(systemName: muted ? "mic.slash.fill" : "mic.fill")
                        .font(.system(size: 10.5))
                        .foregroundColor(muted ? .red : Color.white.opacity(0.75))
                        .frame(width: 18)
                }
                .buttonStyle(.plain)
            } else {
                Spacer()
                Text("Mic")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundColor(Color.white.opacity(0.4))
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 8).fill(rowBg))
    }

    private func inlineAppMixRow(_ app: AudioAppSource) -> some View {
        let key = app.bundleID
        let selected = virtualMic.selectedAppKeys.contains(key)
        let vol = virtualMic.appVolumes[key] ?? 0.45
        let muted = virtualMic.appMuted[key] ?? false
        let callOnly = virtualMic.appMuteLocal[key] ?? false
        let checkFg: Color = (virtualMic.isActive && selected) ? .green : (selected ? .cyan : Color.white.opacity(0.35))
        let rowBg: Color = selected ? Color.cyan.opacity(0.09) : Color.white.opacity(0.04)
        let modeFg: Color = callOnly ? .orange : .cyan

        return HStack(spacing: 8) {
            Button {
                virtualMic.toggleApp(app)
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(checkFg)
                    Image(nsImage: app.icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: 15, height: 15)
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                    Text(app.name)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                }
                .frame(width: 155, alignment: .leading)
            }
            .buttonStyle(.plain)

            if selected {
                Slider(
                    value: Binding(
                        get: { Double(virtualMic.appVolumes[key] ?? 0.45) },
                        set: { v in virtualMic.setAppVolume(key: key, volume: Float(v)) }
                    ),
                    in: 0...1.5
                )
                .tint(.cyan)
                .controlSize(.mini)

                Button {
                    virtualMic.toggleAppMuteLocal(key: key)
                } label: {
                    Text(callOnly ? "Call Only" : "Hear+Call")
                        .font(.system(size: 8.5, weight: .bold))
                        .padding(.horizontal, 5)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(modeFg.opacity(0.18)))
                        .foregroundColor(modeFg)
                }
                .buttonStyle(.plain)

                Text(muted ? "Mute" : "\(Int(round(vol * 100)))%")
                    .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundColor(muted ? .red : Color.white.opacity(0.75))
                    .frame(width: 34, alignment: .trailing)

                Button {
                    virtualMic.toggleAppMute(key: key)
                } label: {
                    Image(systemName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 10.5))
                        .foregroundColor(muted ? .red : Color.white.opacity(0.75))
                        .frame(width: 18)
                }
                .buttonStyle(.plain)
            } else {
                Spacer()
                Text("App Audio")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundColor(Color.white.opacity(0.4))
            }
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 8).fill(rowBg))
    }

    // MARK: - Mode 1: Single Mic Real-Time Voice FX

    private var singleMicFXView: some View {
        VStack(spacing: 6) {
            singleMicTopRow

            if let err = inputAudio.statusError {
                Text(err)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundColor(.yellow)
                    .lineLimit(1)
            }

            presetsScrollStrip
            dspSlidersBox
        }
    }

    private var singleMicTopRow: some View {
        let monFg: Color = inputAudio.monitorEnabled ? .cyan : Color.white.opacity(0.45)
        let monBg: Color = inputAudio.monitorEnabled ? Color.cyan.opacity(0.22) : Color.white.opacity(0.08)
        let muteFg: Color = inputAudio.isMuted ? .red : .white
        let muteBg: Color = inputAudio.isMuted ? Color.red.opacity(0.24) : Color.white.opacity(0.10)
        let fxDot: Color = inputAudio.fxEnabled ? .green : Color.white.opacity(0.35)
        let fxBg: Color = inputAudio.fxEnabled ? Color.green.opacity(0.22) : Color.white.opacity(0.10)
        let fxFg: Color = inputAudio.fxEnabled ? .green : Color.white.opacity(0.75)

        return HStack(spacing: 8) {
            Menu {
                ForEach(inputAudio.inputDevices) { dev in
                    Button {
                        inputAudio.selectSourceMic(dev.id)
                    } label: {
                        HStack {
                            Image(systemName: dev.sfSymbol)
                            Text(dev.name)
                            if dev.id == inputAudio.currentInputDevice?.id {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: inputAudio.currentInputDevice?.sfSymbol ?? "mic.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.cyan)
                    Text(inputAudio.currentInputDevice?.name ?? "Select Input")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(Color.white.opacity(0.55))
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4.5)
                .background(Capsule().fill(Color.white.opacity(0.10)))
            }
            .menuStyle(.borderlessButton)
            .frame(maxWidth: 200, alignment: .leading)

            vuMeterBar(level: inputAudio.isMuted ? 0 : inputAudio.liveLevel)

            Button {
                inputAudio.toggleMonitor()
            } label: {
                Image(systemName: inputAudio.monitorEnabled ? "headphones" : "headphones.circle")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(monFg)
                    .frame(width: 25, height: 25)
                    .background(Circle().fill(monBg))
            }
            .buttonStyle(.plain)

            Button {
                inputAudio.toggleMute()
            } label: {
                Image(systemName: inputAudio.isMuted ? "mic.slash.fill" : "mic.fill")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(muteFg)
                    .frame(width: 25, height: 25)
                    .background(Circle().fill(muteBg))
            }
            .buttonStyle(.plain)

            Button {
                if virtualMic.isActive { virtualMic.stopMix() }
                inputAudio.toggleFXEngine()
            } label: {
                HStack(spacing: 4) {
                    Circle().fill(fxDot).frame(width: 6, height: 6)
                    Text(inputAudio.fxEnabled ? "FX ON" : "FX OFF")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 4.5)
                .background(Capsule().fill(fxBg))
                .foregroundColor(fxFg)
            }
            .buttonStyle(.plain)
        }
    }

    private func vuMeterBar(level: Float) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.12))
                    .frame(height: 5)
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [.green, .yellow, .red],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: max(0, geo.size.width * CGFloat(level)), height: 5)
                    .animation(.linear(duration: 0.06), value: level)
            }
            .frame(maxHeight: .infinity)
        }
        .frame(height: 15)
    }

    private var presetsScrollStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(VoiceEffectPreset.allCases) { preset in
                    presetPill(preset)
                }
            }
            .padding(.horizontal, 3)
            .padding(.vertical, 1)
        }
    }

    private func presetPill(_ preset: VoiceEffectPreset) -> some View {
        let isSelected = inputAudio.selectedPreset == preset
        let bg: Color = isSelected ? Color.purple.opacity(0.32) : Color.white.opacity(0.07)
        let stroke: Color = isSelected ? Color.purple.opacity(0.7) : Color.white.opacity(0.08)
        let fg: Color = isSelected ? .white : Color.white.opacity(0.7)

        return Button {
            inputAudio.applyPreset(preset)
            if !inputAudio.fxEnabled && preset != .clean {
                if virtualMic.isActive { virtualMic.stopMix() }
                inputAudio.toggleFXEngine()
            }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: preset.sfSymbol)
                    .font(.system(size: 10, weight: .semibold))
                Text(preset.rawValue)
                    .font(.system(size: 10, weight: isSelected ? .bold : .semibold))
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 4.5)
            .background(Capsule().fill(bg).overlay(Capsule().stroke(stroke, lineWidth: 1)))
            .foregroundColor(fg)
        }
        .buttonStyle(.plain)
    }

    private var dspSlidersBox: some View {
        let ncBg: Color = inputAudio.noiseCutEnabled ? Color.cyan.opacity(0.24) : Color.white.opacity(0.08)
        let ncFg: Color = inputAudio.noiseCutEnabled ? .cyan : Color.white.opacity(0.5)

        return VStack(spacing: 5) {
            HStack(spacing: 10) {
                Text("Gain")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Color.white.opacity(0.65))
                    .frame(width: 38, alignment: .leading)

                Slider(
                    value: Binding(
                        get: { Double(inputAudio.isMuted ? 0 : inputAudio.inputVolume) },
                        set: { inputAudio.setInputVolume(Float($0)) }
                    ),
                    in: 0...1
                )
                .tint(.cyan)

                Text("\(Int(round((inputAudio.isMuted ? 0 : inputAudio.inputVolume) * 100)))%")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundColor(Color.white.opacity(0.75))
                    .frame(width: 34, alignment: .trailing)

                Button {
                    inputAudio.noiseCutEnabled.toggle()
                    inputAudio.updateDSPParameters()
                } label: {
                    Text("Noise Cut")
                        .font(.system(size: 9, weight: .bold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3.5)
                        .background(Capsule().fill(ncBg))
                        .foregroundColor(ncFg)
                }
                .buttonStyle(.plain)

                singleFXVirtualTargetMenu
            }

            dspBottomSlidersRow
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 11).fill(Color.white.opacity(0.06)))
    }

    @ViewBuilder
    private var singleFXVirtualTargetMenu: some View {
        if !inputAudio.virtualOutputDevices.isEmpty {
            let hasTarget = inputAudio.currentFXTargetDevice != nil
            let bg: Color = hasTarget ? Color.green.opacity(0.22) : Color.white.opacity(0.08)
            let fg: Color = hasTarget ? .green : Color.white.opacity(0.6)
            Menu {
                Button("None (Monitor only)") {
                    inputAudio.setFXTargetDevice(nil)
                }
                ForEach(inputAudio.virtualOutputDevices) { vdev in
                    Button {
                        inputAudio.setFXTargetDevice(vdev.id)
                    } label: {
                        HStack {
                            Text(vdev.name)
                            if inputAudio.fxTargetDeviceID == vdev.id {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            } label: {
                Text("→ \(inputAudio.currentFXTargetDevice?.name ?? "No Virtual Mic")")
                    .font(.system(size: 9, weight: .bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3.5)
                    .background(Capsule().fill(bg))
                    .foregroundColor(fg)
                    .lineLimit(1)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
    }

    private var dspBottomSlidersRow: some View {
        HStack(spacing: 12) {
            HStack(spacing: 6) {
                Text("Pitch")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Color.white.opacity(0.65))
                    .frame(width: 32, alignment: .leading)
                Slider(
                    value: Binding(
                        get: { Double(inputAudio.pitchSemitones) },
                        set: {
                            inputAudio.pitchSemitones = Float($0)
                            inputAudio.updateDSPParameters()
                        }
                    ),
                    in: -12...12
                )
                .tint(.purple)
                Text(String(format: "%+.0f", inputAudio.pitchSemitones))
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundColor(Color.white.opacity(0.75))
                    .frame(width: 24, alignment: .trailing)
            }

            HStack(spacing: 6) {
                Text("Reverb")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Color.white.opacity(0.65))
                    .frame(width: 38, alignment: .leading)
                Slider(
                    value: Binding(
                        get: { Double(inputAudio.reverbWetDry) },
                        set: {
                            inputAudio.reverbWetDry = Float($0)
                            inputAudio.updateDSPParameters()
                        }
                    ),
                    in: 0...100
                )
                .tint(.pink)
                Text("\(Int(inputAudio.reverbWetDry))%")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundColor(Color.white.opacity(0.75))
                    .frame(width: 28, alignment: .trailing)
            }

            HStack(spacing: 6) {
                Text("Echo")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundColor(Color.white.opacity(0.65))
                    .frame(width: 28, alignment: .leading)
                Slider(
                    value: Binding(
                        get: { Double(inputAudio.echoWetDry) },
                        set: {
                            inputAudio.echoWetDry = Float($0)
                            inputAudio.updateDSPParameters()
                        }
                    ),
                    in: 0...100
                )
                .tint(.orange)
                Text("\(Int(inputAudio.echoWetDry))%")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundColor(Color.white.opacity(0.75))
                    .frame(width: 28, alignment: .trailing)
            }
        }
    }
}
