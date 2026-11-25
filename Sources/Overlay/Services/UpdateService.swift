import Foundation
import AppKit
import Combine

enum UpdateChannel: String, CaseIterable, Identifiable {
    case stable = "stable"
    case debug = "debug"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .stable: return "Stable"
        case .debug: return "Debug"
        }
    }

    var icon: String {
        switch self {
        case .stable: return "checkmark.seal.fill"
        case .debug: return "ladybug.fill"
        }
    }
}

struct GitHubReleaseInfo: Equatable {
    let version: String
    let tagName: String
    let releaseNotes: String
    let htmlURL: URL
    let downloadURL: URL
    let assetName: String
    let assetSize: Int64
    let isPrerelease: Bool
}

enum UpdateState: Equatable {
    case idle
    case checking
    case upToDate(String)
    case available(GitHubReleaseInfo)
    case downloading(Double)
    case installing
    case error(String)
}

/// Checks GitHub Releases (A19M98A/notch-mac) for newer NotchPulse versions,
/// downloads the universal .zip with live progress, replaces the running .app
/// in place, and automatically relaunches into the new version.
final class UpdateService: NSObject, ObservableObject {
    static let repo = "A19M98A/notch-mac"

    @Published var state: UpdateState = .idle
    @Published var lastChecked: Date? = nil
    @Published var channel: UpdateChannel = .stable

    var currentVersion: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "1.1.0"
    }

    var hasUpdateAvailable: Bool {
        if case .available = state { return true }
        return false
    }

    private var downloadTask: URLSessionDownloadTask?
    private var downloadSession: URLSession?
    private var pendingRelease: GitHubReleaseInfo?

    override init() {
        super.init()
        // Quiet background check 5 seconds after launch
        DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
            self?.checkForUpdates(silentIfUpToDate: true)
        }
    }

    func checkForUpdates(silentIfUpToDate: Bool = false) {
        if case .downloading = state { return }
        if case .installing = state { return }

        if !silentIfUpToDate {
            DispatchQueue.main.async { self.state = .checking }
        }

        let selectedChannel = channel
        guard let url = URL(string: "https://api.github.com/repos/\(Self.repo)/releases?per_page=20") else {
            if !silentIfUpToDate {
                DispatchQueue.main.async { self.state = .error("Invalid release URL.") }
            }
            return
        }

        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("NotchPulse/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        URLSession.shared.dataTask(with: req) { [weak self] data, response, error in
            guard let self else { return }

            if let error {
                if !silentIfUpToDate {
                    DispatchQueue.main.async {
                        self.state = .error("Check failed: \(error.localizedDescription)")
                    }
                }
                return
            }

            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                if !silentIfUpToDate {
                    DispatchQueue.main.async {
                        self.state = .error("GitHub returned HTTP \(http.statusCode).")
                    }
                }
                return
            }

            guard let data,
                  let list = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
                if !silentIfUpToDate {
                    DispatchQueue.main.async {
                        self.state = .error("Could not parse release list.")
                    }
                }
                return
            }

            // Filter out drafts and pick the best matching release for the selected channel
            let candidates = list.filter { item in
                let isDraft = (item["draft"] as? Bool) ?? false
                if isDraft { return false }
                let isPre = self.isReleaseDebugOrPrerelease(item)
                switch selectedChannel {
                case .stable:
                    return !isPre
                case .debug:
                    return true
                }
            }

            let best = candidates.max { a, b in
                let va = ((a["tag_name"] as? String) ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
                let vb = ((b["tag_name"] as? String) ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
                return self.isVersion(vb, newerThan: va)
            }

            guard let json = best, let tagName = json["tag_name"] as? String else {
                DispatchQueue.main.async {
                    self.lastChecked = Date()
                    if !silentIfUpToDate {
                        self.state = .upToDate(self.currentVersion)
                    }
                }
                return
            }

            let latestVersion = tagName.trimmingCharacters(in: CharacterSet(charactersIn: "vV "))
            let isPre = self.isReleaseDebugOrPrerelease(json)
            let htmlString = (json["html_url"] as? String) ?? "https://github.com/\(Self.repo)/releases"
            let htmlURL = URL(string: htmlString) ?? URL(string: "https://github.com/\(Self.repo)/releases")!
            let notes = (json["body"] as? String) ?? ""

            let assets = (json["assets"] as? [[String: Any]]) ?? []
            let zipAsset = assets.first(where: {
                let name = ($0["name"] as? String ?? "").lowercased()
                return name.hasSuffix(".zip") && name.contains("notchpulse")
            }) ?? assets.first(where: {
                ($0["name"] as? String ?? "").lowercased().hasSuffix(".zip")
            })

            DispatchQueue.main.async {
                self.lastChecked = Date()
                if self.isVersion(latestVersion, newerThan: self.currentVersion) {
                    if let zipAsset,
                       let urlStr = zipAsset["browser_download_url"] as? String,
                       let dlURL = URL(string: urlStr) {
                        let info = GitHubReleaseInfo(
                            version: latestVersion,
                            tagName: tagName,
                            releaseNotes: notes,
                            htmlURL: htmlURL,
                            downloadURL: dlURL,
                            assetName: (zipAsset["name"] as? String) ?? "NotchPulse.zip",
                            assetSize: (zipAsset["size"] as? Int64) ?? 0,
                            isPrerelease: isPre
                        )
                        self.state = .available(info)
                    } else if !silentIfUpToDate {
                        self.state = .error("Release v\(latestVersion) found, but no .zip asset attached yet.")
                    }
                } else {
                    if !silentIfUpToDate {
                        self.state = .upToDate(self.currentVersion)
                    } else if case .checking = self.state {
                        self.state = .idle
                    }
                }
            }
        }.resume()
    }

    func downloadAndInstall(_ release: GitHubReleaseInfo) {
        pendingRelease = release
        DispatchQueue.main.async {
            self.state = .downloading(0.0)
        }

        let config = URLSessionConfiguration.default
        let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
        downloadSession = session

        var req = URLRequest(url: release.downloadURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 120)
        req.setValue("NotchPulse/\(currentVersion)", forHTTPHeaderField: "User-Agent")

        let task = session.downloadTask(with: req)
        downloadTask = task
        task.resume()
    }

    func cancelDownload() {
        downloadTask?.cancel()
        downloadTask = nil
        downloadSession?.invalidateAndCancel()
        downloadSession = nil
        if let release = pendingRelease {
            DispatchQueue.main.async { self.state = .available(release) }
        } else {
            DispatchQueue.main.async { self.state = .idle }
        }
    }

    // MARK: - Extract, Replace, & Relaunch

    private func installDownloadedZip(at tempZipURL: URL) {
        DispatchQueue.main.async { self.state = .installing }

        let fm = FileManager.default
        let workDir = fm.temporaryDirectory.appendingPathComponent("NotchPulseUpdate-\(UUID().uuidString)")
        let zipCopy = workDir.appendingPathComponent("update.zip")
        let extractDir = workDir.appendingPathComponent("extracted")

        do {
            try fm.createDirectory(at: extractDir, withIntermediateDirectories: true)
            try fm.copyItem(at: tempZipURL, to: zipCopy)
        } catch {
            DispatchQueue.main.async { self.state = .error("Failed to stage update: \(error.localizedDescription)") }
            return
        }

        // Unzip via macOS ditto (preserves symlinks, permissions, and code signatures)
        let ditto = Process()
        ditto.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        ditto.arguments = ["-x", "-k", zipCopy.path, extractDir.path]
        do {
            try ditto.run()
            ditto.waitUntilExit()
            guard ditto.terminationStatus == 0 else {
                DispatchQueue.main.async { self.state = .error("Failed to extract update archive.") }
                return
            }
        } catch {
            DispatchQueue.main.async { self.state = .error("Extraction error: \(error.localizedDescription)") }
            return
        }

        // Locate extracted NotchPulse.app
        guard let newAppURL = findAppBundle(in: extractDir) else {
            DispatchQueue.main.async { self.state = .error("No NotchPulse.app found in update archive.") }
            return
        }

        // Clear quarantine flag so macOS launches the updated app cleanly
        let xattr = Process()
        xattr.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        xattr.arguments = ["-dr", "com.apple.quarantine", newAppURL.path]
        try? xattr.run()
        xattr.waitUntilExit()

        // Target bundle: replace current .app in place, or /Applications/NotchPulse.app if run from CLI
        let currentBundlePath = Bundle.main.bundlePath
        let targetAppPath = currentBundlePath.hasSuffix(".app")
            ? currentBundlePath
            : "/Applications/NotchPulse.app"

        let currentPID = ProcessInfo.processInfo.processIdentifier
        let scriptPath = workDir.appendingPathComponent("apply_update.sh").path
        let script = """
        #!/bin/sh
        PID=\(currentPID)
        SRC="\(newAppURL.path)"
        DST="\(targetAppPath)"
        WORK="\(workDir.path)"

        # Wait up to 8s for running NotchPulse to quit
        i=0
        while kill -0 "$PID" 2>/dev/null && [ $i -lt 80 ]; do
            sleep 0.1
            i=$((i + 1))
        done

        # Atomic-style swap with fallback backup
        BACKUP="${DST}.old"
        rm -rf "$BACKUP"
        if [ -d "$DST" ]; then
            mv "$DST" "$BACKUP" || exit 1
        fi
        if mv "$SRC" "$DST"; then
            rm -rf "$BACKUP"
        else
            [ -d "$BACKUP" ] && mv "$BACKUP" "$DST"
            exit 1
        fi

        rm -rf "$WORK"
        open -n "$DST"
        """

        do {
            try script.write(toFile: scriptPath, atomically: true, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: scriptPath)

            let launcher = Process()
            launcher.executableURL = URL(fileURLWithPath: "/bin/sh")
            launcher.arguments = [scriptPath]
            launcher.standardOutput = FileHandle.nullDevice
            launcher.standardError = FileHandle.nullDevice
            try launcher.run()

            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
        } catch {
            DispatchQueue.main.async {
                self.state = .error("Could not launch updater: \(error.localizedDescription)")
            }
        }
    }

    private func findAppBundle(in dir: URL) -> URL? {
        guard let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else {
            return nil
        }
        if let direct = items.first(where: { $0.pathExtension == "app" }) {
            return direct
        }
        for sub in items {
            if let nested = try? FileManager.default.contentsOfDirectory(at: sub, includingPropertiesForKeys: nil),
               let app = nested.first(where: { $0.pathExtension == "app" }) {
                return app
            }
        }
        return nil
    }

    private func isReleaseDebugOrPrerelease(_ item: [String: Any]) -> Bool {
        if (item["prerelease"] as? Bool) == true { return true }
        let tag = ((item["tag_name"] as? String) ?? "").lowercased()
        return tag.contains("-debug") || tag.contains("-beta") || tag.contains("-alpha") || tag.contains("-rc") || tag.contains("-dev")
    }

    private func isVersion(_ lhs: String, newerThan rhs: String) -> Bool {
        let lhsParts = lhs.split(separator: "-", maxSplits: 1).map(String.init)
        let rhsParts = rhs.split(separator: "-", maxSplits: 1).map(String.init)

        let a = lhsParts[0].split(separator: ".").compactMap { Int($0) }
        let b = rhsParts[0].split(separator: ".").compactMap { Int($0) }
        let count = max(a.count, b.count)
        for i in 0..<count {
            let av = i < a.count ? a[i] : 0
            let bv = i < b.count ? b[i] : 0
            if av != bv { return av > bv }
        }

        // Same numeric core version: compare prerelease suffixes
        let lhsPre = lhsParts.count > 1 ? lhsParts[1] : nil
        let rhsPre = rhsParts.count > 1 ? rhsParts[1] : nil

        switch (lhsPre, rhsPre) {
        case (nil, nil):
            return false
        case (nil, .some):
            // Stable release (e.g. 1.2.0) is newer than prerelease (e.g. 1.2.0-debug.1)
            return true
        case (.some, nil):
            return false
        case (.some(let l), .some(let r)):
            let lSegs = l.split(separator: ".").map(String.init)
            let rSegs = r.split(separator: ".").map(String.init)
            let segCount = max(lSegs.count, rSegs.count)
            for i in 0..<segCount {
                if i >= lSegs.count { return false }
                if i >= rSegs.count { return true }
                if let ln = Int(lSegs[i]), let rn = Int(rSegs[i]) {
                    if ln != rn { return ln > rn }
                } else if lSegs[i] != rSegs[i] {
                    return lSegs[i].localizedStandardCompare(rSegs[i]) == .orderedDescending
                }
            }
            return false
        }
    }
}

extension UpdateService: URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let expected = totalBytesExpectedToWrite > 0
            ? totalBytesExpectedToWrite
            : (pendingRelease?.assetSize ?? 0)
        guard expected > 0 else { return }
        let progress = min(1.0, max(0.0, Double(totalBytesWritten) / Double(expected)))
        DispatchQueue.main.async {
            self.state = .downloading(progress)
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // Must process/copy `location` synchronously before returning from this delegate method
        installDownloadedZip(at: location)
        downloadSession?.finishTasksAndInvalidate()
        downloadSession = nil
        downloadTask.cancel()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        let nsErr = error as NSError
        if nsErr.code == NSURLErrorCancelled { return }
        DispatchQueue.main.async {
            self.state = .error("Download failed: \(error.localizedDescription)")
        }
        downloadSession?.invalidateAndCancel()
        downloadSession = nil
    }
}
