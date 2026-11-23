import SwiftUI

struct NotificationsTabView: View {
    @EnvironmentObject var notificationService: NotificationService
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Recent Notifications (\(notificationService.recentNotifications.count))")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.65))
                Spacer()
                if !notificationService.recentNotifications.isEmpty {
                    Button("Clear All") {
                        notificationService.recentNotifications.removeAll()
                    }
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white.opacity(0.55))
                    .buttonStyle(.plain)
                }
            }

            if notificationService.recentNotifications.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "bell.slash")
                        .font(.system(size: 20))
                        .foregroundStyle(.white.opacity(0.4))
                    Text("No notifications yet")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                    Text("Incoming Telegram, Messages, Discord, and system notifications will appear here.")
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
