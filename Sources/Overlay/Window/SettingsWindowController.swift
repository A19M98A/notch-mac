import AppKit
import ApplicationServices
import AVFoundation
import SwiftUI

final class SettingsWindowController: NSWindowController {
    private static var shared: SettingsWindowController?

    static func show(appState: AppState) {
        if let existing = shared, let window = existing.window {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let controller = SettingsWindowController(appState: appState)
        shared = controller
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    private init(appState: AppState) {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = ""
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.isMovableByWindowBackground = true
        window.center()
        window.isReleasedWhenClosed = false

        let root = NotchSettingsView()
            .environmentObject(appState)
            .environmentObject(appState.inputAudio)
            .environmentObject(appState.vpnService)
            .environmentObject(appState.perAppMixer)
            .environmentObject(appState.mediaService)
            .environmentObject(appState.updateService)
            .environmentObject(ShortcutService.shared)

        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(x: 0, y: 0, width: 560, height: 560)
        hosting.autoresizingMask = [.width, .height]
        window.contentView = hosting
        super.init(window: window)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}

private enum SettingsSection: String, CaseIterable, Identifiable {
    case modules = "Modules"
    case appearance = "Appearance"
    case shortcuts = "Shortcuts"
    case permissions = "Permissions"
    case about = "About"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .modules: return "square.grid.2x2"
        case .appearance: return "slider.horizontal.3"
        case .shortcuts: return "command"
        case .permissions: return "checkmark.shield"
        case .about: return "info.circle"
        }
    }
}

struct NotchSettingsView: View {
    @EnvironmentObject var appState: AppState
    @EnvironmentObject var inputAudio: InputAudioManager
    @EnvironmentObject var vpnService: VPNService
    @EnvironmentObject var perAppMixer: PerAppAudioMixer
    @EnvironmentObject var mediaService: MediaRemoteService
    @EnvironmentObject var updateService: UpdateService
    @EnvironmentObject var shortcutService: ShortcutService

    @State private var section: SettingsSection = .modules
    @State private var axTrusted: Bool = AXIsProcessTrusted()
    @State private var micGranted: Bool = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    @State private var copiedHint: String? = nil
    @State private var isSettingUpSigning: Bool = false
    @State private var isInstallingHelper: Bool = false
    @State private var recordingAction: AppShortcutAction? = nil
    @State private var keyMonitor: Any? = nil

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 22, style: .continuous)

        ZStack {
            shape
                .fill(.ultraThinMaterial)
                .overlay(shape.fill(Color.black.opacity(0.76)))
                .overlay(
                    shape.stroke(
                        LinearGradient(
                            colors: [Color.white.opacity(0.18), Color.white.opacity(0.06)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
                )

            VStack(spacing: 12) {
                // Header + Section Pills
                VStack(spacing: 10) {
                    HStack {
                        HStack(spacing: 8) {
                            Image(systemName: "waveform.circle.fill")
                                .font(.system(size: 16, weight: .bold))
                                .foregroundStyle(.cyan)
                            Text("NotchPulse Settings")
                                .font(.system(size: 15, weight: .bold))
                                .foregroundStyle(.white)
                        }
                        Spacer()
                        if let hint = copiedHint {
                            Text(hint)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(.green)
                        }
                    }

                    HStack(spacing: 6) {
                        ForEach(SettingsSection.allCases) { sec in
                            Button {
                                withAnimation(.easeInOut(duration: 0.15)) {
                                    section = sec
                                }
                                if sec == .permissions { refreshPermissions() }
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: sec.icon)
                                        .font(.system(size: 11, weight: .semibold))
                                    Text(sec.rawValue)
                                        .font(.system(size: 11, weight: .semibold))
                                    if sec == .about && updateService.hasUpdateAvailable {
                                        Circle()
                                            .fill(Color.green)
                                            .frame(width: 6, height: 6)
                                    }
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Capsule().fill(section == sec ? Color.white.opacity(0.18) : Color.clear))
                                .foregroundStyle(section == sec ? .white : .white.opacity(0.55))
                            }
                            .buttonStyle(.plain)
                        }
                        Spacer()
                    }
                }
                .padding(.horizontal, 18)

                Divider().overlay(Color.white.opacity(0.09)).padding(.horizontal, 18)

                Group {
                    switch section {
                    case .modules:
                        modulesView
                    case .appearance:
                        appearanceView
                    case .shortcuts:
                        shortcutsView
                    case .permissions:
                        permissionsView
                    case .about:
                        aboutView
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .padding(.top, 32)
            .padding(.bottom, 16)
        }
        .frame(width: 560, height: 560)
        .clipShape(shape)
        .ignoresSafeArea(.container, edges: .top)
        .preferredColorScheme(.dark)
        .onAppear { refreshPermissions() }
        .onDisappear { stopRecordingShortcut() }
    }

    // MARK: - 1. Modules Tab

    private var modulesView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Show or hide tabs in the notch overlay")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.55))
                Spacer()
                Button("Show All") {
                    for t in NotchTab.allCases { appState.setTabEnabled(t, enabled: true) }
                }
                .font(.system(size: 10, weight: .bold))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.white.opacity(0.12)))
                .foregroundStyle(.white)
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 18)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 7) {
                    ForEach(NotchTab.allCases) { tab in
                        let isOn = appState.enabledTabs.contains(tab)
                        let isLast = isOn && appState.enabledTabs.count <= 1

                        HStack(spacing: 12) {
                            ZStack {
                                Circle().fill(isOn ? Color.white.opacity(0.14) : Color.white.opacity(0.05))
                                Image(systemName: tab.sfSymbol)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(isOn ? .white : .white.opacity(0.4))
                            }
                            .frame(width: 28, height: 28)

                            VStack(alignment: .leading, spacing: 1) {
                                Text(tab.rawValue)
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(isOn ? .white : .white.opacity(0.5))
                                Text(tab.descriptionText)
                                    .font(.system(size: 10))
                                    .foregroundStyle(.white.opacity(0.45))
                                    .lineLimit(1)
                            }
                            Spacer()
                            Toggle("", isOn: Binding(
                                get: { isOn },
                                set: { appState.setTabEnabled(tab, enabled: $0) }
                            ))
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .labelsHidden()
                            .disabled(isLast)
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 10).fill(isOn ? Color.white.opacity(0.07) : Color.white.opacity(0.03)))
                    }
                }
                .padding(.horizontal, 18)
            }
        }
    }

    // MARK: - 2. Appearance & Behavior Tab

    private var appearanceView: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 12) {
                // Visual Sizing & Glass
                VStack(spacing: 10) {
                    sliderRow(
                        title: "Notch Transparency",
                        valueText: "\(Int(round(appState.prefs.notchOpacity * 100)))%",
                        value: Binding(
                            get: { appState.prefs.notchOpacity },
                            set: { v in appState.updatePreferences { $0.notchOpacity = v } }
                        ),
                        range: 0.45...0.95
                    )
                    sliderRow(
                        title: "Idle Strip Height",
                        valueText: "\(Int(appState.prefs.idleHeight)) px",
                        value: Binding(
                            get: { appState.prefs.idleHeight },
                            set: { v in appState.updatePreferences { $0.idleHeight = v } }
                        ),
                        range: 10...22
                    )
                    sliderRow(
                        title: "Expanded Panel Height",
                        valueText: "\(Int(appState.prefs.expandedHeight)) px",
                        value: Binding(
                            get: { appState.prefs.expandedHeight },
                            set: { v in appState.updatePreferences { $0.expandedHeight = v } }
                        ),
                        range: 220...310
                    )
                    sliderRow(
                        title: "Auto-Collapse Delay",
                        valueText: String(format: "%.2fs", appState.prefs.collapseDelay),
                        value: Binding(
                            get: { appState.prefs.collapseDelay },
                            set: { v in appState.updatePreferences { $0.collapseDelay = v } }
                        ),
                        range: 0.10...1.00
                    )
                    sliderRow(
                        title: "File Drag Open Delay",
                        valueText: String(format: "%.2fs", appState.prefs.fileDragOpenDelay),
                        value: Binding(
                            get: { appState.prefs.fileDragOpenDelay },
                            set: { v in appState.updatePreferences { $0.fileDragOpenDelay = v } }
                        ),
                        range: 0.15...1.50
                    )
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.06)))

                // Behavior Toggles
                VStack(spacing: 10) {
                    toggleRow("Show Notification Popups Under Notch", isOn: Binding(
                        get: { appState.prefs.showNotificationPopups },
                        set: { v in appState.updatePreferences { $0.showNotificationPopups = v } }
                    ))
                    if appState.prefs.showNotificationPopups {
                        sliderRow(
                            title: "Notification Auto-Hide",
                            valueText: "\(Int(round(appState.prefs.notificationDuration)))s",
                            value: Binding(
                                get: { appState.prefs.notificationDuration },
                                set: { v in appState.updatePreferences { $0.notificationDuration = v } }
                            ),
                            range: 2...8
                        )
                        toggleRow("Notch-Only Mode (Hide macOS System Popup)", isOn: Binding(
                            get: { appState.prefs.autoDismissMacBanner },
                            set: { v in appState.updatePreferences { $0.autoDismissMacBanner = v } }
                        ))
                        toggleRow("Zero-Flash DB Mode (works with DND / Banners Off)", isOn: Binding(
                            get: { appState.prefs.readNotificationDatabase },
                            set: { v in appState.updatePreferences { $0.readNotificationDatabase = v } }
                        ))
                        if appState.prefs.readNotificationDatabase {
                            Text("For zero macOS banners: grant Full Disk Access, then enable Do Not Disturb or set app Alert Style to None (keep Show in Notification Center ON).")
                                .font(.system(size: 10))
                                .foregroundColor(.white.opacity(0.45))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, -4)
                        }
                    }
                    toggleRow("Show Network Speed on Hover", isOn: Binding(
                        get: { appState.prefs.showNetworkSpeedOnHover },
                        set: { v in appState.updatePreferences { $0.showNetworkSpeedOnHover = v } }
                    ))
                    toggleRow("Show Volume HUD in Notch", isOn: Binding(
                        get: { appState.prefs.showVolumeHUD },
                        set: { v in appState.updatePreferences { $0.showVolumeHUD = v } }
                    ))
                    toggleRow("Show Green VPN Dot in Idle Strip", isOn: Binding(
                        get: { appState.prefs.showVPNDotInIdle },
                        set: { v in appState.updatePreferences { $0.showVPNDotInIdle = v } }
                    ))
                    toggleRow("Auto-Switch System Mic on FX ON", isOn: Binding(
                        get: { appState.prefs.autoSwitchSystemMic },
                        set: { v in appState.updatePreferences { $0.autoSwitchSystemMic = v } }
                    ))
                    toggleRow("Launch NotchPulse at Login", isOn: Binding(
                        get: { appState.prefs.launchAtLogin },
                        set: { v in appState.updatePreferences { $0.launchAtLogin = v } }
                    ))

                    HStack {
                        Text("Clipboard History Limit")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                        Spacer()
                        Picker("", selection: Binding(
                            get: { appState.prefs.clipboardLimit },
                            set: { v in appState.updatePreferences { $0.clipboardLimit = v } }
                        )) {
                            Text("30").tag(30)
                            Text("50").tag(50)
                            Text("100").tag(100)
                            Text("200").tag(200)
                        }
                        .pickerStyle(.segmented)
                        .frame(width: 190)
                    }
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.06)))

                HStack {
                    Button("Send Test Notification") {
                        appState.notificationService.sendTestNotification()
                        flashHint("Test popup shown under notch")
                    }
                    .font(.system(size: 11, weight: .bold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.cyan.opacity(0.22)))
                    .foregroundStyle(.cyan)
                    .buttonStyle(.plain)

                    Spacer()
                    Button("Reset All Settings to Default") {
                        appState.resetAllSettings()
                        flashHint("Settings reset")
                    }
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(Color.white.opacity(0.10)))
                    .foregroundStyle(.white.opacity(0.85))
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 18)
        }
    }

    // MARK: - 3. Global Shortcuts Tab

    private var shortcutsView: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Click any shortcut to record a global hotkey (requires ⌘, ⌥, ⌃, or ⇧)")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.55))
                Spacer()
                Button("Reset Defaults") {
                    stopRecordingShortcut()
                    shortcutService.resetToDefaults()
                    flashHint("Shortcuts reset to defaults")
                }
                .font(.system(size: 10, weight: .bold))
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Capsule().fill(Color.white.opacity(0.12)))
                .foregroundStyle(.white)
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 18)

            ScrollView(.vertical, showsIndicators: false) {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(["Main Controls", "Notch Tabs", "Windows"], id: \.self) { category in
                        let actions = AppShortcutAction.allCases.filter { $0.category == category }
                        VStack(alignment: .leading, spacing: 6) {
                            Text(category.uppercased())
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white.opacity(0.45))
                                .padding(.leading, 4)

                            ForEach(actions) { action in
                                shortcutRow(action)
                            }
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 6)
            }
        }
    }

    private func shortcutRow(_ action: AppShortcutAction) -> some View {
        let isRecordingThis = recordingAction == action
        let binding = shortcutService.binding(for: action)

        return HStack(spacing: 10) {
            Image(systemName: action.sfSymbol)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.cyan)
                .frame(width: 24, height: 24)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.cyan.opacity(0.14)))

            Text(action.title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)

            Spacer()

            HStack(spacing: 5) {
                Button {
                    if isRecordingThis {
                        stopRecordingShortcut()
                    } else {
                        startRecordingShortcut(for: action)
                    }
                } label: {
                    Text(isRecordingThis ? "Press keys…" : (binding?.displayString ?? "Record"))
                        .font(.system(size: 11, weight: .semibold, design: .monospaced))
                        .foregroundStyle(isRecordingThis ? .cyan : (binding != nil ? .white : .white.opacity(0.45)))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .frame(minWidth: 86)
                        .background(
                            RoundedRectangle(cornerRadius: 7)
                                .fill(isRecordingThis ? Color.cyan.opacity(0.18) : Color.white.opacity(0.08))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 7)
                                .stroke(isRecordingThis ? Color.cyan : Color.white.opacity(0.10), lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)

                if binding != nil && !isRecordingThis {
                    Button {
                        shortcutService.setBinding(nil, for: action)
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(.white.opacity(0.35))
                    }
                    .buttonStyle(.plain)
                    .help("Clear shortcut")
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.05)))
    }

    private func startRecordingShortcut(for action: AppShortcutAction) {
        stopRecordingShortcut()
        recordingAction = action
        shortcutService.isRecording = true

        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            // Esc (53) cancels recording
            if event.keyCode == 53 {
                stopRecordingShortcut()
                return nil
            }
            let mods = KeyShortcut.carbonModifiers(from: event.modifierFlags)
            // Backspace (51) or Forward Delete (117) without modifiers clears the shortcut
            if mods == 0 && (event.keyCode == 51 || event.keyCode == 117) {
                shortcutService.setBinding(nil, for: action)
                stopRecordingShortcut()
                return nil
            }
            // Require at least one modifier key (Cmd, Option, Control, or Shift)
            guard mods != 0 else {
                NSSound.beep()
                return nil
            }
            let captured = KeyShortcut(keyCode: UInt32(event.keyCode), carbonModifiers: mods)
            shortcutService.setBinding(captured, for: action)
            flashHint("Set \(action.title) to \(captured.displayString)")
            stopRecordingShortcut()
            return nil
        }
    }

    private func stopRecordingShortcut() {
        if let monitor = keyMonitor {
            NSEvent.removeMonitor(monitor)
            keyMonitor = nil
        }
        recordingAction = nil
        shortcutService.isRecording = false
    }

    // MARK: - 4. Permissions & System Status Tab

    private var permissionsView: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 8) {
                HStack {
                    Text("macOS Permissions & Optional Audio/VPN Tools")
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.55))
                    Spacer()
                    Button {
                        refreshPermissions()
                        flashHint("Status refreshed")
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "arrow.clockwise")
                            Text("Refresh")
                        }
                        .font(.system(size: 10, weight: .bold))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.white.opacity(0.12)))
                        .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                }

                persistentSigningPermissionRow

                permissionRow(
                    title: "Notification DB (Zero-Flash Mode)",
                    detail: appState.notificationService.canReadNotificationDB ? "Reading macOS NotificationCenter DB directly" : "Grant Full Disk Access to read notifications with DND/Banners Off",
                    ok: appState.notificationService.canReadNotificationDB,
                    actionTitle: appState.notificationService.canReadNotificationDB ? "Ready" : "Open Settings"
                ) {
                    appState.notificationService.openFullDiskAccessSettings()
                }

                accessibilityPermissionRow

                permissionRow(
                    title: "Microphone",
                    detail: "Live VU meter & real-time Mic FX Studio",
                    ok: micGranted,
                    actionTitle: micGranted ? "Granted" : "Grant"
                ) {
                    AVCaptureDevice.requestAccess(for: .audio) { _ in
                        DispatchQueue.main.async { refreshPermissions() }
                    }
                }

                permissionRow(
                    title: "System Audio Capture (macOS 14.2+)",
                    detail: perAppMixer.supportsPerAppMixing ? "Per-app volume mixing via CoreAudio Process Taps" : "Requires macOS 14.2 or newer",
                    ok: perAppMixer.supportsPerAppMixing && perAppMixer.permissionError == nil,
                    actionTitle: "Settings"
                ) {
                    perAppMixer.openAudioPermissionSettings()
                }

                permissionRow(
                    title: "Virtual Mic (BlackHole 2ch)",
                    detail: inputAudio.virtualOutputDevices.isEmpty ? "Install: brew install blackhole-2ch" : "Detected: \(inputAudio.virtualOutputDevices.map(\.name).joined(separator: ", "))",
                    ok: !inputAudio.virtualOutputDevices.isEmpty,
                    actionTitle: inputAudio.virtualOutputDevices.isEmpty ? "Copy Brew" : "Ready"
                ) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("brew install blackhole-2ch", forType: .string)
                    flashHint("Copied brew install blackhole-2ch")
                }

                permissionRow(
                    title: "VPN Core (sing-box)",
                    detail: vpnService.singBoxBinaryPath ?? "Install: brew install sing-box",
                    ok: vpnService.singBoxBinaryPath != nil,
                    actionTitle: vpnService.singBoxBinaryPath == nil ? "Copy Brew" : "Ready"
                ) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("brew install sing-box", forType: .string)
                    flashHint("Copied brew install sing-box")
                }

                vpnHelperPermissionRow
            }
            .padding(.horizontal, 18)
        }
    }

    // MARK: - 4. About Tab

    private var aboutView: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 8)

            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 82, height: 82)
                .shadow(color: .black.opacity(0.45), radius: 10, y: 4)

            VStack(spacing: 4) {
                Text("NotchPulse")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)
                Text("Version \(updateService.currentVersion) · Universal (Apple Silicon & Intel) · macOS 12+")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.55))
            }

            // Built-in GitHub Releases Auto-Updater Card
            updateCard
                .padding(.horizontal, 22)

            Text("A lightweight, native macOS Dynamic Notch overlay featuring multi-source media controls, per-app volume mixing, real-time microphone DSP effects, live network speed, standalone VPN & split-tunnel manager, Pomodoro timer, and persistent clipboard history.")
                .font(.system(size: 11.5))
                .foregroundStyle(.white.opacity(0.72))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 28)

            HStack(spacing: 10) {
                Button {
                    if let url = URL(string: "https://github.com/A19M98A/notch-mac") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "link")
                        Text("GitHub Repository")
                    }
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Color.white))
                }
                .buttonStyle(.plain)

                Button {
                    if let url = URL(string: "https://github.com/A19M98A/notch-mac/issues") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.bubble")
                        Text("Report Issue")
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Color.white.opacity(0.12)))
                }
                .buttonStyle(.plain)
            }

            VStack(spacing: 2) {
                Text("github.com/A19M98A/notch-mac")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.cyan.opacity(0.85))
                Text("Created by Amin · MIT License")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.45))
            }

            Spacer()
        }
    }

    @ViewBuilder
    private var updateCard: some View {
        VStack(spacing: 9) {
            // Update Channel Picker: Stable vs Debug
            HStack(spacing: 8) {
                Text("Update Channel")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.65))
                Spacer()
                HStack(spacing: 3) {
                    ForEach(UpdateChannel.allCases) { ch in
                        let selected = updateService.channel == ch
                        let accent: Color = ch == .debug ? .orange : .cyan
                        Button {
                            guard updateService.channel != ch else { return }
                            appState.updatePreferences { $0.updateChannel = ch.rawValue }
                            updateService.checkForUpdates()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: ch.icon)
                                    .font(.system(size: 9.5, weight: .bold))
                                Text(ch.title)
                                    .font(.system(size: 10.5, weight: .bold))
                            }
                            .padding(.horizontal, 9)
                            .padding(.vertical, 4)
                            .background(Capsule().fill(selected ? accent.opacity(0.22) : Color.clear))
                            .overlay(Capsule().stroke(selected ? accent.opacity(0.6) : Color.clear, lineWidth: 1))
                            .foregroundStyle(selected ? accent : .white.opacity(0.55))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(2)
                .background(Capsule().fill(Color.white.opacity(0.06)))
            }

            Divider().overlay(Color.white.opacity(0.07))

            switch updateService.state {
            case .idle:
                HStack {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(updateService.channel == .debug ? .orange : .cyan)
                        Text(updateService.channel == .debug ? "Debug & Pre-release Builds" : "Stable Releases")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    Spacer()
                    Button("Check for Updates") {
                        updateService.checkForUpdates()
                    }
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(updateService.channel == .debug ? Color.orange : Color.cyan))
                    .buttonStyle(.plain)
                }

            case .checking:
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Checking \(updateService.channel.title.lowercased()) releases...")
                        .font(.system(size: 11.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.75))
                    Spacer()
                }

            case .upToDate(let ver):
                HStack {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.system(size: 13))
                            .foregroundStyle(.green)
                        Text("v\(ver) is up to date (\(updateService.channel.title))")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    Spacer()
                    Button("Check Again") {
                        updateService.checkForUpdates()
                    }
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.8))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.white.opacity(0.12)))
                    .buttonStyle(.plain)
                }

            case .available(let release):
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 6) {
                        Image(systemName: release.isPrerelease ? "ladybug.fill" : "sparkles")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(release.isPrerelease ? .orange : .green)
                        Text("v\(release.version)")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.white)
                        Text(release.isPrerelease ? "DEBUG" : "STABLE")
                            .font(.system(size: 9, weight: .heavy))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Capsule().fill((release.isPrerelease ? Color.orange : Color.green).opacity(0.22)))
                            .foregroundStyle(release.isPrerelease ? .orange : .green)
                        Spacer()
                        Button("Notes") {
                            NSWorkspace.shared.open(release.htmlURL)
                        }
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.75))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(Color.white.opacity(0.10)))
                        .buttonStyle(.plain)

                        Button("Update & Relaunch") {
                            updateService.downloadAndInstall(release)
                        }
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 11)
                        .padding(.vertical, 5)
                        .background(Capsule().fill(release.isPrerelease ? Color.orange : Color.green))
                        .buttonStyle(.plain)
                    }
                }

            case .downloading(let progress):
                VStack(spacing: 6) {
                    HStack {
                        Text("Downloading update... \(Int(round(progress * 100)))%")
                            .font(.system(size: 11, weight: .semibold, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.85))
                        Spacer()
                        Button("Cancel") {
                            updateService.cancelDownload()
                        }
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                        .buttonStyle(.plain)
                    }
                    ProgressView(value: progress, total: 1.0)
                        .tint(.cyan)
                }

            case .installing:
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Installing update & relaunching NotchPulse...")
                        .font(.system(size: 11.5, weight: .semibold))
                        .foregroundStyle(.green)
                    Spacer()
                }

            case .error(let msg):
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.orange)
                    Text(msg)
                        .font(.system(size: 11))
                        .foregroundStyle(.white.opacity(0.8))
                        .lineLimit(2)
                    Spacer()
                    Button("Retry") {
                        updateService.checkForUpdates()
                    }
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(Color.white.opacity(0.12)))
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.06)))
    }

    // MARK: - UI Helpers

    private func sliderRow(title: String, valueText: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 150, alignment: .leading)
            Slider(value: value, in: range)
                .tint(.cyan)
            Text(valueText)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.75))
                .frame(width: 48, alignment: .trailing)
        }
    }

    private func toggleRow(_ title: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
            Spacer()
            Toggle("", isOn: isOn)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
        }
    }

    private func permissionRow(title: String, detail: String, ok: Bool, actionTitle: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 10) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 15))
                .foregroundStyle(ok ? .green : .orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
            }
            Spacer()
            Button(actionTitle, action: action)
                .font(.system(size: 10, weight: .bold))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(ok ? Color.green.opacity(0.18) : Color.white.opacity(0.14)))
                .foregroundStyle(ok ? .green : .white)
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.05)))
    }

    private var persistentSigningPermissionRow: some View {
        let ok = updateService.isBundleSignedPersistently
        let hasCert = updateService.hasPersistentSigning
        let detail = ok
            ? "Signed with 'NotchPulse Dev' — permissions survive all updates"
            : (hasCert ? "Cert ready — click Re-sign so this build keeps permissions" : "Sign with a local Keychain cert so updates never reset permissions")
        let btnTitle = isSettingUpSigning ? "Signing…" : (ok ? "Active" : (hasCert ? "Re-sign" : "Enable"))

        return permissionRow(
            title: "Keep Permissions Across Updates",
            detail: detail,
            ok: ok,
            actionTitle: btnTitle
        ) {
            guard !isSettingUpSigning else { return }
            isSettingUpSigning = true
            updateService.setupPersistentSigningAndResign { success, msg in
                isSettingUpSigning = false
                flashHint(success ? "Persistent signing active!" : msg)
                refreshPermissions()
            }
        }
    }

    private var accessibilityPermissionRow: some View {
        let iconColor: Color = axTrusted ? .green : .orange
        let detail = axTrusted
            ? "Control background media players, hotkeys & Notch-Only alerts"
            : "If already checked in Settings, click Reset & Fix to clear stale build entry"

        return HStack(spacing: 10) {
            Image(systemName: axTrusted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 15))
                .foregroundColor(iconColor)
            VStack(alignment: .leading, spacing: 2) {
                Text("Accessibility")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.white)
                Text(detail)
                    .font(.system(size: 10))
                    .foregroundColor(Color.white.opacity(0.5))
                    .lineLimit(1)
            }
            Spacer()
            if !axTrusted {
                Button("Reset & Fix") {
                    resetStaleAccessibility()
                }
                .font(.system(size: 10, weight: .bold))
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.orange.opacity(0.24)))
                .foregroundColor(.orange)
                .buttonStyle(.plain)
            }
            Button(axTrusted ? "Granted" : "Open Settings") {
                mediaService.requestAccessibilityPermission()
            }
            .font(.system(size: 10, weight: .bold))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(axTrusted ? Color.green.opacity(0.18) : Color.white.opacity(0.14)))
            .foregroundColor(axTrusted ? .green : .white)
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white.opacity(0.05)))
    }

    private var vpnHelperPermissionRow: some View {
        let installed = vpnService.isPasswordlessHelperInstalled
        let detail = installed
            ? "Installed at /usr/local/libexec/overlay-vpn-core.sh"
            : "Avoids password prompt on VPN connect/disconnect"
        let btnTitle = isInstallingHelper ? "Installing…" : (installed ? "Update" : "Install")

        return permissionRow(
            title: "Passwordless VPN Helper",
            detail: detail,
            ok: installed,
            actionTitle: btnTitle
        ) {
            guard !isInstallingHelper else { return }
            isInstallingHelper = true
            vpnService.installPasswordlessHelper { success, msg in
                isInstallingHelper = false
                flashHint(success ? "VPN helper installed!" : msg)
                refreshPermissions()
            }
        }
    }

    private func resetStaleAccessibility() {
        DispatchQueue.global(qos: .userInitiated).async {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
            proc.arguments = ["reset", "Accessibility", "com.amin.NotchPulse"]
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            try? proc.run()
            proc.waitUntilExit()

            DispatchQueue.main.async {
                mediaService.requestAccessibilityPermission()
                flashHint("Cleared stale entry — toggle ON in Settings")
                refreshPermissions()
            }
        }
    }

    private func refreshPermissions() {
        axTrusted = AXIsProcessTrusted()
        micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        appState.notificationService.checkDatabaseAccess()
        updateService.refreshSigningStatus()
        inputAudio.refreshAll()
        vpnService.refresh()
    }

    private func flashHint(_ msg: String) {
        copiedHint = msg
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            if copiedHint == msg { copiedHint = nil }
        }
    }
}
