import SwiftUI

private enum VPNManagerTab: String, CaseIterable, Identifiable {
    case configs = "Configs"
    case rules = "Rules"
    case settings = "Settings"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .configs: return "lock.shield.fill"
        case .rules: return "arrow.triangle.branch"
        case .settings: return "gearshape.fill"
        }
    }
}

private enum SortMode: String {
    case ping = "Ping"
    case name = "Name"
}

private enum RuleKindFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case domain = "Domain"
    case ipCidr = "IP / CIDR"
    case service = "Service"
    case enabled = "Active"
    case disabled = "Off"

    var id: String { rawValue }
}

struct VPNConfigWindowView: View {
    @EnvironmentObject var vpnService: VPNService
    @State private var activeTab: VPNManagerTab = .configs
    @State private var sortMode: SortMode = .ping
    @State private var editingServer: VPNServerConfig? = nil
    @State private var isEditingNew: Bool = false
    @State private var showAddSubSheet: Bool = false
    @State private var collapsedGroups: Set<String> = []

    // Add Subscription Sheet state
    @State private var subName: String = ""
    @State private var subURL: String = ""
    @State private var isAddingSub: Bool = false

    // Rules tab state
    @State private var newRuleTarget: String = ""
    @State private var newRuleLabel: String = ""
    @State private var newRuleTag: String = ""
    @State private var newRuleType: VPNRuleType = .domain
    @State private var ruleSearchQuery: String = ""
    @State private var selectedRuleCategory: String = "All"
    @State private var selectedRuleKindFilter: RuleKindFilter = .all
    @State private var duplicateRuleAlert: String? = nil
    @State private var editingTagRule: VPNRule? = nil
    @State private var editingTagText: String = ""
    @State private var showSDRSheet: Bool = false
    @State private var sdrPops: [SDRPop] = []
    @State private var isLoadingSDR: Bool = false

    var body: some View {
        let panelShape = RoundedRectangle(cornerRadius: 22, style: .continuous)

        ZStack {
            // Signature Overlay Notch frosted dark glass surface
            panelShape
                .fill(.ultraThinMaterial)
                .overlay(panelShape.fill(Color.black.opacity(0.72)))
                .overlay(
                    panelShape.stroke(
                        LinearGradient(
                            colors: [Color.white.opacity(0.18), Color.white.opacity(0.06)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
                )

            if let serverToEdit = editingServer {
                ServerEditorView(
                    server: serverToEdit,
                    isNew: isEditingNew,
                    onCancel: { editingServer = nil },
                    onSave: { updated in
                        vpnService.saveServer(updated)
                        editingServer = nil
                    },
                    onDelete: { toDelete in
                        vpnService.deleteServer(toDelete)
                        editingServer = nil
                    }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
            } else {
                VStack(spacing: 12) {
                    // Notch-style Top Bar (traffic lights safe area + live status + pill tabs)
                    notchHeaderBar

                    Divider()
                        .overlay(Color.white.opacity(0.09))
                        .padding(.horizontal, 18)

                    if let msg = vpnService.feedbackMessage {
                        HStack(spacing: 6) {
                            Image(systemName: vpnService.feedbackIsError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                                .font(.system(size: 11))
                            Text(msg)
                                .font(.system(size: 11, weight: .semibold))
                                .lineLimit(1)
                            Spacer()
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            Capsule().fill(vpnService.feedbackIsError ? Color.red.opacity(0.20) : Color.green.opacity(0.18))
                        )
                        .foregroundStyle(vpnService.feedbackIsError ? .red : .green)
                        .padding(.horizontal, 18)
                    }

                    // Active Tab Body
                    Group {
                        switch activeTab {
                        case .configs:
                            configsListView
                        case .rules:
                            rulesManagerView
                        case .settings:
                            settingsView
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    // Compact Notch-style Bottom Action Pill
                    bottomActionPill
                }
                .padding(.top, 30) // room for transparent macOS traffic lights
                .padding(.bottom, 16)
            }
        }
        .frame(width: 520, height: 600)
        .clipShape(panelShape)
        .ignoresSafeArea(.container, edges: .top)
        .preferredColorScheme(.dark)
        .onAppear {
            vpnService.refresh()
        }
        .sheet(isPresented: $showAddSubSheet) {
            addSubscriptionSheet
        }
        .sheet(isPresented: $showSDRSheet) {
            sdrPickerSheet
        }
    }

    // MARK: - Notch-Style Header Bar

    private var notchHeaderBar: some View {
        VStack(spacing: 10) {
            // Live Tunnel Pill + Quick Actions
            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(vpnService.liveStatus.connected ? Color.green : Color.white.opacity(0.30))
                        .frame(width: 8, height: 8)
                        .shadow(color: vpnService.liveStatus.connected ? .green.opacity(0.7) : .clear, radius: 4)

                    Text(vpnService.liveStatus.connected ? vpnService.liveStatus.providerLabel : "VPN Disconnected")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(.white)
                        .lineLimit(1)

                    if !vpnService.liveStatus.iface.isEmpty {
                        Text(vpnService.liveStatus.iface)
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.green.opacity(0.20)))
                            .foregroundStyle(.green)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(
                    Capsule()
                        .fill(vpnService.liveStatus.connected ? Color.green.opacity(0.12) : Color.white.opacity(0.07))
                        .overlay(Capsule().stroke(Color.white.opacity(0.10), lineWidth: 1))
                )

                Spacer()

                // "+" Menu Pill (All V2BOX add/import options)
                Menu {
                    Button {
                        vpnService.importFromClipboard()
                    } label: {
                        Label("Import from clipboard", systemImage: "doc.on.clipboard")
                    }

                    Button {
                        vpnService.importJSONWithDialog()
                    } label: {
                        Label("Import config file (.json)", systemImage: "square.and.arrow.down")
                    }

                    Button {
                        subName = ""
                        subURL = ""
                        showAddSubSheet = true
                    } label: {
                        Label("Add Subscription", systemImage: "globe")
                    }

                    Button {
                        isEditingNew = true
                        editingServer = VPNServerConfig(proto: .vless, port: 443)
                    } label: {
                        Label("Add manual config", systemImage: "plus.circle")
                    }

                    Divider()

                    Button {
                        vpnService.updateAllSubscriptions()
                    } label: {
                        Label("Update all subscriptions", systemImage: "arrow.triangle.2.circlepath")
                    }

                    Button {
                        vpnService.importBypassRulesFromOCPanel()
                    } label: {
                        Label("Copy bypass rules from ocpanel", systemImage: "arrow.triangle.branch")
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "plus")
                            .font(.system(size: 11, weight: .bold))
                        Text("Add")
                            .font(.system(size: 11, weight: .bold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.white.opacity(0.14)))
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            .padding(.horizontal, 18)

            // Notch-Style Pill Tab Switcher
            HStack(spacing: 6) {
                ForEach(VPNManagerTab.allCases) { tab in
                    Button {
                        withAnimation(.easeInOut(duration: 0.16)) {
                            activeTab = tab
                        }
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: tab.icon)
                                .font(.system(size: 11, weight: .semibold))
                            Text(tab.rawValue)
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            Capsule()
                                .fill(activeTab == tab ? Color.white.opacity(0.18) : Color.clear)
                        )
                        .foregroundStyle(activeTab == tab ? .white : .white.opacity(0.55))
                    }
                    .buttonStyle(.plain)
                }

                Spacer()

                if activeTab == .configs {
                    Button {
                        sortMode = sortMode == .ping ? .name : .ping
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.up.arrow.down")
                                .font(.system(size: 9, weight: .bold))
                            Text(sortMode.rawValue)
                                .font(.system(size: 10, weight: .semibold))
                        }
                        .foregroundStyle(.white.opacity(0.75))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(Color.white.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 18)
        }
    }

    // MARK: - Configs List (Notch Aesthetic + All V2BOX Features)

    private var configsListView: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 10) {
                // 1. Local Configs Group
                let localServers = sorted(vpnService.store.servers.filter { $0.groupID == "local" })
                groupSection(
                    id: "local",
                    title: "Local",
                    count: localServers.count,
                    subtitle: localServers.isEmpty ? "Click + Add to paste or create a server" : "Manual & clipboard configs",
                    servers: localServers,
                    subscription: nil
                )

                // 2. Subscription Groups
                ForEach(vpnService.store.subscriptions) { sub in
                    let subServers = sorted(vpnService.store.servers.filter { $0.groupID == sub.id })
                    groupSection(
                        id: sub.id,
                        title: sub.name,
                        count: subServers.count,
                        subtitle: sub.lastUpdated.map { "Updated \($0.formatted(date: .abbreviated, time: .shortened))" } ?? sub.url,
                        servers: subServers,
                        subscription: sub
                    )
                }

                // 3. System VPNs Group
                if !vpnService.systemVPNs.isEmpty {
                    groupSection(
                        id: "system",
                        title: "System VPNs",
                        count: vpnService.systemVPNs.count,
                        subtitle: "macOS NetworkExtension",
                        servers: vpnService.systemVPNs,
                        subscription: nil
                    )
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 6)
        }
    }

    @ViewBuilder
    private func groupSection(
        id: String,
        title: String,
        count: Int,
        subtitle: String,
        servers: [VPNServerConfig],
        subscription: VPNSubscription?
    ) -> some View {
        let isCollapsed = collapsedGroups.contains(id)

        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        if isCollapsed { collapsedGroups.remove(id) } else { collapsedGroups.insert(id) }
                    }
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white.opacity(0.55))
                            .frame(width: 12)

                        Text(title)
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)

                        Text("\(count)")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(Capsule().fill(Color.white.opacity(0.10)))
                            .foregroundStyle(.white.opacity(0.7))

                        Text(subtitle)
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.4))
                            .lineLimit(1)

                        Spacer()
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                if let sub = subscription {
                    Button { vpnService.updateSubscription(sub) } label: {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.75))
                    }
                    .buttonStyle(.plain)
                    .help("Update subscription")

                    Button { vpnService.pingServers(in: sub.id) } label: {
                        Image(systemName: "speedometer")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.cyan)
                    }
                    .buttonStyle(.plain)
                    .help("Ping group")

                    Button { vpnService.deleteSubscription(sub) } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 10))
                            .foregroundStyle(.red.opacity(0.75))
                    }
                    .buttonStyle(.plain)
                    .help("Delete subscription")
                } else if id == "local" && !servers.isEmpty {
                    Button { vpnService.pingServers(in: "local") } label: {
                        Image(systemName: "speedometer")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.cyan)
                    }
                    .buttonStyle(.plain)
                    .help("Ping local configs")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 11)
                    .fill(Color.white.opacity(0.06))
            )

            if !isCollapsed {
                ForEach(servers) { srv in
                    notchServerRow(srv)
                }
            }
        }
    }

    private func notchServerRow(_ srv: VPNServerConfig) -> some View {
        let isSelected = vpnService.store.selectedServerID == srv.id
        let isConnected = vpnService.isServerConnected(srv)
        let pingVal = vpnService.pings[srv.id]

        return HStack(spacing: 10) {
            Button {
                vpnService.selectServer(srv)
            } label: {
                HStack(spacing: 10) {
                    // Status dot
                    Circle()
                        .fill(isConnected ? Color.green : (isSelected ? srv.proto.accentColor : Color.white.opacity(0.22)))
                        .frame(width: 7, height: 7)
                        .shadow(color: isConnected ? .green.opacity(0.7) : .clear, radius: 4)

                    // Protocol capsule badge
                    Text(srv.proto.shortLabel)
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(srv.proto.accentColor.opacity(isSelected ? 0.30 : 0.16)))
                        .foregroundStyle(srv.proto.accentColor)
                        .frame(width: 48)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(srv.displayName)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text(srv.proto == .systemVPN ? srv.extraArgs : srv.maskedEndpoint)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.45))
                            .lineLimit(1)
                    }

                    Spacer()

                    if let ms = pingVal {
                        Text(ms < 0 ? "err" : "\(ms)ms")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .monospacedDigit()
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(pingColor(ms).opacity(0.20)))
                            .foregroundStyle(pingColor(ms))
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Quick Edit & Copy URI pills
            if srv.proto != .systemVPN {
                HStack(spacing: 5) {
                    Button {
                        isEditingNew = false
                        editingServer = srv
                    } label: {
                        Image(systemName: "pencil")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.75))
                            .frame(width: 24, height: 24)
                            .background(Circle().fill(Color.white.opacity(0.09)))
                    }
                    .buttonStyle(.plain)
                    .help("Edit server")

                    Button {
                        let uri = VPNURIParser.exportURI(for: srv)
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(uri, forType: .string)
                        vpnService.setFeedback("Copied URI for \(srv.displayName)")
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.75))
                            .frame(width: 24, height: 24)
                            .background(Circle().fill(Color.white.opacity(0.09)))
                    }
                    .buttonStyle(.plain)
                    .help("Copy URI")
                }
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 11)
                .fill(isConnected ? Color.green.opacity(0.11) : (isSelected ? Color.white.opacity(0.11) : Color.white.opacity(0.04)))
                .overlay(
                    RoundedRectangle(cornerRadius: 11)
                        .stroke(
                            isConnected ? Color.green.opacity(0.45) : (isSelected ? Color.white.opacity(0.22) : Color.white.opacity(0.06)),
                            lineWidth: 1
                        )
                )
        )
    }

    // MARK: - Rules Screen (Search, Auto-Categories, Tagging, Duplicate Guard & Live Bypass Refresh)

    private var ruleCategories: [(name: String, count: Int)] {
        let rules = vpnService.activeRules
        var counts: [String: Int] = [:]
        for r in rules {
            counts[r.resolvedCategory, default: 0] += 1
        }
        let sorted = counts.keys.sorted { a, b in
            let ca = counts[a] ?? 0
            let cb = counts[b] ?? 0
            if ca != cb { return ca > cb }
            return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
        }
        return [("All", rules.count)] + sorted.map { ($0, counts[$0] ?? 0) }
    }

    private var filteredRules: [VPNRule] {
        let q = ruleSearchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return vpnService.activeRules.filter { rule in
            if selectedRuleCategory != "All" && rule.resolvedCategory != selectedRuleCategory {
                return false
            }
            switch selectedRuleKindFilter {
            case .all: break
            case .domain: if rule.type != .domain { return false }
            case .ipCidr: if rule.type != .ipCidr { return false }
            case .service: if rule.type != .service { return false }
            case .enabled: if !rule.enabled { return false }
            case .disabled: if rule.enabled { return false }
            }
            if !q.isEmpty {
                let ips = (vpnService.resolvedIPsByRuleID[rule.id] ?? []).joined(separator: " ")
                let hay = "\(rule.target) \(rule.label) \(rule.tag) \(rule.resolvedCategory) \(ips)".lowercased()
                if !hay.contains(q) { return false }
            }
            return true
        }
    }

    private var rulesManagerView: some View {
        let allRules = vpnService.activeRules
        let visibleRules = filteredRules
        let enabledCount = allRules.filter(\.enabled).count
        let domainCount = allRules.filter { $0.type == .domain }.count
        let ipCount = allRules.filter { $0.type == .ipCidr }.count
        let resolvedTotal = vpnService.resolvedIPsByRuleID.values.reduce(0) { $0 + $1.count }

        return VStack(alignment: .leading, spacing: 8) {
            // Top Mode Switcher + Refresh Bypass + Import + Bulk Actions
            HStack(spacing: 8) {
                Picker("", selection: Binding(
                    get: { vpnService.store.mode },
                    set: {
                        vpnService.setMode($0)
                        selectedRuleCategory = "All"
                        duplicateRuleAlert = nil
                    }
                )) {
                    ForEach(VPNRouteMode.allCases) { m in
                        Text(m.shortTitle).tag(m)
                    }
                }
                .pickerStyle(.segmented)

                Button {
                    vpnService.refreshBypassAndIPs()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 10, weight: .bold))
                        Text(vpnService.isRefreshingBypass ? "Refreshing…" : "Refresh IPs")
                            .font(.system(size: 10, weight: .bold))
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.green.opacity(vpnService.isRefreshingBypass ? 0.14 : 0.22)))
                    .foregroundStyle(.green)
                }
                .buttonStyle(.plain)
                .disabled(vpnService.isRefreshingBypass)
                .help("Flush DNS, resolve fresh IPs for domain rules & reload live bypass")

                Button {
                    vpnService.importBypassRulesFromOCPanel()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "tray.and.arrow.down")
                            .font(.system(size: 10, weight: .bold))
                        Text("Copy ocpanel")
                            .font(.system(size: 10, weight: .bold))
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.white.opacity(0.12)))
                    .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
                .help("Copy bypass rules from ~/.config/ocpanel/config.json")

                Menu {
                    Button("Enable Filtered (\(visibleRules.count))") {
                        vpnService.setRulesEnabled(visibleRules, enabled: true)
                    }
                    Button("Disable Filtered (\(visibleRules.count))") {
                        vpnService.setRulesEnabled(visibleRules, enabled: false)
                    }
                    Divider()
                    Button("Export Backup JSON…") {
                        vpnService.exportJSONWithDialog()
                    }
                    Button("Import Backup JSON…") {
                        vpnService.importJSONWithDialog()
                    }
                    Divider()
                    Button("Delete Disabled Rules", role: .destructive) {
                        let disabled = allRules.filter { !$0.enabled }
                        vpnService.deleteRules(disabled)
                    }
                    Button("Delete Filtered (\(visibleRules.count))", role: .destructive) {
                        vpnService.deleteRules(visibleRules)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.75))
                        .frame(width: 24, height: 24)
                }
                .menuStyle(.borderlessButton)
                .frame(width: 24)
            }
            .padding(.horizontal, 18)

            // Stats / Info Strip
            HStack(spacing: 10) {
                Label("\(enabledCount)/\(allRules.count) active", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green.opacity(0.9))
                Text("·").foregroundStyle(.white.opacity(0.3))
                Text("\(domainCount) domains · \(ipCount) IP/CIDRs")
                    .foregroundStyle(.white.opacity(0.6))
                if resolvedTotal > 0 {
                    Text("·").foregroundStyle(.white.opacity(0.3))
                    Text("\(resolvedTotal) IPs resolved")
                        .foregroundStyle(.cyan.opacity(0.85))
                }
                Spacer()
                if let refreshed = vpnService.lastBypassRefreshAt {
                    Text("Refreshed \(refreshed, style: .time)")
                        .foregroundStyle(.white.opacity(0.45))
                }
            }
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .padding(.horizontal, 18)

            // Add Rule Row + Optional Tag + Duplicate Alert
            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 6) {
                    Picker("", selection: $newRuleType) {
                        ForEach(VPNRuleType.allCases) { t in
                            Text(t.label).tag(t)
                        }
                    }
                    .frame(width: 88)

                    TextField(newRuleType == .domain ? "Domain or URL (e.g. youtube.com)" : "e.g. 1.1.1.1/32", text: $newRuleTarget)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11.5))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.55)))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(duplicateRuleAlert != nil ? Color.orange.opacity(0.75) : Color.white.opacity(0.10), lineWidth: 1))
                        .onChange(of: newRuleTarget) { _ in
                            if duplicateRuleAlert != nil { duplicateRuleAlert = nil }
                        }

                    TextField("Tag (optional)", text: $newRuleTag)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11.5))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 6)
                        .frame(width: 112)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Color.black.opacity(0.55)))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.white.opacity(0.10), lineWidth: 1))

                    Button {
                        submitNewRule()
                    } label: {
                        Text("Add")
                            .font(.system(size: 11, weight: .bold))
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(Color.cyan.opacity(0.28)))
                            .foregroundStyle(.cyan)
                    }
                    .buttonStyle(.plain)
                    .disabled(newRuleTarget.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                if let dupMsg = duplicateRuleAlert {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 10.5))
                            .foregroundStyle(.orange)
                        Text(dupMsg)
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(.orange)
                        Spacer()
                        Button("Dismiss") {
                            duplicateRuleAlert = nil
                        }
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white.opacity(0.6))
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Color.orange.opacity(0.14)))
                }

                // Quick Service Presets
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        Button("+ Google & YouTube (IPs)") {
                            vpnService.addGoogleServiceRule()
                        }
                        .font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.green.opacity(0.20)))
                        .foregroundStyle(.green)
                        .buttonStyle(.plain)

                        Button("+ Dota 2 / Steam SDR") {
                            showSDRSheet = true
                            isLoadingSDR = true
                            VPNRuleServices.fetchSteamSDR { pops, err in
                                isLoadingSDR = false
                                sdrPops = pops
                                if let err, pops.isEmpty {
                                    vpnService.setFeedback(err, isError: true)
                                }
                            }
                        }
                        .font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.orange.opacity(0.20)))
                        .foregroundStyle(.orange)
                        .buttonStyle(.plain)

                        ForEach(["Telegram", "Apple & iCloud"], id: \.self) { preset in
                            Button("+ \(preset)") {
                                vpnService.addPresetRules(service: preset)
                            }
                            .font(.system(size: 10, weight: .semibold))
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(Color.white.opacity(0.08)))
                            .foregroundStyle(.white.opacity(0.8))
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.horizontal, 18)

            // Search & Kind Filter + Auto-Category Chips
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.45))
                        TextField("Search domain, IP, tag, or note…", text: $ruleSearchQuery)
                            .textFieldStyle(.plain)
                            .font(.system(size: 11.5))
                        if !ruleSearchQuery.isEmpty {
                            Button {
                                ruleSearchQuery = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.white.opacity(0.45))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.06)))

                    Picker("", selection: $selectedRuleKindFilter) {
                        ForEach(RuleKindFilter.allCases) { f in
                            Text(f.rawValue).tag(f)
                        }
                    }
                    .frame(width: 96)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        ForEach(ruleCategories, id: \.name) { cat in
                            let selected = selectedRuleCategory == cat.name
                            Button {
                                selectedRuleCategory = cat.name
                            } label: {
                                Text("\(cat.name) (\(cat.count))")
                                    .font(.system(size: 10, weight: selected ? .bold : .medium))
                                    .padding(.horizontal, 9)
                                    .padding(.vertical, 4)
                                    .background(Capsule().fill(selected ? Color.cyan.opacity(0.24) : Color.white.opacity(0.07)))
                                    .foregroundStyle(selected ? .cyan : .white.opacity(0.75))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
            }
            .padding(.horizontal, 18)

            // Active Rules List
            if allRules.isEmpty {
                VStack(spacing: 6) {
                    Text(vpnService.store.mode == .vpnDefault ? "No bypass rules yet" : "No VPN rules yet")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.55))
                    Text("Add domains, IP/CIDRs, Google IP ranges, or copy bypass rules from ocpanel.")
                        .font(.system(size: 10))
                        .foregroundStyle(.white.opacity(0.38))
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 24)
            } else if visibleRules.isEmpty {
                VStack(spacing: 6) {
                    Text("No matching rules")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.55))
                    Button("Clear Search & Filters") {
                        ruleSearchQuery = ""
                        selectedRuleCategory = "All"
                        selectedRuleKindFilter = .all
                    }
                    .font(.system(size: 10.5, weight: .bold))
                    .foregroundStyle(.cyan)
                    .buttonStyle(.plain)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 6) {
                        ForEach(visibleRules) { rule in
                            let resolvedIPs = vpnService.resolvedIPsByRuleID[rule.id] ?? []
                            HStack(spacing: 9) {
                                Toggle("", isOn: Binding(
                                    get: { rule.enabled },
                                    set: { _ in vpnService.toggleRule(rule) }
                                ))
                                .toggleStyle(.switch)
                                .controlSize(.mini)
                                .labelsHidden()

                                Text(rule.type.label)
                                    .font(.system(size: 9, weight: .bold))
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Capsule().fill(Color.cyan.opacity(0.18)))
                                    .foregroundStyle(.cyan)

                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(rule.target)
                                            .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                            .foregroundStyle(rule.enabled ? .white : .white.opacity(0.4))
                                            .lineLimit(1)

                                        Button {
                                            editingTagRule = rule
                                            editingTagText = rule.tag
                                        } label: {
                                            Text(rule.resolvedCategory)
                                                .font(.system(size: 9, weight: .semibold))
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 1.5)
                                                .background(Capsule().fill(rule.tag.isEmpty ? Color.white.opacity(0.08) : Color.purple.opacity(0.22)))
                                                .foregroundStyle(rule.tag.isEmpty ? Color.white.opacity(0.65) : Color.purple)
                                        }
                                        .buttonStyle(.plain)
                                        .help("Click to edit tag")
                                    }

                                    HStack(spacing: 6) {
                                        if !rule.label.isEmpty {
                                            Text(rule.label)
                                                .font(.system(size: 10))
                                                .foregroundStyle(.white.opacity(0.45))
                                                .lineLimit(1)
                                        }
                                        if !resolvedIPs.isEmpty {
                                            Text("IP: \(resolvedIPs.prefix(2).joined(separator: ", "))\(resolvedIPs.count > 2 ? " +\(resolvedIPs.count - 2)" : "")")
                                                .font(.system(size: 9.5, design: .monospaced))
                                                .foregroundStyle(.green.opacity(0.8))
                                                .help(resolvedIPs.joined(separator: "\n"))
                                        }
                                    }
                                }

                                Spacer()

                                Button {
                                    vpnService.deleteRule(rule)
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.red.opacity(0.75))
                                }
                                .buttonStyle(.plain)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.05)))
                        }
                    }
                    .padding(.horizontal, 18)
                }
            }
        }
        .sheet(item: $editingTagRule) { rule in
            VStack(alignment: .leading, spacing: 12) {
                Text("Edit Tag for \(rule.target)")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(.white)
                Text("Leave empty to use auto-category (\(VPNRule.autoCategory(target: rule.target, label: rule.label))).")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.white.opacity(0.55))
                TextField("Optional custom tag", text: $editingTagText)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("Auto") {
                        vpnService.updateRuleTag(rule, tag: "")
                        editingTagRule = nil
                    }
                    Spacer()
                    Button("Cancel") {
                        editingTagRule = nil
                    }
                    Button("Save") {
                        vpnService.updateRuleTag(rule, tag: editingTagText)
                        editingTagRule = nil
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(16)
            .frame(width: 320)
            .preferredColorScheme(.dark)
        }
    }

    private func submitNewRule() {
        let result = vpnService.addRuleResult(
            target: newRuleTarget,
            type: newRuleType,
            label: newRuleLabel,
            tag: newRuleTag
        )
        switch result {
        case .added:
            duplicateRuleAlert = nil
            newRuleTarget = ""
            newRuleLabel = ""
            newRuleTag = ""
        case .duplicate(let existing):
            NSSound.beep()
            duplicateRuleAlert = "'\(existing.target)' already exists in \(existing.resolvedCategory) — duplicate not added."
        case .invalid:
            break
        }
    }

    // MARK: - Settings Screen

    private var settingsView: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Backup & Rules Import")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white.opacity(0.85))

                    HStack(spacing: 8) {
                        Button {
                            vpnService.exportJSONWithDialog()
                        } label: {
                            Label("Export JSON", systemImage: "square.and.arrow.up")
                                .font(.system(size: 11, weight: .semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 7)
                                .background(Capsule().fill(Color.white.opacity(0.10)))
                                .foregroundStyle(.white)
                        }
                        .buttonStyle(.plain)

                        Button {
                            vpnService.importJSONWithDialog()
                        } label: {
                            Label("Import JSON", systemImage: "square.and.arrow.down")
                                .font(.system(size: 11, weight: .semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 7)
                                .background(Capsule().fill(Color.white.opacity(0.10)))
                                .foregroundStyle(.white)
                        }
                        .buttonStyle(.plain)
                    }

                    Button {
                        vpnService.importBypassRulesFromOCPanel()
                    } label: {
                        Label("Copy Bypass Rules Only from ocpanel", systemImage: "arrow.triangle.branch")
                            .font(.system(size: 11, weight: .bold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                            .background(Capsule().fill(Color.cyan.opacity(0.20)))
                            .foregroundStyle(.cyan)
                    }
                    .buttonStyle(.plain)
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.05)))

                VStack(alignment: .leading, spacing: 8) {
                    Text("Standalone Core Status")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white.opacity(0.85))

                    statusRow("sing-box binary", ok: vpnService.singBoxBinaryPath != nil, detail: vpnService.singBoxBinaryPath ?? "Install: brew install sing-box")
                    statusRow("openconnect binary", ok: vpnService.openConnectBinaryPath != nil, detail: vpnService.openConnectBinaryPath ?? "Optional: brew install openconnect")
                    statusRow("Passwordless helper", ok: vpnService.isPasswordlessHelperInstalled, detail: vpnService.isPasswordlessHelperInstalled ? "Installed (/usr/local/libexec/overlay-vpn-core.sh)" : "Run scripts/install_vpn_helper.sh")

                    if !vpnService.isPasswordlessHelperInstalled {
                        Button("Copy Install Helper Command") {
                            let cmd = "/Users/amin/Documents/Develop/Overlay/scripts/install_vpn_helper.sh"
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(cmd, forType: .string)
                            vpnService.setFeedback("Copied command to clipboard")
                        }
                        .font(.system(size: 11, weight: .semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.white.opacity(0.10)))
                        .foregroundStyle(.white)
                        .buttonStyle(.plain)
                        .padding(.top, 4)
                    }
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.05)))
            }
            .padding(.horizontal, 18)
        }
    }

    private func statusRow(_ title: String, ok: Bool, detail: String) -> some View {
        HStack(spacing: 8) {
            Circle()
                .fill(ok ? Color.green : Color.orange)
                .frame(width: 7, height: 7)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                Text(detail)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
            }
            Spacer()
        }
    }

    // MARK: - Notch-Style Bottom Action Pill

    private var bottomActionPill: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 1) {
                Text(vpnService.liveStatus.connected
                     ? vpnService.liveStatus.providerLabel
                     : (vpnService.selectedServer?.displayName ?? "No server selected"))
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(vpnService.liveStatus.connected
                     ? "Connected · \(vpnService.store.mode.shortTitle)"
                     : "\(vpnService.allServers.count) configs · \(vpnService.activeRules.filter { $0.enabled }.count) rules")
                    .font(.system(size: 10))
                    .foregroundStyle(vpnService.liveStatus.connected ? .green : .white.opacity(0.5))
            }

            Spacer()

            Button {
                vpnService.pingAllServers()
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "speedometer")
                        .font(.system(size: 11, weight: .semibold))
                    Text(vpnService.isPinging ? "Pinging…" : "Ping")
                        .font(.system(size: 11, weight: .semibold))
                }
                .foregroundStyle(.white.opacity(0.85))
                .padding(.horizontal, 11)
                .padding(.vertical, 7)
                .background(Capsule().fill(Color.white.opacity(0.10)))
            }
            .buttonStyle(.plain)

            Button {
                if vpnService.liveStatus.connected {
                    vpnService.disconnectActive()
                } else if let sel = vpnService.selectedServer {
                    vpnService.connectServer(sel)
                } else {
                    vpnService.setFeedback("Select or add a VPN config first", isError: true)
                }
            } label: {
                Text(vpnService.isBusy ? "Working…" : (vpnService.liveStatus.connected ? "Disconnect" : "Connect"))
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(vpnService.liveStatus.connected ? .white : .black)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 7)
                    .background(
                        Capsule()
                            .fill(vpnService.liveStatus.connected ? Color.red.opacity(0.85) : Color.white)
                    )
            }
            .buttonStyle(.plain)
            .disabled(vpnService.isBusy)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            Capsule()
                .fill(Color.white.opacity(0.08))
                .overlay(Capsule().stroke(Color.white.opacity(0.12), lineWidth: 1))
        )
        .padding(.horizontal, 18)
    }

    // MARK: - Sheets

    private var addSubscriptionSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add Subscription")
                .font(.system(size: 16, weight: .bold))
            TextField("Subscription Name", text: $subName)
                .textFieldStyle(.roundedBorder)
            TextField("Subscription URL (https://...)", text: $subURL)
                .textFieldStyle(.roundedBorder)

            HStack {
                Spacer()
                Button("Cancel") { showAddSubSheet = false }
                Button(isAddingSub ? "Fetching…" : "Add") {
                    isAddingSub = true
                    vpnService.addSubscription(name: subName, url: subURL) { ok, msg in
                        isAddingSub = false
                        vpnService.setFeedback(msg, isError: !ok)
                        if ok { showAddSubSheet = false }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isAddingSub || subURL.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
        .preferredColorScheme(.dark)
    }

    private var sdrPickerSheet: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Valve Steam SDR Relays (Dota 2 / CS2)")
                        .font(.system(size: 15, weight: .bold))
                    Text("Adds /24 relay subnets to your active \(vpnService.store.mode.shortTitle) list")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { showSDRSheet = false }
            }

            if isLoadingSDR {
                ProgressView("Fetching Valve SDR directory…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if sdrPops.isEmpty {
                Text("No SDR clusters loaded.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(sdrPops) { pop in
                            HStack {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(pop.label)
                                        .font(.system(size: 12, weight: .semibold))
                                    Text("\(pop.cidrs.count) /24 subnet\(pop.cidrs.count == 1 ? "" : "s")")
                                        .font(.system(size: 10))
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Button("Add") {
                                    vpnService.addSDRPopRules(pop)
                                }
                                .buttonStyle(.borderedProminent)
                                .controlSize(.small)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.06)))
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 400, height: 420)
        .preferredColorScheme(.dark)
    }

    private func sorted(_ list: [VPNServerConfig]) -> [VPNServerConfig] {
        switch sortMode {
        case .name:
            return list.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        case .ping:
            return list.sorted { lhs, rhs in
                let p1 = vpnService.pings[lhs.id] ?? 99999
                let p2 = vpnService.pings[rhs.id] ?? 99999
                let v1 = p1 < 0 ? 99998 : p1
                let v2 = p2 < 0 ? 99998 : p2
                if v1 != v2 { return v1 < v2 }
                return lhs.displayName.localizedCaseInsensitiveCompare(rhs.displayName) == .orderedAscending
            }
        }
    }

    private func pingColor(_ ms: Int) -> Color {
        if ms < 0 { return .red }
        if ms < 250 { return .green }
        if ms < 500 { return .yellow }
        return .orange
    }
}

// MARK: - Notch-Style Server Add / Edit Screen

private struct ServerEditorView: View {
    @State var server: VPNServerConfig
    let isNew: Bool
    let onCancel: () -> Void
    let onSave: (VPNServerConfig) -> Void
    let onDelete: (VPNServerConfig) -> Void

    @State private var portText: String = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    onCancel()
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 11, weight: .bold))
                        Text("Back")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.white.opacity(0.10)))
                }
                .buttonStyle(.plain)

                Spacer()
                Text(isNew ? "New Server" : "Edit Server")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white)
                Spacer()

                Button {
                    server.port = Int(portText) ?? server.proto.defaultPort
                    server.rawURI = nil
                    onSave(server)
                } label: {
                    Text("Save")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)
                        .background(Capsule().fill(Color.white))
                }
                .buttonStyle(.plain)
                .disabled(server.address.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 18)
            .padding(.top, 30)
            .padding(.bottom, 12)

            Divider().overlay(Color.white.opacity(0.09)).padding(.horizontal, 18)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(spacing: 11) {
                        HStack {
                            Text("Protocol")
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(.white)
                            Spacer()
                            Picker("", selection: $server.proto) {
                                ForEach(VPNProtocol.editableCases) { p in
                                    Text(p.rawValue).tag(p)
                                }
                            }
                            .pickerStyle(.menu)
                            .tint(.cyan)
                            .onChange(of: server.proto) { newProto in
                                if isNew {
                                    portText = "\(newProto.defaultPort)"
                                }
                            }
                        }

                        Divider().overlay(Color.white.opacity(0.08))

                        darkField("Remarks", placeholder: "e.g. Germany or Home SSH", text: $server.remarks)
                        HStack(spacing: 10) {
                            darkField("Address", placeholder: "example.com or 1.2.3.4", text: $server.address)
                            darkField("Port", placeholder: "\(server.proto.defaultPort)", text: $portText)
                                .frame(width: 90)
                        }

                        if [.ssh, .socks, .http, .openconnect].contains(server.proto) {
                            darkField("Username", placeholder: "username", text: $server.username)
                        }

                        darkField(secretLabel, placeholder: secretPlaceholder, text: $server.secret)

                        if server.proto == .shadowsocks || server.proto == .vmess {
                            darkField("Method / Cipher", placeholder: server.proto == .shadowsocks ? "aes-256-gcm" : "auto", text: $server.method)
                        }

                        if [.vless, .vmess, .trojan, .hysteria2, .http].contains(server.proto) {
                            HStack {
                                Text("Security")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(.white.opacity(0.85))
                                Spacer()
                                Picker("", selection: $server.security) {
                                    Text("none").tag("none")
                                    Text("tls").tag("tls")
                                    Text("reality").tag("reality")
                                }
                                .pickerStyle(.segmented)
                                .frame(width: 210)
                            }

                            if server.proto != .hysteria2 && server.proto != .http {
                                HStack {
                                    Text("Transport")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(.white.opacity(0.85))
                                    Spacer()
                                    Picker("", selection: $server.transport) {
                                        Text("tcp").tag("tcp")
                                        Text("ws").tag("ws")
                                        Text("grpc").tag("grpc")
                                    }
                                    .pickerStyle(.segmented)
                                    .frame(width: 210)
                                }
                            }

                            darkField("SNI", placeholder: "optional server name", text: $server.sni)

                            if server.transport == "ws" || server.transport == "grpc" {
                                darkField("WS Host", placeholder: "optional host header", text: $server.wsHost)
                                darkField("Path / Service Name", placeholder: "/", text: $server.path)
                            }

                            if server.proto == .vless {
                                darkField("Flow", placeholder: "e.g. xtls-rprx-vision", text: $server.flow)
                            }

                            Toggle("Allow Insecure TLS", isOn: $server.allowInsecure)
                                .font(.system(size: 12, weight: .semibold))
                        }

                        if server.proto == .openconnect {
                            darkField("Extra Args", placeholder: "--protocol=anyconnect", text: $server.extraArgs)
                        }
                    }
                    .padding(14)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.05)))

                    if !isNew {
                        Button(role: .destructive) {
                            onDelete(server)
                        } label: {
                            Text("Delete Server")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(.red)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 9)
                                .background(Capsule().fill(Color.red.opacity(0.16)))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(18)
            }
        }
        .onAppear {
            portText = "\(server.port)"
        }
    }

    private var secretLabel: String {
        switch server.proto {
        case .vless, .vmess: return "UUID / ID"
        case .ssh: return "ID / Password / Key Path"
        default: return "Password / Key"
        }
    }

    private var secretPlaceholder: String {
        switch server.proto {
        case .vless, .vmess: return "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
        case .ssh: return "password or ~/.ssh/id_ed25519"
        default: return "password"
        }
    }

    private func darkField(_ title: String, placeholder: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white.opacity(0.7))
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(RoundedRectangle(cornerRadius: 9).fill(Color.black.opacity(0.55)))
                .overlay(RoundedRectangle(cornerRadius: 9).stroke(Color.white.opacity(0.09), lineWidth: 1))
        }
    }
}
