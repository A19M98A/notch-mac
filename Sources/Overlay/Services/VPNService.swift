import Foundation
import AppKit
import Network
import Combine

struct VPNLiveStatus: Equatable {
    var connected: Bool = false
    var providerLabel: String = "Disconnected"
    var providerKind: String = "none" // "sing-box" | "openconnect" | "systemVPN" | "tunnel" | "none"
    var activeServerID: String? = nil
    var activeServiceName: String? = nil
    var activePID: Int? = nil
    var iface: String = ""
}

private struct ActiveVPNSession: Codable {
    let serverID: String
    let serverName: String
    let providerKind: String
    let startedAt: Date
}

enum RuleAddResult {
    case added(VPNRule)
    case duplicate(VPNRule)
    case invalid
}

final class VPNService: ObservableObject {
    @Published var store = VPNStoreData()
    @Published var systemVPNs: [VPNServerConfig] = []
    @Published var liveStatus = VPNLiveStatus()
    @Published var pings: [String: Int] = [:] // server.id -> ms (-1 = timeout)
    @Published var isBusy: Bool = false
    @Published var isPinging: Bool = false
    @Published var isRefreshingBypass: Bool = false
    @Published var lastBypassRefreshAt: Date? = nil
    @Published var resolvedIPsByRuleID: [String: [String]] = [:]
    @Published var feedbackMessage: String? = nil
    @Published var feedbackIsError: Bool = false

    private var pollTimer: Timer?
    private let fm = FileManager.default
    private let homeDir = FileManager.default.homeDirectoryForCurrentUser.path
    private let helperPath = "/usr/local/libexec/overlay-vpn-core.sh"

    var configDir: String { "\(homeDir)/.config/overlay-vpn" }
    var storeFileURL: URL { URL(fileURLWithPath: "\(configDir)/store.json") }
    var activeSessionURL: URL { URL(fileURLWithPath: "\(configDir)/active_session.json") }
    var singBoxConfigURL: URL { URL(fileURLWithPath: "\(configDir)/sing-box.json") }
    var singBoxPIDFile: String { "\(configDir)/sing-box.pid" }
    var openConnectPIDFile: String { "\(configDir)/openconnect.pid" }

    var allServers: [VPNServerConfig] {
        store.servers + systemVPNs
    }

    var activeRules: [VPNRule] {
        store.mode == .vpnDefault ? store.bypassRules : store.vpnRules
    }

    var selectedServer: VPNServerConfig? {
        if let id = store.selectedServerID, let found = allServers.first(where: { $0.id == id }) {
            return found
        }
        return allServers.first
    }

    var singBoxBinaryPath: String? {
        for p in ["/opt/homebrew/bin/sing-box", "/usr/local/bin/sing-box", "/usr/bin/sing-box"] {
            if fm.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    var openConnectBinaryPath: String? {
        for p in ["/opt/homebrew/bin/openconnect", "/usr/local/bin/openconnect", "/usr/bin/openconnect"] {
            if fm.isExecutableFile(atPath: p) { return p }
        }
        return nil
    }

    var isPasswordlessHelperInstalled: Bool {
        fm.isExecutableFile(atPath: helperPath)
    }

    func installPasswordlessHelper(completion: @escaping (Bool, String) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            let bundledPath = Bundle.main.path(forResource: "overlay_vpn_core", ofType: "sh")
            let tmpHelper = "/tmp/notchpulse-overlay-vpn-core-\(UUID().uuidString).sh"
            let srcPath: String

            if let bPath = bundledPath, self.fm.fileExists(atPath: bPath) {
                srcPath = bPath
            } else {
                // Fallback: write embedded script to /tmp
                do {
                    try Self.embeddedVPNCoreScript.write(toFile: tmpHelper, atomically: true, encoding: .utf8)
                    srcPath = tmpHelper
                } catch {
                    DispatchQueue.main.async {
                        completion(false, "Could not prepare helper script: \(error.localizedDescription)")
                    }
                    return
                }
            }

            let userName = NSUserName()
            func q(_ s: String) -> String { "'\(s.replacingOccurrences(of: "'", with: "'\\''"))'" }

            let shellCmd = """
            mkdir -p /usr/local/libexec && \
            cp \(q(srcPath)) \(q(self.helperPath)) && \
            chown root:wheel \(q(self.helperPath)) && \
            chmod 755 \(q(self.helperPath)) && \
            TMP_SUD=$(mktemp) && \
            printf '%s ALL=(root) NOPASSWD: %s *\\n' \(q(userName)) \(q(self.helperPath)) > "$TMP_SUD" && \
            visudo -cf "$TMP_SUD" && \
            cp "$TMP_SUD" /etc/sudoers.d/overlay-vpn && \
            chown root:wheel /etc/sudoers.d/overlay-vpn && \
            chmod 440 /etc/sudoers.d/overlay-vpn && \
            rm -f "$TMP_SUD"
            """
            let escaped = shellCmd.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            let appleScript = "do shell script \"\(escaped)\" with administrator privileges"
            let (rc, out) = self.runProcessWithStatus(executable: "/usr/bin/osascript", arguments: ["-e", appleScript])
            try? self.fm.removeItem(atPath: tmpHelper)

            DispatchQueue.main.async {
                self.objectWillChange.send()
                if rc == 0 {
                    self.setFeedback("Passwordless VPN helper installed", isError: false)
                    completion(true, "Installed! VPN connect/disconnect now runs without password prompts.")
                } else {
                    let msg = out.trimmingCharacters(in: .whitespacesAndNewlines)
                    completion(false, msg.isEmpty ? "Installation cancelled or failed." : msg)
                }
            }
        }
    }

    private static let embeddedVPNCoreScript = #"""
#!/usr/bin/env bash
set -euo pipefail
CMD="${1:-}"
shift || true
case "$CMD" in
    start-singbox)
        BIN="$1"; CFG="$2"; PID_FILE="$3"; LOG_FILE="$4"
        if [ -f "$PID_FILE" ]; then
            OLD_PID="$(cat "$PID_FILE" 2>/dev/null || true)"
            [ -n "$OLD_PID" ] && kill -TERM "$OLD_PID" 2>/dev/null || true
            rm -f "$PID_FILE"
        fi
        "$BIN" check -c "$CFG"
        nohup "$BIN" run -c "$CFG" >> "$LOG_FILE" 2>&1 < /dev/null &
        echo $! > "$PID_FILE"
        ;;
    start-openconnect)
        BIN="$1"; PID_FILE="$2"; SERVER="$3"; USER_NAME="${4:-}"; PASSWORD="${5:-}"; EXTRA_ARGS="${6:-}"; LOG_FILE="${7:-/tmp/overlay-openconnect.log}"
        if [ -f "$PID_FILE" ]; then
            OLD_PID="$(cat "$PID_FILE" 2>/dev/null || true)"
            [ -n "$OLD_PID" ] && (kill -INT "$OLD_PID" 2>/dev/null || kill -TERM "$OLD_PID" 2>/dev/null || true)
            rm -f "$PID_FILE"
        fi
        ARGS=("--background" "--non-inter" "--pid-file=$PID_FILE")
        [ -n "$USER_NAME" ] && ARGS+=("--user" "$USER_NAME")
        if [ -n "$EXTRA_ARGS" ]; then
            EXTRA_ARR=($EXTRA_ARGS)
            ARGS+=("${EXTRA_ARR[@]}")
        fi
        if [ -n "$PASSWORD" ]; then
            ARGS+=("--passwd-on-stdin")
            printf '%s\n' "$PASSWORD" | "$BIN" "${ARGS[@]}" "$SERVER" >> "$LOG_FILE" 2>&1 < /dev/null
        else
            "$BIN" "${ARGS[@]}" "$SERVER" >> "$LOG_FILE" 2>&1 < /dev/null
        fi
        ;;
    stop-pid)
        PID="$1"; PID_FILE="${2:-}"
        kill -INT "$PID" 2>/dev/null || kill -TERM "$PID" 2>/dev/null || true
        [ -n "$PID_FILE" ] && rm -f "$PID_FILE"
        ;;
    stop-all)
        SB_PID="${1:-}"; OC_PID="${2:-}"
        pkill -TERM -f "sing-box run" 2>/dev/null || true
        pkill -INT openconnect 2>/dev/null || pkill -TERM openconnect 2>/dev/null || true
        [ -n "$SB_PID" ] && rm -f "$SB_PID"
        [ -n "$OC_PID" ] && rm -f "$OC_PID"
        ;;
    *)
        exit 1
        ;;
esac
"""#

    init() {
        ensureConfigDir()
        loadStore()
        refresh()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    deinit {
        pollTimer?.invalidate()
    }

    // MARK: - Persistence

    private func ensureConfigDir() {
        try? fm.createDirectory(atPath: configDir, withIntermediateDirectories: true)
    }

    private func loadStore() {
        guard let data = try? Data(contentsOf: storeFileURL),
              let decoded = try? JSONDecoder().decode(VPNStoreData.self, from: data) else {
            return
        }
        self.store = decoded
    }

    func saveStore() {
        ensureConfigDir()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(store) {
            try? data.write(to: storeFileURL, options: .atomic)
        }
    }

    // MARK: - Live Status Polling (100% Native, Detects Already-Running VPN Across Restarts)

    private func saveActiveSession(server: VPNServerConfig, providerKind: String) {
        ensureConfigDir()
        let session = ActiveVPNSession(
            serverID: server.id,
            serverName: server.displayName,
            providerKind: providerKind,
            startedAt: Date()
        )
        if let data = try? JSONEncoder().encode(session) {
            try? data.write(to: activeSessionURL, options: .atomic)
        }
    }

    private func loadActiveSession() -> ActiveVPNSession? {
        guard let data = try? Data(contentsOf: activeSessionURL),
              let session = try? JSONDecoder().decode(ActiveVPNSession.self, from: data) else {
            return nil
        }
        return session
    }

    private func clearActiveSession() {
        try? fm.removeItem(at: activeSessionURL)
    }

    func refresh() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }

            let neList = self.querySystemVPNs()
            let sbPID = self.findRunningPID(pidFile: self.singBoxPIDFile, processMatch: "sing-box")
            let ocPID = self.findRunningPID(pidFile: self.openConnectPIDFile, processMatch: "openconnect")
            let connectedNE = neList.first(where: { $0.extraArgs == "Connected" })
            let savedSession = self.loadActiveSession()
            let tunnelIface = self.detectTunnelInterface()

            var status = VPNLiveStatus()
            if let pid = sbPID {
                status.connected = true
                status.providerKind = "sing-box"
                status.activePID = pid
                let resolvedID = (savedSession?.providerKind == "sing-box" ? savedSession?.serverID : nil) ?? self.store.selectedServerID
                status.activeServerID = resolvedID
                let matchedName = self.store.servers.first(where: { $0.id == resolvedID })?.displayName
                status.providerLabel = matchedName ?? savedSession?.serverName ?? "sing-box"
                status.iface = tunnelIface
            } else if let pid = ocPID {
                status.connected = true
                status.providerKind = "openconnect"
                status.activePID = pid
                let resolvedID = (savedSession?.providerKind == "openconnect" ? savedSession?.serverID : nil) ?? self.store.selectedServerID
                status.activeServerID = resolvedID
                let matchedName = self.store.servers.first(where: { $0.id == resolvedID })?.displayName
                status.providerLabel = matchedName ?? savedSession?.serverName ?? "OpenConnect"
                status.iface = tunnelIface
            } else if let ne = connectedNE {
                status.connected = true
                status.providerKind = "systemVPN"
                status.activeServiceName = ne.serviceName
                status.activeServerID = ne.id
                status.providerLabel = ne.displayName
                status.iface = tunnelIface
            } else if !tunnelIface.isEmpty {
                // External tunnel interface detected even if started outside Overlay
                status.connected = true
                status.providerKind = "tunnel"
                status.providerLabel = "VPN Tunnel (\(tunnelIface))"
                status.iface = tunnelIface
            } else if savedSession != nil {
                // Process is no longer running; clear stale session marker
                self.clearActiveSession()
            }

            DispatchQueue.main.async {
                self.systemVPNs = neList
                self.liveStatus = status
                if status.connected, let activeID = status.activeServerID, self.store.selectedServerID != activeID {
                    self.store.selectedServerID = activeID
                }
            }
        }
    }

    func isServerConnected(_ server: VPNServerConfig) -> Bool {
        guard liveStatus.connected else { return false }
        if server.proto == .systemVPN {
            return server.extraArgs == "Connected"
        }
        return liveStatus.activeServerID == server.id
    }

    // MARK: - CRUD for Servers, Subscriptions, and Rules

    func selectServer(_ server: VPNServerConfig) {
        store.selectedServerID = server.id
        saveStore()
    }

    func saveServer(_ server: VPNServerConfig) {
        if let idx = store.servers.firstIndex(where: { $0.id == server.id }) {
            store.servers[idx] = server
        } else {
            store.servers.append(server)
            if store.selectedServerID == nil {
                store.selectedServerID = server.id
            }
        }
        saveStore()
        setFeedback("Saved \(server.displayName)")
    }

    func deleteServer(_ server: VPNServerConfig) {
        store.servers.removeAll { $0.id == server.id }
        if store.selectedServerID == server.id {
            store.selectedServerID = allServers.first?.id
        }
        saveStore()
    }

    func importFromClipboard() {
        guard let text = NSPasteboard.general.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            setFeedback("Clipboard is empty", isError: true)
            return
        }
        let parsed = VPNURIParser.parseMany(text, groupID: "local")
        guard !parsed.isEmpty else {
            setFeedback("No supported VPN URI found in clipboard", isError: true)
            return
        }
        store.servers.append(contentsOf: parsed)
        if store.selectedServerID == nil {
            store.selectedServerID = parsed.first?.id
        }
        saveStore()
        setFeedback("Imported \(parsed.count) config\(parsed.count == 1 ? "" : "s") from clipboard")
    }

    func addSubscription(name: String, url: String, completion: @escaping (Bool, String) -> Void) {
        let trimmedURL = url.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsedURL = URL(string: trimmedURL), parsedURL.scheme?.hasPrefix("http") == true else {
            completion(false, "Invalid subscription URL")
            return
        }

        let sub = VPNSubscription(
            name: trimmedName.isEmpty ? (parsedURL.host ?? "Subscription") : trimmedName,
            url: trimmedURL
        )

        fetchSubscriptionServers(url: parsedURL, groupID: sub.id) { [weak self] servers, error in
            guard let self else { return }
            if let error {
                completion(false, error)
                return
            }
            var savedSub = sub
            savedSub.lastUpdated = Date()
            self.store.subscriptions.append(savedSub)
            self.store.servers.append(contentsOf: servers)
            if self.store.selectedServerID == nil {
                self.store.selectedServerID = servers.first?.id
            }
            self.saveStore()
            completion(true, "Added \(savedSub.name) (\(servers.count) servers)")
        }
    }

    func updateSubscription(_ sub: VPNSubscription) {
        guard let url = URL(string: sub.url) else { return }
        setFeedback("Updating \(sub.name)…")
        fetchSubscriptionServers(url: url, groupID: sub.id) { [weak self] servers, error in
            guard let self else { return }
            if let error {
                self.setFeedback(error, isError: true)
                return
            }
            self.store.servers.removeAll { $0.groupID == sub.id }
            self.store.servers.append(contentsOf: servers)
            if let idx = self.store.subscriptions.firstIndex(where: { $0.id == sub.id }) {
                self.store.subscriptions[idx].lastUpdated = Date()
            }
            self.saveStore()
            self.setFeedback("Updated \(sub.name) (\(servers.count) servers)")
        }
    }

    func updateAllSubscriptions() {
        guard !store.subscriptions.isEmpty else {
            setFeedback("No subscriptions to update")
            return
        }
        for sub in store.subscriptions {
            updateSubscription(sub)
        }
    }

    func deleteSubscription(_ sub: VPNSubscription) {
        store.subscriptions.removeAll { $0.id == sub.id }
        store.servers.removeAll { $0.groupID == sub.id }
        saveStore()
        setFeedback("Deleted subscription \(sub.name)")
    }

    // MARK: - Split-Tunnel Rules

    func setMode(_ mode: VPNRouteMode) {
        store.mode = mode
        saveStore()
    }

    static func normalizeRuleTarget(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return "" }
        if s.lowercased().hasPrefix("service:") {
            return s.lowercased()
        }
        // If the user pasted a full URL (e.g. https://www.youtube.com/watch?v=...), extract the host
        if let url = URL(string: s), let host = url.host, !host.isEmpty {
            s = host
        } else if s.lowercased().hasPrefix("http://") || s.lowercased().hasPrefix("https://") {
            s = s.replacingOccurrences(of: "^https?://", with: "", options: [.regularExpression, .caseInsensitive])
            if let slash = s.firstIndex(of: "/") { s = String(s[..<slash]) }
            if let q = s.firstIndex(of: "?") { s = String(s[..<q]) }
        } else if !s.contains("/") {
            // Domain or IP without path
            s = s.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @discardableResult
    func addRuleResult(target: String, type: VPNRuleType? = nil, label: String = "", tag: String = "") -> RuleAddResult {
        let cleaned = Self.normalizeRuleTarget(target)
        guard !cleaned.isEmpty else { return .invalid }

        let key = cleaned.lowercased()
        if let existing = activeRules.first(where: { Self.normalizeRuleTarget($0.target).lowercased() == key }) {
            setFeedback("Already exists: \(existing.target) (\(existing.resolvedCategory))", isError: true)
            return .duplicate(existing)
        }

        let resolvedType: VPNRuleType
        if let type {
            resolvedType = type
        } else if key.hasPrefix("service:") {
            resolvedType = .service
        } else if cleaned.contains("/") || cleaned.allSatisfy({ $0.isNumber || $0 == "." || $0 == ":" }) {
            resolvedType = .ipCidr
        } else {
            resolvedType = .domain
        }

        let cleanTag = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        let rule = VPNRule(target: cleaned, type: resolvedType, label: label, tag: cleanTag)
        if store.mode == .vpnDefault {
            store.bypassRules.append(rule)
        } else {
            store.vpnRules.append(rule)
        }
        saveStore()
        setFeedback("Added \(cleaned)")
        return .added(rule)
    }

    func addRule(target: String, type: VPNRuleType? = nil, label: String = "", tag: String = "") {
        _ = addRuleResult(target: target, type: type, label: label, tag: tag)
    }

    func updateRuleTag(_ rule: VPNRule, tag: String) {
        let cleanTag = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        if store.mode == .vpnDefault {
            if let idx = store.bypassRules.firstIndex(where: { $0.id == rule.id }) {
                store.bypassRules[idx].tag = cleanTag
            }
        } else {
            if let idx = store.vpnRules.firstIndex(where: { $0.id == rule.id }) {
                store.vpnRules[idx].tag = cleanTag
            }
        }
        saveStore()
    }

    func setRulesEnabled(_ rules: [VPNRule], enabled: Bool) {
        let ids = Set(rules.map(\.id))
        if store.mode == .vpnDefault {
            for i in store.bypassRules.indices where ids.contains(store.bypassRules[i].id) {
                store.bypassRules[i].enabled = enabled
            }
        } else {
            for i in store.vpnRules.indices where ids.contains(store.vpnRules[i].id) {
                store.vpnRules[i].enabled = enabled
            }
        }
        saveStore()
        setFeedback("\(enabled ? "Enabled" : "Disabled") \(ids.count) rule(s)")
    }

    func deleteRules(_ rules: [VPNRule]) {
        let ids = Set(rules.map(\.id))
        if store.mode == .vpnDefault {
            store.bypassRules.removeAll { ids.contains($0.id) }
        } else {
            store.vpnRules.removeAll { ids.contains($0.id) }
        }
        saveStore()
        setFeedback("Removed \(ids.count) rule(s)")
    }

    /// Flushes DNS cache, resolves fresh IPs for all enabled domain rules, updates Google IP ranges if used,
    /// and reloads the active sing-box tunnel if currently connected so bypass rules take effect immediately.
    func refreshBypassAndIPs() {
        guard !isRefreshingBypass else { return }
        isRefreshingBypass = true
        setFeedback("Refreshing DNS & bypass IPs…")

        let rulesSnapshot = activeRules.filter(\.enabled)
        let hasGoogleService = rulesSnapshot.contains { $0.target.lowercased() == "service:google" }

        if hasGoogleService {
            VPNRuleServices.fetchGoogleRanges { _, _ in }
        }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            // Flush local DNS cache so domain resolutions get fresh IPs
            _ = self.runProcess(executable: "/usr/bin/dscacheutil", arguments: ["-flushcache"])

            var resolvedMap: [String: [String]] = [:]
            var totalIPs = 0
            let domainRules = rulesSnapshot.filter { $0.type == .domain }

            for rule in domainRules {
                let ips = Self.resolveIPv4Addresses(for: rule.target)
                if !ips.isEmpty {
                    resolvedMap[rule.id] = ips
                    totalIPs += ips.count
                }
            }

            DispatchQueue.main.async {
                for (id, ips) in resolvedMap {
                    self.resolvedIPsByRuleID[id] = ips
                }
                self.lastBypassRefreshAt = Date()

                // If sing-box is currently connected, rebuild config & reload it so new rules/IPs apply live
                if self.liveStatus.connected,
                   self.liveStatus.providerKind == "sing-box",
                   let activeID = self.liveStatus.activeServerID,
                   let srv = self.allServers.first(where: { $0.id == activeID }) {
                    self.isRefreshingBypass = false
                    self.connectServer(srv)
                    self.setFeedback("Refreshed \(totalIPs) IPs (\(domainRules.count) domains) & reloaded bypass")
                } else {
                    self.isRefreshingBypass = false
                    self.setFeedback("Refreshed \(totalIPs) IPs across \(domainRules.count) domain(s)")
                }
            }
        }
    }

    private static func resolveIPv4Addresses(for host: String) -> [String] {
        var hints = addrinfo(
            ai_flags: 0,
            ai_family: AF_INET,
            ai_socktype: SOCK_STREAM,
            ai_protocol: 0,
            ai_addrlen: 0,
            ai_canonname: nil,
            ai_addr: nil,
            ai_next: nil
        )
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &result) == 0, let first = result else {
            return []
        }
        defer { freeaddrinfo(first) }

        var ips: [String] = []
        var ptr: UnsafeMutablePointer<addrinfo>? = first
        while let current = ptr {
            if let addr = current.pointee.ai_addr {
                var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                if getnameinfo(addr, socklen_t(current.pointee.ai_addrlen), &hostBuffer, socklen_t(hostBuffer.count), nil, 0, NI_NUMERICHOST) == 0 {
                    let ip = String(cString: hostBuffer)
                    if !ips.contains(ip) {
                        ips.append(ip)
                    }
                }
            }
            ptr = current.pointee.ai_next
        }
        return ips
    }

    func addGoogleServiceRule() {
        setFeedback("Downloading Google & YouTube IP ranges…")
        VPNRuleServices.fetchGoogleRanges { [weak self] ranges, error in
            guard let self else { return }
            if let error, ranges.isEmpty {
                self.setFeedback(error, isError: true)
                return
            }
            let existing = Set(self.activeRules.map { $0.target.lowercased() })
            if !existing.contains("service:google") {
                self.addRule(target: "service:google", type: .service, label: "Google & YouTube (\(ranges.count) IPv4 ranges)")
            }
            self.setFeedback("Google & YouTube ready (\(ranges.count) IPv4 ranges)")
        }
    }

    func addSDRPopRules(_ pop: SDRPop) {
        let existing = Set(activeRules.map { $0.target.lowercased() })
        var added = 0
        for cidr in pop.cidrs where !existing.contains(cidr.lowercased()) {
            addRule(target: cidr, type: .ipCidr, label: "Dota 2 SDR · \(pop.label)")
            added += 1
        }
        setFeedback("Added \(added) SDR subnets for \(pop.code)")
    }

    func toggleRule(_ rule: VPNRule) {
        if store.mode == .vpnDefault {
            if let idx = store.bypassRules.firstIndex(where: { $0.id == rule.id }) {
                store.bypassRules[idx].enabled.toggle()
            }
        } else {
            if let idx = store.vpnRules.firstIndex(where: { $0.id == rule.id }) {
                store.vpnRules[idx].enabled.toggle()
            }
        }
        saveStore()
    }

    func deleteRule(_ rule: VPNRule) {
        if store.mode == .vpnDefault {
            store.bypassRules.removeAll { $0.id == rule.id }
        } else {
            store.vpnRules.removeAll { $0.id == rule.id }
        }
        saveStore()
    }

    func addPresetRules(service: String) {
        let presets: [(String, VPNRuleType, String)]
        switch service {
        case "Google & YouTube":
            presets = [
                ("google.com", .domain, "Google"),
                ("youtube.com", .domain, "YouTube"),
                ("googlevideo.com", .domain, "YouTube Video"),
                ("gstatic.com", .domain, "Google Static")
            ]
        case "Steam & Gaming":
            presets = [
                ("steampowered.com", .domain, "Steam"),
                ("steamcommunity.com", .domain, "Steam"),
                ("steamstatic.com", .domain, "Steam CDN"),
                ("valve.net", .domain, "Valve")
            ]
        case "Telegram":
            presets = [
                ("telegram.org", .domain, "Telegram"),
                ("t.me", .domain, "Telegram"),
                ("91.108.4.0/22", .ipCidr, "Telegram DC"),
                ("149.154.160.0/20", .ipCidr, "Telegram DC")
            ]
        case "Apple & iCloud":
            presets = [
                ("apple.com", .domain, "Apple"),
                ("icloud.com", .domain, "iCloud"),
                ("mzstatic.com", .domain, "Apple CDN")
            ]
        default:
            presets = []
        }

        let existing = Set(activeRules.map { $0.target.lowercased() })
        for (target, type, label) in presets where !existing.contains(target.lowercased()) {
            addRule(target: target, type: type, label: label)
        }
        setFeedback("Added \(service) rules")
    }

    // MARK: - Import / Export JSON & One-Click Import from ocpanel

    func exportJSONWithDialog() {
        let panel = NSSavePanel()
        panel.title = "Export Overlay VPN Configs & Rules"
        panel.nameFieldStringValue = "overlay-vpn-backup.json"
        panel.allowedContentTypes = [.json]
        if panel.runModal() == .OK, let url = panel.url {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let data = try? encoder.encode(store) {
                try? data.write(to: url, options: .atomic)
                setFeedback("Exported to \(url.lastPathComponent)")
            }
        }
    }

    func importJSONWithDialog() {
        let panel = NSOpenPanel()
        panel.title = "Import Overlay VPN Configs & Rules"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            guard let data = try? Data(contentsOf: url) else {
                setFeedback("Could not read file", isError: true)
                return
            }
            if let decoded = try? JSONDecoder().decode(VPNStoreData.self, from: data) {
                store.servers.append(contentsOf: decoded.servers)
                store.subscriptions.append(contentsOf: decoded.subscriptions)
                store.bypassRules.append(contentsOf: decoded.bypassRules)
                store.vpnRules.append(contentsOf: decoded.vpnRules)
                store.mode = decoded.mode
                saveStore()
                setFeedback("Imported \(decoded.servers.count) servers & \(decoded.bypassRules.count + decoded.vpnRules.count) rules")
            } else if let text = String(data: data, encoding: .utf8) {
                let parsed = VPNURIParser.parseMany(text)
                if !parsed.isEmpty {
                    store.servers.append(contentsOf: parsed)
                    saveStore()
                    setFeedback("Imported \(parsed.count) URI configs")
                } else {
                    setFeedback("Unrecognized config format", isError: true)
                }
            }
        }
    }

    /// Copies ONLY the bypass rules (and cached service ranges like service:google) from ~/.config/ocpanel/config.json.
    func importBypassRulesFromOCPanel() {
        let ocPath = "\(homeDir)/.config/ocpanel/config.json"
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: ocPath)),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            setFeedback("No ocpanel config found at ~/.config/ocpanel/config.json", isError: true)
            return
        }

        var importedCount = 0

        func parseOCPanelRule(_ r: [String: Any]) -> VPNRule? {
            guard let target = r["target"] as? String, !target.isEmpty else { return nil }
            let note = (r["note"] as? String) ?? (r["label"] as? String) ?? ""
            let enabled = (r["enabled"] as? Bool) ?? true
            let type: VPNRuleType
            if target.lowercased().hasPrefix("service:") {
                type = .service
                _ = VPNRuleServices.cachedRanges(for: String(target.dropFirst("service:".count)))
            } else if target.contains("/") || target.allSatisfy({ $0.isNumber || $0 == "." }) {
                type = .ipCidr
            } else {
                type = .domain
            }
            return VPNRule(target: target, type: type, label: note, enabled: enabled)
        }

        let existingBypass = Set(store.bypassRules.map { $0.target.lowercased() })
        if let rules = root["rules"] as? [[String: Any]] {
            for r in rules {
                guard let parsed = parseOCPanelRule(r), !existingBypass.contains(parsed.target.lowercased()) else { continue }
                store.bypassRules.append(parsed)
                importedCount += 1
            }
        }

        saveStore()
        setFeedback(importedCount > 0 ? "Copied \(importedCount) bypass rule\(importedCount == 1 ? "" : "s") from ocpanel" : "All ocpanel bypass rules already copied")
    }

    // MARK: - Real TCP Ping Tester

    func pingAllServers() {
        guard !isPinging else { return }
        let targets = store.servers.filter { !$0.address.isEmpty && $0.port > 0 }
        guard !targets.isEmpty else { return }
        isPinging = true
        let group = DispatchGroup()

        for srv in targets {
            group.enter()
            measureTCPPing(host: srv.address, port: srv.port) { [weak self] ms in
                DispatchQueue.main.async {
                    self?.pings[srv.id] = ms
                }
                group.leave()
            }
        }

        group.notify(queue: .main) { [weak self] in
            self?.isPinging = false
        }
    }

    func pingServers(in groupID: String) {
        let targets = store.servers.filter { $0.groupID == groupID && !$0.address.isEmpty && $0.port > 0 }
        for srv in targets {
            measureTCPPing(host: srv.address, port: srv.port) { [weak self] ms in
                DispatchQueue.main.async {
                    self?.pings[srv.id] = ms
                }
            }
        }
    }

    private func measureTCPPing(host: String, port: Int, completion: @escaping (Int) -> Void) {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(max(1, min(65535, port)))) else {
            completion(-1)
            return
        }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        let start = CFAbsoluteTimeGetCurrent()
        var finished = false
        let lock = NSLock()

        func finish(_ result: Int) {
            lock.lock()
            defer { lock.unlock() }
            guard !finished else { return }
            finished = true
            conn.cancel()
            completion(result)
        }

        conn.stateUpdateHandler = { state in
            switch state {
            case .ready:
                let ms = Int((CFAbsoluteTimeGetCurrent() - start) * 1000.0)
                finish(max(1, ms))
            case .failed, .cancelled:
                finish(-1)
            default:
                break
            }
        }

        let queue = DispatchQueue(label: "overlay.ping.\(UUID().uuidString)")
        conn.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 3.0) {
            finish(-1)
        }
    }

    // MARK: - Connect / Disconnect (100% Standalone Core)

    func toggleServer(_ server: VPNServerConfig) {
        if isServerConnected(server) {
            disconnectActive()
        } else {
            connectServer(server)
        }
    }

    func connectServer(_ server: VPNServerConfig) {
        selectServer(server)
        isBusy = true
        setFeedback("Connecting to \(server.displayName)…")

        switch server.proto {
        case .systemVPN:
            guard let svc = server.serviceName else {
                isBusy = false
                return
            }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else { return }
                _ = self.runProcess(executable: "/usr/sbin/scutil", arguments: ["--nc", "start", svc])
                Thread.sleep(forTimeInterval: 1.5)
                DispatchQueue.main.async {
                    self.isBusy = false
                    self.refresh()
                }
            }

        case .openconnect:
            guard let ocBin = openConnectBinaryPath else {
                isBusy = false
                setFeedback("openconnect not installed (brew install openconnect)", isError: true)
                return
            }
            ensureConfigDir()
            saveActiveSession(server: server, providerKind: "openconnect")
            runPrivilegedCoreAction(
                command: "start-openconnect",
                args: [ocBin, openConnectPIDFile, server.address, server.username, server.secret, server.extraArgs, "\(configDir)/openconnect.log"],
                successMessage: "Connected to \(server.displayName)"
            )

        default:
            guard let sbBin = singBoxBinaryPath else {
                isBusy = false
                setFeedback("sing-box not installed (brew install sing-box)", isError: true)
                return
            }
            ensureConfigDir()
            let configObj = VPNURIParser.buildSingBoxConfig(
                server: server,
                mode: store.mode,
                bypassRules: store.bypassRules,
                vpnRules: store.vpnRules
            )
            guard let data = try? JSONSerialization.data(withJSONObject: configObj, options: [.prettyPrinted]) else {
                isBusy = false
                setFeedback("Failed to build sing-box config", isError: true)
                return
            }
            do {
                try data.write(to: singBoxConfigURL, options: .atomic)
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: singBoxConfigURL.path)
            } catch {
                isBusy = false
                setFeedback("Failed to write sing-box config", isError: true)
                return
            }

            saveActiveSession(server: server, providerKind: "sing-box")
            runPrivilegedCoreAction(
                command: "start-singbox",
                args: [sbBin, singBoxConfigURL.path, singBoxPIDFile, "\(configDir)/sing-box.log"],
                successMessage: "Connected to \(server.displayName)"
            )
        }
    }

    func disconnectActive() {
        let status = liveStatus
        guard status.connected else { return }
        isBusy = true
        clearActiveSession()
        setFeedback("Disconnecting \(status.providerLabel)…")

        if status.providerKind == "systemVPN", let svc = status.activeServiceName {
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else { return }
                _ = self.runProcess(executable: "/usr/sbin/scutil", arguments: ["--nc", "stop", svc])
                Thread.sleep(forTimeInterval: 1.0)
                DispatchQueue.main.async {
                    self.isBusy = false
                    self.refresh()
                }
            }
            return
        }

        if let pid = status.activePID {
            let pidFile = status.providerKind == "openconnect" ? openConnectPIDFile : singBoxPIDFile
            runPrivilegedCoreAction(
                command: "stop-pid",
                args: ["\(pid)", pidFile],
                successMessage: "Disconnected"
            )
        } else {
            // Fallback: stop any running sing-box / openconnect even if PID wasn't recorded
            runPrivilegedCoreAction(
                command: "stop-all",
                args: [singBoxPIDFile, openConnectPIDFile],
                successMessage: "Disconnected"
            )
        }
    }

    // MARK: - Privileged Core Runner (Passwordless sudoers helper -> fallback macOS admin prompt)

    private func runPrivilegedCoreAction(command: String, args: [String], successMessage: String) {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }

            var rc: Int32 = -1
            var out = ""

            if self.fm.isExecutableFile(atPath: self.helperPath) {
                let res = self.runProcessWithStatus(
                    executable: "/usr/bin/sudo",
                    arguments: ["-n", self.helperPath, command] + args
                )
                rc = res.0
                out = res.1
            }

            if rc != 0 {
                // Fallback to macOS admin dialog using a direct shell command
                let shellCmd = self.buildFallbackShellCommand(command: command, args: args)
                let escaped = shellCmd.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
                let appleScript = "do shell script \"\(escaped)\" with administrator privileges"
                let res = self.runProcessWithStatus(executable: "/usr/bin/osascript", arguments: ["-e", appleScript])
                rc = res.0
                out = res.1
            }

            Thread.sleep(forTimeInterval: 0.9)
            DispatchQueue.main.async {
                self.isBusy = false
                if rc == 0 {
                    self.setFeedback(successMessage, isError: false)
                } else {
                    let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
                    self.setFeedback(trimmed.isEmpty ? "Cancelled or failed" : String(trimmed.prefix(90)), isError: true)
                }
                self.refresh()
            }
        }
    }

    private func buildFallbackShellCommand(command: String, args: [String]) -> String {
        func q(_ s: String) -> String { "'\(s.replacingOccurrences(of: "'", with: "'\\''"))'" }
        switch command {
        case "start-singbox":
            let bin = args[0], cfg = args[1], pidF = args[2], logF = args[3]
            return "if [ -f \(q(pidF)) ]; then kill $(cat \(q(pidF))) 2>/dev/null || true; rm -f \(q(pidF)); fi; \(q(bin)) check -c \(q(cfg)) && nohup \(q(bin)) run -c \(q(cfg)) >> \(q(logF)) 2>&1 < /dev/null & echo $! > \(q(pidF))"
        case "start-openconnect":
            let bin = args[0], pidF = args[1], srv = args[2], usr = args[3], pw = args[4], extra = args[5]
            let logF = args.count > 6 ? args[6] : "/tmp/overlay-openconnect.log"
            let userArg = usr.isEmpty ? "" : "--user \(q(usr))"
            let pwPipe = pw.isEmpty ? "" : "printf '%s\\n' \(q(pw)) | "
            let pwFlag = pw.isEmpty ? "" : "--passwd-on-stdin"
            return "if [ -f \(q(pidF)) ]; then kill -INT $(cat \(q(pidF))) 2>/dev/null || kill -TERM $(cat \(q(pidF))) 2>/dev/null || true; rm -f \(q(pidF)); fi; \(pwPipe)\(q(bin)) --background --non-inter --pid-file=\(q(pidF)) \(userArg) \(pwFlag) \(extra) \(q(srv)) >> \(q(logF)) 2>&1 < /dev/null"
        case "stop-pid":
            let pid = args[0], pidF = args[1]
            return "kill -INT \(q(pid)) 2>/dev/null || kill -TERM \(q(pid)) 2>/dev/null || true; rm -f \(q(pidF))"
        case "stop-all":
            let sbPid = args[0], ocPid = args[1]
            return "pkill -TERM -f 'sing-box run' 2>/dev/null || true; pkill -INT openconnect 2>/dev/null || pkill -TERM openconnect 2>/dev/null || true; rm -f \(q(sbPid)) \(q(ocPid))"
        default:
            return "true"
        }
    }

    // MARK: - Helpers

    private func fetchSubscriptionServers(url: URL, groupID: String, completion: @escaping ([VPNServerConfig], String?) -> Void) {
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("v2rayN/6.0", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, _, error in
            DispatchQueue.main.async {
                if let error {
                    completion([], error.localizedDescription)
                    return
                }
                guard let data, let body = String(data: data, encoding: .utf8) else {
                    completion([], "Empty subscription response")
                    return
                }
                let servers = VPNURIParser.parseMany(body, groupID: groupID)
                if servers.isEmpty {
                    completion([], "No valid servers found in subscription")
                } else {
                    completion(servers, nil)
                }
            }
        }.resume()
    }

    private func querySystemVPNs() -> [VPNServerConfig] {
        let out = runProcess(executable: "/usr/sbin/scutil", arguments: ["--nc", "list"])
        var list: [VPNServerConfig] = []
        // Example: * (Connected)   UUID IPSec (bundle) "V2BOX"
        let pattern = #"^\s*(\*|\s)\s*\((\w+)\)\s+\S+\s+\S+\s+\([^)]*\)\s+"([^"]*)""#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        for line in out.components(separatedBy: .newlines) {
            let ns = line as NSString
            guard let m = regex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)),
                  m.numberOfRanges >= 4 else { continue }
            let status = ns.substring(with: m.range(at: 2))
            let name = ns.substring(with: m.range(at: 3))
            list.append(VPNServerConfig(
                id: "sysvpn:\(name)",
                groupID: "system",
                proto: .systemVPN,
                remarks: name,
                address: status,
                port: 0,
                extraArgs: status,
                serviceName: name
            ))
        }
        return list
    }

    private func findRunningPID(pidFile: String, processMatch: String) -> Int? {
        if let raw = try? String(contentsOfFile: pidFile, encoding: .utf8),
           let pid = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 {
            if kill(pid_t(pid), 0) == 0 || errno == EPERM {
                return pid
            }
        }
        // Use pgrep (fast, tiny output, sees root-owned processes too)
        let args: [String]
        if processMatch == "sing-box" {
            args = ["-f", "sing-box run"]
        } else {
            args = ["-x", processMatch]
        }
        let (rc, out) = runProcessWithStatus(executable: "/usr/bin/pgrep", arguments: args)
        if rc == 0 {
            for line in out.components(separatedBy: .newlines) {
                if let pid = Int(line.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 {
                    return pid
                }
            }
        }
        return nil
    }

    private func detectTunnelInterface() -> String {
        let out = runProcess(executable: "/usr/sbin/netstat", arguments: ["-rn", "-f", "inet"])
        for line in out.components(separatedBy: .newlines) {
            let cols = line.split(whereSeparator: { $0.isWhitespace })
            if cols.count >= 4 {
                let dest = String(cols[0])
                let iface = String(cols[3])
                if (dest == "default" || dest == "0/1" || dest == "128.0/1" || dest == "1" || dest == "172.19.0.1") && iface.hasPrefix("utun") {
                    return iface
                }
            }
        }
        return ""
    }

    private func readKeychainPassword(service: String, account: String) -> String? {
        let (rc, out) = runProcessWithStatus(
            executable: "/usr/bin/security",
            arguments: ["find-generic-password", "-w", "-a", account, "-s", service]
        )
        guard rc == 0 else { return nil }
        let trimmed = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func setFeedback(_ text: String, isError: Bool = false) {
        DispatchQueue.main.async { [weak self] in
            self?.feedbackMessage = text
            self?.feedbackIsError = isError
            DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
                if self?.feedbackMessage == text {
                    self?.feedbackMessage = nil
                }
            }
        }
    }

    private func runProcess(executable: String, arguments: [String]) -> String {
        runProcessWithStatus(executable: executable, arguments: arguments).1
    }

    private func runProcessWithStatus(executable: String, arguments: [String]) -> (Int32, String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: executable)
        proc.arguments = arguments
        let pipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = errPipe
        do {
            try proc.run()
            // Drain stdout & stderr concurrently BEFORE waitUntilExit() to prevent 64KB pipe deadlock
            var outData = Data()
            var errData = Data()
            let group = DispatchGroup()
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                outData = pipe.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }
            proc.waitUntilExit()
            group.wait()
            let combined = (String(data: outData, encoding: .utf8) ?? "") + (String(data: errData, encoding: .utf8) ?? "")
            return (proc.terminationStatus, combined)
        } catch {
            return (-1, error.localizedDescription)
        }
    }
}
