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
                studioHeaderSection
                    .padding(.horizontal, 18)

                if let msg = pairPlay.statusMessage {
                    statusBanner(msg)
                        .padding(.horizontal, 18)
                }

                Divider().overlay(Color.white.opacity(0.09)).padding(.horizontal, 18)

                sectionContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .padding(.top, 32)
            .padding(.bottom, 16)
        }
        .ignoresSafeArea(.container, edges: .top)
        .preferredColorScheme(.dark)
    }

    // MARK: - Header & Navigation

    private var studioHeaderSection: some View {
        let canStart = pairPlay.isActive || selectedConnectedCount >= 2
        let actionBg: Color = pairPlay.isActive ? .green : (selectedConnectedCount >= 2 ? .cyan : Color.white.opacity(0.12))
        let actionFg: Color = canStart ? .black : Color.white.opacity(0.45)

        return VStack(spacing: 10) {
            HStack {
                HStack(spacing: 8) {
                    Image(systemName: "person.2.wave.2.fill")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundColor(.cyan)
                    Text("PairPlay Audio Studio")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundColor(.white)
                    if pairPlay.isActive {
                        Text("LIVE · \(selectedConnectedCount) OUTPUTS")
                            .font(.system(size: 9.5, weight: .heavy))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.green.opacity(0.22)))
                            .foregroundColor(.green)
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
                    .background(Capsule().fill(actionBg))
                    .foregroundColor(actionFg)
                }
                .buttonStyle(.plain)
                .disabled(!canStart)

                Button {
                    systemAudio.refreshAll()
                    perAppMixer.refreshAudioProcesses()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Color.white.opacity(0.7))
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 6) {
                ForEach(PairPlayStudioSection.allCases) { sec in
                    sectionTabPill(sec)
                }
                Spacer()
            }
        }
    }

    private func sectionTabPill(_ sec: PairPlayStudioSection) -> some View {
        let isSelected = section == sec
        let bg: Color = isSelected ? Color.cyan.opacity(0.22) : .clear
        let stroke: Color = isSelected ? Color.cyan.opacity(0.55) : .clear
        let fg: Color = isSelected ? .cyan : Color.white.opacity(0.6)

        return Button {
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
            .background(Capsule().fill(bg))
            .overlay(Capsule().stroke(stroke, lineWidth: 1))
            .foregroundColor(fg)
        }
        .buttonStyle(.plain)
    }

    private func statusBanner(_ msg: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "info.circle.fill")
                .font(.system(size: 11))
                .foregroundColor(.cyan)
            Text(msg)
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Color.white.opacity(0.85))
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.cyan.opacity(0.12)))
    }

    @ViewBuilder
    private var sectionContent: some View {
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

    // MARK: - 1. Multi-Output + Spatial Channel + Per-Device EQ

    private var multiOutputSection: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Select 2 or more Bluetooth or wired outputs to stream simultaneously. Customize each device's volume, Spatial Ear channel, EQ profile, and sync offset.")
                    .font(.system(size: 11))
                    .foregroundColor(Color.white.opacity(0.55))

                if pairableDevices.isEmpty {
                    Text("No output devices detected.")
                        .font(.system(size: 12))
                        .foregroundColor(Color.white.opacity(0.5))
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
        let cardFill: Color = isStreaming ? Color.green.opacity(0.09) : (isSelected ? Color.cyan.opacity(0.07) : Color.white.opacity(0.04))
        let cardStroke: Color = isStreaming ? Color.green.opacity(0.35) : (isSelected ? Color.cyan.opacity(0.25) : Color.white.opacity(0.06))

        return VStack(alignment: .leading, spacing: 10) {
            studioDeviceHeaderRow(device, isSelected: isSelected, isStreaming: isStreaming)

            if isSelected {
                studioDeviceVolumeRow(device, isStreaming: isStreaming)
                studioDeviceChannelRow(device)
                studioDeviceEQRow(device)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(cardFill))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(cardStroke, lineWidth: 1))
    }

    private func studioDeviceHeaderRow(_ device: AudioOutputDevice, isSelected: Bool, isStreaming: Bool) -> some View {
        let delayMs = pairPlay.deviceDelayMs[device.uid] ?? 0
        let checkColor: Color = isStreaming ? .green : (isSelected ? .cyan : Color.white.opacity(0.35))
        let iconBg: Color = isSelected ? Color.cyan.opacity(0.20) : Color.white.opacity(0.08)
        let iconFg: Color = isSelected ? .cyan : Color.white.opacity(0.75)
        let subtitle: String = isStreaming ? "Streaming Live" : (isSelected ? "Ready for PairPlay" : "Click to include in PairPlay")
        let subColor: Color = isStreaming ? .green : (isSelected ? .cyan : Color.white.opacity(0.45))

        return HStack(spacing: 10) {
            Button {
                pairPlay.toggleDeviceSelection(device)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundColor(checkColor)

                    ZStack {
                        Circle().fill(iconBg)
                        Image(systemName: device.sfSymbol)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundColor(iconFg)
                    }
                    .frame(width: 30, height: 30)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(device.name)
                            .font(.system(size: 13, weight: .bold))
                            .foregroundColor(.white)
                        Text(subtitle)
                            .font(.system(size: 10, weight: .medium))
                            .foregroundColor(subColor)
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
                    .foregroundColor(.orange)
            }
        }
    }

    private func studioDeviceVolumeRow(_ device: AudioOutputDevice, isStreaming: Bool) -> some View {
        let vol = pairPlay.deviceVolumes[device.uid] ?? 0.75
        let isMuted = pairPlay.deviceMuted[device.uid] ?? false
        let muteColor: Color = isMuted ? .red : Color.white.opacity(0.8)
        let sliderTint: Color = isStreaming ? .green : .cyan

        return HStack(spacing: 8) {
            Button {
                pairPlay.toggleDeviceMute(uid: device.uid)
            } label: {
                Image(systemName: isMuted || vol <= 0.001 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(muteColor)
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
            .tint(sliderTint)

            Text(isMuted ? "Muted" : "\(Int(round(vol * 100)))%")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .foregroundColor(muteColor)
                .frame(width: 44, alignment: .trailing)
        }
    }

    private func studioDeviceChannelRow(_ device: AudioOutputDevice) -> some View {
        let current = pairPlay.deviceChannelModes[device.uid] ?? .stereo

        return HStack(spacing: 8) {
            Text("Ear / Channel:")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundColor(Color.white.opacity(0.55))

            ForEach(PairPlayChannelMode.allCases) { mode in
                let active = current == mode
                let bg: Color = active ? Color.cyan.opacity(0.24) : Color.white.opacity(0.07)
                let fg: Color = active ? .cyan : Color.white.opacity(0.65)
                Button {
                    pairPlay.setDeviceChannelMode(uid: device.uid, mode: mode)
                } label: {
                    Text(mode.shortLabel)
                        .font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(bg))
                        .foregroundColor(fg)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }

    private func studioDeviceEQRow(_ device: AudioOutputDevice) -> some View {
        let current = pairPlay.deviceEQPresets[device.uid] ?? .flat
        let activePurple = Color(red: 0.85, green: 0.65, blue: 1.0)

        return HStack(spacing: 8) {
            Text("Equalizer:")
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundColor(Color.white.opacity(0.55))
                .frame(width: 72, alignment: .leading)

            ForEach(PairPlayEQPreset.allCases) { preset in
                let active = current == preset
                let bg: Color = active ? Color.purple.opacity(0.28) : Color.white.opacity(0.07)
                let fg: Color = active ? activePurple : Color.white.opacity(0.65)
                Button {
                    pairPlay.setDeviceEQPreset(uid: device.uid, preset: preset)
                } label: {
                    Text(preset.rawValue)
                        .font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(bg))
                        .foregroundColor(fg)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }

    // MARK: - 2. Per-App Audio Routing & Spatial Ear Isolation

    private var appRouterSection: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Route individual apps (e.g. Discord, Chrome, Spotify, Telegram) to specific headphones/speakers or isolate calls in Left/Right ear.")
                    .font(.system(size: 11))
                    .foregroundColor(Color.white.opacity(0.55))

                if let err = perAppMixer.permissionError {
                    permissionWarningRow(err)
                }

                if !perAppMixer.supportsPerAppMixing {
                    Text("Per-App Audio Routing requires macOS 14.2 or newer.")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(Color.white.opacity(0.65))
                        .padding(.top, 20)
                } else if perAppMixer.apps.isEmpty {
                    Text("No active audio apps detected. Start playing audio in any app to route it.")
                        .font(.system(size: 12))
                        .foregroundColor(Color.white.opacity(0.55))
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

    private func permissionWarningRow(_ err: String) -> some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundColor(.yellow)
            Text(err)
                .font(.system(size: 11))
                .foregroundColor(Color.white.opacity(0.85))
            Spacer()
            Button("Grant") {
                perAppMixer.openAudioPermissionSettings()
            }
            .font(.system(size: 10.5, weight: .bold))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(Capsule().fill(Color.yellow))
            .foregroundColor(.black)
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.yellow.opacity(0.12)))
    }

    private func appRouteCard(_ app: AudioAppSource) -> some View {
        let routedName: String = {
            guard let uid = app.targetDeviceUID else { return "System Default" }
            return systemAudio.outputDevices.first(where: { $0.uid == uid })?.name ?? "Custom Device"
        }()
        let hasCustom = app.targetDeviceUID != nil || app.channelMode != .stereo
        let subColor: Color = hasCustom ? .cyan : Color.white.opacity(0.45)
        let cardBg: Color = Color.white.opacity(app.isRunningOutput ? 0.06 : 0.035)

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
                            .foregroundColor(.white)
                            .lineLimit(1)
                        if app.isRunningOutput {
                            Circle()
                                .fill(Color.green)
                                .frame(width: 6, height: 6)
                        }
                    }
                    Text("\(routedName) · \(app.channelMode.rawValue)")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(subColor)
                        .lineLimit(1)
                }

                Spacer()

                appDestinationMenu(app, routedName: routedName)
                appChannelMenu(app)
            }

            appVolumeSliderRow(app)
        }
        .padding(11)
        .background(RoundedRectangle(cornerRadius: 11).fill(cardBg))
    }

    private func appDestinationMenu(_ app: AudioAppSource, routedName: String) -> some View {
        let custom = app.targetDeviceUID != nil
        let bg: Color = custom ? Color.cyan.opacity(0.22) : Color.white.opacity(0.10)
        let fg: Color = custom ? .cyan : Color.white.opacity(0.85)

        return Menu {
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
            .background(Capsule().fill(bg))
            .foregroundColor(fg)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func appChannelMenu(_ app: AudioAppSource) -> some View {
        let custom = app.channelMode != .stereo
        let bg: Color = custom ? Color.purple.opacity(0.25) : Color.white.opacity(0.10)
        let fg: Color = custom ? Color(red: 0.85, green: 0.65, blue: 1.0) : Color.white.opacity(0.85)

        return Menu {
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
            .background(Capsule().fill(bg))
            .foregroundColor(fg)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func appVolumeSliderRow(_ app: AudioAppSource) -> some View {
        let muteColor: Color = app.isMuted ? .red : Color.white.opacity(0.75)
        let sliderTint: Color = app.isRunningOutput ? .green : .cyan

        return HStack(spacing: 8) {
            Button {
                perAppMixer.toggleMute(for: app.id)
            } label: {
                Image(systemName: app.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    .font(.system(size: 11))
                    .foregroundColor(muteColor)
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
            .tint(sliderTint)

            Text("\(Int(round((app.isMuted ? 0 : app.volume) * 100)))%")
                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .foregroundColor(Color.white.opacity(0.75))
                .frame(width: 36, alignment: .trailing)
        }
    }

    // MARK: - 3. Millisecond Latency Calibration + Rhythmic Sync Test

    private var latencySyncSection: some View {
        let activeDevices = pairableDevices.filter { pairPlay.selectedUIDs.contains($0.uid) }

        return ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 12) {
                syncMetronomeBanner

                ForEach(activeDevices) { dev in
                    latencyDeviceRow(dev)
                }

                if activeDevices.isEmpty {
                    Text("Select devices in the Multi-Output tab first to calibrate their sync delay.")
                        .font(.system(size: 11.5))
                        .foregroundColor(Color.white.opacity(0.5))
                }
            }
            .padding(.horizontal, 18)
        }
    }

    private var syncMetronomeBanner: some View {
        let playing = pairPlay.isSyncTestPlaying
        let circleBg: Color = playing ? Color.orange.opacity(0.25) : Color.white.opacity(0.08)
        let iconFg: Color = playing ? .orange : .cyan
        let btnBg: Color = playing ? .orange : .cyan

        return HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(circleBg)
                    .frame(width: 38, height: 38)
                Image(systemName: "metronome.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(iconFg)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Bluetooth Latency Sync Calibration")
                    .font(.system(size: 12.5, weight: .bold))
                    .foregroundColor(.white)
                Text("Play the rhythmic click test and delay the faster headphone/speaker until echo disappears.")
                    .font(.system(size: 10.5))
                    .foregroundColor(Color.white.opacity(0.55))
            }

            Spacer()

            Button {
                pairPlay.toggleSyncTest()
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: playing ? "stop.fill" : "play.fill")
                        .font(.system(size: 10, weight: .bold))
                    Text(playing ? "Stop Click" : "Sync Click Test")
                        .font(.system(size: 11, weight: .bold))
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(btnBg))
                .foregroundColor(.black)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.06)))
    }

    private func latencyDeviceRow(_ dev: AudioOutputDevice) -> some View {
        let delayMs = pairPlay.deviceDelayMs[dev.uid] ?? 0
        let readoutColor: Color = delayMs > 0 ? .orange : Color.white.opacity(0.65)

        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Image(systemName: dev.sfSymbol)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.cyan)
                Text(dev.name)
                    .font(.system(size: 12.5, weight: .bold))
                    .foregroundColor(.white)
                Spacer()
                Text("\(delayMs) ms")
                    .font(.system(size: 12, weight: .bold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundColor(readoutColor)
                if delayMs > 0 {
                    Button("Reset") {
                        pairPlay.setDeviceDelay(uid: dev.uid, delayMs: 0)
                    }
                    .font(.system(size: 10, weight: .bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.white.opacity(0.12)))
                    .foregroundColor(.white)
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
                .foregroundColor(Color.white.opacity(0.8))
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
                .foregroundColor(Color.white.opacity(0.8))
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 11).fill(Color.white.opacity(0.05)))
    }

    // MARK: - 4. Real-Time Mic Voice FX & Noise Cut

    private var voiceFXSection: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Real-time hardware microphone voice effects & noise suppression across Discord, Zoom, Telegram, and games.")
                    .font(.system(size: 11))
                    .foregroundColor(Color.white.opacity(0.55))

                MicTabView()
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.05)))
            }
            .padding(.horizontal, 18)
        }
    }
}
