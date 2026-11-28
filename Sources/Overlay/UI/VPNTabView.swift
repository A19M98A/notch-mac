import SwiftUI

struct VPNTabView: View {
    @EnvironmentObject var vpnService: VPNService
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 8) {
            // Compact Live Status Bar
            HStack(spacing: 10) {
                Circle()
                    .fill(vpnService.liveStatus.connected ? Color.green : Color.white.opacity(0.3))
                    .frame(width: 8, height: 8)

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(vpnService.liveStatus.connected ? vpnService.liveStatus.providerLabel : "VPN Disconnected")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                            .lineLimit(1)

                        if !vpnService.liveStatus.iface.isEmpty {
                            Text(vpnService.liveStatus.iface)
                                .font(.system(size: 9, weight: .semibold, design: .monospaced))
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Capsule().fill(Color.green.opacity(0.20)))
                                .foregroundStyle(.green)
                        }
                    }

                    Text("\(vpnService.store.mode.shortTitle) · \(vpnService.activeRules.filter { $0.enabled }.count) rules")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.5))
                }

                Spacer()

                HStack(spacing: 6) {
                    if vpnService.liveStatus.connected {
                        Button {
                            vpnService.disconnectActive()
                        } label: {
                            Text("Disconnect")
                                .font(.system(size: 10, weight: .bold))
                                .padding(.horizontal, 9)
                                .padding(.vertical, 4)
                                .background(Capsule().fill(Color.red.opacity(0.24)))
                                .foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                        .disabled(vpnService.isBusy)
                    }

                    Button {
                        appState.isPinned = false
                        appState.setDisplayState(.idle)
                        VPNConfigWindowController.show(vpnService: vpnService)
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "plus")
                                .font(.system(size: 10, weight: .bold))
                            Text("Manage")
                                .font(.system(size: 10, weight: .bold))
                        }
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.white.opacity(0.15)))
                        .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)

                    Button {
                        vpnService.refreshBypassAndIPs()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(vpnService.isRefreshingBypass ? .orange : .green)
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(Color.white.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                    .disabled(vpnService.isRefreshingBypass)
                    .help("Refresh DNS & reload bypass IPs")

                    Button {
                        vpnService.pingAllServers()
                    } label: {
                        Image(systemName: "speedometer")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(vpnService.isPinging ? .orange : .cyan)
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(Color.white.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                    .help("Ping all servers")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(vpnService.liveStatus.connected ? Color.green.opacity(0.11) : Color.white.opacity(0.06))
            )

            if let msg = vpnService.feedbackMessage {
                Text(msg)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(vpnService.feedbackIsError ? .red : .orange)
                    .lineLimit(1)
            }

            // Unified Config List (All Protocols + System VPNs)
            if vpnService.allServers.isEmpty {
                VStack(spacing: 6) {
                    Text("No VPN configurations yet")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.55))
                    Button {
                        appState.isPinned = false
                        appState.setDisplayState(.idle)
                        VPNConfigWindowController.show(vpnService: vpnService)
                    } label: {
                        Text("+ Add or Import Configs")
                            .font(.system(size: 11, weight: .bold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(Color.blue.opacity(0.28)))
                            .foregroundStyle(.blue)
                    }
                    .buttonStyle(.plain)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 5) {
                        ForEach(vpnService.allServers) { srv in
                            let connected = vpnService.isServerConnected(srv)
                            let ping = vpnService.pings[srv.id]

                            HStack(spacing: 8) {
                                Circle()
                                    .fill(connected ? Color.green : Color.white.opacity(0.25))
                                    .frame(width: 6, height: 6)

                                Text(srv.proto.shortLabel)
                                    .font(.system(size: 9, weight: .bold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(srv.proto.accentColor.opacity(0.20)))
                                    .foregroundStyle(srv.proto.accentColor)

                                VStack(alignment: .leading, spacing: 1) {
                                    Text(srv.displayName)
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(.white)
                                        .lineLimit(1)
                                    Text(srv.proto == .systemVPN ? srv.extraArgs : srv.maskedEndpoint)
                                        .font(.system(size: 9, design: .monospaced))
                                        .foregroundStyle(.white.opacity(0.45))
                                        .lineLimit(1)
                                }

                                Spacer()

                                if let ms = ping {
                                    Text(ms < 0 ? "err" : "\(ms)ms")
                                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                                        .foregroundStyle(ms < 0 ? .red : (ms < 250 ? .green : .yellow))
                                }

                                Button {
                                    vpnService.toggleServer(srv)
                                } label: {
                                    Text(connected ? "Disconnect" : "Connect")
                                        .font(.system(size: 10, weight: .bold))
                                        .padding(.horizontal, 9)
                                        .padding(.vertical, 4)
                                        .background(
                                            Capsule().fill(connected ? Color.red.opacity(0.22) : Color.blue.opacity(0.26))
                                        )
                                        .foregroundStyle(connected ? .red : .blue)
                                }
                                .buttonStyle(.plain)
                                .disabled(vpnService.isBusy)
                            }
                            .padding(.horizontal, 9)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 8)
                                    .fill(connected ? Color.green.opacity(0.09) : Color.white.opacity(0.05))
                            )
                        }
                    }
                }
            }
        }
    }
}
