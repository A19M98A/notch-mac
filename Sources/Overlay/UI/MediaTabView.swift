import SwiftUI

struct MediaTabView: View {
    @EnvironmentObject var mediaService: MediaRemoteService
    @EnvironmentObject var systemAudio: SystemAudioManager
    @EnvironmentObject var perAppMixer: PerAppAudioMixer
    @EnvironmentObject var appState: AppState

    private var activeSession: MediaSession? {
        mediaService.activeSession
    }

    private var accentColor: Color {
        if let hex = activeSession?.accentHex {
            return colorFromHex(hex)
        }
        return .pink
    }

    var body: some View {
        VStack(spacing: 8) {
            // 1. Multi-Source Switcher Strip (shows all active sources: YouTube, SoundCloud, Telegram, Spotify, Music...)
            if !mediaService.sessions.isEmpty {
                HStack(spacing: 6) {
                    if mediaService.playingCount > 1 {
                        Text("\(mediaService.playingCount) LIVE")
                            .font(.system(size: 8, weight: .black, design: .monospaced))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.green.opacity(0.24)))
                            .foregroundStyle(.green)
                    }

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(mediaService.sessions) { session in
                                let isSelected = activeSession?.id == session.id
                                let tint = colorFromHex(session.accentHex)

                                Button {
                                    withAnimation(.easeInOut(duration: 0.15)) {
                                        mediaService.selectSession(session)
                                    }
                                } label: {
                                    HStack(spacing: 5) {
                                        if let icon = session.appIcon {
                                            Image(nsImage: icon)
                                                .resizable()
                                                .aspectRatio(contentMode: .fit)
                                                .frame(width: 13, height: 13)
                                                .clipShape(RoundedRectangle(cornerRadius: 3))
                                        }

                                        Text(session.sourceName)
                                            .font(.system(size: 10, weight: isSelected ? .bold : .semibold))
                                            .foregroundStyle(isSelected ? .white : .white.opacity(0.7))
                                            .lineLimit(1)

                                        if session.isPlaying {
                                            Circle()
                                                .fill(Color.green)
                                                .frame(width: 5, height: 5)
                                        }
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(
                                        Capsule()
                                            .fill(isSelected ? tint.opacity(0.28) : Color.white.opacity(0.07))
                                            .overlay(
                                                Capsule()
                                                    .stroke(isSelected ? tint.opacity(0.65) : Color.white.opacity(0.08), lineWidth: 1)
                                            )
                                    )
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }

                    Button {
                        mediaService.refreshNowPlaying()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.55))
                            .frame(width: 20, height: 20)
                            .background(Circle().fill(Color.white.opacity(0.07)))
                    }
                    .buttonStyle(.plain)
                    .help("Refresh media sources")
                }
            }

            // 2. Hero Now Playing Deck
            HStack(spacing: 12) {
                // Artwork with subtle source-colored ambient glow & mini app badge
                ZStack(alignment: .bottomTrailing) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [accentColor.opacity(0.45), Color.black.opacity(0.6)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )

                        if let art = activeSession?.artwork ?? mediaService.track.artwork {
                            Image(nsImage: art)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                        } else if let appIcon = activeSession?.appIcon {
                            Image(nsImage: appIcon)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                                .padding(10)
                        } else {
                            Image(systemName: "music.note")
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.85))
                        }
                    }
                    .frame(width: 56, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .stroke(accentColor.opacity(0.35), lineWidth: 1)
                    )
                    .shadow(color: accentColor.opacity(activeSession?.isPlaying == true ? 0.35 : 0.12), radius: 10)

                    if let icon = activeSession?.appIcon, activeSession?.artwork != nil {
                        Image(nsImage: icon)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(width: 18, height: 18)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                            .shadow(radius: 2)
                            .offset(x: 3, y: 3)
                    }
                }

                // Track Metadata + Interactive Scrubber
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(activeSession?.title ?? mediaService.track.title)
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)

                        Spacer(minLength: 4)

                        if let session = activeSession {
                            // Focus / Jump to App or Browser Tab
                            Button {
                                mediaService.focusSession(session)
                            } label: {
                                Image(systemName: "arrow.up.forward.square")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.6))
                            }
                            .buttonStyle(.plain)
                            .help("Focus \(session.sourceName)")

                            // Quick per-app mute if available in CoreAudio Mixer
                            if let pid = session.pid,
                               let mixerApp = perAppMixer.apps.first(where: { $0.pid == pid }) {
                                Button {
                                    perAppMixer.toggleMute(for: mixerApp.id)
                                } label: {
                                    Image(systemName: mixerApp.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(mixerApp.isMuted ? .red : .white.opacity(0.65))
                                }
                                .buttonStyle(.plain)
                                .help(mixerApp.isMuted ? "Unmute \(session.sourceName)" : "Mute \(session.sourceName)")
                            }
                        }
                    }

                    Text(activeSession?.artist ?? mediaService.track.artist)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.white.opacity(0.6))
                        .lineLimit(1)

                    // Interactive Scrubber (when duration > 0) or Live Audio indicator
                    if let s = activeSession, s.duration > 0 {
                        VStack(spacing: 2) {
                            GeometryReader { geo in
                                ZStack(alignment: .leading) {
                                    Capsule()
                                        .fill(Color.white.opacity(0.15))
                                        .frame(height: 4)
                                    Capsule()
                                        .fill(accentColor)
                                        .frame(
                                            width: max(0, geo.size.width * CGFloat(min(1, s.elapsed / max(1, s.duration)))),
                                            height: 4
                                        )
                                }
                                .contentShape(Rectangle())
                                .gesture(
                                    DragGesture(minimumDistance: 0)
                                        .onEnded { value in
                                            let ratio = max(0, min(1, value.location.x / max(1, geo.size.width)))
                                            mediaService.seek(to: s.duration * Double(ratio), for: s)
                                        }
                                )
                            }
                            .frame(height: 8)
                            .padding(.top, 2)

                            HStack {
                                Text(formatTime(s.elapsed))
                                Spacer()
                                Text("-\(formatTime(max(0, s.duration - s.elapsed)))")
                            }
                            .font(.system(size: 9, weight: .medium, design: .monospaced))
                            .monospacedDigit()
                            .foregroundStyle(.white.opacity(0.45))
                        }
                    } else if let s = activeSession {
                        HStack(spacing: 6) {
                            Circle()
                                .fill(s.isPlaying ? accentColor : Color.white.opacity(0.3))
                                .frame(width: 5, height: 5)
                            Text(s.isPlaying ? "Live Source · \(s.sourceName)" : "Paused · \(s.sourceName)")
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(.white.opacity(0.5))
                        }
                        .padding(.top, 4)
                    }
                }

                EqualizerView(
                    isPlaying: activeSession?.isPlaying ?? mediaService.track.isPlaying,
                    barCount: 4,
                    color: accentColor,
                    maxHeight: 20
                )
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(Color.white.opacity(0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .stroke(accentColor.opacity(0.18), lineWidth: 1)
                    )
            )

            // 3. Bottom Transport Controls + Master Volume Row
            HStack(spacing: 12) {
                // Transport cluster
                HStack(spacing: 10) {
                    Button {
                        mediaService.previousTrack(for: activeSession)
                    } label: {
                        Image(systemName: "backward.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 30, height: 30)
                            .background(Circle().fill(Color.white.opacity(0.10)))
                    }
                    .buttonStyle(.plain)

                    Button {
                        mediaService.togglePlayPause(for: activeSession)
                    } label: {
                        Image(systemName: (activeSession?.isPlaying ?? mediaService.track.isPlaying) ? "pause.fill" : "play.fill")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(.black)
                            .frame(width: 36, height: 36)
                            .background(Circle().fill(Color.white))
                    }
                    .buttonStyle(.plain)

                    Button {
                        mediaService.nextTrack(for: activeSession)
                    } label: {
                        Image(systemName: "forward.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 30, height: 30)
                            .background(Circle().fill(Color.white.opacity(0.10)))
                    }
                    .buttonStyle(.plain)
                }

                Divider()
                    .frame(height: 22)
                    .overlay(Color.white.opacity(0.12))

                // Master Volume Slider
                Button {
                    systemAudio.toggleMute()
                } label: {
                    Image(systemName: systemAudio.isMuted || systemAudio.volume <= 0.001 ? "speaker.slash.fill" : "speaker.wave.2.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(systemAudio.isMuted ? .red : .white.opacity(0.85))
                        .frame(width: 20)
                }
                .buttonStyle(.plain)

                Slider(
                    value: Binding(
                        get: { Double(systemAudio.isMuted ? 0 : systemAudio.volume) },
                        set: { systemAudio.setVolume(Float($0)) }
                    ),
                    in: 0...1
                )
                .tint(.white)

                Text("\(Int(round((systemAudio.isMuted ? 0 : systemAudio.volume) * 100)))%")
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 32, alignment: .trailing)

                Button {
                    appState.selectedTab = .mixer
                } label: {
                    HStack(spacing: 3) {
                        Image(systemName: "slider.vertical.3")
                        Text("Mix")
                    }
                    .font(.system(size: 10, weight: .bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Color.white.opacity(0.12)))
                    .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule()
                    .fill(Color.white.opacity(0.06))
            )
        }
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite && seconds >= 0 else { return "0:00" }
        let total = Int(seconds)
        let mins = total / 60
        let secs = total % 60
        return String(format: "%d:%02d", mins, secs)
    }

    private func colorFromHex(_ hex: String) -> Color {
        let cleaned = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        guard cleaned.count == 6, let rgb = UInt64(cleaned, radix: 16) else { return .pink }
        return Color(
            red: Double((rgb >> 16) & 0xFF) / 255.0,
            green: Double((rgb >> 8) & 0xFF) / 255.0,
            blue: Double(rgb & 0xFF) / 255.0
        )
    }
}
