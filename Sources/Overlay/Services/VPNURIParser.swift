import Foundation

enum VPNURIParser {
    /// Parses a single URI or a multi-line / base64 subscription body into VPNServerConfig items.
    static func parseMany(_ rawText: String, groupID: String = "local") -> [VPNServerConfig] {
        let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }

        let decoded: String
        if !trimmed.contains("://"), let b64 = decodeBase64Flexible(trimmed), b64.contains("://") {
            decoded = b64
        } else {
            decoded = trimmed
        }

        var results: [VPNServerConfig] = []
        for rawLine in decoded.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || !line.contains("://") { continue }
            if var cfg = parseSingle(line) {
                cfg.groupID = groupID
                results.append(cfg)
            }
        }
        return results
    }

    static func parseSingle(_ uri: String) -> VPNServerConfig? {
        let s = uri.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let schemeRange = s.range(of: "://") else { return nil }
        let scheme = String(s[..<schemeRange.lowerBound]).lowercased()

        switch scheme {
        case "vmess":
            return parseVMess(s)
        case "vless":
            return parseStandardURI(s, proto: .vless)
        case "trojan":
            return parseStandardURI(s, proto: .trojan)
        case "ss":
            return parseShadowsocks(s)
        case "ssh":
            return parseStandardURI(s, proto: .ssh)
        case "hysteria2", "hy2":
            return parseStandardURI(s, proto: .hysteria2)
        case "socks", "socks5":
            return parseStandardURI(s, proto: .socks)
        case "http", "https":
            return parseStandardURI(s, proto: .http)
        default:
            return nil
        }
    }

    private static func parseVMess(_ uri: String) -> VPNServerConfig? {
        let body = String(uri.dropFirst("vmess://".count))
        guard let decoded = decodeBase64Flexible(body),
              let data = decoded.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return parseStandardURI(uri, proto: .vmess)
        }

        let address = (json["add"] as? String) ?? ""
        let port: Int
        if let p = json["port"] as? Int {
            port = p
        } else if let ps = json["port"] as? String, let p = Int(ps) {
            port = p
        } else {
            port = 443
        }
        guard !address.isEmpty else { return nil }

        let remarks = (json["ps"] as? String) ?? address
        let uuid = (json["id"] as? String) ?? ""
        let net = ((json["net"] as? String) ?? "tcp").lowercased()
        let host = (json["host"] as? String) ?? ""
        let path = (json["path"] as? String) ?? ""
        let tls = ((json["tls"] as? String) ?? "").lowercased()
        let sni = (json["sni"] as? String) ?? host
        let scy = (json["scy"] as? String) ?? "auto"

        return VPNServerConfig(
            proto: .vmess,
            remarks: remarks,
            address: address,
            port: port,
            secret: uuid,
            method: scy,
            security: tls == "tls" ? "tls" : "none",
            transport: net.isEmpty ? "tcp" : net,
            sni: sni,
            wsHost: host,
            path: path,
            rawURI: uri
        )
    }

    private static func parseShadowsocks(_ uri: String) -> VPNServerConfig? {
        // ss://BASE64(method:password)@host:port#remarks  OR  ss://BASE64(method:password@host:port)#remarks
        let afterScheme = String(uri.dropFirst("ss://".count))
        let hashParts = afterScheme.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false)
        let mainPart = String(hashParts[0])
        let remarks = hashParts.count > 1 ? (String(hashParts[1]).removingPercentEncoding ?? String(hashParts[1])) : ""

        var method = "aes-256-gcm"
        var password = ""
        var host = ""
        var port = 8388

        if let atIdx = mainPart.lastIndex(of: "@") {
            let userInfoRaw = String(mainPart[..<atIdx])
            let hostPortRaw = String(mainPart[mainPart.index(after: atIdx)...]).split(separator: "?").first.map(String.init) ?? ""
            let userInfo = decodeBase64Flexible(userInfoRaw) ?? (userInfoRaw.removingPercentEncoding ?? userInfoRaw)
            let creds = userInfo.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            if creds.count == 2 {
                method = String(creds[0])
                password = String(creds[1])
            }
            let hp = splitHostPort(hostPortRaw, defaultPort: 8388)
            host = hp.0
            port = hp.1
        } else if let decoded = decodeBase64Flexible(mainPart), let atIdx = decoded.lastIndex(of: "@") {
            let userInfo = String(decoded[..<atIdx])
            let hostPortRaw = String(decoded[decoded.index(after: atIdx)...])
            let creds = userInfo.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            if creds.count == 2 {
                method = String(creds[0])
                password = String(creds[1])
            }
            let hp = splitHostPort(hostPortRaw, defaultPort: 8388)
            host = hp.0
            port = hp.1
        }

        guard !host.isEmpty else { return nil }
        return VPNServerConfig(
            proto: .shadowsocks,
            remarks: remarks.isEmpty ? host : remarks,
            address: host,
            port: port,
            secret: password,
            method: method,
            rawURI: uri
        )
    }

    private static func parseStandardURI(_ uri: String, proto: VPNProtocol) -> VPNServerConfig? {
        guard let comps = URLComponents(string: uri) else { return nil }
        guard let host = comps.host, !host.isEmpty else { return nil }
        let port = comps.port ?? proto.defaultPort
        let remarks = (comps.fragment?.removingPercentEncoding ?? comps.fragment) ?? host
        let user = comps.user?.removingPercentEncoding ?? ""
        let pass = comps.password?.removingPercentEncoding ?? ""

        var queryMap: [String: String] = [:]
        for item in comps.queryItems ?? [] {
            queryMap[item.name] = item.value ?? ""
        }

        let security = (queryMap["security"] ?? (proto == .trojan || proto == .hysteria2 ? "tls" : "none")).lowercased()
        let transport = (queryMap["type"] ?? "tcp").lowercased()
        let sni = queryMap["sni"] ?? queryMap["peer"] ?? ""
        let wsHost = queryMap["host"] ?? ""
        let path = queryMap["path"] ?? ""
        let flow = queryMap["flow"] ?? ""
        let insecure = ["1", "true", "yes"].contains((queryMap["allowInsecure"] ?? queryMap["insecure"] ?? "").lowercased())

        var username = ""
        var secret = ""
        if proto == .ssh || proto == .socks || proto == .http {
            username = user
            secret = pass.isEmpty ? (queryMap["key"] ?? queryMap["private_key"] ?? "") : pass
        } else {
            secret = pass.isEmpty ? user : "\(user):\(pass)"
        }

        return VPNServerConfig(
            proto: proto,
            remarks: remarks,
            address: host,
            port: port,
            username: username,
            secret: secret,
            security: security,
            transport: transport,
            sni: sni,
            wsHost: wsHost,
            path: path,
            flow: flow,
            allowInsecure: insecure,
            rawURI: uri
        )
    }

    /// Exports a server back to a shareable URI string.
    static func exportURI(for cfg: VPNServerConfig) -> String {
        if let raw = cfg.rawURI, !raw.isEmpty {
            return raw
        }
        let encodedRemarks = cfg.displayName.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? cfg.displayName
        switch cfg.proto {
        case .vless:
            return "vless://\(cfg.secret)@\(cfg.address):\(cfg.port)?type=\(cfg.transport)&security=\(cfg.security)&sni=\(cfg.sni)&host=\(cfg.wsHost)&path=\(cfg.path)#\(encodedRemarks)"
        case .trojan:
            return "trojan://\(cfg.secret)@\(cfg.address):\(cfg.port)?type=\(cfg.transport)&security=\(cfg.security)&sni=\(cfg.sni)#\(encodedRemarks)"
        case .ssh:
            let auth = cfg.secret.isEmpty ? cfg.username : "\(cfg.username):\(cfg.secret)"
            return "ssh://\(auth)@\(cfg.address):\(cfg.port)#\(encodedRemarks)"
        case .hysteria2:
            return "hysteria2://\(cfg.secret)@\(cfg.address):\(cfg.port)?sni=\(cfg.sni)#\(encodedRemarks)"
        case .shadowsocks:
            let b64 = Data("\(cfg.method):\(cfg.secret)".utf8).base64EncodedString()
            return "ss://\(b64)@\(cfg.address):\(cfg.port)#\(encodedRemarks)"
        case .vmess:
            let obj: [String: Any] = [
                "v": "2", "ps": cfg.displayName, "add": cfg.address, "port": cfg.port,
                "id": cfg.secret, "aid": 0, "scy": cfg.method, "net": cfg.transport,
                "host": cfg.wsHost, "path": cfg.path, "tls": cfg.security == "tls" ? "tls" : "", "sni": cfg.sni
            ]
            if let data = try? JSONSerialization.data(withJSONObject: obj) {
                return "vmess://\(data.base64EncodedString())"
            }
            return "vmess://\(cfg.secret)@\(cfg.address):\(cfg.port)#\(encodedRemarks)"
        case .socks:
            let auth = cfg.username.isEmpty ? "" : "\(cfg.username):\(cfg.secret)@"
            return "socks5://\(auth)\(cfg.address):\(cfg.port)#\(encodedRemarks)"
        case .http:
            let auth = cfg.username.isEmpty ? "" : "\(cfg.username):\(cfg.secret)@"
            return "http://\(auth)\(cfg.address):\(cfg.port)#\(encodedRemarks)"
        case .openconnect:
            return "openconnect://\(cfg.username)@\(cfg.address):\(cfg.port)#\(encodedRemarks)"
        case .systemVPN:
            return cfg.serviceName ?? cfg.displayName
        }
    }

    // MARK: - Standalone sing-box JSON Generator (with built-in Split-Tunnel Rules)

    static func buildSingBoxConfig(
        server: VPNServerConfig,
        mode: VPNRouteMode,
        bypassRules: [VPNRule],
        vpnRules: [VPNRule]
    ) -> [String: Any] {
        var outbound = buildOutbound(for: server)
        outbound["tag"] = "proxy"

        var routeRules: [[String: Any]] = [
            ["action": "sniff"],
            ["protocol": "dns", "action": "hijack-dns"],
            ["port": 53, "action": "hijack-dns"],
            ["ip_is_private": true, "outbound": "direct"]
        ]

        // Apply user split-tunnel rules directly in sing-box routing (including ocpanel-style service:google IP ranges)
        let activeRules = (mode == .vpnDefault ? bypassRules : vpnRules).filter { $0.enabled }
        let targetOutbound = (mode == .vpnDefault) ? "direct" : "proxy"

        var domains: [String] = []
        var cidrs: [String] = []

        for rule in activeRules {
            let t = rule.target.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { continue }
            if rule.type == .service || t.lowercased().hasPrefix("service:") {
                let key = t.lowercased().hasPrefix("service:") ? String(t.dropFirst("service:".count)) : t.lowercased()
                let ranges = VPNRuleServices.cachedRanges(for: key)
                cidrs.append(contentsOf: ranges)
            } else if rule.type == .ipCidr {
                cidrs.append(t.contains("/") ? t : "\(t)/32")
            } else {
                domains.append(t)
            }
        }

        if !domains.isEmpty {
            routeRules.append([
                "domain_suffix": Array(Set(domains)).sorted(),
                "outbound": targetOutbound
            ])
        }
        if !cidrs.isEmpty {
            routeRules.append([
                "ip_cidr": Array(Set(cidrs)).sorted(),
                "outbound": targetOutbound
            ])
        }

        // Reject QUIC/UDP 443 for protocols that don't carry UDP (like SSH)
        if server.proto == .ssh || server.proto == .http {
            routeRules.append(["network": "udp", "port": 443, "action": "reject"])
        }

        return [
            "log": ["level": "warn"],
            "dns": [
                "servers": [
                    ["tag": "remote", "type": "udp", "server": "1.1.1.1", "detour": "proxy"],
                    ["tag": "local", "type": "udp", "server": "8.8.8.8"]
                ],
                "final": mode == .vpnDefault ? "remote" : "local"
            ],
            "inbounds": [
                [
                    "type": "tun",
                    "tag": "tun-in",
                    "address": ["172.19.0.1/30"],
                    "auto_route": true,
                    "strict_route": false
                ]
            ],
            "outbounds": [
                outbound,
                ["type": "direct", "tag": "direct"]
            ],
            "route": [
                "auto_detect_interface": true,
                "default_domain_resolver": ["server": "local"],
                "final": mode == .vpnDefault ? "proxy" : "direct",
                "rules": routeRules
            ]
        ]
    }

    private static func buildOutbound(for s: VPNServerConfig) -> [String: Any] {
        var out: [String: Any] = [
            "server": s.address,
            "server_port": s.port
        ]

        switch s.proto {
        case .vless:
            out["type"] = "vless"
            out["uuid"] = s.secret
            if !s.flow.isEmpty { out["flow"] = s.flow }
            attachTLSAndTransport(&out, s)
        case .vmess:
            out["type"] = "vmess"
            out["uuid"] = s.secret
            out["security"] = s.method.isEmpty ? "auto" : s.method
            out["alter_id"] = 0
            attachTLSAndTransport(&out, s)
        case .trojan:
            out["type"] = "trojan"
            out["password"] = s.secret
            attachTLSAndTransport(&out, s)
        case .shadowsocks:
            out["type"] = "shadowsocks"
            out["method"] = s.method.isEmpty ? "aes-256-gcm" : s.method
            out["password"] = s.secret
        case .ssh:
            out["type"] = "ssh"
            out["user"] = s.username.isEmpty ? "root" : s.username
            if s.secret.hasPrefix("/") || s.secret.hasPrefix("~") {
                out["private_key_path"] = (s.secret as NSString).expandingTildeInPath
            } else if !s.secret.isEmpty {
                out["password"] = s.secret
            }
        case .hysteria2:
            out["type"] = "hysteria2"
            out["password"] = s.secret
            out["tls"] = [
                "enabled": true,
                "server_name": s.sni.isEmpty ? s.address : s.sni,
                "insecure": s.allowInsecure
            ]
        case .socks:
            out["type"] = "socks"
            out["version"] = "5"
            if !s.username.isEmpty { out["username"] = s.username }
            if !s.secret.isEmpty { out["password"] = s.secret }
        case .http:
            out["type"] = "http"
            if !s.username.isEmpty { out["username"] = s.username }
            if !s.secret.isEmpty { out["password"] = s.secret }
            if s.security == "tls" {
                out["tls"] = ["enabled": true, "server_name": s.sni.isEmpty ? s.address : s.sni, "insecure": s.allowInsecure]
            }
        case .openconnect, .systemVPN:
            out["type"] = "direct"
        }
        return out
    }

    private static func attachTLSAndTransport(_ out: inout [String: Any], _ s: VPNServerConfig) {
        if s.security == "tls" || s.security == "reality" || s.security == "xtls" {
            out["tls"] = [
                "enabled": true,
                "server_name": s.sni.isEmpty ? (s.wsHost.isEmpty ? s.address : s.wsHost) : s.sni,
                "insecure": s.allowInsecure
            ]
        }
        if s.transport == "ws" {
            var ws: [String: Any] = ["type": "ws", "path": s.path.isEmpty ? "/" : s.path]
            if !s.wsHost.isEmpty {
                ws["headers"] = ["Host": s.wsHost]
            }
            out["transport"] = ws
        } else if s.transport == "grpc" {
            out["transport"] = ["type": "grpc", "service_name": s.path]
        }
    }

    private static func splitHostPort(_ raw: String, defaultPort: Int) -> (String, Int) {
        if let colon = raw.lastIndex(of: ":") {
            let h = String(raw[..<colon]).trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
            let p = Int(raw[raw.index(after: colon)...]) ?? defaultPort
            return (h, p)
        }
        return (raw, defaultPort)
    }

    private static func decodeBase64Flexible(_ str: String) -> String? {
        var cleaned = str.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let rem = cleaned.count % 4
        if rem > 0 {
            cleaned += String(repeating: "=", count: 4 - rem)
        }
        guard let data = Data(base64Encoded: cleaned, options: .ignoreUnknownCharacters) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
