import AppKit
import ApplicationServices
import SwiftUI
import Carbon

@main
struct OverlayMain {
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var appState: AppState!
    private var notchController: NotchWindowController!
    private var statusItem: NSStatusItem!
    private var hotKeyRef: EventHotKeyRef?
    private var hotKeyHandlerRef: EventHandlerRef?

    func applicationDidFinishLaunching(_ notification: Notification) {
        appState = AppState()
        notchController = NotchWindowController(appState: appState)
        notchController.showWindow(nil)

        setupMenuBar()
        registerGlobalHotKey()
    }

    func applicationWillTerminate(_ notification: Notification) {
        appState.perAppMixer.teardownAllTaps()
        appState.inputAudio.stopFXEngine()
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
        }
    }

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "waveform.circle.fill", accessibilityDescription: "NotchPulse")
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Toggle NotchPulse (⌥Space)", action: #selector(toggleNotch), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Pin / Unpin Notch", action: #selector(togglePin), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "PairPlay Audio Studio…", action: #selector(openPairPlayStudio), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "VPN Configurations…", action: #selector(openVPNConfigs), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit NotchPulse", action: #selector(quitApp), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    @objc private func toggleNotch() {
        appState.toggleFromHotkey()
    }

    @objc private func togglePin() {
        appState.togglePin()
    }

    @objc private func openPairPlayStudio() {
        PairPlayWindowController.show(appState: appState)
    }

    @objc private func openVPNConfigs() {
        VPNConfigWindowController.show(vpnService: appState.vpnService)
    }

    @objc private func openSettings() {
        SettingsWindowController.show(appState: appState)
    }

    @objc private func openAccessibilityPermissions() {
        appState.mediaService.requestAccessibilityPermission()
    }

    @objc private func openAudioPermissions() {
        appState.perAppMixer.openAudioPermissionSettings()
    }

    @objc private func quitApp() {
        NSApplication.shared.terminate(nil)
    }

    // MARK: - Global Hotkey (Option + Space)

    private func registerGlobalHotKey() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, _, userData in
                guard let userData else { return noErr }
                let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
                DispatchQueue.main.async {
                    delegate.appState.toggleFromHotkey()
                }
                return noErr
            },
            1,
            &eventType,
            selfPtr,
            &hotKeyHandlerRef
        )

        let hotKeyID = EventHotKeyID(signature: 0x4F564C59, id: 1) // 'OVLY'
        // kVK_Space = 49, optionKey = 2048
        RegisterEventHotKey(UInt32(kVK_Space), UInt32(optionKey), hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
    }
}
