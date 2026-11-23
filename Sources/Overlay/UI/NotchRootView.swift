import SwiftUI

struct NotchRootView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var systemAudio: SystemAudioManager
    @EnvironmentObject var mediaService: MediaRemoteService
    @EnvironmentObject var notificationService: NotificationService
    @EnvironmentObject var vpnService: VPNService
    @EnvironmentObject var networkMonitor: NetworkMonitorService
    @EnvironmentObject var timerService: TimerService

    @State private var alarmPulse: Bool = false

    private var activeMediaColor: Color {
        if let hex = mediaService.activeSession?.accentHex {
            let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
            if cleaned.count == 6, let rgb = UInt64(cleaned, radix: 16) {
                return Color(
                    red: Double((rgb >> 16) & 0xFF) / 255.0,
                    green: Double((rgb >> 8) & 0xFF) / 255.0,
                    blue: Double(rgb & 0xFF) / 255.0
                )
            }
        }
        return .green
    }

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

            // Persistent Timer Alarm Popup (stays until user reacts with Stop / +5m / Restart!)
            if timerService.isAlarmRinging && appState.displayState != .expanded {
                timerAlarmPopupCard
                    .padding(.top, 8)
                    .transition(.asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity).combined(with: .scale(scale: 0.90, anchor: .top)),
                        removal: .move(edge: .top).combined(with: .opacity)
                    ))
            } else if let notif = notificationService.activePopup, appState.displayState != .expanded {
                // Under-Notch Notification Popup (auto-disappears after 3s unless hovered or replying)
                notificationPopupCard(notif)
                    .padding(.top, 8)
                    .transition(.asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity).combined(with: .scale(scale: 0.92, anchor: .top)),
                        removal: .move(edge: .top).combined(with: .opacity)
                    ))
            }

            Spacer(minLength: 0)
        }
        .animation(.spring(response: 0.30, dampingFraction: 0.80), value: notificationService.activePopup?.id)
        .animation(.spring(response: 0.30, dampingFraction: 0.80), value: timerService.isAlarmRinging)
        .animation(.spring(response: 0.25, dampingFraction: 0.82), value: notificationService.isReplying)
        .frame(width: NotchWindowController.windowWidth, height: NotchWindowController.windowHeight, alignment: .top)
        .preferredColorScheme(.dark)
    }

    // MARK: - Persistent Timer Alarm Popup (Requires User Reaction + Pulsing Glow Effect)

    private var timerAlarmPopupCard: some View {
        let cardShape = RoundedRectangle(cornerRadius: 18, style: .continuous)

        return HStack(spacing: 12) {
            ZStack {
                Circle()
                    .fill(Color.orange.opacity(alarmPulse ? 0.38 : 0.16))
                    .frame(width: 38, height: 38)
                    .scaleEffect(alarmPulse ? 1.15 : 0.95)
                Image(systemName: "bell.and.waves.left.and.right.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.orange)
                    .rotationEffect(.degrees(alarmPulse ? 10 : -10))
            }
            .animation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true), value: alarmPulse)
            .onAppear { alarmPulse = true }
            .onDisappear { alarmPulse = false }

            VStack(alignment: .leading, spacing: 2) {
                Text("Time's Up!")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                Text("\(timerService.label) finished")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.orange.opacity(0.9))
                    .lineLimit(1)
            }

            Spacer(minLength: 4)

            HStack(spacing: 6) {
                Button {
                    timerService.snooze(minutes: 5)
                } label: {
                    Text("+5m")
                        .font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.white.opacity(0.14)))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)

                Button {
                    timerService.restartTimer()
                } label: {
                    Image(systemName: "arrow.counterclockwise")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.cyan)
                        .frame(width: 26, height: 26)
                        .background(Circle().fill(Color.cyan.opacity(0.20)))
                }
                .buttonStyle(.plain)
                .help("Restart Timer")

                Button {
                    timerService.dismissAlarm()
                } label: {
                    Text("Stop")
                        .font(.system(size: 11, weight: .bold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.orange))
                        .foregroundStyle(.black)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(width: 386)
        .background(
            cardShape
                .fill(.ultraThinMaterial)
                .overlay(cardShape.fill(Color.black.opacity(appState.prefs.notchOpacity)))
                .overlay(
                    cardShape.stroke(
                        LinearGradient(
                            colors: [Color.orange.opacity(alarmPulse ? 0.85 : 0.35), Color.yellow.opacity(0.25)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1.5
                    )
                )
                .shadow(color: Color.orange.opacity(alarmPulse ? 0.45 : 0.18), radius: 16, y: 4)
        )
    }

    // MARK: - Under-Notch Notification Popup

    private func notificationPopupCard(_ notif: CapturedNotification) -> some View {
        let cardShape = RoundedRectangle(cornerRadius: 18, style: .continuous)

        return VStack(spacing: 8) {
            HStack(spacing: 10) {
                // App icon
                ZStack {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(Color.white.opacity(0.08))
                    if let icon = notif.appIcon {
                        Image(nsImage: icon)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 28, height: 28)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    } else {
                        Image(systemName: "bell.badge.fill")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.cyan)
                    }
                }
                .frame(width: 34, height: 34)

                // Title & Message Body (tap to open conversation)
                Button {
                    notificationService.openSourceApp(notif)
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 5) {
                            Text(notif.title)
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                            Text("· \(notif.appName)")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.white.opacity(0.5))
                                .lineLimit(1)
                        }
                        if !notif.body.isEmpty {
                            Text(notif.body)
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(0.82))
                                .lineLimit(2)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                // Quick Reaction Pills: Reply, Read, Dismiss
                HStack(spacing: 5) {
                    Button {
                        notificationService.beginReply()
                    } label: {
                        Image(systemName: "arrowshape.turn.up.left.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.cyan)
                            .frame(width: 24, height: 24)
                            .background(Circle().fill(Color.cyan.opacity(0.20)))
                    }
                    .buttonStyle(.plain)
                    .help("Reply")

                    Button {
                        notificationService.markAsRead(notif)
                    } label: {
                        Image(systemName: "checkmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.green)
                            .frame(width: 24, height: 24)
                            .background(Circle().fill(Color.green.opacity(0.20)))
                    }
                    .buttonStyle(.plain)
                    .help("Mark as Read")

                    Button {
                        notificationService.dismissPopup(alsoDismissSystemBanner: true)
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white.opacity(0.6))
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(Color.white.opacity(0.09)))
                    }
                    .buttonStyle(.plain)
                    .help("Dismiss")
                }
            }

            // Inline Quick-Reply Composer (expands smoothly when Reply is clicked)
            if notificationService.isReplying {
                HStack(spacing: 8) {
                    TextField("Reply to \(notif.title)…", text: $notificationService.replyText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 9).fill(Color.black.opacity(0.55)))
                        .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.cyan.opacity(0.45), lineWidth: 1))
                        .onSubmit {
                            notificationService.sendReply(for: notif, message: notificationService.replyText)
                        }

                    Button {
                        notificationService.sendReply(for: notif, message: notificationService.replyText)
                    } label: {
                        Image(systemName: "paperplane.fill")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(.black)
                            .frame(width: 28, height: 28)
                            .background(Circle().fill(Color.cyan))
                    }
                    .buttonStyle(.plain)
                    .disabled(notificationService.replyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: 386)
        .background(
            cardShape
                .fill(.ultraThinMaterial)
                .overlay(cardShape.fill(Color.black.opacity(appState.prefs.notchOpacity)))
                .overlay(
                    cardShape.stroke(
                        LinearGradient(
                            colors: [Color.white.opacity(0.20), Color.white.opacity(0.06)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
                )
                .shadow(color: .black.opacity(0.45), radius: 14, y: 6)
        )
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
                    .fill(activeMediaColor)
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
                        EqualizerView(isPlaying: mediaService.track.isPlaying, barCount: 3, color: activeMediaColor, maxHeight: 13)
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
            HStack(spacing: 3) {
                ForEach(appState.visibleTabs) { tab in
                    Button {
                        withAnimation(.easeInOut(duration: 0.16)) {
                            appState.selectedTab = tab
                        }
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: tab.sfSymbol)
                                .font(.system(size: 10, weight: .semibold))
                            Text(tab.rawValue)
                                .font(.system(size: 10.5, weight: .semibold))
                                .lineLimit(1)
                                .fixedSize(horizontal: true, vertical: false)
                        }
                        .padding(.horizontal, 7)
                        .padding(.vertical, 5)
                        .background(
                            Capsule()
                                .fill(appState.selectedTab == tab ? Color.white.opacity(0.18) : Color.clear)
                        )
                        .foregroundStyle(appState.selectedTab == tab ? .white : .white.opacity(0.58))
                    }
                    .buttonStyle(.plain)
                }

                Spacer(minLength: 4)

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
                case .notifications:
                    NotificationsTabView()
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
