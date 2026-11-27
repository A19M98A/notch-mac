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
        ShortcutService.shared.stop()
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

    // MARK: - Global Hotkeys (Configurable via ShortcutService)

    private func registerGlobalHotKey() {
        ShortcutService.shared.start { [weak self] action in
            guard let self else { return }
            self.handleShortcutAction(action)
        }
    }

    private func handleShortcutAction(_ action: AppShortcutAction) {
        switch action {
        case .toggleNotch:
            appState.toggleFromHotkey()
        case .toggleTerminal:
            TerminalWindowController.toggle(appState: appState)
        case .togglePin:
            appState.togglePin()
        case .tabMedia, .tabMixer, .tabOutput, .tabMic, .tabVPN, .tabTimer, .tabClipboard, .tabNotifications:
            if let tab = action.notchTab {
                if appState.displayState == .expanded && appState.selectedTab == tab {
                    appState.toggleFromHotkey()
                } else {
                    appState.selectedTab = tab
                    appState.isPinned = true
                    appState.setDisplayState(.expanded)
                }
            }
        case .openPairPlay:
            PairPlayWindowController.show(appState: appState, initialSection: .multiOutput)
        case .openVPNConfigs:
            VPNConfigWindowController.show(vpnService: appState.vpnService)
        case .openSettings:
            SettingsWindowController.show(appState: appState)
        }
    }
}
