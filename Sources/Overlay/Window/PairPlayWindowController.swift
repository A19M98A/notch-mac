import AppKit
import SwiftUI

final class PairPlayWindowController: NSWindowController {
    private static var shared: PairPlayWindowController?

    static func show(appState: AppState) {
        appState.systemAudio.refreshAll()
        appState.perAppMixer.refreshAudioProcesses()

        if let existing = shared, let window = existing.window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let controller = PairPlayWindowController(appState: appState)
        shared = controller
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    private init(appState: AppState) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 580, height: 540),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = ""
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isMovableByWindowBackground = true
        window.center()
        window.isReleasedWhenClosed = false

        let root = PairPlayStudioView()
            .environmentObject(appState)
            .environmentObject(appState.systemAudio)
            .environmentObject(appState.pairPlayService)
            .environmentObject(appState.perAppMixer)
            .environmentObject(appState.inputAudio)

        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(x: 0, y: 0, width: 580, height: 540)
        hosting.autoresizingMask = [.width, .height]
        window.contentView = hosting
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private enum PairPlayStudioSection: String, CaseIterable, Identifiable {
    case multiOutput = "Multi-Output"
    case appRouter = "App Router"
    case latencySync = "Latency Sync"
    case voiceFX = "Mic & Voice FX"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .multiOutput: return "person.2.wave.2.fill"
        case .appRouter: return "arrow.triangle.branch"
        case .latencySync: return "metronome.fill"
        case .voiceFX: return "waveform.badge.mic"
        }
    }
}

struct PairPlayStudioView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var systemAudio: SystemAudioManager
    @EnvironmentObject var pairPlay: PairPlayService
    @EnvironmentObject var perAppMixer: PerAppAudioMixer
    @EnvironmentObject var inputAudio: InputAudioManager

    @State private var section: PairPlayStudioSection = .multiOutput

    private var pairableDevices: [AudioOutputDevice] {
        pairPlay.pairableDevices(from: systemAudio.outputDevices)
    }

    private var selectedConnectedCount: Int {
        pairableDevices.filter { pairPlay.selectedUIDs.contains($0.uid) }.count
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)

        ZStack {
            shape
                .fill(.ultraThinMaterial)
                .overlay(shape.fill(Color.black.opacity(0.78)))
                .overlay(
                    shape.stroke(
                        LinearGradient(
                            colors: [Color.white.opacity(0.18), Color.white.opacity(0.06)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
                )

            VStack(spacing: 12) {
                // Header + Section Tabs
                VStack(spacing: 10) {
                    HStack {
                        HStack(spacing: 8) {
                            Image(systemName: "person.2.wave.2.fill")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(.cyan)
                            Text("PairPlay Audio Studio")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(.white)
                            if pairPlay.isActive {
                                Text("LIVE · \(selectedConnectedCount) OUTPUTS")
                                    .font(.system(size: 9.5, weight: .heavy))
                                    .padding(.horizontal, 7)
                                    .padding(.vertical, 3)
                                    .background(Capsule().fill(Color.green.opacity(0.22)))
                                    .foregroundStyle(.green)
                            }
                        }

                        Spacer()

                        Button {
                            pairPlay.togglePairPlay()
                        } label: {
                            HStack(spacing: 5) {
                                Image(systemName: pairPlay.isActive ? "stop.fill" : "play.fill")
                                    .font(.system(size: 10, weight: .bold))
                                Text(pairPlay.isActive ? "Stop PairPlay" : "Start PairPlay (\(selectedConnectedCount))")
                                    .font(.system(size: 11, weight: .bold))
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                Capsule().fill(
                                    pairPlay.isActive
                                        ? Color.green
                                        : (selectedConnectedCount >= 2 ? Color.cyan : Color.white.opacity(0.12))
                                )
                            )
                            .foregroundStyle(
                                pairPlay.isActive || selectedConnectedCount >= 2 ? Color.black : Color.white.opacity(0.45)
                            )
                        }
                        .buttonStyle(.plain)
                        .disabled(!pairPlay.isActive && selectedConnectedCount < 2)

                        Button {
                            systemAudio.refreshAll()
                            perAppMixer.refreshAudioProcesses()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.7))
                                .frame(width: 26, height: 26)
                                .background(Circle().fill(Color.white.opacity(0.08)))
                        }
                        .buttonStyle(.plain)
                    }

                    HStack(spacing: 6) {
                        ForEach(PairPlayStudioSection.allCases) { sec in
                            Button {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    section = sec
                                }
                                if sec == .appRouter { perAppMixer.refreshAudioProcesses() }
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: sec.icon)
                                        .font(.system(size: 11, weight: .semibold))
                                    Text(sec.rawValue)
                                        .font(.system(size: 11, weight: .semibold))
                                }
                                .padding(.horizontal, 11)
                                .padding(.vertical, 6)
                                .background(Capsule().fill(section == sec ? Color.cyan.opacity(0.22) : Color.clear))
                                .overlay(
                                    Capsule().stroke(section == sec ? Color.cyan.opacity(0.55) : Color.clear, lineWidth: 1)
                                )
                                .foregroundStyle(section == sec ? .cyan : .white.opacity(0.6))
                            }
                            .buttonStyle(.plain)
                        }
                        Spacer()
                    }
                }
                .padding(.horizontal, 18)

                if let msg = pairPlay.statusMessage {
                    HStack(spacing: 6) {
                        Image(systemName: "info.circle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.cyan)
                        Text(msg)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.85))
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.cyan.opacity(0.12)))
                    .padding(.horizontal, 18)
                }

                Divider().overlay(Color.white.opacity(0.09)).padding(.horizontal, 18)

                Group {
                    switch section {
                    case .multiOutput:
                        multiOutputSection
                    case .appRouter:
                        appRouterSection
                    case .latencySync:
                        latencySyncSection
                    case .voiceFX:
                        voiceFXSection
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .padding(.top, 32)
            .padding(.bottom, 16)
        }
        .ignoresSafeArea(.container, edges: .top)
        .preferredColorScheme(.dark)
    }

    // MARK: - 1. Multi-Output + Spatial Channel + Per-Device EQ

    private var multiOutputSection: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Select 2 or more Bluetooth or wired outputs to stream simultaneously. Customize each device's volume, Spatial Ear channel, EQ profile, and sync offset.")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.55))

                if pairableDevices.isEmpty {
                    Text("No output devices detected.")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.5))
                        .padding(.top, 24)
                } else {
                    ForEach(pairableDevices) { dev in
                        studioDeviceCard(dev)
                    }
                }
            }
            .padding(.horizontal, 18)
        }
    }

    private func studioDeviceCard(_ device: AudioOutputDevice) -> some View {
        let isSelected = pairPlay.selectedUIDs.contains(device.uid)
        let isStreaming = pairPlay.isActive && isSelected
        let vol = pairPlay.deviceVolumes[device.uid] ?? 0.75
        let isMuted = pairPlay.deviceMuted[device.uid] ?? false
        let chMode = pairPlay.deviceChannelModes[device.uid] ?? .stereo
        let eq = pairPlay.deviceEQPresets[device.uid] ?? .flat
        let delayMs = pairPlay.deviceDelayMs[device.uid] ?? 0

        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    pairPlay.toggleDeviceSelection(device)
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(isStreaming ? .green : (isSelected ? .cyan : .white.opacity(0.35)))

                        ZStack {
                            Circle()
                                .fill(isSelected ? Color.cyan.opacity(0.20) : Color.white.opacity(0.08))
                            Image(systemName: device.sfSymbol)
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(isSelected ? .cyan : .white.opacity(0.75))
                        }
                        .frame(width: 30, height: 30)

                        VStack(alignment: .leading, spacing: 1) {
                            Text(device.name)
                                .font(.system(size: 13, weight: .bold))
                                .foregroundStyle(.white)
                            Text(isStreaming ? "Streaming Live" : (isSelected ? "Ready for PairPlay" : "Click to include in PairPlay"))
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(isStreaming ? .green : (isSelected ? .cyan : .white.opacity(0.45)))
                        }

                        Spacer()
                    }
                }
                .buttonStyle(.plain)

                if delayMs > 0 {
                    Text("+\(delayMs) ms")
                        .font(.system(size: 10, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(Color.orange.opacity(0.20)))
                        .foregroundStyle(.orange)
                }
            }

            if isSelected {
                // Volume Row
                HStack(spacing: 8) {
                    Button {
                        pairPlay.toggleDeviceMute(uid: device.uid)
                    } label: {
                        Image(systemName: isMuted || vol <= 0.001 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(isMuted ? .red : .white.opacity(0.8))
                            .frame(width: 20)
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

                    Text(isMuted ? "Muted" : "\(Int(round(vol * 100)))%")
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(isMuted ? .red : .white.opacity(0.8))
                        .frame(width: 44, alignment: .trailing)
                }

                // Spatial Ear Separation + EQ Preset Row
                HStack(spacing: 8) {
                    Text("Ear / Channel:")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.55))

                    ForEach(PairPlayChannelMode.allCases) { mode in
                        let active = chMode == mode
                        Button {
                            pairPlay.setDeviceChannelMode(uid: device.uid, mode: mode)
                        } label: {
                            Text(mode.shortLabel)
                                .font(.system(size: 10, weight: .bold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Capsule().fill(active ? Color.cyan.opacity(0.24) : Color.white.opacity(0.07)))
                                .foregroundStyle(active ? .cyan : .white.opacity(0.65))
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                }

                HStack(spacing: 8) {
                    Text("Equalizer:")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.55))
                        .frame(width: 72, alignment: .leading)

                    ForEach(PairPlayEQPreset.allCases) { preset in
                        let active = eq == preset
                        Button {
                            pairPlay.setDeviceEQPreset(uid: device.uid, preset: preset)
                        } label: {
                            Text(preset.rawValue)
                                .font(.system(size: 10, weight: .bold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Capsule().fill(active ? Color.purple.opacity(0.28) : Color.white.opacity(0.07)))
                                .foregroundStyle(active ? Color(red: 0.85, green: 0.65, blue: 1.0) : .white.opacity(0.65))
                        }
                        .buttonStyle(.plain)
                    }
                    Spacer()
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(isStreaming ? Color.green.opacity(0.09) : (isSelected ? Color.cyan.opacity(0.07) : Color.white.opacity(0.04)))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(isStreaming ? Color.green.opacity(0.35) : (isSelected ? Color.cyan.opacity(0.25) : Color.white.opacity(0.06)), lineWidth: 1)
        )
    }

    // MARK: - 2. Per-App Audio Routing & Spatial Ear Isolation

    private var appRouterSection: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Route individual apps (e.g. Discord, Chrome, Spotify, Telegram) to specific headphones/speakers or isolate calls in Left/Right ear.")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.55))

                if let err = perAppMixer.permissionError {
                    HStack {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.yellow)
                        Text(err)
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.85))
                        Spacer()
                        Button("Grant") {
                            perAppMixer.openAudioPermissionSettings()
                        }
                        .font(.system(size: 10.5, weight: .bold))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.yellow))
                        .foregroundStyle(.black)
                        .buttonStyle(.plain)
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.yellow.opacity(0.12)))
                }

                if !perAppMixer.supportsPerAppMixing {
                    Text("Per-App Audio Routing requires macOS 14.2 or newer.")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.65))
                        .padding(.top, 20)
                } else if perAppMixer.apps.isEmpty {
                    Text("No active audio apps detected. Start playing audio in any app to route it.")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.55))
                        .padding(.top, 20)
                } else {
                    ForEach(perAppMixer.apps) { app in
                        appRouteCard(app)
                    }
                }
            }
            .padding(.horizontal, 18)
        }
    }

    private func appRouteCard(_ app: AudioAppSource) -> some View {
        let routedName: String = {
            guard let uid = app.targetDeviceUID else { return "System Default" }
            return systemAudio.outputDevices.first(where: { $0.uid == uid })?.name ?? "Custom Device"
        }()

        return VStack(spacing: 8) {
            HStack(spacing: 10) {
                Image(nsImage: app.icon)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: 26, height: 26)
                    .clipShape(RoundedRectangle(cornerRadius: 6))

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 5) {
                        Text(app.name)
                            .font(.system(size: 12.5, weight: .bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        if app.isRunningOutput {
                            Circle()
                                .fill(Color.green)
                                .frame(width: 6, height: 6)
                        }
                    }
                    Text("\(routedName) · \(app.channelMode.rawValue)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(app.targetDeviceUID != nil || app.channelMode != .stereo ? .cyan : .white.opacity(0.45))
                        .lineLimit(1)
                }

                Spacer()

                // Output Destination Picker Menu
                Menu {
                    Button {
                        perAppMixer.setTargetDevice(for: app.id, deviceUID: nil)
                    } label: {
                        HStack {
                            Text("System Default")
                            if app.targetDeviceUID == nil { Image(systemName: "checkmark") }
                        }
                    }
                    Divider()
                    ForEach(pairableDevices) { dev in
                        Button {
                            perAppMixer.setTargetDevice(for: app.id, deviceUID: dev.uid)
                        } label: {
                            HStack {
                                Text(dev.name)
                                if app.targetDeviceUID == dev.uid { Image(systemName: "checkmark") }
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "hifispeaker.2.fill")
                            .font(.system(size: 9.5))
                        Text(routedName)
                            .font(.system(size: 10.5, weight: .semibold))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(app.targetDeviceUID != nil ? Color.cyan.opacity(0.22) : Color.white.opacity(0.10)))
                    .foregroundStyle(app.targetDeviceUID != nil ? .cyan : .white.opacity(0.85))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                // Spatial Ear Separation Menu
                Menu {
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
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: app.channelMode.sfSymbol)
                            .font(.system(size: 9.5))
                        Text(app.channelMode.shortLabel)
                            .font(.system(size: 10.5, weight: .semibold))
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(app.channelMode != .stereo ? Color.purple.opacity(0.25) : Color.white.opacity(0.10)))
                    .foregroundStyle(app.channelMode != .stereo ? Color(red: 0.85, green: 0.65, blue: 1.0) : .white.opacity(0.85))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            HStack(spacing: 8) {
                Button {
                    perAppMixer.toggleMute(for: app.id)
                } label: {
                    Image(systemName: app.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(app.isMuted ? .red : .white.opacity(0.75))
                        .frame(width: 20)
                }
                .buttonStyle(.plain)

                Slider(
                    value: Binding(
                        get: { Double(app.isMuted ? 0 : app.volume) },
                        set: { perAppMixer.setVolume(for: app.id, volume: Float($0)) }
                    ),
                    in: 0...1
                )
                .tint(app.isRunningOutput ? .green : .cyan)

                Text("\(Int(round((app.isMuted ? 0 : app.volume) * 100)))%")
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.75))
                    .frame(width: 36, alignment: .trailing)
            }
        }
        .padding(11)
        .background(RoundedRectangle(cornerRadius: 11).fill(Color.white.opacity(app.isRunningOutput ? 0.06 : 0.035)))
    }

    // MARK: - 3. Millisecond Latency Calibration + Rhythmic Sync Test

    private var latencySyncSection: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 12) {
                // Metronome Sync Click Banner
                HStack(spacing: 12) {
                    ZStack {
                        Circle()
                            .fill(pairPlay.isSyncTestPlaying ? Color.orange.opacity(0.25) : Color.white.opacity(0.08))
                            .frame(width: 38, height: 38)
                        Image(systemName: "metronome.fill")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(pairPlay.isSyncTestPlaying ? .orange : .cyan)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Bluetooth Latency Sync Calibration")
                            .font(.system(size: 12.5, weight: .bold))
                            .foregroundStyle(.white)
                        Text("Play the rhythmic click test and delay the faster headphone/speaker until echo disappears.")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.white.opacity(0.55))
                    }

                    Spacer()

                    Button {
                        pairPlay.toggleSyncTest()
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: pairPlay.isSyncTestPlaying ? "stop.fill" : "play.fill")
                                .font(.system(size: 10, weight: .bold))
                            Text(pairPlay.isSyncTestPlaying ? "Stop Click" : "Sync Click Test")
                                .font(.system(size: 11, weight: .bold))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(pairPlay.isSyncTestPlaying ? Color.orange : Color.cyan))
                        .foregroundStyle(.black)
                    }
                    .buttonStyle(.plain)
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.06)))

                ForEach(pairableDevices.filter { pairPlay.selectedUIDs.contains($0.uid) }) { dev in
                    let delayMs = pairPlay.deviceDelayMs[dev.uid] ?? 0
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: dev.sfSymbol)
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.cyan)
                            Text(dev.name)
                                .font(.system(size: 12.5, weight: .bold))
                                .foregroundStyle(.white)
                            Spacer()
                            Text("\(delayMs) ms")
                                .font(.system(size: 12, weight: .bold, design: .monospaced))
                                .monospacedDigit()
                                .foregroundStyle(delayMs > 0 ? .orange : .white.opacity(0.65))
                            if delayMs > 0 {
                                Button("Reset") {
                                    pairPlay.setDeviceDelay(uid: dev.uid, delayMs: 0)
                                }
                                .font(.system(size: 10, weight: .bold))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(Color.white.opacity(0.12)))
                                .foregroundStyle(.white)
                                .buttonStyle(.plain)
                            }
                        }

                        HStack(spacing: 8) {
                            Button("-5ms") {
                                pairPlay.setDeviceDelay(uid: dev.uid, delayMs: max(0, delayMs - 5))
                            }
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.white.opacity(0.09)))
                            .foregroundStyle(.white.opacity(0.8))
                            .buttonStyle(.plain)

                            Slider(
                                value: Binding(
                                    get: { Double(pairPlay.deviceDelayMs[dev.uid] ?? 0) },
                                    set: { v in pairPlay.setDeviceDelay(uid: dev.uid, delayMs: Int(round(v))) }
                                ),
                                in: 0...400
                            )
                            .tint(.orange)

                            Button("+5ms") {
                                pairPlay.setDeviceDelay(uid: dev.uid, delayMs: min(400, delayMs + 5))
                            }
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.white.opacity(0.09)))
                            .foregroundStyle(.white.opacity(0.8))
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 11).fill(Color.white.opacity(0.05)))
                }

                if pairableDevices.filter({ pairPlay.selectedUIDs.contains($0.uid) }).isEmpty {
                    Text("Select devices in the Multi-Output tab first to calibrate their sync delay.")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.white.opacity(0.5))
                }
            }
            .padding(.horizontal, 18)
        }
    }

    // MARK: - 4. Real-Time Mic Voice FX & Noise Cut (PairPlay Voice Changer Integration)

    private var voiceFXSection: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Real-time hardware microphone voice effects & noise suppression across Discord, Zoom, Telegram, and games.")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.55))

                MicTabView()
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.05)))
            }
            .padding(.horizontal, 18)
        }
    }
}
