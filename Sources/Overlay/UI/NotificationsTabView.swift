import SwiftUI

struct NotificationsTabView: View {
    @EnvironmentObject var notificationService: NotificationService
    @EnvironmentObject var appState: AppState

    private var isNotchOnly: Bool {
        appState.prefs.autoDismissMacBanner
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            alertsHeaderBar

            if isNotchOnly && !notificationService.isAccessibilityTrusted {
                accessibilityWarningBar
            }

            if notificationService.recentNotifications.isEmpty {
                emptyAlertsPlaceholder
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 6) {
                        ForEach(notificationService.recentNotifications) { notif in
                            notificationRow(notif)
                        }
                    }
                }
            }
        }
    }

    private var alertsHeaderBar: some View {
        let on = isNotchOnly
        let pillBg: Color = on ? Color.green.opacity(0.22) : Color.white.opacity(0.08)
        let pillStroke: Color = on ? Color.green.opacity(0.55) : Color.white.opacity(0.12)
        let pillFg: Color = on ? .green : Color.white.opacity(0.65)

        return HStack(spacing: 8) {
            Text("Alerts (\(notificationService.recentNotifications.count))")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(Color.white.opacity(0.75))

            Spacer()

            Button {
                let next = !appState.prefs.autoDismissMacBanner
                appState.updatePreferences { $0.autoDismissMacBanner = next }
            } label: {
                HStack(spacing: 5) {
                    Image(systemName: on ? "bell.badge.slash.fill" : "bell.badge")
                        .font(.system(size: 9.5, weight: .bold))
                    Text(on ? "Notch-Only: ON" : "Notch-Only: OFF")
                        .font(.system(size: 10, weight: .bold))
                }
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Capsule().fill(pillBg))
                .overlay(Capsule().stroke(pillStroke, lineWidth: 1))
                .foregroundColor(pillFg)
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
                    .foregroundColor(.cyan)
            }
            .buttonStyle(.plain)

            if !notificationService.recentNotifications.isEmpty {
                Button("Clear") {
                    notificationService.recentNotifications.removeAll()
                }
                .font(.system(size: 10, weight: .bold))
                .foregroundColor(Color.white.opacity(0.55))
                .buttonStyle(.plain)
            }
        }
    }

    private var accessibilityWarningBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
                .foregroundColor(.orange)
            Text("Grant Accessibility so NotchPulse can block macOS system popups instantly.")
                .font(.system(size: 10, weight: .medium))
                .foregroundColor(Color.white.opacity(0.85))
                .lineLimit(1)
            Spacer()
            Button("Grant") {
                notificationService.requestAccessibilityPermission()
            }
            .font(.system(size: 9.5, weight: .bold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Capsule().fill(Color.orange))
            .foregroundColor(.black)
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.orange.opacity(0.14)))
    }

    private var emptyAlertsPlaceholder: some View {
        VStack(spacing: 6) {
            Image(systemName: "bell.slash")
                .font(.system(size: 20))
                .foregroundColor(Color.white.opacity(0.4))
            Text("No notifications yet")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Color.white.opacity(0.55))
            Text("Incoming Telegram, Messages, Discord, and system notifications appear instantly under the Notch.")
                .font(.system(size: 10))
                .foregroundColor(Color.white.opacity(0.4))
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func notificationRow(_ notif: CapturedNotification) -> some View {
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
                    .foregroundColor(.cyan)
                    .frame(width: 24, height: 24)
            }

            Button {
                notificationService.openSourceApp(notif)
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(notif.title)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundColor(.white)
                            .lineLimit(1)
                        Text("· \(notif.appName)")
                            .font(.system(size: 10))
                            .foregroundColor(Color.white.opacity(0.45))
                            .lineLimit(1)
                        Spacer()
                        Text(relativeTime(notif.date))
                            .font(.system(size: 9, design: .monospaced))
                            .foregroundColor(Color.white.opacity(0.38))
                    }
                    if !notif.body.isEmpty {
                        Text(notif.body)
                            .font(.system(size: 11))
                            .foregroundColor(Color.white.opacity(0.75))
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
                    .foregroundColor(.cyan)
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
                    .foregroundColor(Color.white.opacity(0.45))
                    .frame(width: 20, height: 20)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.white.opacity(0.05)))
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
