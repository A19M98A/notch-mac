import SwiftUI

struct NotificationsTabView: View {
    @EnvironmentObject var notificationService: NotificationService
    @EnvironmentObject var appState: AppState

    private var isNotchOnly: Bool {
        appState.prefs.autoDismissMacBanner
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            // Header + 1-Click "Notch-Only (Hide System Popup)" Toggle + Test + Clear
            HStack(spacing: 8) {
                Text("Alerts (\(notificationService.recentNotifications.count))")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.75))

                Spacer()

                // Active / Deactive Notch-Only System Banner Blocker
                Button {
                    let next = !appState.prefs.autoDismissMacBanner
                    appState.updatePreferences { $0.autoDismissMacBanner = next }
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: isNotchOnly ? "bell.badge.slash.fill" : "bell.badge")
                            .font(.system(size: 9.5, weight: .bold))
                        Text(isNotchOnly ? "Notch-Only: ON" : "Notch-Only: OFF")
                            .font(.system(size: 10, weight: .bold))
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(
                        Capsule().fill(isNotchOnly ? Color.green.opacity(0.22) : Color.white.opacity(0.08))
                    )
                    .overlay(
                        Capsule().stroke(isNotchOnly ? Color.green.opacity(0.55) : Color.white.opacity(0.12), lineWidth: 1)
                    )
                    .foregroundStyle(isNotchOnly ? .green : .white.opacity(0.65))
                }
                .buttonStyle(.plain)
                .help("When ON, suppresses macOS top-right notification popups so alerts show ONLY in the Notch")

                Button {
                    appState.isPinned = false
                    appState.setDisplayState(.idle)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
                        notificationService.sendTestNotification()
                    }
                } label: {
                    Text("Test")
                        .font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.cyan.opacity(0.18)))
                        .foregroundStyle(.cyan)
                }
                .buttonStyle(.plain)

                if !notificationService.recentNotifications.isEmpty {
                    Button("Clear") {
                        notificationService.recentNotifications.removeAll()
                    }
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.55))
                    .buttonStyle(.plain)
                }
            }

            if isNotchOnly && !notificationService.isAccessibilityTrusted {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.orange)
                    Text("Grant Accessibility so NotchPulse can block macOS system popups instantly.")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                    Spacer()
                    Button("Grant") {
                        notificationService.requestAccessibilityPermission()
                    }
                    .font(.system(size: 9.5, weight: .bold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.orange))
                    .foregroundStyle(.black)
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.orange.opacity(0.14)))
            }

            if notificationService.recentNotifications.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "bell.slash")
                        .font(.system(size: 20))
                        .foregroundStyle(.white.opacity(0.4))
                    Text("No notifications yet")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                    Text("Incoming Telegram, Messages, Discord, and system notifications appear instantly under the Notch.")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.4))
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 6) {
                        ForEach(notificationService.recentNotifications) { notif in
                            HStack(spacing: 10) {
                                if let icon = notif.appIcon {
                                    Image(nsImage: icon)
                                        .resizable()
                                        .aspectRatio(contentMode: .fit)
                                        .frame(width: 24, height: 24)
                                        .clipShape(RoundedRectangle(cornerRadius: 6))
                                } else {
                                    Image(systemName: "bell.badge.fill")
                                        .font(.system(size: 14))
                                        .foregroundStyle(.cyan)
                                        .frame(width: 24, height: 24)
                                }

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
                                                .font(.system(size: 10))
                                                .foregroundStyle(.white.opacity(0.45))
                                                .lineLimit(1)
                                            Spacer()
                                            Text(relativeTime(notif.date))
                                                .font(.system(size: 9, design: .monospaced))
                                                .foregroundStyle(.white.opacity(0.38))
                                        }
                                        if !notif.body.isEmpty {
                                            Text(notif.body)
                                                .font(.system(size: 11))
                                                .foregroundStyle(.white.opacity(0.75))
                                                .lineLimit(1)
                                        }
                                    }
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)

                                Button {
                                    appState.isPinned = false
                                    appState.setDisplayState(.idle)
                                    notificationService.showPopup(notif)
                                    notificationService.beginReply()
                                } label: {
                                    Image(systemName: "arrowshape.turn.up.left.fill")
                                        .font(.system(size: 10, weight: .bold))
                                        .foregroundStyle(.cyan)
                                        .frame(width: 24, height: 24)
                                        .background(Circle().fill(Color.cyan.opacity(0.18)))
                                }
                                .buttonStyle(.plain)
                                .help("Quick Reply")

                                Button {
                                    notificationService.recentNotifications.removeAll { $0.id == notif.id }
                                } label: {
                                    Image(systemName: "xmark")
                                        .font(.system(size: 9, weight: .bold))
                                        .foregroundStyle(.white.opacity(0.45))
                                        .frame(width: 20, height: 20)
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.05)))
                        }
                    }
                }
            }
        }
    }

    private func relativeTime(_ date: Date) -> String {
        let sec = Int(Date().timeIntervalSince(date))
        if sec < 15 { return "now" }
        if sec < 60 { return "\(sec)s" }
        let min = sec / 60
        if min < 60 { return "\(min)m" }
        return "\(min / 60)h"
    }
}
