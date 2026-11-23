import Foundation
import AppKit
import ApplicationServices
import CoreAudio
import Combine

enum MediaControlKind: Equatable {
    case mediaRemote
    case spotify
    case appleMusic
    case browserTab(browserApp: String, windowIndex: Int, tabIndex: Int)
    case audioApp(pid: pid_t)
}

struct MediaSession: Identifiable, Equatable {
    let id: String
    let sourceName: String      // e.g. "YouTube", "SoundCloud", "Spotify", "Telegram", "Music"
    let bundleID: String
    let appIcon: NSImage?
    let accentHex: String       // hex for subtle ambient tint
    var title: String
    var artist: String
    var artwork: NSImage?
    var duration: TimeInterval
    var elapsed: TimeInterval
    var isPlaying: Bool
    var controlKind: MediaControlKind
    var pid: pid_t?

    static func == (lhs: MediaSession, rhs: MediaSession) -> Bool {
        lhs.id == rhs.id &&
        lhs.sourceName == rhs.sourceName &&
        lhs.title == rhs.title &&
        lhs.artist == rhs.artist &&
        lhs.duration == rhs.duration &&
        Int(lhs.elapsed) == Int(rhs.elapsed) &&
        lhs.isPlaying == rhs.isPlaying &&
        lhs.controlKind == rhs.controlKind
    }
}

struct NowPlayingTrack: Equatable {
    var title: String = "Nothing Playing"
    var artist: String = "Play music, YouTube, SoundCloud, or Telegram audio"
    var album: String = ""
    var artwork: NSImage? = nil
    var duration: TimeInterval = 0
    var elapsed: TimeInterval = 0
    var isPlaying: Bool = false
    var hasActiveTrack: Bool = false
    var sourceApp: String = ""
}

final class MediaRemoteService: ObservableObject {
    @Published var sessions: [MediaSession] = []
    @Published var selectedSessionID: String? = nil
    @Published var track = NowPlayingTrack()
    @Published var hasAccessibilityPermission: Bool = AXIsProcessTrusted()

    /// Fallback to mute/unmute a specific app's audio stream (by PID) without touching other apps.
    var onToggleAppAudioMute: ((pid_t) -> Bool)?

    var activeSession: MediaSession? {
        if let id = selectedSessionID, let found = sessions.first(where: { $0.id == id }) {
            return found
        }
        return sessions.first(where: { $0.isPlaying }) ?? sessions.first
    }

    var playingCount: Int {
        sessions.filter { $0.isPlaying }.count
    }

    private var pollTimer: Timer?
    private var tickTimer: Timer?
    private var mrHandle: UnsafeMutableRawPointer?
    private var artworkCache: [String: NSImage] = [:]

    private typealias MRGetNowPlayingInfoFn = @convention(c) (DispatchQueue, @escaping @convention(block) (CFDictionary?) -> Void) -> Void
    private typealias MRSendCommandFn = @convention(c) (UInt32, CFDictionary?) -> Bool

    private var getNowPlayingInfoFn: MRGetNowPlayingInfoFn?
    private var sendCommandFn: MRSendCommandFn?

    init() {
        loadMediaRemote()
        refreshNowPlaying()

        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refreshNowPlaying()
        }

        // Smooth 0.5s progress tick for playing sessions
        tickTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            var changed = false
            for i in self.sessions.indices {
                if self.sessions[i].isPlaying && self.sessions[i].duration > 0 {
                    self.sessions[i].elapsed = min(self.sessions[i].duration, self.sessions[i].elapsed + 0.5)
                    changed = true
                }
            }
            if changed {
                self.syncPrimaryTrack()
            }
        }
    }

    deinit {
        pollTimer?.invalidate()
        tickTimer?.invalidate()
        if let h = mrHandle { dlclose(h) }
    }

    private func loadMediaRemote() {
        let path = "/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote"
        guard let handle = dlopen(path, RTLD_LAZY) else { return }
        mrHandle = handle
        if let sym = dlsym(handle, "MRMediaRemoteGetNowPlayingInfo") {
            getNowPlayingInfoFn = unsafeBitCast(sym, to: MRGetNowPlayingInfoFn.self)
        }
        if let sym = dlsym(handle, "MRMediaRemoteSendCommand") {
            sendCommandFn = unsafeBitCast(sym, to: MRSendCommandFn.self)
        }
    }

    func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.hasAccessibilityPermission = AXIsProcessTrusted()
        }
    }

    func selectSession(_ session: MediaSession) {
        selectedSessionID = session.id
        syncPrimaryTrack()
    }

    func refreshNowPlaying() {
        let axTrusted = AXIsProcessTrusted()
        DispatchQueue.main.async {
            if self.hasAccessibilityPermission != axTrusted {
                self.hasAccessibilityPermission = axTrusted
            }
        }
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            var collected: [MediaSession] = []
            var representedBundleIDs = Set<String>()

            // 1. Spotify (direct AppleScript — supports independent control even when YouTube is also playing)
            let runningApps = NSWorkspace.shared.runningApplications
            let runningByBundle = Dictionary(grouping: runningApps.compactMap { app -> (String, NSRunningApplication)? in
                guard let bid = app.bundleIdentifier else { return nil }
                return (bid, app)
            }, by: { $0.0 })

            if let spotifyApp = runningByBundle["com.spotify.client"]?.first?.1,
               let sp = self.querySpotify(app: spotifyApp) {
                collected.append(sp)
                representedBundleIDs.insert("com.spotify.client")
            }

            // 2. Apple Music
            if let musicApp = runningByBundle["com.apple.Music"]?.first?.1,
               let am = self.queryAppleMusic(app: musicApp) {
                collected.append(am)
                representedBundleIDs.insert("com.apple.Music")
            }

            // 3. Web Browsers (YouTube, YouTube Music, SoundCloud, Twitch, Spotify Web, Vimeo, Netflix)
            let browserBundles: [(bundleID: String, appName: String, isSafari: Bool)] = [
                ("com.google.Chrome", "Google Chrome", false),
                ("company.thebrowser.Browser", "Arc", false),
                ("com.brave.Browser", "Brave Browser", false),
                ("com.microsoft.edgemac", "Microsoft Edge", false),
                ("com.apple.Safari", "Safari", true)
            ]
            for b in browserBundles {
                if let app = runningByBundle[b.bundleID]?.first?.1 {
                    let tabs = self.queryBrowserMediaTabs(appName: b.appName, bundleID: b.bundleID, icon: app.icon, pid: app.processIdentifier, isSafari: b.isSafari)
                    if !tabs.isEmpty {
                        collected.append(contentsOf: tabs)
                        representedBundleIDs.insert(b.bundleID)
                    }
                }
            }

            // 4. System MediaRemote (catches system-registered players like Podcasts, TV, QuickTime, etc.)
            if let mrSession = self.queryMediaRemoteSync() {
                let alreadyCovered = collected.contains { existing in
                    existing.title.lowercased() == mrSession.title.lowercased()
                }
                if !alreadyCovered {
                    collected.append(mrSession)
                }
            }

            // 5. Active Audio Apps via CoreAudio Process List (Telegram, Discord, VLC, IINA, Games, etc. — macOS 14.2+)
            if #available(macOS 14.2, *) {
                let audioSessions = self.queryActiveCoreAudioApps(excludingBundles: representedBundleIDs)
                collected.append(contentsOf: audioSessions)
            }

            // Sort: actively playing first, then keep deterministic order
            collected.sort { lhs, rhs in
                if lhs.isPlaying != rhs.isPlaying { return lhs.isPlaying }
                return lhs.sourceName.localizedCaseInsensitiveCompare(rhs.sourceName) == .orderedAscending
            }

            DispatchQueue.main.async {
                self.sessions = collected
                if let sel = self.selectedSessionID, !collected.contains(where: { $0.id == sel }) {
                    self.selectedSessionID = collected.first(where: { $0.isPlaying })?.id ?? collected.first?.id
                } else if self.selectedSessionID == nil {
                    self.selectedSessionID = collected.first(where: { $0.isPlaying })?.id ?? collected.first?.id
                }
                self.syncPrimaryTrack()
            }
        }
    }

    private func syncPrimaryTrack() {
        if let active = activeSession {
            track = NowPlayingTrack(
                title: active.title,
                artist: active.artist.isEmpty ? active.sourceName : active.artist,
                album: active.sourceName,
                artwork: active.artwork ?? active.appIcon,
                duration: active.duration,
                elapsed: active.elapsed,
                isPlaying: active.isPlaying,
                hasActiveTrack: true,
                sourceApp: active.sourceName
            )
        } else {
            track = NowPlayingTrack()
        }
    }

    // MARK: - Playback Controls (Strictly targeted to the selected session!)

    func togglePlayPause(for session: MediaSession? = nil) {
        let target = session ?? activeSession
        guard let target else {
            sendHIDMediaKey(16)
            return
        }

        switch target.controlKind {
        case .spotify:
            DispatchQueue.global(qos: .userInitiated).async {
                _ = self.runAppleScriptWithError("tell application \"Spotify\" to playpause")
            }
        case .appleMusic:
            DispatchQueue.global(qos: .userInitiated).async {
                _ = self.runAppleScriptWithError("tell application \"Music\" to playpause")
            }
        case .browserTab(let appName, let winIdx, let tabIdx):
            let js = """
            (function(){
                var sc = document.querySelector('.playControl');
                if (sc) {
                    var wasPlaying = sc.classList.contains('playing');
                    sc.click();
                    return wasPlaying ? 'paused' : 'playing';
                }
                var v = document.querySelector('video, audio');
                if (v) {
                    if (v.paused) { v.play(); return 'playing'; }
                    else { v.pause(); return 'paused'; }
                }
                var ytp = document.querySelector('.ytp-play-button');
                if (ytp) { ytp.click(); return 'toggled'; }
                var btn = document.querySelector('button[aria-label*="Play"], button[aria-label*="Pause"]');
                if (btn) { btn.click(); return 'toggled'; }
                return 'none';
            })();
            """
            let isYouTube = target.sourceName.lowercased().contains("youtube") || target.sourceName.lowercased().contains("yt")
            runBrowserMediaJS(
                appName: appName,
                windowIndex: winIdx,
                tabIndex: tabIdx,
                js: js,
                fallbackKeystroke: isYouTube ? "k" : " "
            ) { [weak self] result in
                DispatchQueue.main.async {
                    guard let self, let idx = self.sessions.firstIndex(where: { $0.id == target.id }) else { return }
                    if result == "playing" {
                        self.sessions[idx].isPlaying = true
                    } else if result == "paused" {
                        self.sessions[idx].isPlaying = false
                    } else if result == "toggled" {
                        self.sessions[idx].isPlaying.toggle()
                    }
                    self.syncPrimaryTrack()
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.refreshNowPlaying() }
            return
        case .audioApp(let pid):
            controlAudioApp(session: target, pid: pid, action: .playPause)
        case .mediaRemote:
            if let send = sendCommandFn, send(2, nil) { break }
            sendHIDMediaKey(16)
        }

        if let idx = sessions.firstIndex(where: { $0.id == target.id }) {
            sessions[idx].isPlaying.toggle()
            syncPrimaryTrack()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { self.refreshNowPlaying() }
    }

    func nextTrack(for session: MediaSession? = nil) {
        let target = session ?? activeSession
        guard let target else {
            sendHIDMediaKey(17)
            return
        }

        switch target.controlKind {
        case .spotify:
            DispatchQueue.global(qos: .userInitiated).async {
                _ = self.runAppleScriptWithError("tell application \"Spotify\" to next track")
            }
        case .appleMusic:
            DispatchQueue.global(qos: .userInitiated).async {
                _ = self.runAppleScriptWithError("tell application \"Music\" to next track")
            }
        case .browserTab(let appName, let winIdx, let tabIdx):
            let js = """
            (function(){
                var btn = document.querySelector('.ytp-next-button, .skipControl__next, button[aria-label*="Next"], .next-button');
                if (btn) { btn.click(); return 'ok'; }
                return 'none';
            })();
            """
            runBrowserMediaJS(appName: appName, windowIndex: winIdx, tabIndex: tabIdx, js: js, fallbackKeystroke: nil)
        case .audioApp(let pid):
            controlAudioApp(session: target, pid: pid, action: .next)
        case .mediaRemote:
            if let send = sendCommandFn, send(4, nil) { break }
            sendHIDMediaKey(17)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.refreshNowPlaying() }
    }

    func previousTrack(for session: MediaSession? = nil) {
        let target = session ?? activeSession
        guard let target else {
            sendHIDMediaKey(18)
            return
        }

        switch target.controlKind {
        case .spotify:
            DispatchQueue.global(qos: .userInitiated).async {
                _ = self.runAppleScriptWithError("tell application \"Spotify\" to previous track")
            }
        case .appleMusic:
            DispatchQueue.global(qos: .userInitiated).async {
                _ = self.runAppleScriptWithError("tell application \"Music\" to previous track")
            }
        case .browserTab(let appName, let winIdx, let tabIdx):
            let js = """
            (function(){
                var btn = document.querySelector('.ytp-prev-button, .skipControl__previous, button[aria-label*="Previous"], .previous-button');
                if (btn) { btn.click(); return 'ok'; }
                var v = document.querySelector('video, audio');
                if (v) { v.currentTime = 0; return 'ok'; }
                return 'none';
            })();
            """
            runBrowserMediaJS(appName: appName, windowIndex: winIdx, tabIndex: tabIdx, js: js, fallbackKeystroke: nil)
        case .audioApp(let pid):
            controlAudioApp(session: target, pid: pid, action: .previous)
        case .mediaRemote:
            if let send = sendCommandFn, send(5, nil) { break }
            sendHIDMediaKey(18)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.refreshNowPlaying() }
    }

    private enum AppMediaAction {
        case playPause, next, previous
    }

    private func controlAudioApp(session: MediaSession, pid: pid_t, action: AppMediaAction) {
        let lower = (session.sourceName + " " + session.bundleID).lowercased()
        DispatchQueue.global(qos: .userInitiated).async {
            if lower.contains("vlc") {
                switch action {
                case .playPause: _ = self.runAppleScriptWithError("tell application \"VLC\" to play")
                case .next: _ = self.runAppleScriptWithError("tell application \"VLC\" to next")
                case .previous: _ = self.runAppleScriptWithError("tell application \"VLC\" to previous")
                }
                return
            }
            if lower.contains("quicktime") {
                if action == .playPause {
                    _ = self.runAppleScriptWithError("tell application \"QuickTime Player\" to if playing of front document then pause front document else play front document")
                }
                return
            }

            // 1. Primary path for Telegram, Discord, IINA, and any native macOS player:
            //    Use Accessibility (AXUIElement) to press the app's actual Play/Pause/Next/Prev button
            //    without stealing focus or typing into text fields.
            if AXIsProcessTrusted() {
                if self.clickAXMediaButton(pid: pid, action: action) {
                    return
                }
            }

            // 2. Strictly isolated fallback for this exact PID ONLY (NEVER fire global MediaRemote,
            //    which would accidentally pause Chrome/YouTube/Spotify!).
            if action == .playPause {
                DispatchQueue.main.async {
                    _ = self.onToggleAppAudioMute?(pid)
                }
            }
        }
    }

    /// Traverses the target app's AX tree (e.g., Telegram's top mini-player bar) and presses its media button.
    private func clickAXMediaButton(pid: pid_t, action: AppMediaAction) -> Bool {
        let appElem = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElem, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement] else {
            return false
        }

        let keywords: [String]
        switch action {
        case .playPause: keywords = ["pause", "play"]
        case .next: keywords = ["next", "forward"]
        case .previous: keywords = ["previous", "prev", "back"]
        }

        for window in windows {
            if let button = findAXButton(in: window, matching: keywords, depth: 0, maxDepth: 9) {
                let status = AXUIElementPerformAction(button, kAXPressAction as CFString)
                if status == .success {
                    return true
                }
            }
        }
        return false
    }

    private func findAXButton(in element: AXUIElement, matching keywords: [String], depth: Int, maxDepth: Int) -> AXUIElement? {
        guard depth <= maxDepth else { return nil }

        var roleRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef) == .success,
           let role = roleRef as? String,
           role == (kAXButtonRole as String) {
            let texts = [
                axStringAttribute(element, kAXDescriptionAttribute),
                axStringAttribute(element, kAXTitleAttribute),
                axStringAttribute(element, kAXHelpAttribute),
                axStringAttribute(element, "AXIdentifier")
            ].compactMap { $0?.lowercased() }

            for text in texts {
                if keywords.contains(where: { text.contains($0) }) {
                    // Avoid hitting unrelated buttons like "Play Game" or "Back to Chats"
                    if text.contains("game") || text.contains("chat") || text.contains("settings") {
                        continue
                    }
                    return element
                }
            }
        }

        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else {
            return nil
        }

        for child in children {
            if let found = findAXButton(in: child, matching: keywords, depth: depth + 1, maxDepth: maxDepth) {
                return found
            }
        }
        return nil
    }

    private func axStringAttribute(_ element: AXUIElement, _ attr: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attr as CFString, &ref) == .success,
              let str = ref as? String, !str.isEmpty else {
            return nil
        }
        return str
    }

    private func postKeyToPID(_ pid: pid_t, keyCode: CGKeyCode) {
        guard let src = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false) else {
            return
        }
        down.postToPid(pid)
        up.postToPid(pid)
    }

    func seek(to seconds: TimeInterval, for session: MediaSession? = nil) {
        let target = session ?? activeSession
        guard let target, target.duration > 0 else { return }
        let clamped = max(0, min(target.duration, seconds))

        switch target.controlKind {
        case .spotify:
            _ = runAppleScript("tell application \"Spotify\" to set player position to \(clamped)")
        case .appleMusic:
            _ = runAppleScript("tell application \"Music\" to set player position to \(clamped)")
        case .browserTab(let appName, let winIdx, let tabIdx):
            runBrowserMediaJS(appName: appName, windowIndex: winIdx, tabIndex: tabIdx, js: "var m = document.querySelector('video, audio'); if (m) { m.currentTime = \(clamped); 'ok'; }", fallbackKeystroke: nil)
        default:
            break
        }

        if let idx = sessions.firstIndex(where: { $0.id == target.id }) {
            sessions[idx].elapsed = clamped
            syncPrimaryTrack()
        }
    }

    func focusSession(_ session: MediaSession) {
        switch session.controlKind {
        case .browserTab(let appName, let winIdx, let tabIdx):
            let script: String
            if appName == "Safari" {
                script = """
                tell application "Safari"
                    activate
                    set current tab of window \(winIdx) to tab \(tabIdx) of window \(winIdx)
                    set index of window \(winIdx) to 1
                end tell
                """
            } else {
                script = """
                tell application "\(appName)"
                    activate
                    set active tab index of window \(winIdx) to \(tabIdx)
                    set index of window \(winIdx) to 1
                end tell
                """
            }
            DispatchQueue.global(qos: .userInitiated).async { _ = self.runAppleScript(script) }
        default:
            if let pid = session.pid, let app = NSRunningApplication(processIdentifier: pid) {
                app.activate(options: [.activateIgnoringOtherApps])
            } else if !session.bundleID.isEmpty,
                      let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == session.bundleID }) {
                app.activate(options: [.activateIgnoringOtherApps])
            }
        }
    }

    // MARK: - Source Queries

    private func queryMediaRemoteSync() -> MediaSession? {
        guard let getInfo = getNowPlayingInfoFn else { return nil }
        let sem = DispatchSemaphore(value: 0)
        var session: MediaSession?

        getInfo(DispatchQueue.global(qos: .utility)) { cfDict in
            if let dict = cfDict as? [String: Any], !dict.isEmpty,
               let title = dict["kMRMediaRemoteNowPlayingInfoTitle"] as? String, !title.isEmpty {
                let artist = (dict["kMRMediaRemoteNowPlayingInfoArtist"] as? String) ?? ""
                let album = (dict["kMRMediaRemoteNowPlayingInfoAlbum"] as? String) ?? ""
                let duration = (dict["kMRMediaRemoteNowPlayingInfoDuration"] as? Double) ?? 0
                let elapsed = (dict["kMRMediaRemoteNowPlayingInfoElapsedTime"] as? Double) ?? 0
                let rate = (dict["kMRMediaRemoteNowPlayingInfoPlaybackRate"] as? Double) ?? 0
                let artData = dict["kMRMediaRemoteNowPlayingInfoArtworkData"] as? Data
                let img = artData.flatMap { NSImage(data: $0) }

                session = MediaSession(
                    id: "mediaremote:system",
                    sourceName: "Now Playing",
                    bundleID: "",
                    appIcon: NSImage(systemSymbolName: "music.note", accessibilityDescription: nil),
                    accentHex: "#EC4899",
                    title: title,
                    artist: artist.isEmpty ? album : artist,
                    artwork: img,
                    duration: duration,
                    elapsed: elapsed,
                    isPlaying: rate > 0.01,
                    controlKind: .mediaRemote,
                    pid: nil
                )
            }
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 0.5)
        return session
    }

    private func querySpotify(app: NSRunningApplication) -> MediaSession? {
        let script = """
        tell application "Spotify"
            if player state is stopped then return ""
            set st to player state as string
            set tName to name of current track
            set tArtist to artist of current track
            set tDur to (duration of current track) / 1000
            set tPos to player position
            set tArt to artwork url of current track
            return st & "|||" & tName & "|||" & tArtist & "|||" & tDur & "|||" & tPos & "|||" & tArt
        end tell
        """
        guard let output = runAppleScript(script), !output.isEmpty else { return nil }
        let parts = output.components(separatedBy: "|||")
        guard parts.count >= 6 else { return nil }
        let artURL = parts[5]
        let art = fetchCachedImage(urlString: artURL)

        return MediaSession(
            id: "spotify",
            sourceName: "Spotify",
            bundleID: "com.spotify.client",
            appIcon: app.icon,
            accentHex: "#1DB954",
            title: parts[1],
            artist: parts[2],
            artwork: art,
            duration: Double(parts[3]) ?? 0,
            elapsed: Double(parts[4]) ?? 0,
            isPlaying: parts[0] == "playing",
            controlKind: .spotify,
            pid: app.processIdentifier
        )
    }

    private func queryAppleMusic(app: NSRunningApplication) -> MediaSession? {
        let script = """
        tell application "Music"
            if player state is stopped then return ""
            set st to player state as string
            set tName to name of current track
            set tArtist to artist of current track
            set tDur to duration of current track
            set tPos to player position
            return st & "|||" & tName & "|||" & tArtist & "|||" & tDur & "|||" & tPos
        end tell
        """
        guard let output = runAppleScript(script), !output.isEmpty else { return nil }
        let parts = output.components(separatedBy: "|||")
        guard parts.count >= 5 else { return nil }

        return MediaSession(
            id: "apple-music",
            sourceName: "Music",
            bundleID: "com.apple.Music",
            appIcon: app.icon,
            accentHex: "#FA2D48",
            title: parts[1],
            artist: parts[2],
            artwork: nil,
            duration: Double(parts[3]) ?? 0,
            elapsed: Double(parts[4]) ?? 0,
            isPlaying: parts[0] == "playing",
            controlKind: .appleMusic,
            pid: app.processIdentifier
        )
    }

    private func queryBrowserMediaTabs(appName: String, bundleID: String, icon: NSImage?, pid: pid_t, isSafari: Bool) -> [MediaSession] {
        let script: String
        if isSafari {
            script = """
            tell application "Safari"
                set out to ""
                set wIdx to 0
                repeat with w in windows
                    set wIdx to wIdx + 1
                    set tIdx to 0
                    repeat with t in tabs of w
                        set tIdx to tIdx + 1
                        set u to URL of t
                        if u contains "youtube.com/watch" or u contains "music.youtube.com" or u contains "soundcloud.com" or u contains "twitch.tv" or u contains "open.spotify.com" then
                            set out to out & wIdx & "|||" & tIdx & "|||" & (name of t) & "|||" & u & linefeed
                        end if
                    end repeat
                end repeat
                return out
            end tell
            """
        } else {
            script = """
            tell application "\(appName)"
                set out to ""
                set wIdx to 0
                repeat with w in windows
                    set wIdx to wIdx + 1
                    set tIdx to 0
                    repeat with t in tabs of w
                        set tIdx to tIdx + 1
                        set u to URL of t
                        if u contains "youtube.com/watch" or u contains "music.youtube.com" or u contains "soundcloud.com" or u contains "twitch.tv" or u contains "open.spotify.com" then
                            set out to out & wIdx & "|||" & tIdx & "|||" & (title of t) & "|||" & u & linefeed
                        end if
                    end repeat
                end repeat
                return out
            end tell
            """
        }

        guard let output = runAppleScript(script), !output.isEmpty else { return [] }
        var results: [MediaSession] = []

        for line in output.components(separatedBy: .newlines) {
            let parts = line.components(separatedBy: "|||")
            guard parts.count >= 4,
                  let wIdx = Int(parts[0]),
                  let tIdx = Int(parts[1]) else { continue }
            let rawTitle = parts[2].trimmingCharacters(in: .whitespacesAndNewlines)
            let urlStr = parts[3]

            let (platform, hex, cleanedTitle) = classifyWebMedia(url: urlStr, rawTitle: rawTitle)
            let id = "web:\(bundleID):\(wIdx):\(tIdx)"

            // Query real playback state from the tab (if JS Apple Events is enabled) so Play/Pause icon is always accurate
            let realState = queryBrowserTabPlayingState(appName: appName, windowIndex: wIdx, tabIndex: tIdx, isSafari: isSafari)
            let isPlayingNow = realState ?? (sessions.first(where: { $0.id == id })?.isPlaying ?? false)

            results.append(MediaSession(
                id: id,
                sourceName: platform,
                bundleID: bundleID,
                appIcon: icon,
                accentHex: hex,
                title: cleanedTitle.isEmpty ? platform : cleanedTitle,
                artist: "\(platform) · \(appName)",
                artwork: nil,
                duration: 0,
                elapsed: 0,
                isPlaying: isPlayingNow,
                controlKind: .browserTab(browserApp: appName, windowIndex: wIdx, tabIndex: tIdx),
                pid: pid
            ))
        }
        return results
    }

    private func classifyWebMedia(url: String, rawTitle: String) -> (String, String, String) {
        let lower = url.lowercased()
        if lower.contains("music.youtube.com") {
            let clean = rawTitle.replacingOccurrences(of: " - YouTube Music", with: "")
            return ("YT Music", "#FF0033", clean)
        } else if lower.contains("youtube.com") {
            let clean = rawTitle.replacingOccurrences(of: " - YouTube", with: "")
            return ("YouTube", "#FF0000", clean)
        } else if lower.contains("soundcloud.com") {
            let clean = rawTitle.replacingOccurrences(of: " | Free Listening on SoundCloud", with: "")
                .replacingOccurrences(of: " on SoundCloud", with: "")
            return ("SoundCloud", "#FF5500", clean)
        } else if lower.contains("twitch.tv") {
            let clean = rawTitle.replacingOccurrences(of: " - Twitch", with: "")
            return ("Twitch", "#9146FF", clean)
        } else if lower.contains("open.spotify.com") {
            return ("Spotify Web", "#1DB954", rawTitle)
        }
        return ("Web Audio", "#38BDF8", rawTitle)
    }

    @available(macOS 14.2, *)
    private func queryActiveCoreAudioApps(excludingBundles: Set<String>) -> [MediaSession] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize) == noErr,
              dataSize > 0 else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioObjectID>.size
        var processIDs = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &dataSize, &processIDs) == noErr else {
            return []
        }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        var results: [MediaSession] = []
        var seenPIDs = Set<pid_t>()

        for procObjID in processIDs {
            var running: UInt32 = 0
            var runSize = UInt32(MemoryLayout<UInt32>.size)
            var runAddr = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyIsRunningOutput,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            guard AudioObjectGetPropertyData(procObjID, &runAddr, 0, nil, &runSize, &running) == noErr,
                  running != 0 else { continue }

            var pid: pid_t = 0
            var pidSize = UInt32(MemoryLayout<pid_t>.size)
            var pidAddr = AudioObjectPropertyAddress(
                mSelector: kAudioProcessPropertyPID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            guard AudioObjectGetPropertyData(procObjID, &pidAddr, 0, nil, &pidSize, &pid) == noErr,
                  pid != ownPID, !seenPIDs.contains(pid) else { continue }

            guard let app = NSRunningApplication(processIdentifier: pid),
                  app.activationPolicy == .regular else { continue }
            let bundleID = app.bundleIdentifier ?? ""
            if excludingBundles.contains(bundleID) { continue }

            seenPIDs.insert(pid)
            let name = app.localizedName ?? "Audio App"
            let accent = accentForApp(name: name, bundleID: bundleID)

            results.append(MediaSession(
                id: "audio:\(pid)",
                sourceName: name,
                bundleID: bundleID,
                appIcon: app.icon,
                accentHex: accent,
                title: "\(name) Audio",
                artist: "Playing live audio",
                artwork: nil,
                duration: 0,
                elapsed: 0,
                isPlaying: true,
                controlKind: .audioApp(pid: pid),
                pid: pid
            ))
        }
        return results
    }

    private func accentForApp(name: String, bundleID: String) -> String {
        let lower = (name + " " + bundleID).lowercased()
        if lower.contains("telegram") { return "#26A5E4" }
        if lower.contains("discord") { return "#5865F2" }
        if lower.contains("vlc") { return "#FF8800" }
        if lower.contains("iina") { return "#60A5FA" }
        if lower.contains("whatsapp") { return "#25D366" }
        return "#38BDF8"
    }

    private func queryBrowserTabPlayingState(appName: String, windowIndex: Int, tabIndex: Int, isSafari: Bool) -> Bool? {
        let js = "(function(){ var sc=document.querySelector('.playControl'); if(sc) return sc.classList.contains('playing')?'playing':'paused'; var v=document.querySelector('video,audio'); if(v) return (!v.paused && !v.ended)?'playing':'paused'; return 'unknown'; })();"
        let escaped = js.replacingOccurrences(of: "\"", with: "\\\"")
        let script = isSafari
            ? "tell application \"Safari\" to do JavaScript \"\(escaped)\" in tab \(tabIndex) of window \(windowIndex)"
            : "tell application \"\(appName)\" to execute tab \(tabIndex) of window \(windowIndex) javascript \"\(escaped)\""
        let (ok, val) = runAppleScriptWithError(script)
        guard ok, let state = val?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        if state == "playing" { return true }
        if state == "paused" { return false }
        return nil
    }

    private func runBrowserMediaJS(
        appName: String,
        windowIndex: Int,
        tabIndex: Int,
        js: String,
        fallbackKeystroke: String?,
        completion: ((String?) -> Void)? = nil
    ) {
        let escapedJS = js.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
        let script: String
        if appName == "Safari" {
            script = "tell application \"Safari\" to do JavaScript \"\(escapedJS)\" in tab \(tabIndex) of window \(windowIndex)"
        } else {
            script = "tell application \"\(appName)\" to execute tab \(tabIndex) of window \(windowIndex) javascript \"\(escapedJS)\""
        }
        DispatchQueue.global(qos: .userInitiated).async {
            let (ok, val) = self.runAppleScriptWithError(script)
            if ok {
                completion?(val?.trimmingCharacters(in: .whitespacesAndNewlines))
                return
            }

            // JS Apple Events not enabled in browser:
            // Focus that exact tab and send YouTube 'k' or SoundCloud Space via System Events
            guard let key = fallbackKeystroke else {
                completion?(nil)
                return
            }
            let keyCmd = key == " " ? "key code 49" : "keystroke \"\(key)\""
            let fallbackScript: String
            if appName == "Safari" {
                fallbackScript = """
                tell application "Safari"
                    activate
                    set current tab of window \(windowIndex) to tab \(tabIndex) of window \(windowIndex)
                    set index of window \(windowIndex) to 1
                end tell
                delay 0.15
                tell application "System Events" to \(keyCmd)
                """
            } else {
                fallbackScript = """
                tell application "\(appName)"
                    activate
                    set active tab index of window \(windowIndex) to \(tabIndex)
                    set index of window \(windowIndex) to 1
                end tell
                delay 0.15
                tell application "System Events" to \(keyCmd)
                """
            }
            let (fbOk, _) = self.runAppleScriptWithError(fallbackScript)
            completion?(fbOk ? "toggled" : nil)
        }
    }

    private func fetchCachedImage(urlString: String) -> NSImage? {
        guard !urlString.isEmpty, let url = URL(string: urlString) else { return nil }
        if let cached = artworkCache[urlString] { return cached }
        if let data = try? Data(contentsOf: url), let img = NSImage(data: data) {
            artworkCache[urlString] = img
            return img
        }
        return nil
    }

    private func runAppleScript(_ source: String) -> String? {
        let (ok, val) = runAppleScriptWithError(source)
        return ok ? val : nil
    }

    private func runAppleScriptWithError(_ source: String) -> (Bool, String?) {
        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return (false, nil) }
        let result = script.executeAndReturnError(&error)
        if error != nil { return (false, nil) }
        return (true, result.stringValue)
    }

    private func sendHIDMediaKey(_ keyType: Int32) {
        func post(down: Bool) {
            let flags = NSEvent.ModifierFlags(rawValue: down ? 0xa00 : 0xb00)
            let data1 = Int((keyType << 16) | (down ? 0xa00 : 0xb00))
            guard let event = NSEvent.otherEvent(
                with: .systemDefined,
                location: .zero,
                modifierFlags: flags,
                timestamp: 0,
                windowNumber: 0,
                context: nil,
                subtype: 8,
                data1: data1,
                data2: -1
            ) else { return }
            event.cgEvent?.post(tap: .cghidEventTap)
        }
        post(down: true)
        post(down: false)
    }
}
