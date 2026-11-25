import Foundation
import Combine
import SwiftUI

enum NotchTab: String, CaseIterable, Identifiable, Codable {
    case media = "Media"
    case mixer = "Mixer"
    case output = "Output"
    case mic = "Mic"
    case vpn = "VPN"
    case timer = "Timer"
    case clipboard = "Clips"
    case notifications = "Alerts"

    var id: String { rawValue }

    var sfSymbol: String {
        switch self {
        case .media: return "music.note"
        case .mixer: return "slider.vertical.3"
        case .output: return "airplayaudio"
        case .mic: return "mic.fill"
        case .vpn: return "lock.shield.fill"
        case .timer: return "timer"
        case .clipboard: return "doc.on.clipboard"
        case .notifications: return "bell.badge.fill"
        }
    }

    var descriptionText: String {
        switch self {
        case .media: return "Now Playing & multi-source media deck"
        case .mixer: return "Master & per-app volume mixer"
        case .output: return "Audio output device switcher"
        case .mic: return "Microphone selector & live voice effects"
        case .vpn: return "VPN status, quick connect & manager"
        case .timer: return "Quick timer & Pomodoro countdown"
        case .clipboard: return "Persistent clipboard history (last 100)"
        case .notifications: return "Recent macOS notifications & quick reply"
        }
    }
}

enum NotchDisplayState: Equatable {
    case idle       // Very slim top strip with minimal status dots
    case peek       // Medium notch pill on immediate hover
    case expanded   // Full interactive panel on click or hotkey
}

struct NotchPreferences: Codable, Equatable {
    var enabledTabs: [String] = NotchTab.allCases.map { $0.rawValue }
    var notchOpacity: Double = 0.72          // 0.45 ... 0.95
    var idleHeight: Double = 14.0            // 10 ... 22
    var expandedHeight: Double = 246.0       // 220 ... 310
    var collapseDelay: Double = 0.28         // 0.10 ... 1.00
    var showNetworkSpeedOnHover: Bool = true
    var showVolumeHUD: Bool = true
    var showVPNDotInIdle: Bool = true
    var showNotificationPopups: Bool = true
    var notificationDuration: Double = 3.0
    var autoDismissMacBanner: Bool = true
    var readNotificationDatabase: Bool = true
    var clipboardLimit: Int = 100
    var autoSwitchSystemMic: Bool = true
    var launchAtLogin: Bool = false
    var updateChannel: String = "stable"
}

final class AppState: ObservableObject {
    @Published var displayState: NotchDisplayState = .idle
    @Published var isPinned: Bool = false
    @Published var selectedTab: NotchTab = .media
    @Published var enabledTabs: Set<NotchTab> = Set(NotchTab.allCases)
    @Published var prefs = NotchPreferences()
    @Published var showVolumeHUD: Bool = false

    var isExpanded: Bool { displayState == .expanded }

    var visibleTabs: [NotchTab] {
        let filtered = NotchTab.allCases.filter { enabledTabs.contains($0) }
        return filtered.isEmpty ? [.media] : filtered
    }

    private let settingsURL: URL = {
        let dir = "\(FileManager.default.homeDirectoryForCurrentUser.path)/.config/overlay"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return URL(fileURLWithPath: "\(dir)/settings.json")
    }()

    let systemAudio = SystemAudioManager()
    let pairPlayService = PairPlayService()
    let inputAudio = InputAudioManager()
    let perAppMixer = PerAppAudioMixer()
    let mediaService = MediaRemoteService()
    let notificationService = NotificationService()
    let vpnService = VPNService()
    let networkMonitor = NetworkMonitorService()
    let timerService = TimerService()
    let clipboardService = ClipboardService()
    let updateService = UpdateService()

    private var cancellables = Set<AnyCancellable>()
    private var hudDismissWorkItem: DispatchWorkItem?

    init() {
        pairPlayService.systemAudio = systemAudio
        systemAudio.pairPlay = pairPlayService
        systemAudio.refreshAll()
        loadSettings()
        applyPreferencesToServices()

        // Wire per-app CoreAudio mute fallback for apps like Telegram that don't expose Pause APIs
        mediaService.onToggleAppAudioMute = { [weak self] pid in
            self?.perAppMixer.toggleMuteByPID(pid) ?? false
        }

        // Show a brief volume HUD pill in the peek notch when system volume changes
        systemAudio.$lastVolumeChangeDate
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.triggerVolumeHUD()
            }
            .store(in: &cancellables)
    }

    func setTabEnabled(_ tab: NotchTab, enabled: Bool) {
        if enabled {
            enabledTabs.insert(tab)
        } else {
            guard enabledTabs.count > 1 else { return }
            enabledTabs.remove(tab)
            if selectedTab == tab, let first = visibleTabs.first {
                selectedTab = first
            }
        }
        prefs.enabledTabs = visibleTabs.map { $0.rawValue }
        saveSettings()
    }

    func updatePreferences(_ update: (inout NotchPreferences) -> Void) {
        update(&prefs)
        applyPreferencesToServices()
        saveSettings()
    }

    func resetAllSettings() {
        prefs = NotchPreferences()
        enabledTabs = Set(NotchTab.allCases)
        applyPreferencesToServices()
        saveSettings()
    }

    private func applyPreferencesToServices() {
        clipboardService.setMaxItems(prefs.clipboardLimit)
        inputAudio.autoSwitchSystemMic = prefs.autoSwitchSystemMic
        notificationService.enabled = prefs.showNotificationPopups
        notificationService.popupDuration = prefs.notificationDuration
        notificationService.autoDismissMacBanner = prefs.autoDismissMacBanner
        notificationService.readNotificationDatabase = prefs.readNotificationDatabase
        updateService.channel = UpdateChannel(rawValue: prefs.updateChannel) ?? .stable
        updateLaunchAgent(enabled: prefs.launchAtLogin)
    }

    private func updateLaunchAgent(enabled: Bool) {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let agentsDir = "\(home)/Library/LaunchAgents"
        let plistPath = "\(agentsDir)/com.amin.NotchPulse.plist"
        if !enabled {
            try? FileManager.default.removeItem(atPath: plistPath)
            return
        }
        try? FileManager.default.createDirectory(atPath: agentsDir, withIntermediateDirectories: true)
        let execPath = Bundle.main.executablePath ?? "/Applications/NotchPulse.app/Contents/MacOS/NotchPulse"
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>Label</key>
            <string>com.amin.NotchPulse</string>
            <key>ProgramArguments</key>
            <array>
                <string>\(execPath)</string>
            </array>
            <key>RunAtLoad</key>
            <true/>
        </dict>
        </plist>
        """
        try? plist.write(toFile: plistPath, atomically: true, encoding: .utf8)
    }

    private func loadSettings() {
        guard let data = try? Data(contentsOf: settingsURL) else { return }
        if let decoded = try? JSONDecoder().decode(NotchPreferences.self, from: data) {
            prefs = decoded
            let parsed = Set(decoded.enabledTabs.compactMap { NotchTab(rawValue: $0) })
            if !parsed.isEmpty {
                enabledTabs = parsed
                if !enabledTabs.contains(selectedTab), let first = visibleTabs.first {
                    selectedTab = first
                }
            }
        } else if let legacyTabs = try? JSONDecoder().decode([String].self, from: data) {
            let parsed = Set(legacyTabs.compactMap { NotchTab(rawValue: $0) })
            if !parsed.isEmpty {
                enabledTabs = parsed
                prefs.enabledTabs = visibleTabs.map { $0.rawValue }
            }
        }
    }

    private func saveSettings() {
        prefs.enabledTabs = visibleTabs.map { $0.rawValue }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(prefs) {
            try? data.write(to: settingsURL, options: .atomic)
        }
    }

    func setDisplayState(_ newState: NotchDisplayState) {
        if newState != .expanded && isPinned { return }
        if displayState != newState {
            withAnimation(.spring(response: 0.30, dampingFraction: 0.82)) {
                displayState = newState
            }
            if newState == .expanded {
                perAppMixer.refreshAudioProcesses()
                systemAudio.refreshAll()
                vpnService.refresh()
            }
        }
    }

    func setExpanded(_ expanded: Bool) {
        setDisplayState(expanded ? .expanded : .idle)
    }

    func togglePin() {
        isPinned.toggle()
        if isPinned {
            setDisplayState(.expanded)
        } else {
            withAnimation(.spring(response: 0.30, dampingFraction: 0.82)) {
                displayState = .idle
            }
        }
    }

    func toggleFromHotkey() {
        if displayState == .expanded {
            isPinned = false
            withAnimation(.spring(response: 0.30, dampingFraction: 0.82)) {
                displayState = .idle
            }
        } else {
            isPinned = true
            setDisplayState(.expanded)
        }
    }

    private func triggerVolumeHUD() {
        guard prefs.showVolumeHUD, displayState != .expanded else { return }
        withAnimation(.spring(response: 0.25, dampingFraction: 0.8)) {
            showVolumeHUD = true
        }
        hudDismissWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            withAnimation(.easeOut(duration: 0.25)) {
                self?.showVolumeHUD = false
            }
        }
        hudDismissWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8, execute: work)
    }
}
