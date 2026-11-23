import Foundation
import AppKit
import ApplicationServices
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

/// Captures incoming macOS notification banners via NotificationCenter's Accessibility tree
/// and supports inline Quick Reply, Mark as Read, Open App, and Dismiss actions.
final class NotificationService: ObservableObject {
    @Published var activePopup: CapturedNotification? = nil
    @Published var recentNotifications: [CapturedNotification] = []
    @Published var isReplying: Bool = false
    @Published var replyText: String = ""
    @Published var isHoveringPopup: Bool = false

    var enabled: Bool = true
    var popupDuration: TimeInterval = 3.0

    private var pollTimer: Timer?
    private var dismissWorkItem: DispatchWorkItem?
    private var seenTimestamps: [String: Date] = [:]
    private var liveBannerElements: [UUID: AXUIElement] = [:]
    private let maxHistory = 30

    init() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.45, repeats: true) { [weak self] _ in
            self?.scanNotificationCenter()
        }
    }

    deinit {
        pollTimer?.invalidate()
        dismissWorkItem?.cancel()
    }

    // MARK: - Popup Lifecycle (3-second auto-dismiss, paused on hover or while typing reply)

    func showPopup(_ notif: CapturedNotification, axBanner: AXUIElement? = nil) {
        if let axBanner {
            liveBannerElements[notif.id] = axBanner
        }
        DispatchQueue.main.async {
            if !self.recentNotifications.contains(where: { $0.dedupeKey == notif.dedupeKey && Date().timeIntervalSince($0.date) < 5 }) {
                self.recentNotifications.insert(notif, at: 0)
                if self.recentNotifications.count > self.maxHistory {
                    self.recentNotifications = Array(self.recentNotifications.prefix(self.maxHistory))
                }
            }

            guard self.enabled else { return }
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
            DispatchQueue.global(qos: .userInitiated).async {
                _ = self.pressAXAction(on: banner, matching: ["close", "dismiss", "clear"])
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
            body: "Hey! Testing NotchPulse notification popup & quick reply.",
            date: Date(),
            isTest: true
        )
        showPopup(test)
    }

    // MARK: - Notification Actions (Reply, Mark as Read, Open App)

    func markAsRead(_ notif: CapturedNotification) {
        if notif.isTest {
            dismissPopup()
            return
        }
        if let banner = liveBannerElements[notif.id] {
            DispatchQueue.global(qos: .userInitiated).async {
                // 1. Try native "Mark as Read" action on the macOS notification banner
                if self.pressAXAction(on: banner, matching: ["mark as read", "read"]) {
                    return
                }
                // 2. Otherwise click the banner itself to open the conversation & mark read
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
            // 1. Try native inline AX Reply directly inside macOS NotificationCenter banner (works in background!)
            if let banner, self.tryNativeAXReply(banner: banner, message: trimmed) {
                return
            }

            // 2. Try clicking the macOS banner to jump directly into the exact chat
            var openedViaBanner = false
            if let banner {
                openedViaBanner = (AXUIElementPerformAction(banner, kAXPressAction as CFString) == .success)
            }

            if openedViaBanner {
                Thread.sleep(forTimeInterval: 0.45)
                self.pasteAndSendText(trimmed)
                return
            }

            // 3. Banner already auto-dismissed: activate the app (e.g. Telegram), jump to sender's chat via Cmd+K, and send!
            DispatchQueue.main.sync {
                self.activateApp(named: notif.appName, bundleID: notif.bundleID)
            }
            Thread.sleep(forTimeInterval: 0.35)

            let lowerApp = (notif.appName + " " + notif.bundleID).lowercased()
            if (lowerApp.contains("telegram") || lowerApp.contains("discord") || lowerApp.contains("slack")),
               !notif.title.isEmpty,
               notif.title.lowercased() != notif.appName.lowercased() {
                // Open Quick Switcher (Cmd+K), search sender name, press Return to open exact chat
                self.postKeyCombo(keyCode: 40, flags: .maskCommand) // Cmd+K
                Thread.sleep(forTimeInterval: 0.25)
                self.pasteTextOnly(notif.title)
                Thread.sleep(forTimeInterval: 0.35)
                self.postKeyCombo(keyCode: 36, flags: []) // Return -> opens chat & focuses input box
                Thread.sleep(forTimeInterval: 0.30)
            }

            self.pasteAndSendText(trimmed)
        }
    }

    private func tryNativeAXReply(banner: AXUIElement, message: String) -> Bool {
        // Click "Reply" button/action on the banner first if present
        guard pressAXAction(on: banner, matching: ["reply"]) else {
            return false
        }
        Thread.sleep(forTimeInterval: 0.28)

        // Find the AXTextField / AXTextArea that opened inside the banner
        guard let textField = findAXElement(in: banner, roles: [kAXTextFieldRole as String, kAXTextAreaRole as String], depth: 0, maxDepth: 8) else {
            return false
        }
        let setRes = AXUIElementSetAttributeValue(textField, kAXValueAttribute as CFString, message as CFTypeRef)
        guard setRes == .success else { return false }
        Thread.sleep(forTimeInterval: 0.12)

        // Click "Send" button if present, or press Return on the text field
        if pressAXAction(on: banner, matching: ["send"]) {
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
        postKeyCombo(keyCode: 9, flags: .maskCommand) // Cmd+V
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
        postKeyCombo(keyCode: 9, flags: .maskCommand) // Cmd+V
        Thread.sleep(forTimeInterval: 0.14)
        postKeyCombo(keyCode: 36, flags: [])          // Return
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

    // MARK: - NotificationCenter AX Scanner

    private func scanNotificationCenter() {
        guard enabled, AXIsProcessTrusted() else { return }

        guard let ncApp = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == "com.apple.notificationcenterui"
        }) else {
            return
        }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            let appElem = AXUIElementCreateApplication(ncApp.processIdentifier)
            var windowsRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(appElem, kAXWindowsAttribute as CFString, &windowsRef) == .success,
                  let windows = windowsRef as? [AXUIElement] else {
                return
            }

            let now = Date()
            // Prune old dedupe entries (> 60s)
            self.seenTimestamps = self.seenTimestamps.filter { now.timeIntervalSince($0.value) < 60 }

            for window in windows {
                let banners = self.findNotificationBanners(in: window, depth: 0, maxDepth: 6)
                for banner in banners {
                    guard let parsed = self.extractNotification(from: banner) else { continue }
                    if let lastSeen = self.seenTimestamps[parsed.dedupeKey], now.timeIntervalSince(lastSeen) < 15 {
                        continue
                    }
                    self.seenTimestamps[parsed.dedupeKey] = now
                    self.showPopup(parsed, axBanner: banner)
                    return
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
        collectStaticTexts(in: banner, into: &texts, depth: 0, maxDepth: 7)

        // Filter out noise strings like "Close", "Options", "now", "Reply"
        let noise: Set<String> = ["close", "options", "reply", "now", "clear", "mark as read", "actions"]
        let cleaned = texts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !noise.contains($0.lowercased()) }

        guard !cleaned.isEmpty else { return nil }

        // Determine app name from banner AXDescription or first matching running app
        let desc = axString(banner, kAXDescriptionAttribute) ?? ""
        var appName = ""
        var bundleID = ""
        var appIcon: NSImage? = nil

        // macOS banner description often starts with "<AppName>, <Title>, <Body>"
        let descParts = desc.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        if let firstPart = descParts.first, !firstPart.isEmpty {
            if let matched = matchRunningApp(name: firstPart) {
                appName = matched.name
                bundleID = matched.bundleID
                appIcon = matched.icon
            }
        }

        if appName.isEmpty {
            for candidate in cleaned {
                if let matched = matchRunningApp(name: candidate) {
                    appName = matched.name
                    bundleID = matched.bundleID
                    appIcon = matched.icon
                    break
                }
            }
        }

        if appName.isEmpty {
            appName = descParts.first?.isEmpty == false ? descParts[0] : "Notification"
            appIcon = NSImage(systemSymbolName: "bell.badge.fill", accessibilityDescription: nil)
        }

        // Remove the app name itself from the text lines so Title & Body are crisp
        let contentLines = cleaned.filter { $0.localizedCaseInsensitiveCompare(appName) != .orderedSame }
        let title = contentLines.first ?? appName
        let subtitle = contentLines.count >= 3 ? contentLines[1] : ""
        let body = contentLines.count >= 3 ? contentLines[2] : (contentLines.count == 2 ? contentLines[1] : "")

        let dedupe = "\(appName)|\(title)|\(body)"
        return CapturedNotification(
            id: UUID(),
            dedupeKey: dedupe,
            appName: appName,
            bundleID: bundleID,
            appIcon: appIcon,
            title: title,
            subtitle: subtitle,
            body: body.isEmpty ? subtitle : body,
            date: Date(),
            isTest: false
        )
    }

    private func collectStaticTexts(in element: AXUIElement, into out: inout [String], depth: Int, maxDepth: Int) {
        guard depth <= maxDepth else { return }
        let role = axString(element, kAXRoleAttribute) ?? ""
        if role == (kAXStaticTextRole as String) {
            if let val = axString(element, kAXValueAttribute), !val.isEmpty {
                out.append(val)
            } else if let title = axString(element, kAXTitleAttribute), !title.isEmpty {
                out.append(title)
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

    private func pressAXAction(on element: AXUIElement, matching keywords: [String]) -> Bool {
        // 1. Check custom AX actions directly on the banner (macOS puts Reply / Mark as Read here!)
        var actionsRef: CFArray?
        if AXUIElementCopyActionNames(element, &actionsRef) == .success,
           let actions = actionsRef as? [String] {
            for act in actions {
                let lower = act.lowercased()
                if keywords.contains(where: { lower.contains($0) }) {
                    if AXUIElementPerformAction(element, act as CFString) == .success {
                        return true
                    }
                }
            }
        }

        // 2. Otherwise search child AXButtons
        if let btn = findAXButton(in: element, matching: keywords, depth: 0, maxDepth: 7) {
            return AXUIElementPerformAction(btn, kAXPressAction as CFString) == .success
        }
        return false
    }

    private func findAXButton(in element: AXUIElement, matching keywords: [String], depth: Int, maxDepth: Int) -> AXUIElement? {
        guard depth <= maxDepth else { return nil }
        if axString(element, kAXRoleAttribute) == (kAXButtonRole as String) {
            let texts = [
                axString(element, kAXTitleAttribute),
                axString(element, kAXDescriptionAttribute),
                axString(element, kAXHelpAttribute)
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

    private func matchRunningApp(name: String) -> (name: String, bundleID: String, icon: NSImage?)? {
        let lower = name.lowercased()
        for app in NSWorkspace.shared.runningApplications {
            guard let loc = app.localizedName, !loc.isEmpty else { continue }
            if loc.lowercased() == lower || lower.contains(loc.lowercased()) {
                return (loc, app.bundleIdentifier ?? "", app.icon)
            }
        }
        return nil
    }

    private func findAppIcon(named name: String) -> NSImage? {
        matchRunningApp(name: name)?.icon
    }
}
