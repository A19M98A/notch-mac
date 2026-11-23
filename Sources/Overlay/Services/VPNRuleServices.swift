import Foundation

struct SDRPop: Identifiable, Equatable {
    var id: String { code }
    let code: String
    let desc: String
    let cidrs: [String] // /24 subnets

    var label: String { "\(code) - \(desc)" }
}

/// Native Swift implementation of ocpanel's published IP range services (Google & YouTube, Valve Steam SDR).
/// Caches downloaded ranges under ~/.config/overlay-vpn/services/ so it works offline and standalone.
enum VPNRuleServices {
    private static var baseDir: String {
        "\(FileManager.default.homeDirectoryForCurrentUser.path)/.config/overlay-vpn"
    }

    private static var servicesDir: String { "\(baseDir)/services" }
    private static var googleCacheURL: URL { URL(fileURLWithPath: "\(servicesDir)/google.json") }
    private static var sdrCacheURL: URL { URL(fileURLWithPath: "\(baseDir)/sdr.json") }

    // MARK: - Service Ranges (e.g. service:google)

    static func cachedRanges(for serviceKey: String) -> [String] {
        let key = serviceKey.lowercased()
        let url = URL(fileURLWithPath: "\(servicesDir)/\(key).json")
        if let ranges = readRangesFile(url), !ranges.isEmpty {
            return ranges
        }
        // Fallback: if user previously ran ocpanel, read its cached copy too
        let ocURL = URL(fileURLWithPath: "\(FileManager.default.homeDirectoryForCurrentUser.path)/.config/ocpanel/services/\(key).json")
        if let ranges = readRangesFile(ocURL), !ranges.isEmpty {
            saveRanges(ranges, for: key, source: "imported from ocpanel cache")
            return ranges
        }
        return []
    }

    private static func readRangesFile(_ url: URL) -> [String]? {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let ranges = obj["ranges"] as? [String] else {
            return nil
        }
        return ranges
    }

    private static func saveRanges(_ ranges: [String], for key: String, source: String) {
        try? FileManager.default.createDirectory(atPath: servicesDir, withIntermediateDirectories: true)
        let payload: [String: Any] = ["service": key, "source": source, "ranges": ranges]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted]) {
            try? data.write(to: URL(fileURLWithPath: "\(servicesDir)/\(key).json"), options: .atomic)
        }
    }

    /// Downloads Google's published IPv4 ranges (`goog.json` minus `cloud.json`), matching ocpanel/services.py.
    static func fetchGoogleRanges(completion: @escaping ([String], String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let googData = downloadSync("https://www.gstatic.com/ipranges/goog.json"),
                  let cloudData = downloadSync("https://www.gstatic.com/ipranges/cloud.json") else {
                let fallback = cachedRanges(for: "google")
                DispatchQueue.main.async {
                    if !fallback.isEmpty {
                        completion(fallback, nil)
                    } else {
                        completion([], "Failed to download Google IP ranges")
                    }
                }
                return
            }

            let googNets = parseIPv4Prefixes(from: googData)
            let cloudNets = parseIPv4Prefixes(from: cloudData)
            let subtracted = subtractIPv4Networks(base: googNets, exclude: cloudNets)
            let cidrs = subtracted.map { $0.cidrString }

            if !cidrs.isEmpty {
                saveRanges(cidrs, for: "google", source: "gstatic.com/ipranges (goog.json - cloud.json)")
            }

            DispatchQueue.main.async {
                completion(cidrs, cidrs.isEmpty ? "No Google ranges parsed" : nil)
            }
        }
    }

    // MARK: - Valve Steam Datagram Relay (Dota 2 / CS2)

    static func fetchSteamSDR(appid: Int = 570, completion: @escaping ([SDRPop], String?) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let urlStr = "https://api.steampowered.com/ISteamApps/GetSDRConfig/v1/?appid=\(appid)"
            var rawData = downloadSync(urlStr)
            if let data = rawData {
                try? FileManager.default.createDirectory(atPath: baseDir, withIntermediateDirectories: true)
                try? data.write(to: sdrCacheURL, options: .atomic)
            } else {
                rawData = try? Data(contentsOf: sdrCacheURL)
                if rawData == nil {
                    let ocSDR = URL(fileURLWithPath: "\(FileManager.default.homeDirectoryForCurrentUser.path)/.config/ocpanel/sdr.json")
                    rawData = try? Data(contentsOf: ocSDR)
                }
            }

            guard let data = rawData,
                  let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let popsDict = root["pops"] as? [String: [String: Any]] else {
                DispatchQueue.main.async {
                    completion([], "Failed to load Valve Steam SDR directory")
                }
                return
            }

            var pops: [SDRPop] = []
            for (code, info) in popsDict.sorted(by: { $0.key < $1.key }) {
                let desc = (info["desc"] as? String) ?? code
                let relays = (info["relays"] as? [[String: Any]]) ?? []
                var slash24Set = Set<String>()
                for r in relays {
                    if let ip = r["ipv4"] as? String {
                        let parts = ip.split(separator: ".")
                        if parts.count == 4 {
                            slash24Set.insert("\(parts[0]).\(parts[1]).\(parts[2]).0/24")
                        }
                    }
                }
                if !slash24Set.isEmpty {
                    pops.append(SDRPop(code: code, desc: desc, cidrs: slash24Set.sorted()))
                }
            }

            DispatchQueue.main.async {
                completion(pops, pops.isEmpty ? "No SDR relays found" : nil)
            }
        }
    }

    // MARK: - IPv4 CIDR Math (Exact Subtraction + Prefix Decomposition)

    private struct IPv4Range: Comparable {
        let start: UInt32
        let end: UInt32 // inclusive

        static func < (lhs: IPv4Range, rhs: IPv4Range) -> Bool {
            lhs.start < rhs.start
        }
    }

    private struct IPv4Net {
        let network: UInt32
        let prefixLen: Int

        var cidrString: String {
            let a = (network >> 24) & 0xFF
            let b = (network >> 16) & 0xFF
            let c = (network >> 8) & 0xFF
            let d = network & 0xFF
            return "\(a).\(b).\(c).\(d)/\(prefixLen)"
        }

        var range: IPv4Range {
            let mask: UInt32 = prefixLen == 0 ? 0 : (UInt32.max << (32 - prefixLen))
            let s = network & mask
            let e = s | ~mask
            return IPv4Range(start: s, end: e)
        }
    }

    private static func parseIPv4Prefixes(from data: Data) -> [IPv4Net] {
        guard let doc = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let prefixes = doc["prefixes"] as? [[String: Any]] else {
            return []
        }
        var nets: [IPv4Net] = []
        for p in prefixes {
            guard let cidr = p["ipv4Prefix"] as? String,
                  let net = parseCIDR(cidr) else { continue }
            nets.append(net)
        }
        return nets
    }

    private static func parseCIDR(_ cidr: String) -> IPv4Net? {
        let parts = cidr.split(separator: "/")
        guard parts.count == 2, let prefixLen = Int(parts[1]), (0...32).contains(prefixLen) else { return nil }
        let octets = parts[0].split(separator: ".").compactMap { UInt32($0) }
        guard octets.count == 4, octets.allSatisfy({ $0 <= 255 }) else { return nil }
        let ip = (octets[0] << 24) | (octets[1] << 16) | (octets[2] << 8) | octets[3]
        let mask: UInt32 = prefixLen == 0 ? 0 : (UInt32.max << (32 - prefixLen))
        return IPv4Net(network: ip & mask, prefixLen: prefixLen)
    }

    private static func subtractIPv4Networks(base: [IPv4Net], exclude: [IPv4Net]) -> [IPv4Net] {
        var ranges = mergeRanges(base.map { $0.range })
        let excl = mergeRanges(exclude.map { $0.range })

        for ex in excl {
            var next: [IPv4Range] = []
            for r in ranges {
                if ex.end < r.start || ex.start > r.end {
                    next.append(r)
                } else {
                    if ex.start > r.start {
                        next.append(IPv4Range(start: r.start, end: ex.start - 1))
                    }
                    if ex.end < r.end {
                        next.append(IPv4Range(start: ex.end + 1, end: r.end))
                    }
                }
            }
            ranges = next
        }

        // Convert merged ranges back to minimal CIDR blocks
        var result: [IPv4Net] = []
        for r in mergeRanges(ranges) {
            var cur = UInt64(r.start)
            let end = UInt64(r.end)
            while cur <= end {
                var maxSize: UInt64 = 1
                var prefixLen = 32
                while prefixLen > 0 {
                    let candidateSize = maxSize << 1
                    if (cur % candidateSize) == 0 && (cur + candidateSize - 1) <= end {
                        maxSize = candidateSize
                        prefixLen -= 1
                    } else {
                        break
                    }
                }
                result.append(IPv4Net(network: UInt32(cur), prefixLen: prefixLen))
                cur += maxSize
            }
        }
        return result
    }

    private static func mergeRanges(_ input: [IPv4Range]) -> [IPv4Range] {
        let sorted = input.sorted()
        var merged: [IPv4Range] = []
        for r in sorted {
            if let last = merged.last, UInt64(r.start) <= UInt64(last.end) + 1 {
                merged[merged.count - 1] = IPv4Range(start: last.start, end: max(last.end, r.end))
            } else {
                merged.append(r)
            }
        }
        return merged
    }

    private static func downloadSync(_ urlString: String) -> Data? {
        guard let url = URL(string: urlString) else { return nil }
        let sem = DispatchSemaphore(value: 0)
        var result: Data?
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("OverlayVPN/1.0", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            if let http = resp as? HTTPURLResponse, (200...299).contains(http.statusCode) {
                result = data
            }
            sem.signal()
        }.resume()
        _ = sem.wait(timeout: .now() + 18)
        return result
    }
}
