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
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 550),
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

        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(x: 0, y: 0, width: 520, height: 550)
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
    case permissions = "Permissions"
    case about = "About"

    var id: String { rawValue }

    var icon: String {
        switch self {
        case .modules: return "square.grid.2x2"
        case .appearance: return "slider.horizontal.3"
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

    @State private var section: SettingsSection = .modules
    @State private var axTrusted: Bool = AXIsProcessTrusted()
    @State private var micGranted: Bool = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
    @State private var copiedHint: String? = nil

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
                                }
                                .padding(.horizontal, 11)
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
        .frame(width: 520, height: 550)
        .clipShape(shape)
        .ignoresSafeArea(.container, edges: .top)
        .preferredColorScheme(.dark)
        .onAppear { refreshPermissions() }
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
                }
                .padding(14)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.white.opacity(0.06)))

                // Behavior Toggles
                VStack(spacing: 10) {
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

    // MARK: - 3. Permissions & System Status Tab

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

                permissionRow(
                    title: "Accessibility",
                    detail: "Control background media players & hotkeys",
                    ok: axTrusted,
                    actionTitle: axTrusted ? "Granted" : "Open Settings"
                ) {
                    mediaService.requestAccessibilityPermission()
                }

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

                permissionRow(
                    title: "Passwordless VPN Helper",
                    detail: vpnService.isPasswordlessHelperInstalled ? "Installed at /usr/local/libexec/overlay-vpn-core.sh" : "Avoids sudo prompt on VPN connect/disconnect",
                    ok: vpnService.isPasswordlessHelperInstalled,
                    actionTitle: vpnService.isPasswordlessHelperInstalled ? "Installed" : "Copy Cmd"
                ) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString("scripts/install_vpn_helper.sh", forType: .string)
                    flashHint("Copied helper command")
                }
            }
            .padding(.horizontal, 18)
        }
    }

    // MARK: - 4. About Tab

    private var aboutView: some View {
        VStack(spacing: 16) {
            Spacer(minLength: 8)

            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.cyan.opacity(0.35), Color.purple.opacity(0.35)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 72, height: 72)
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(Color.white.opacity(0.22), lineWidth: 1)
                    )
                Image(systemName: "waveform")
                    .font(.system(size: 32, weight: .bold))
                    .foregroundStyle(.white)
            }

            VStack(spacing: 4) {
                Text("NotchPulse")
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(.white)
                Text("Version 1.0.0 · Universal (Apple Silicon & Intel) · macOS 12+")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.55))
            }

            Text("A lightweight, native macOS Dynamic Notch overlay featuring multi-source media controls, per-app volume mixing, real-time microphone DSP effects, live network speed, standalone VPN & split-tunnel manager, Pomodoro timer, and persistent clipboard history.")
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.75))
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

    private func refreshPermissions() {
        axTrusted = AXIsProcessTrusted()
        micGranted = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
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
