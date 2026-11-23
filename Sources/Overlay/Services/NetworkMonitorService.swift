import Foundation
import Darwin
import Combine

final class NetworkMonitorService: ObservableObject {
    @Published var downloadBytesPerSec: Double = 0
    @Published var uploadBytesPerSec: Double = 0
    @Published var totalDownloadBytes: UInt64 = 0
    @Published var totalUploadBytes: UInt64 = 0

    private var timer: Timer?
    private var lastSampleTime: Date?
    private var lastRawIn: UInt64 = 0
    private var lastRawOut: UInt64 = 0
    private var baselineIn: UInt64 = 0
    private var baselineOut: UInt64 = 0
    private var initialized: Bool = false

    init() {
        sample()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            self?.sample()
        }
    }

    deinit {
        timer?.invalidate()
    }

    var downSpeedParts: (value: String, unit: String) { Self.splitRate(downloadBytesPerSec) }
    var upSpeedParts: (value: String, unit: String) { Self.splitRate(uploadBytesPerSec) }
    var totalDownParts: (value: String, unit: String) { Self.splitBytes(totalDownloadBytes) }
    var totalUpParts: (value: String, unit: String) { Self.splitBytes(totalUploadBytes) }

    var formattedDownSpeed: String { "\(downSpeedParts.value) \(downSpeedParts.unit)" }
    var formattedUpSpeed: String { "\(upSpeedParts.value) \(upSpeedParts.unit)" }
    var formattedTotalDown: String { "\(totalDownParts.value) \(totalDownParts.unit)" }
    var formattedTotalUp: String { "\(totalUpParts.value) \(totalUpParts.unit)" }

    private func sample() {
        let (rawIn, rawOut) = readPhysicalInterfaceBytes()
        let now = Date()

        if !initialized {
            initialized = true
            baselineIn = rawIn
            baselineOut = rawOut
            lastRawIn = rawIn
            lastRawOut = rawOut
            lastSampleTime = now
            return
        }

        let dt = max(0.2, now.timeIntervalSince(lastSampleTime ?? now))
        let deltaIn = rawIn >= lastRawIn ? (rawIn - lastRawIn) : 0
        let deltaOut = rawOut >= lastRawOut ? (rawOut - lastRawOut) : 0

        lastRawIn = rawIn
        lastRawOut = rawOut
        lastSampleTime = now

        let downRate = Double(deltaIn) / dt
        let upRate = Double(deltaOut) / dt
        let totIn = rawIn >= baselineIn ? (rawIn - baselineIn) : totalDownloadBytes + deltaIn
        let totOut = rawOut >= baselineOut ? (rawOut - baselineOut) : totalUploadBytes + deltaOut

        DispatchQueue.main.async {
            self.downloadBytesPerSec = downRate
            self.uploadBytesPerSec = upRate
            self.totalDownloadBytes = totIn
            self.totalUploadBytes = totOut
        }
    }

    /// Reads cumulative RX/TX bytes across active physical interfaces (`en*`) to avoid double-counting VPN `utun*` traffic.
    private func readPhysicalInterfaceBytes() -> (UInt64, UInt64) {
        var ifaddrPtr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddrPtr) == 0, let firstAddr = ifaddrPtr else {
            return (0, 0)
        }
        defer { freeifaddrs(firstAddr) }

        var totalIn: UInt64 = 0
        var totalOut: UInt64 = 0

        var cursor: UnsafeMutablePointer<ifaddrs>? = firstAddr
        while let addr = cursor {
            let flags = Int32(addr.pointee.ifa_flags)
            let isUp = (flags & IFF_UP) != 0
            let isRunning = (flags & IFF_RUNNING) != 0
            let isLoopback = (flags & IFF_LOOPBACK) != 0

            if isUp && isRunning && !isLoopback,
               let sa = addr.pointee.ifa_addr,
               sa.pointee.sa_family == UInt8(AF_LINK),
               let namePtr = addr.pointee.ifa_name,
               let dataPtr = addr.pointee.ifa_data {
                let name = String(cString: namePtr)
                // Count physical interfaces (en0 Wi-Fi, en* Ethernet/USB) to avoid double-counting utun/awdl
                if name.hasPrefix("en") {
                    let netData = dataPtr.assumingMemoryBound(to: if_data.self).pointee
                    totalIn &+= UInt64(netData.ifi_ibytes)
                    totalOut &+= UInt64(netData.ifi_obytes)
                }
            }
            cursor = addr.pointee.ifa_next
        }

        return (totalIn, totalOut)
    }

    static func splitRate(_ bytesPerSec: Double) -> (String, String) {
        if bytesPerSec < 1024 {
            return (String(format: "%.0f", bytesPerSec), "B/s")
        } else if bytesPerSec < 1024 * 1024 {
            return (String(format: "%.0f", bytesPerSec / 1024), "KB/s")
        } else if bytesPerSec < 1024 * 1024 * 1024 {
            return (String(format: "%.1f", bytesPerSec / (1024 * 1024)), "MB/s")
        } else {
            return (String(format: "%.2f", bytesPerSec / (1024 * 1024 * 1024)), "GB/s")
        }
    }

    static func splitBytes(_ bytes: UInt64) -> (String, String) {
        let b = Double(bytes)
        if b < 1024 {
            return (String(format: "%.0f", b), "B")
        } else if b < 1024 * 1024 {
            return (String(format: "%.0f", b / 1024), "KB")
        } else if b < 1024 * 1024 * 1024 {
            return (String(format: "%.1f", b / (1024 * 1024)), "MB")
        } else {
            return (String(format: "%.2f", b / (1024 * 1024 * 1024)), "GB")
        }
    }
}
