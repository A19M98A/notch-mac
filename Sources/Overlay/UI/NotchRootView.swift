import SwiftUI

struct NotchRootView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var systemAudio: SystemAudioManager
    @EnvironmentObject var mediaService: MediaRemoteService
    @EnvironmentObject var vpnService: VPNService
    @EnvironmentObject var networkMonitor: NetworkMonitorService
    @EnvironmentObject var timerService: TimerService

    private var effectiveState: NotchDisplayState {
        if appState.displayState == .idle && appState.showVolumeHUD {
            return .peek
        }
        return appState.displayState
    }

    private var notchWidth: CGFloat {
        switch effectiveState {
        case .idle:
            return NotchWindowController.idleWidth
        case .peek:
            return NotchWindowController.peekWidth
        case .expanded:
            return NotchWindowController.expandedWidth
        }
    }

    private var notchHeight: CGFloat {
        switch effectiveState {
        case .idle:
            return CGFloat(appState.prefs.idleHeight)
        case .peek:
            return NotchWindowController.peekHeight
        case .expanded:
            return CGFloat(appState.prefs.expandedHeight)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            let topR: CGFloat = effectiveState == .expanded ? 13 : (effectiveState == .peek ? 9 : 6)
            let botR: CGFloat = effectiveState == .expanded ? 24 : (effectiveState == .peek ? 14 : 8)
            let shape = NotchShape(topCornerRadius: topR, bottomCornerRadius: botR)
            let bgOpacity = effectiveState == .expanded ? appState.prefs.notchOpacity : min(0.92, appState.prefs.notchOpacity + 0.08)

            ZStack(alignment: .top) {
                shape
                    .fill(.ultraThinMaterial)
                    .overlay(
                        shape.fill(Color.black.opacity(bgOpacity))
                    )
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
                    .shadow(color: .black.opacity(effectiveState == .expanded ? 0.45 : 0.28), radius: effectiveState == .expanded ? 20 : 6, y: 4)

                switch effectiveState {
                case .idle:
                    idleContent
                        .padding(.horizontal, 14)
                        .frame(height: CGFloat(appState.prefs.idleHeight))
                        .transition(.opacity)
                case .peek:
                    collapsedContent
                        .padding(.horizontal, 16)
                        .frame(height: NotchWindowController.peekHeight)
                        .transition(.opacity)
                case .expanded:
                    expandedContent
                        .padding(.horizontal, 20)
                        .padding(.top, 10)
                        .padding(.bottom, 10)
                        .frame(width: NotchWindowController.expandedWidth, height: CGFloat(appState.prefs.expandedHeight), alignment: .top)
                        .clipped()
                        .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .top)))
                }
            }
            .frame(width: notchWidth, height: notchHeight)
            .animation(.spring(response: 0.28, dampingFraction: 0.82), value: effectiveState)
            .onTapGesture {
                if appState.displayState != .expanded {
                    appState.setDisplayState(.expanded)
                }
            }

            Spacer(minLength: 0)
        }
        .frame(width: NotchWindowController.windowWidth, height: NotchWindowController.windowHeight, alignment: .top)
        .preferredColorScheme(.dark)
    }

    // MARK: - Stage 1: Very Slim Idle Strip (Minimal Dots Only)

    private var idleContent: some View {
        HStack(spacing: 6) {
            if appState.prefs.showVPNDotInIdle && vpnService.liveStatus.connected {
                Circle()
                    .fill(Color.green)
                    .frame(width: 5, height: 5)
            }

            if mediaService.track.isPlaying {
                Circle()
                    .fill(Color.pink)
                    .frame(width: 5, height: 5)
            }

            if timerService.isActiveInNotch {
                Circle()
                    .fill(Color.orange)
                    .frame(width: 5, height: 5)
            }

            if !(appState.prefs.showVPNDotInIdle && vpnService.liveStatus.connected) && !mediaService.track.isPlaying && !timerService.isActiveInNotch {
                Capsule()
                    .fill(Color.white.opacity(0.28))
                    .frame(width: 24, height: 3)
            }
        }
    }

    // MARK: - Collapsed Live Activity Pill

    @ViewBuilder
    private var collapsedContent: some View {
        HStack(spacing: 10) {
            if appState.showVolumeHUD {
                Image(systemName: volumeSymbol)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(systemAudio.isMuted ? .red : .white)

                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.white.opacity(0.2))
                            .frame(height: 4)
                        Capsule()
                            .fill(systemAudio.isMuted ? Color.red : Color.white)
                            .frame(width: max(0, geo.size.width * CGFloat(systemAudio.isMuted ? 0 : systemAudio.volume)), height: 4)
                    }
                    .frame(maxHeight: .infinity)
                }
                .frame(height: 16)

                Text(systemAudio.isMuted ? "Muted" : "\(Int(round(systemAudio.volume * 100)))%")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.85))
                    .frame(width: 36, alignment: .trailing)
            } else {
                // Live Network Speed & Session Totals (when enabled in Settings)
                if appState.prefs.showNetworkSpeedOnHover {
                    HStack(spacing: 10) {
                    let down = networkMonitor.downSpeedParts
                    let totDown = networkMonitor.totalDownParts
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.down")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.green)
                                .frame(width: 9)
                            Text(down.value)
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .monospacedDigit()
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .frame(width: 36, alignment: .trailing)
                            Text(down.unit)
                                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.65))
                                .lineLimit(1)
                                .frame(width: 28, alignment: .leading)
                        }
                        HStack(spacing: 3) {
                            Text("Σ")
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.45))
                                .frame(width: 9)
                            Text(totDown.value)
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                .monospacedDigit()
                                .foregroundStyle(.white.opacity(0.55))
                                .lineLimit(1)
                                .frame(width: 36, alignment: .trailing)
                            Text(totDown.unit)
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.45))
                                .lineLimit(1)
                                .frame(width: 28, alignment: .leading)
                        }
                    }

                    let up = networkMonitor.upSpeedParts
                    let totUp = networkMonitor.totalUpParts
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 3) {
                            Image(systemName: "arrow.up")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.cyan)
                                .frame(width: 9)
                            Text(up.value)
                                .font(.system(size: 11, weight: .bold, design: .monospaced))
                                .monospacedDigit()
                                .foregroundStyle(.white)
                                .lineLimit(1)
                                .frame(width: 36, alignment: .trailing)
                            Text(up.unit)
                                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.65))
                                .lineLimit(1)
                                .frame(width: 28, alignment: .leading)
                        }
                        HStack(spacing: 3) {
                            Text("Σ")
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.45))
                                .frame(width: 9)
                            Text(totUp.value)
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                .monospacedDigit()
                                .foregroundStyle(.white.opacity(0.55))
                                .lineLimit(1)
                                .frame(width: 36, alignment: .trailing)
                            Text(totUp.unit)
                                .font(.system(size: 9, weight: .medium, design: .monospaced))
                                .foregroundStyle(.white.opacity(0.45))
                                .lineLimit(1)
                                .frame(width: 28, alignment: .leading)
                        }
                    }
                }
                } else {
                    HStack(spacing: 6) {
                        Image(systemName: "waveform")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.65))
                        Text("NotchPulse")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.75))
                    }
                }

                Spacer(minLength: 6)

                // Right ear: VPN shield + Timer badge + Media artwork/equalizer
                HStack(spacing: 6) {
                    if vpnService.liveStatus.connected {
                        Image(systemName: "lock.shield.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.green)
                    }

                    if timerService.isActiveInNotch {
                        HStack(spacing: 4) {
                            Circle()
                                .fill(timerService.isRunning ? Color.orange : Color.yellow)
                                .frame(width: 6, height: 6)
                            Text(timerService.formattedRemaining)
                                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                                .foregroundStyle(.orange)
                        }
                    } else if mediaService.track.hasActiveTrack {
                        if let artwork = mediaService.track.artwork {
                            Image(nsImage: artwork)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 20, height: 20)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                        }
                        EqualizerView(isPlaying: mediaService.track.isPlaying, barCount: 3, color: .green, maxHeight: 13)
                    } else if !vpnService.liveStatus.connected {
                        Image(systemName: volumeSymbol)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.white.opacity(0.55))
                    }
                }
            }
        }
    }

    // MARK: - Expanded Panel

    private var expandedContent: some View {
        VStack(spacing: 12) {
            // Header with Visible Tabs, Settings & Pin Control
            HStack(spacing: 5) {
                ForEach(appState.visibleTabs) { tab in
                    Button {
                        withAnimation(.easeInOut(duration: 0.16)) {
                            appState.selectedTab = tab
                        }
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: tab.sfSymbol)
                                .font(.system(size: 11, weight: .semibold))
                            Text(tab.rawValue)
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(
                            Capsule()
                                .fill(appState.selectedTab == tab ? Color.white.opacity(0.18) : Color.clear)
                        )
                        .foregroundStyle(appState.selectedTab == tab ? .white : .white.opacity(0.58))
                    }
                    .buttonStyle(.plain)
                }

                Spacer()

                Button {
                    appState.isPinned = false
                    appState.setDisplayState(.idle)
                    SettingsWindowController.show(appState: appState)
                } label: {
                    Image(systemName: "gearshape.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.55))
                        .padding(6)
                        .background(Circle().fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .help("Notch Settings")

                Button {
                    appState.togglePin()
                } label: {
                    Image(systemName: appState.isPinned ? "pin.fill" : "pin")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(appState.isPinned ? .orange : .white.opacity(0.55))
                        .padding(6)
                        .background(
                            Circle()
                                .fill(appState.isPinned ? Color.orange.opacity(0.18) : Color.white.opacity(0.08))
                        )
                }
                .buttonStyle(.plain)
                .help(appState.isPinned ? "Unpin notch" : "Pin notch open (⌥Space)")
            }

            Divider()
                .overlay(Color.white.opacity(0.1))

            // Active Tab Body
            Group {
                switch appState.selectedTab {
                case .media:
                    MediaTabView()
                case .mixer:
                    MixerTabView()
                case .output:
                    OutputTabView()
                case .mic:
                    MicTabView()
                case .vpn:
                    VPNTabView()
                case .timer:
                    TimerTabView()
                case .clipboard:
                    ClipboardTabView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    private var volumeSymbol: String {
        if systemAudio.isMuted || systemAudio.volume <= 0.001 {
            return "speaker.slash.fill"
        } else if systemAudio.volume < 0.35 {
            return "speaker.wave.1.fill"
        } else if systemAudio.volume < 0.7 {
            return "speaker.wave.2.fill"
        } else {
            return "speaker.wave.3.fill"
        }
    }
}
