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
    private var termHotKeyRef: EventHotKeyRef?
    private var hotKeyHandlerRef: EventHandlerRef?

    func applicationDidFinishLaunching(_ notification: Notification) {
        appState = AppState()
        notchController = NotchWindowController(appState: appState)
        notchController.showWindow(nil)

        setupMainMenu()
        setupMenuBar()
        registerGlobalHotKey()
    }

    func applicationWillTerminate(_ notification: Notification) {
        appState.perAppMixer.teardownAllTaps()
        appState.virtualMicService.stopMix()
        appState.inputAudio.stopFXEngine()
        if let ref = hotKeyRef {
            UnregisterEventHotKey(ref)
        }
        if let ref = termHotKeyRef {
            UnregisterEventHotKey(ref)
        }
    }

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "Quit NotchPulse", action: #selector(quitApp), keyEquivalent: "q"))
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        let redoItem = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        redoItem.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redoItem)
        editMenu.addItem(NSMenuItem.separator())
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        NSApplication.shared.mainMenu = mainMenu
    }

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "waveform.circle.fill", accessibilityDescription: "NotchPulse")
        }

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Toggle NotchPulse (⌥Space)", action: #selector(toggleNotch), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Toggle Terminal Panel (⌥T)", action: #selector(toggleTerminal), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Pin / Unpin Notch", action: #selector(togglePin), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "PairPlay Audio Studio…", action: #selector(openPairPlayStudio), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Virtual Mic Mixer…", action: #selector(openVirtualMicStudio), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "VPN Configurations…", action: #selector(openVPNConfigs), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit NotchPulse", action: #selector(quitApp), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    @objc private func toggleNotch() {
        appState.toggleFromHotkey()
    }

    @objc private func toggleTerminal() {
        TerminalWindowController.toggle(appState: appState)
    }

    @objc private func togglePin() {
        appState.togglePin()
    }

    @objc private func openPairPlayStudio() {
        PairPlayWindowController.show(appState: appState, initialSection: .multiOutput)
    }

    @objc private func openVirtualMicStudio() {
        PairPlayWindowController.show(appState: appState, initialSection: .virtualMicMix)
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
            { _, event, userData in
                guard let userData, let event else { return noErr }
                let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
                var hkID = EventHotKeyID()
                GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hkID
                )
                DispatchQueue.main.async {
                    if hkID.id == 2 {
                        TerminalWindowController.toggle(appState: delegate.appState)
                    } else {
                        delegate.appState.toggleFromHotkey()
                    }
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

        let termHotKeyID = EventHotKeyID(signature: 0x4F564C59, id: 2)
        // kVK_ANSI_T = 17, optionKey = 2048
        RegisterEventHotKey(UInt32(kVK_ANSI_T), UInt32(optionKey), termHotKeyID, GetApplicationEventTarget(), 0, &termHotKeyRef)
    }
}
