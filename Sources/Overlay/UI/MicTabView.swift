import SwiftUI

struct MicTabView: View {
    @EnvironmentObject var inputAudio: InputAudioManager

    var body: some View {
        VStack(spacing: 8) {
            // 1. Top Row: Input Device Selector + Live VU Meter + Mute + FX Engine Toggle
            HStack(spacing: 8) {
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
                            .foregroundStyle(.cyan)
                        Text(inputAudio.currentInputDevice?.name ?? "Select Input")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Image(systemName: "chevron.down")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.white.opacity(0.10)))
                }
                .menuStyle(.borderlessButton)
                .frame(maxWidth: 210, alignment: .leading)

                // Live Input VU Meter
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
                            .frame(width: max(0, geo.size.width * CGFloat(inputAudio.isMuted ? 0 : inputAudio.liveLevel)), height: 5)
                            .animation(.linear(duration: 0.06), value: inputAudio.liveLevel)
                    }
                    .frame(maxHeight: .infinity)
                }
                .frame(height: 16)

                Button {
                    inputAudio.toggleMonitor()
                } label: {
                    Image(systemName: inputAudio.monitorEnabled ? "headphones" : "headphones.circle")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(inputAudio.monitorEnabled ? .cyan : .white.opacity(0.45))
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(inputAudio.monitorEnabled ? Color.cyan.opacity(0.22) : Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .help(inputAudio.monitorEnabled ? "Headphone Monitor ON (click to silence playback)" : "Headphone Monitor OFF (silent)")

                Button {
                    inputAudio.toggleMute()
                } label: {
                    Image(systemName: inputAudio.isMuted ? "mic.slash.fill" : "mic.fill")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(inputAudio.isMuted ? .red : .white)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(inputAudio.isMuted ? Color.red.opacity(0.24) : Color.white.opacity(0.10)))
                }
                .buttonStyle(.plain)
                .help(inputAudio.isMuted ? "Unmute mic" : "Mute mic")

                Button {
                    inputAudio.toggleFXEngine()
                } label: {
                    HStack(spacing: 4) {
                        Circle()
                            .fill(inputAudio.fxEnabled ? Color.green : Color.white.opacity(0.35))
                            .frame(width: 6, height: 6)
                        Text(inputAudio.fxEnabled ? "FX ON" : "FX OFF")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(inputAudio.fxEnabled ? Color.green.opacity(0.22) : Color.white.opacity(0.10)))
                    .foregroundStyle(inputAudio.fxEnabled ? .green : .white.opacity(0.75))
                }
                .buttonStyle(.plain)
            }

            if let err = inputAudio.statusError {
                Text(err)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.yellow)
                    .lineLimit(1)
            }

            // 2. Effect Presets Strip
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(VoiceEffectPreset.allCases) { preset in
                        let isSelected = inputAudio.selectedPreset == preset
                        Button {
                            inputAudio.applyPreset(preset)
                            if !inputAudio.fxEnabled && preset != .clean {
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
                            .padding(.vertical, 5)
                            .background(
                                Capsule()
                                    .fill(isSelected ? Color.purple.opacity(0.32) : Color.white.opacity(0.07))
                                    .overlay(
                                        Capsule().stroke(isSelected ? Color.purple.opacity(0.7) : Color.white.opacity(0.08), lineWidth: 1)
                                    )
                            )
                            .foregroundStyle(isSelected ? .white : .white.opacity(0.7))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 3)
                .padding(.vertical, 2)
            }

            // 3. Compact Studio DSP Sliders (Gain + Noise Cut | Pitch | Reverb + Echo)
            VStack(spacing: 6) {
                HStack(spacing: 10) {
                    Text("Gain")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.65))
                        .frame(width: 42, alignment: .leading)

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
                        .foregroundStyle(.white.opacity(0.75))
                        .frame(width: 34, alignment: .trailing)

                    Button {
                        inputAudio.noiseCutEnabled.toggle()
                        inputAudio.updateDSPParameters()
                    } label: {
                        Text("Noise Cut")
                            .font(.system(size: 9, weight: .bold))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(inputAudio.noiseCutEnabled ? Color.cyan.opacity(0.24) : Color.white.opacity(0.08)))
                            .foregroundStyle(inputAudio.noiseCutEnabled ? .cyan : .white.opacity(0.5))
                    }
                    .buttonStyle(.plain)

                    // Virtual Mic Output Route (e.g. BlackHole 2ch -> Telegram / Discord)
                    if !inputAudio.virtualOutputDevices.isEmpty {
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
                                .padding(.vertical, 4)
                                .background(Capsule().fill(inputAudio.currentFXTargetDevice != nil ? Color.green.opacity(0.22) : Color.white.opacity(0.08)))
                                .foregroundStyle(inputAudio.currentFXTargetDevice != nil ? .green : .white.opacity(0.6))
                                .lineLimit(1)
                        }
                        .menuStyle(.borderlessButton)
                        .fixedSize()
                    } else {
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString("brew install blackhole-2ch", forType: .string)
                            inputAudio.statusError = "Copied 'brew install blackhole-2ch' — run in Terminal, then pick BlackHole in Telegram!"
                        } label: {
                            Text("→ Setup Virtual Mic")
                                .font(.system(size: 9, weight: .bold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Capsule().fill(Color.orange.opacity(0.22)))
                                .foregroundStyle(.orange)
                        }
                        .buttonStyle(.plain)
                        .help("Install BlackHole 2ch so Telegram/Discord/Zoom record your FX mic")
                    }
                }

                HStack(spacing: 12) {
                    // Pitch
                    HStack(spacing: 6) {
                        Text("Pitch")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.65))
                            .frame(width: 34, alignment: .leading)
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
                            .foregroundStyle(.white.opacity(0.75))
                            .frame(width: 24, alignment: .trailing)
                    }

                    // Reverb
                    HStack(spacing: 6) {
                        Text("Reverb")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.65))
                            .frame(width: 40, alignment: .leading)
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
                            .foregroundStyle(.white.opacity(0.75))
                            .frame(width: 30, alignment: .trailing)
                    }

                    // Echo
                    HStack(spacing: 6) {
                        Text("Echo")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.65))
                            .frame(width: 30, alignment: .leading)
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
                            .foregroundStyle(.white.opacity(0.75))
                            .frame(width: 30, alignment: .trailing)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 11).fill(Color.white.opacity(0.06)))
        }
    }
}
