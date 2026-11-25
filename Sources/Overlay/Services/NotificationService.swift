import Foundation
import AppKit
import ApplicationServices
import SQLite3
import Combine

struct CapturedNotification: Identifiable, Equatable {
    let id: UUID
    let dedupeKey: String
    let appName: String
    let bundleID: String
    let appIcon: NSImage?
    let title: String
    let subtitle: String
    let body: String
    let date: Date
    let isTest: Bool

    static func == (lhs: CapturedNotification, rhs: CapturedNotification) -> Bool {
        lhs.id == rhs.id && lhs.dedupeKey == rhs.dedupeKey
    }
}

/// Instant macOS notification capture & Notch-Only banner suppressor:
/// 1. Real-time `AXObserver` attached to `com.apple.notificationcenterui` (< 2 ms reaction when a banner spawns)
/// 2. Instant off-screen window teleport + deep SwiftUI custom-action `Close` dismissal when `autoDismissMacBanner` (Notch-Only Mode) is ON
/// 3. Event-driven `kqueue` file watcher (`db-wal` + `db`) + `PRAGMA read_uncommitted = 1` SQLite reader for zero-delay DND capture
final class NotificationService: ObservableObject {
    @Published var activePopup: CapturedNotification? = nil
    @Published var recentNotifications: [CapturedNotification] = []
    @Published var isReplying: Bool = false
    @Published var replyText: String = ""
    @Published var isHoveringPopup: Bool = false
    @Published var canReadNotificationDB: Bool = false
    @Published var isAccessibilityTrusted: Bool = AXIsProcessTrusted()

    var enabled: Bool = true
    var popupDuration: TimeInterval = 3.0
    /// "Notch-Only Mode": when true, completely suppresses macOS's top-right system notification popup
    /// and displays notifications exclusively under the Notch.
    var autoDismissMacBanner: Bool = true {
        didSet {
            if autoDismissMacBanner {
                handleImmediateAXEvent()
            }
        }
    }
    var readNotificationDatabase: Bool = true

    private var fastPollTimer: Timer?
    private var dismissWorkItem: DispatchWorkItem?
    private let scanQueue = DispatchQueue(label: "com.amin.notchpulse.notifscan", qos: .userInteractive)
    private var seenTimestamps: [String: Date] = [:]
    private var liveBannerElements: [UUID: AXUIElement] = [:]
    private var lastDBRecID: Int64 = -1
    private var lastWALMtime: timespec = timespec(tv_sec: 0, tv_nsec: 0)
    private let maxHistory = 30

    // Real-time AXObserver for com.apple.notificationcenterui
    private var axObserver: AXObserver?
    private var observedNCPID: pid_t = 0

    // Real-time kqueue file watchers for SQLite WAL & DB
    private var walWatcher: DispatchSourceFileSystemObject?
    private var dbWatcher: DispatchSourceFileSystemObject?
    private var watchedDBPath: String?

    init() {
        checkDatabaseAccess()
        setupRealtimeWatchers()

        // Fast lightweight heartbeat (100ms): checks WAL mtime (~2µs stat) & keeps AXObserver attached
        fastPollTimer = Timer.scheduledTimer(withTimeInterval: 0.10, repeats: true) { [weak self] _ in
            self?.heartbeatTick()
        }
    }

    deinit {
        fastPollTimer?.invalidate()
        dismissWorkItem?.cancel()
        teardownAXObserver()
        teardownDBWatchers()
    }

    // MARK: - Real-Time Watchers (0 ms AXObserver + 0 ms kqueue WAL Watcher)

    private func setupRealtimeWatchers() {
        ensureAXObserverAttached()
        scanQueue.async { [weak self] in
            guard let self else { return }
            if let path = self.resolveNotificationDBPath() {
                self.installDBFileWatchersIfNeeded(dbPath: path)
                self.scanNotificationDatabaseSync(force: true)
            }
        }
    }

    private func heartbeatTick() {
        let trusted = AXIsProcessTrusted()
        if trusted != isAccessibilityTrusted {
            isAccessibilityTrusted = trusted
        }

        guard enabled else { return }

        if trusted {
            ensureAXObserverAttached()
        } else if observedNCPID != 0 {
            teardownAXObserver()
        }

        let shouldReadDB = readNotificationDatabase
        let shouldAutoDismiss = autoDismissMacBanner
        let ncPID = trusted ? observedNCPID : 0

        scanQueue.async { [weak self] in
            guard let self else { return }
            if shouldReadDB {
                if let path = self.watchedDBPath ?? self.resolveNotificationDBPath() {
                    self.installDBFileWatchersIfNeeded(dbPath: path)
                    if self.hasDBChangedOnDisk(dbPath: path) {
                        self.scanNotificationDatabaseSync(force: false)
                    }
                }
            }
            if ncPID > 0 {
                self.scanNotificationCenterSync(ncPID: ncPID, autoDismiss: shouldAutoDismiss)
            }
        }
    }

    fileprivate func handleImmediateAXEvent() {
        guard enabled, AXIsProcessTrusted() else { return }
        let pid = observedNCPID
        guard pid > 0 else { return }
        let autoDismiss = autoDismissMacBanner

        scanQueue.async { [weak self] in
            guard let self else { return }
            self.scanNotificationCenterSync(ncPID: pid, autoDismiss: autoDismiss)
        }
        // Second micro-pass 22ms later in case SwiftUI populated AXStaticText nodes 1 frame after window creation
        scanQueue.asyncAfter(deadline: .now() + 0.022) { [weak self] in
            guard let self else { return }
            self.scanNotificationCenterSync(ncPID: pid, autoDismiss: autoDismiss)
        }
    }

    private func ensureAXObserverAttached() {
        guard AXIsProcessTrusted(),
              let ncApp = NSWorkspace.shared.runningApplications.first(where: {
                  $0.bundleIdentifier == "com.apple.notificationcenterui"
              }) else {
            return
        }

        let pid = ncApp.processIdentifier
        guard pid > 0, pid != observedNCPID else { return }

        teardownAXObserver()

        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            let service = Unmanaged<NotificationService>.fromOpaque(refcon).takeUnretainedValue()
            service.handleImmediateAXEvent()
        }

        var obs: AXObserver?
        guard AXObserverCreate(pid, callback, &obs) == .success, let observer = obs else {
            return
        }

        let appElem = AXUIElementCreateApplication(pid)
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        let notifications: [String] = [
            kAXWindowCreatedNotification as String,
            kAXCreatedNotification as String,
            kAXLayoutChangedNotification as String,
            kAXMovedNotification as String,
            kAXUIElementDestroyedNotification as String
        ]
        for notif in notifications {
            AXObserverAddNotification(observer, appElem, notif as CFString, selfPtr)
        }

        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        axObserver = observer
        observedNCPID = pid
    }

    private func teardownAXObserver() {
        if let obs = axObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .commonModes)
            axObserver = nil
        }
        observedNCPID = 0
    }

    private func installDBFileWatchersIfNeeded(dbPath: String) {
        guard watchedDBPath != dbPath else { return }
        teardownDBWatchers()
        watchedDBPath = dbPath

        let walPath = dbPath + "-wal"
        walWatcher = makeFileWatcher(path: walPath)
        dbWatcher = makeFileWatcher(path: dbPath)
    }

    private func makeFileWatcher(path: String) -> DispatchSourceFileSystemObject? {
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .extend, .attrib, .rename, .delete],
            queue: scanQueue
        )
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = source.data
            if flags.contains(.delete) || flags.contains(.rename) {
                self.watchedDBPath = nil
            }
            if self.enabled && self.readNotificationDatabase {
                self.scanNotificationDatabaseSync(force: true)
            }
        }
        source.setCancelHandler {
            close(fd)
        }
        source.resume()
        return source
    }

    private func teardownDBWatchers() {
        walWatcher?.cancel()
        walWatcher = nil
        dbWatcher?.cancel()
        dbWatcher = nil
        watchedDBPath = nil
    }

    private func hasDBChangedOnDisk(dbPath: String) -> Bool {
        var st = stat()
        let walPath = dbPath + "-wal"
        if stat(walPath, &st) == 0 {
            if st.st_mtimespec.tv_sec != lastWALMtime.tv_sec || st.st_mtimespec.tv_nsec != lastWALMtime.tv_nsec {
                lastWALMtime = st.st_mtimespec
                return true
            }
            return false
        }
        if stat(dbPath, &st) == 0 {
            if st.st_mtimespec.tv_sec != lastWALMtime.tv_sec || st.st_mtimespec.tv_nsec != lastWALMtime.tv_nsec {
                lastWALMtime = st.st_mtimespec
                return true
            }
        }
        return false
    }

    // MARK: - Popup Lifecycle (Paused on hover or while typing reply)

    func showPopup(_ notif: CapturedNotification, axBanner: AXUIElement? = nil, playSubtleSound: Bool = false) {
        if let axBanner {
            liveBannerElements[notif.id] = axBanner
        }
        DispatchQueue.main.async {
            if !self.recentNotifications.contains(where: { $0.dedupeKey == notif.dedupeKey && Date().timeIntervalSince($0.date) < 8 }) {
                self.recentNotifications.insert(notif, at: 0)
                if self.recentNotifications.count > self.maxHistory {
                    self.recentNotifications = Array(self.recentNotifications.prefix(self.maxHistory))
                }
            }

            guard self.enabled else { return }
            if playSubtleSound, let sound = NSSound(named: NSSound.Name("Glass")) ?? NSSound(named: NSSound.Name("Tink")) {
                sound.volume = 0.45
                sound.play()
            }
            self.isReplying = false
            self.replyText = ""
            self.activePopup = notif
            self.scheduleDismiss()
        }
    }

    func scheduleDismiss() {
        dismissWorkItem?.cancel()
        guard !isReplying && !isHoveringPopup else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if !self.isReplying && !self.isHoveringPopup {
                self.dismissPopup()
            }
        }
        dismissWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + popupDuration, execute: work)
    }

    func setHovering(_ hovering: Bool) {
        if isHoveringPopup != hovering {
            isHoveringPopup = hovering
            if hovering {
                dismissWorkItem?.cancel()
            } else {
                scheduleDismiss()
            }
        }
    }

    func beginReply() {
        dismissWorkItem?.cancel()
        isReplying = true
    }

    func dismissPopup(alsoDismissSystemBanner: Bool = false) {
        dismissWorkItem?.cancel()
        if alsoDismissSystemBanner, let current = activePopup, let banner = liveBannerElements[current.id] {
            scanQueue.async {
                self.dismissBannerElement(banner, owningWindow: nil)
            }
        }
        activePopup = nil
        isReplying = false
        replyText = ""
    }

    func sendTestNotification() {
        let tgIcon = findAppIcon(named: "Telegram") ?? NSImage(systemSymbolName: "paperplane.fill", accessibilityDescription: nil)
        let test = CapturedNotification(
            id: UUID(),
            dedupeKey: "test-\(UUID().uuidString)",
            appName: "Telegram",
            bundleID: "ru.keepcoder.Telegram",
            appIcon: tgIcon,
            title: "Alex",
            subtitle: "",
            body: "Instant Notch-Only notification test!",
            date: Date(),
            isTest: true
        )
        showPopup(test, playSubtleSound: true)
    }

    func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: - Notification Actions (Reply, Mark as Read, Open App)

    func markAsRead(_ notif: CapturedNotification) {
        if notif.isTest {
            dismissPopup()
            return
        }
        if let banner = liveBannerElements[notif.id] {
            DispatchQueue.global(qos: .userInitiated).async {
                if self.pressAXAction(on: banner, matching: ["mark as read", "read"], maxDepth: 10) {
                    return
                }
                _ = AXUIElementPerformAction(banner, kAXPressAction as CFString)
            }
        } else {
            openSourceApp(notif)
        }
        dismissPopup()
    }

    func openSourceApp(_ notif: CapturedNotification) {
        if notif.isTest {
            dismissPopup()
            return
        }
        if let banner = liveBannerElements[notif.id] {
            DispatchQueue.global(qos: .userInitiated).async {
                if AXUIElementPerformAction(banner, kAXPressAction as CFString) != .success {
                    DispatchQueue.main.async { self.activateApp(named: notif.appName, bundleID: notif.bundleID) }
                }
            }
        } else {
            activateApp(named: notif.appName, bundleID: notif.bundleID)
        }
        dismissPopup()
    }

    func sendReply(for notif: CapturedNotification, message: String) {
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if notif.isTest {
            dismissPopup()
            return
        }

        let banner = liveBannerElements[notif.id]
        dismissPopup()

        DispatchQueue.global(qos: .userInitiated).async {
            if let banner, self.tryNativeAXReply(banner: banner, message: trimmed) {
                return
            }

            var openedViaBanner = false
            if let banner {
                openedViaBanner = (AXUIElementPerformAction(banner, kAXPressAction as CFString) == .success)
            }

            if openedViaBanner {
                Thread.sleep(forTimeInterval: 0.45)
                self.pasteAndSendText(trimmed)
                return
            }

            DispatchQueue.main.sync {
                self.activateApp(named: notif.appName, bundleID: notif.bundleID)
            }
            Thread.sleep(forTimeInterval: 0.35)

            let lowerApp = (notif.appName + " " + notif.bundleID).lowercased()
            if (lowerApp.contains("telegram") || lowerApp.contains("discord") || lowerApp.contains("slack")),
               !notif.title.isEmpty,
               notif.title.lowercased() != notif.appName.lowercased() {
                self.postKeyCombo(keyCode: 40, flags: .maskCommand) // Cmd+K
                Thread.sleep(forTimeInterval: 0.25)
                self.pasteTextOnly(notif.title)
                Thread.sleep(forTimeInterval: 0.35)
                self.postKeyCombo(keyCode: 36, flags: []) // Return
                Thread.sleep(forTimeInterval: 0.30)
            }

            self.pasteAndSendText(trimmed)
        }
    }

    private func tryNativeAXReply(banner: AXUIElement, message: String) -> Bool {
        guard pressAXAction(on: banner, matching: ["reply"], maxDepth: 10) else {
            return false
        }
        Thread.sleep(forTimeInterval: 0.25)

        guard let textField = findAXElement(in: banner, roles: [kAXTextFieldRole as String, kAXTextAreaRole as String], depth: 0, maxDepth: 12) else {
            return false
        }
        let setRes = AXUIElementSetAttributeValue(textField, kAXValueAttribute as CFString, message as CFTypeRef)
        guard setRes == .success else { return false }
        Thread.sleep(forTimeInterval: 0.10)

        if pressAXAction(on: banner, matching: ["send"], maxDepth: 10) {
            return true
        }
        return AXUIElementPerformAction(textField, kAXConfirmAction as CFString) == .success
    }

    private func pasteTextOnly(_ text: String) {
        let saved: String? = DispatchQueue.main.sync {
            let pb = NSPasteboard.general
            let prev = pb.string(forType: .string)
            pb.clearContents()
            pb.setString(text, forType: .string)
            return prev
        }
        Thread.sleep(forTimeInterval: 0.06)
        postKeyCombo(keyCode: 9, flags: .maskCommand)
        Thread.sleep(forTimeInterval: 0.12)
        if let saved {
            DispatchQueue.main.async {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(saved, forType: .string)
            }
        }
    }

    private func pasteAndSendText(_ text: String) {
        let saved: String? = DispatchQueue.main.sync {
            let pb = NSPasteboard.general
            let prev = pb.string(forType: .string)
            pb.clearContents()
            pb.setString(text, forType: .string)
            return prev
        }
        Thread.sleep(forTimeInterval: 0.08)
        postKeyCombo(keyCode: 9, flags: .maskCommand)
        Thread.sleep(forTimeInterval: 0.14)
        postKeyCombo(keyCode: 36, flags: [])
        Thread.sleep(forTimeInterval: 0.15)
        if let saved {
            DispatchQueue.main.async {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(saved, forType: .string)
            }
        }
    }

    private func postKeyCombo(keyCode: CGKeyCode, flags: CGEventFlags) {
        guard let src = CGEventSource(stateID: .hidSystemState),
              let down = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false) else {
            return
        }
        down.flags = flags
        up.flags = flags
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
    }

    private func activateApp(named appName: String, bundleID: String) {
        if !bundleID.isEmpty,
           let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }) {
            app.activate(options: [.activateIgnoringOtherApps])
            return
        }
        if let app = NSWorkspace.shared.runningApplications.first(where: {
            ($0.localizedName ?? "").localizedCaseInsensitiveCompare(appName) == .orderedSame
        }) {
            app.activate(options: [.activateIgnoringOtherApps])
        }
    }

    // MARK: - Instant NotificationCenter AX Scanner & System Popup Suppressor

    private func teleportWindowOffscreen(_ window: AXUIElement) {
        var offscreen = CGPoint(x: 32000, y: -32000)
        if let posVal = AXValueCreate(.cgPoint, &offscreen) {
            _ = AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, posVal)
        }
    }

    private func isCompactBannerWindow(_ window: AXUIElement) -> Bool {
        if let size = axSize(window, kAXSizeAttribute) {
            // Notification Center's full sidebar is tall (> 500px); individual popup banner windows are compact (< 420px)
            if size.height >= 28 && size.height <= 420 && size.width >= 160 && size.width <= 560 {
                return true
            }
            if size.height > 480 {
                return false
            }
        }
        return false
    }

    private func dismissBannerElement(_ banner: AXUIElement, owningWindow: AXUIElement?) {
        if let owningWindow {
            teleportWindowOffscreen(owningWindow)
        }

        let closeKeywords = [
            "close", "clear", "dismiss", "cancel",
            "بستن", "پاک", "fermer", "schließen", "cerrar", "chiudi", "закрыть", "关闭", "閉じる", "닫기"
        ]

        // 1. Search custom AXActions (checking BOTH raw action name AND localized AXUIElementCopyActionDescription!)
        //    and AXButtons across the banner subtree (depth 0..14)
        if pressAXAction(on: banner, matching: closeKeywords, maxDepth: 14) {
            return
        }

        // 2. Try kAXCancelAction & kAXCloseButtonAttribute on banner
        if AXUIElementPerformAction(banner, kAXCancelAction as CFString) == .success {
            return
        }
        if pressCloseButtonAttribute(on: banner) {
            return
        }

        // 3. Walk up parent chain to owningWindow and try custom Close actions / close button there too
        if let owningWindow {
            if pressAXAction(on: owningWindow, matching: closeKeywords, maxDepth: 14) {
                return
            }
            if AXUIElementPerformAction(owningWindow, kAXCancelAction as CFString) == .success {
                return
            }
            _ = pressCloseButtonAttribute(on: owningWindow)
        }
    }

    private func pressCloseButtonAttribute(on element: AXUIElement) -> Bool {
        var closeRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXCloseButtonAttribute as CFString, &closeRef) == .success,
           let btn = closeRef {
            return AXUIElementPerformAction(btn as! AXUIElement, kAXPressAction as CFString) == .success
        }
        return false
    }

    private func scanNotificationCenterSync(ncPID: pid_t, autoDismiss: Bool) {
        let appElem = AXUIElementCreateApplication(ncPID)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElem, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let windows = windowsRef as? [AXUIElement], !windows.isEmpty else {
            return
        }

        let now = Date()
        seenTimestamps = seenTimestamps.filter { now.timeIntervalSince($0.value) < 60 }

        for window in windows {
            let isCompactPopupWin = isCompactBannerWindow(window)

            // Search deep (up to depth 16) for SwiftUI / AppKit notification banner elements
            var banners = findNotificationBanners(in: window, depth: 0, maxDepth: 16)
            if banners.isEmpty && isCompactPopupWin {
                banners = [window]
            }
            guard !banners.isEmpty else { continue }

            // If Notch-Only Mode is ON, immediately push compact popup windows off-screen before animation appears
            if autoDismiss && isCompactPopupWin {
                teleportWindowOffscreen(window)
            }

            for banner in banners {
                if let parsed = extractNotification(from: banner) {
                    if autoDismiss {
                        dismissBannerElement(banner, owningWindow: isCompactPopupWin ? window : nil)
                    }

                    if let lastSeen = seenTimestamps[parsed.dedupeKey], now.timeIntervalSince(lastSeen) < 15 {
                        continue
                    }
                    seenTimestamps[parsed.dedupeKey] = now
                    showPopup(parsed, axBanner: autoDismiss ? nil : banner)
                } else if autoDismiss && isCompactPopupWin {
                    // Window just spawned and text nodes are still mounting; keep it off-screen until the +22ms pass reads & closes it
                    teleportWindowOffscreen(window)
                }
            }
        }
    }

    private func findNotificationBanners(in element: AXUIElement, depth: Int, maxDepth: Int) -> [AXUIElement] {
        guard depth <= maxDepth else { return [] }
        let subrole = axString(element, kAXSubroleAttribute) ?? ""
        if subrole == "AXNotificationCenterBanner" || subrole == "AXNotificationCenterAlert" {
            return [element]
        }

        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else {
            return []
        }

        var found: [AXUIElement] = []
        for child in children {
            found.append(contentsOf: findNotificationBanners(in: child, depth: depth + 1, maxDepth: maxDepth))
        }
        return found
    }

    private func extractNotification(from banner: AXUIElement) -> CapturedNotification? {
        var texts: [String] = []
        collectStaticTexts(in: banner, into: &texts, depth: 0, maxDepth: 14)

        let noise: Set<String> = [
            "close", "options", "reply", "now", "clear", "clear all",
            "mark as read", "actions", "notification center", "stack"
        ]
        let cleaned = texts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !noise.contains($0.lowercased()) }

        // Also check AXDescription on the banner itself (SwiftUI banners often pack "<App>, <Title>, <Body>" here immediately!)
        let desc = axString(banner, kAXDescriptionAttribute) ?? ""
        if cleaned.isEmpty && desc.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return nil
        }

        var appName = ""
        var bundleID = ""
        var appIcon: NSImage? = nil

        let descParts = desc.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if let firstPart = descParts.first {
            if let matched = matchApp(name: firstPart) {
                appName = matched.name
                bundleID = matched.bundleID
                appIcon = matched.icon
            }
        }

        if appName.isEmpty {
            for candidate in cleaned {
                if let matched = matchApp(name: candidate) {
                    appName = matched.name
                    bundleID = matched.bundleID
                    appIcon = matched.icon
                    break
                }
            }
        }

        if appName.isEmpty {
            appName = descParts.first ?? "Notification"
            appIcon = NSImage(systemSymbolName: "bell.badge.fill", accessibilityDescription: nil)
        }

        let sourceLines = !cleaned.isEmpty ? cleaned : Array(descParts.dropFirst())
        let contentLines = sourceLines.filter { $0.localizedCaseInsensitiveCompare(appName) != .orderedSame }
        let title = contentLines.first ?? appName
        let subtitle = contentLines.count >= 3 ? contentLines[1] : ""
        let body = contentLines.count >= 3 ? contentLines[2] : (contentLines.count == 2 ? contentLines[1] : "")
        let finalBody = body.isEmpty ? subtitle : body

        guard !title.isEmpty || !finalBody.isEmpty else { return nil }

        let dedupe = makeDedupeKey(title: title, body: finalBody)
        return CapturedNotification(
            id: UUID(),
            dedupeKey: dedupe,
            appName: appName,
            bundleID: bundleID,
            appIcon: appIcon,
            title: title,
            subtitle: subtitle,
            body: finalBody,
            date: Date(),
            isTest: false
        )
    }

    private func makeDedupeKey(title: String, body: String) -> String {
        "\(title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())|\(body.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())"
    }

    private func collectStaticTexts(in element: AXUIElement, into out: inout [String], depth: Int, maxDepth: Int) {
        guard depth <= maxDepth else { return }
        let role = axString(element, kAXRoleAttribute) ?? ""
        if role == (kAXStaticTextRole as String) {
            if let val = axString(element, kAXValueAttribute), !val.isEmpty {
                out.append(val)
            } else if let title = axString(element, kAXTitleAttribute), !title.isEmpty {
                out.append(title)
            } else if let desc = axString(element, kAXDescriptionAttribute), !desc.isEmpty {
                out.append(desc)
            }
        }
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else {
            return
        }
        for child in children {
            collectStaticTexts(in: child, into: &out, depth: depth + 1, maxDepth: maxDepth)
        }
    }

    /// Recursively searches `element` and its descendants for custom AXActions (checking BOTH action name
    /// and `AXUIElementCopyActionDescription` for SwiftUI custom actions) as well as matching AXButtons.
    private func pressAXAction(on element: AXUIElement, matching keywords: [String], maxDepth: Int) -> Bool {
        if pressCustomActionRecursive(on: element, matching: keywords, depth: 0, maxDepth: maxDepth) {
            return true
        }
        if let btn = findAXButton(in: element, matching: keywords, depth: 0, maxDepth: maxDepth) {
            return AXUIElementPerformAction(btn, kAXPressAction as CFString) == .success
        }
        return false
    }

    private func pressCustomActionRecursive(on element: AXUIElement, matching keywords: [String], depth: Int, maxDepth: Int) -> Bool {
        guard depth <= maxDepth else { return false }

        let forbiddenActions = ["axpress", "axshowmenu", "mute", "turn off"]
        var actionsRef: CFArray?
        if AXUIElementCopyActionNames(element, &actionsRef) == .success,
           let actions = actionsRef as? [String] {
            for act in actions {
                let lowerName = act.lowercased()
                if forbiddenActions.contains(lowerName) { continue }

                var descStr = ""
                var descRef: CFString?
                if AXUIElementCopyActionDescription(element, act as CFString, &descRef) == .success,
                   let d = descRef as String? {
                    descStr = d.lowercased()
                }

                let combined = lowerName + " " + descStr
                if forbiddenActions.contains(where: { descStr.contains($0) }) { continue }

                if keywords.contains(where: { combined.contains($0) }) {
                    if AXUIElementPerformAction(element, act as CFString) == .success {
                        return true
                    }
                }
            }
        }

        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else {
            return false
        }
        for child in children {
            if pressCustomActionRecursive(on: child, matching: keywords, depth: depth + 1, maxDepth: maxDepth) {
                return true
            }
        }
        return false
    }

    private func findAXButton(in element: AXUIElement, matching keywords: [String], depth: Int, maxDepth: Int) -> AXUIElement? {
        guard depth <= maxDepth else { return nil }
        if axString(element, kAXRoleAttribute) == (kAXButtonRole as String) {
            let texts = [
                axString(element, kAXTitleAttribute),
                axString(element, kAXDescriptionAttribute),
                axString(element, kAXHelpAttribute),
                axString(element, kAXIdentifierAttribute)
            ].compactMap { $0?.lowercased() }
            if texts.contains(where: { t in keywords.contains(where: { t.contains($0) }) }) {
                return element
            }
        }
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else { return nil }
        for child in children {
            if let found = findAXButton(in: child, matching: keywords, depth: depth + 1, maxDepth: maxDepth) {
                return found
            }
        }
        return nil
    }

    private func findAXElement(in element: AXUIElement, roles: [String], depth: Int, maxDepth: Int) -> AXUIElement? {
        guard depth <= maxDepth else { return nil }
        if let r = axString(element, kAXRoleAttribute), roles.contains(r) {
            return element
        }
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else { return nil }
        for child in children {
            if let found = findAXElement(in: child, roles: roles, depth: depth + 1, maxDepth: maxDepth) {
                return found
            }
        }
        return nil
    }

    private func axString(_ element: AXUIElement, _ attr: String) -> String? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attr as CFString, &ref) == .success,
              let s = ref as? String, !s.isEmpty else { return nil }
        return s
    }

    private func axSize(_ element: AXUIElement, _ attr: String) -> CGSize? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attr as CFString, &ref) == .success,
              let val = ref, CFGetTypeID(val) == AXValueGetTypeID() else { return nil }
        var sz = CGSize.zero
        guard AXValueGetValue(val as! AXValue, .cgSize, &sz) else { return nil }
        return sz
    }

    private func matchApp(name: String) -> (name: String, bundleID: String, icon: NSImage?)? {
        let lower = name.lowercased()
        for app in NSWorkspace.shared.runningApplications {
            guard let loc = app.localizedName, !loc.isEmpty else { continue }
            if loc.lowercased() == lower || lower.contains(loc.lowercased()) {
                return (loc, app.bundleIdentifier ?? "", app.icon)
            }
        }
        return nil
    }

    // MARK: - Event-Driven Zero-Flash SQLite WAL Reader (Works with DND / Banners OFF)

    func openFullDiskAccessSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            NSWorkspace.shared.open(url)
        }
    }

    func checkDatabaseAccess() {
        scanQueue.async { [weak self] in
            guard let self else { return }
            let path = self.resolveNotificationDBPath()
            if let path {
                self.installDBFileWatchersIfNeeded(dbPath: path)
            }
            let readable = path != nil
            DispatchQueue.main.async {
                self.canReadNotificationDB = readable
            }
        }
    }

    private func resolveNotificationDBPath() -> String? {
        var candidates: [String] = []

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        candidates.append("\(home)/Library/Group Containers/group.com.apple.usernoted/db2/db")

        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        let len = confstr(_CS_DARWIN_USER_DIR, &buf, buf.count)
        if len > 0 {
            let userDir = String(cString: buf)
            candidates.append("\(userDir)com.apple.notificationcenter/db2/db")
        }

        for path in candidates {
            if FileManager.default.isReadableFile(atPath: path) {
                var db: OpaquePointer?
                if sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK {
                    sqlite3_close(db)
                    return path
                }
            }
        }
        return nil
    }

    private func scanNotificationDatabaseSync(force: Bool) {
        guard let dbPath = watchedDBPath ?? resolveNotificationDBPath() else {
            DispatchQueue.main.async { self.canReadNotificationDB = false }
            return
        }
        if !canReadNotificationDB {
            DispatchQueue.main.async { self.canReadNotificationDB = true }
        }

        var db: OpaquePointer?
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK, let db else { return }
        defer { sqlite3_close(db) }

        // Read latest WAL frames immediately without waiting for checkpoint
        sqlite3_exec(db, "PRAGMA read_uncommitted = 1;", nil, nil, nil)

        if lastDBRecID < 0 {
            var stmt: OpaquePointer?
            if sqlite3_prepare_v2(db, "SELECT COALESCE(MAX(rec_id), 0) FROM record", -1, &stmt, nil) == SQLITE_OK {
                if sqlite3_step(stmt) == SQLITE_ROW {
                    lastDBRecID = sqlite3_column_int64(stmt, 0)
                }
                sqlite3_finalize(stmt)
            }
            return
        }

        let sql = """
        SELECT r.rec_id, a.identifier, r.data
        FROM record r
        JOIN app a ON r.app_id = a.app_id
        WHERE r.rec_id > ?
        ORDER BY r.rec_id ASC
        LIMIT 10
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, lastDBRecID)

        let now = Date()
        seenTimestamps = seenTimestamps.filter { now.timeIntervalSince($0.value) < 60 }

        while sqlite3_step(stmt) == SQLITE_ROW {
            let recID = sqlite3_column_int64(stmt, 0)
            if recID > lastDBRecID {
                lastDBRecID = recID
            }

            let bundleID = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
            guard let blobPtr = sqlite3_column_blob(stmt, 2) else { continue }
            let blobLen = Int(sqlite3_column_bytes(stmt, 2))
            guard blobLen > 0 else { continue }
            let plistData = Data(bytes: blobPtr, count: blobLen)

            guard let parsed = parseNotificationPlist(plistData, bundleID: bundleID) else { continue }
            if let lastSeen = seenTimestamps[parsed.dedupeKey], now.timeIntervalSince(lastSeen) < 15 {
                continue
            }
            seenTimestamps[parsed.dedupeKey] = now
            showPopup(parsed, axBanner: nil)
        }
    }

    private func parseNotificationPlist(_ data: Data, bundleID: String) -> CapturedNotification? {
        guard let root = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            return nil
        }
        let req = (root["req"] as? [String: Any]) ?? root
        let title = (req["titl"] as? String) ?? ""
        let subtitle = (req["subt"] as? String) ?? ""
        let body = (req["body"] as? String) ?? ""
        guard !title.isEmpty || !body.isEmpty else { return nil }

        var appName = bundleID.split(separator: ".").last.map(String.init) ?? "Notification"
        var appIcon: NSImage? = nil
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            appName = Bundle(url: appURL)?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? Bundle(url: appURL)?.object(forInfoDictionaryKey: "CFBundleName") as? String
                ?? appURL.deletingPathExtension().lastPathComponent
            appIcon = NSWorkspace.shared.icon(forFile: appURL.path)
        } else if let running = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }) {
            appName = running.localizedName ?? appName
            appIcon = running.icon
        }

        let displayTitle = title.isEmpty ? appName : title
        let displayBody = body.isEmpty ? subtitle : body
        let dedupe = makeDedupeKey(title: displayTitle, body: displayBody)

        return CapturedNotification(
            id: UUID(),
            dedupeKey: dedupe,
            appName: appName,
            bundleID: bundleID,
            appIcon: appIcon ?? NSImage(systemSymbolName: "bell.badge.fill", accessibilityDescription: nil),
            title: displayTitle,
            subtitle: subtitle,
            body: displayBody,
            date: Date(),
            isTest: false
        )
    }

    private func findAppIcon(named name: String) -> NSImage? {
        matchApp(name: name)?.icon
    }
}
