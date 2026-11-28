import Foundation
import SwiftUI

enum VPNProtocol: String, CaseIterable, Codable, Identifiable {
    case vless = "VLESS"
    case vmess = "VMESS"
    case trojan = "TROJAN"
    case shadowsocks = "SHADOWSOCKS"
    case ssh = "SSH"
    case hysteria2 = "HYSTERIA2"
    case socks = "SOCKS"
    case http = "HTTP"
    case openconnect = "OPENCONNECT"
    case systemVPN = "SYSTEM"

    var id: String { rawValue }

    /// Protocols the user can manually create in the Server Add/Edit screen
    static var editableCases: [VPNProtocol] {
        [.vless, .vmess, .trojan, .shadowsocks, .ssh, .hysteria2, .socks, .http, .openconnect]
    }

    var shortLabel: String {
        switch self {
        case .vless: return "VLESS"
        case .vmess: return "VMESS"
        case .trojan: return "TROJAN"
        case .shadowsocks: return "SS"
        case .ssh: return "SSH"
        case .hysteria2: return "HY2"
        case .socks: return "SOCKS"
        case .http: return "HTTP"
        case .openconnect: return "OC"
        case .systemVPN: return "SYS"
        }
    }

    var accentColor: Color {
        switch self {
        case .vless: return .cyan
        case .vmess: return .purple
        case .trojan: return .pink
        case .shadowsocks: return .indigo
        case .ssh: return Color(red: 0.45, green: 0.85, blue: 0.95)
        case .hysteria2: return .mint
        case .socks: return .teal
        case .http: return .blue
        case .openconnect: return .orange
        case .systemVPN: return .green
        }
    }

    var defaultPort: Int {
        switch self {
        case .vless, .vmess, .trojan, .hysteria2, .openconnect: return 443
        case .shadowsocks: return 8388
        case .ssh: return 22
        case .socks: return 1080
        case .http: return 8080
        case .systemVPN: return 0
        }
    }
}

struct VPNServerConfig: Identifiable, Codable, Equatable {
    var id: String = UUID().uuidString
    var groupID: String = "local" // "local" or a VPNSubscription.id
    var proto: VPNProtocol = .vless
    var remarks: String = ""
    var address: String = ""
    var port: Int = 443
    var username: String = ""
    var secret: String = ""       // UUID, password, or private key path
    var method: String = "aes-256-gcm" // Shadowsocks cipher or VMess security
    var security: String = "none" // none | tls | reality
    var transport: String = "tcp" // tcp | ws | grpc
    var sni: String = ""
    var wsHost: String = ""
    var path: String = ""
    var flow: String = ""
    var allowInsecure: Bool = false
    var extraArgs: String = ""    // OpenConnect extra CLI args
    var serviceName: String? = nil // macOS NetworkExtension name (for .systemVPN)
    var rawURI: String? = nil

    var displayName: String {
        if !remarks.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return remarks
        }
        return address.isEmpty ? proto.rawValue : "\(address):\(port)"
    }

    var maskedEndpoint: String {
        guard !address.isEmpty else { return "" }
        if address.count > 10 {
            let prefix = address.prefix(4)
            let suffix = address.suffix(4)
            return "\(prefix)****\(suffix):\(port)"
        }
        return "\(address):\(port)"
    }
}

struct VPNSubscription: Identifiable, Codable, Equatable {
    var id: String = UUID().uuidString
    var name: String
    var url: String
    var lastUpdated: Date? = nil
}

enum VPNRouteMode: String, Codable, CaseIterable, Identifiable {
    case vpnDefault = "vpn"       // Everything through VPN except bypass rules
    case directDefault = "direct" // Everything direct except VPN rules

    var id: String { rawValue }

    var title: String {
        switch self {
        case .vpnDefault: return "VPN Default (Bypass List)"
        case .directDefault: return "Direct Default (VPN List)"
        }
    }

    var shortTitle: String {
        switch self {
        case .vpnDefault: return "VPN Default"
        case .directDefault: return "Direct Default"
        }
    }
}

enum VPNRuleType: String, Codable, CaseIterable, Identifiable {
    case domain = "domain"
    case ipCidr = "ip_cidr"
    case service = "service"

    var id: String { rawValue }
    var label: String {
        switch self {
        case .domain: return "Domain"
        case .ipCidr: return "IP / CIDR"
        case .service: return "Service"
        }
    }
}

struct VPNRule: Identifiable, Codable, Equatable {
    var id: String = UUID().uuidString
    var target: String
    var type: VPNRuleType = .domain
    var label: String = ""
    var tag: String = ""
    var enabled: Bool = true

    init(id: String = UUID().uuidString, target: String, type: VPNRuleType = .domain, label: String = "", tag: String = "", enabled: Bool = true) {
        self.id = id
        self.target = target
        self.type = type
        self.label = label
        self.tag = tag
        self.enabled = enabled
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        target = try c.decode(String.self, forKey: .target)
        type = try c.decodeIfPresent(VPNRuleType.self, forKey: .type) ?? .domain
        label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        tag = try c.decodeIfPresent(String.self, forKey: .tag) ?? ""
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }

    /// Returns the user-assigned tag if present, or an auto-detected category based on target/label.
    var resolvedCategory: String {
        let custom = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty { return custom }
        return Self.autoCategory(target: target, label: label)
    }

    static func autoCategory(target: String, label: String) -> String {
        let hay = "\(target) \(label)".lowercased()
        if hay.contains("dota") || hay.contains("steam") || hay.contains("valve") || hay.contains("sdr") || hay.contains("155.133.") || hay.contains("162.254.") {
            return "Dota 2 / Steam"
        }
        if hay.contains("google") || hay.contains("youtube") || hay.contains("youtu.be") || hay.contains("gstatic") || hay.contains("ggpht") {
            return "Google / YouTube"
        }
        if hay.contains("telegram") || hay.contains("t.me") || hay.contains("91.108.") || hay.contains("149.154.") {
            return "Telegram"
        }
        if hay.contains("apple") || hay.contains("icloud") || hay.contains("mzstatic") {
            return "Apple & iCloud"
        }
        if hay.contains("openai") || hay.contains("chatgpt") || hay.contains("anthropic") || hay.contains("claude") || hay.contains("gemini") || hay.contains("perplexity") {
            return "AI"
        }
        if hay.contains("github") || hay.contains("gitlab") || hay.contains("npmjs") || hay.contains("pypi") || hay.contains("docker") || hay.contains("brew") {
            return "Dev"
        }
        if hay.contains("instagram") || hay.contains("whatsapp") || hay.contains("twitter") || hay.contains("x.com") || hay.contains("discord") || hay.contains("twitch") {
            return "Social"
        }
        if hay.contains("cloudflare") || hay.contains("1.1.1.") || hay.contains("8.8.8.") {
            return "DNS / CDN"
        }
        return "General"
    }
}

struct VPNStoreData: Codable {
    var servers: [VPNServerConfig] = []
    var subscriptions: [VPNSubscription] = []
    var mode: VPNRouteMode = .vpnDefault
    var bypassRules: [VPNRule] = []
    var vpnRules: [VPNRule] = []
    var selectedServerID: String? = nil
}
