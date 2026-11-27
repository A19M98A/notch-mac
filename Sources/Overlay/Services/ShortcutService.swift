import AppKit
import Carbon
import Combine

// MARK: - Shortcut Action

enum AppShortcutAction: String, CaseIterable, Identifiable, Codable {
    case toggleNotch
    case toggleTerminal
    case togglePin
    case tabMedia
    case tabMixer
    case tabOutput
    case tabMic
    case tabVPN
    case tabTimer
    case tabClipboard
    case tabNotifications
    case openPairPlay
    case openVPNConfigs
    case openSettings

    var id: String { rawValue }

    var hotKeyID: UInt32 {
        UInt32((Self.allCases.firstIndex(of: self) ?? 0) + 1)
    }

    var title: String {
        switch self {
        case .toggleNotch: return "Toggle Notch Panel"
        case .toggleTerminal: return "Toggle Terminal Panel"
        case .togglePin: return "Pin / Unpin Notch"
        case .tabMedia: return "Media Tab"
        case .tabMixer: return "Mixer Tab"
        case .tabOutput: return "Output Tab"
        case .tabMic: return "Mic Tab"
        case .tabVPN: return "VPN Tab"
        case .tabTimer: return "Timer Tab"
        case .tabClipboard: return "Clips & Files Tab"
        case .tabNotifications: return "Alerts Tab"
        case .openPairPlay: return "PairPlay Audio Studio"
        case .openVPNConfigs: return "VPN Configurations"
        case .openSettings: return "NotchPulse Settings"
        }
    }

    var category: String {
        switch self {
        case .toggleNotch, .toggleTerminal, .togglePin:
            return "Main Controls"
        case .tabMedia, .tabMixer, .tabOutput, .tabMic, .tabVPN, .tabTimer, .tabClipboard, .tabNotifications:
            return "Notch Tabs"
        case .openPairPlay, .openVPNConfigs, .openSettings:
            return "Windows"
        }
    }

    var sfSymbol: String {
        switch self {
        case .toggleNotch: return "menubar.rectangle"
        case .toggleTerminal: return "terminal.fill"
        case .togglePin: return "pin.fill"
        case .tabMedia: return NotchTab.media.sfSymbol
        case .tabMixer: return NotchTab.mixer.sfSymbol
        case .tabOutput: return NotchTab.output.sfSymbol
        case .tabMic: return NotchTab.mic.sfSymbol
        case .tabVPN: return NotchTab.vpn.sfSymbol
        case .tabTimer: return NotchTab.timer.sfSymbol
        case .tabClipboard: return NotchTab.clipboard.sfSymbol
        case .tabNotifications: return NotchTab.notifications.sfSymbol
        case .openPairPlay: return "waveform.badge.plus"
        case .openVPNConfigs: return "network.badge.shield.half.filled"
        case .openSettings: return "gearshape.fill"
        }
    }

    var notchTab: NotchTab? {
        switch self {
        case .tabMedia: return .media
        case .tabMixer: return .mixer
        case .tabOutput: return .output
        case .tabMic: return .mic
        case .tabVPN: return .vpn
        case .tabTimer: return .timer
        case .tabClipboard: return .clipboard
        case .tabNotifications: return .notifications
        default: return nil
        }
    }

    var defaultBinding: KeyShortcut? {
        switch self {
        case .toggleNotch:
            return KeyShortcut(keyCode: UInt32(kVK_Space), carbonModifiers: UInt32(optionKey))
        case .toggleTerminal:
            return KeyShortcut(keyCode: UInt32(kVK_ANSI_T), carbonModifiers: UInt32(optionKey))
        default:
            return nil
        }
    }
}

// MARK: - KeyShortcut Model

struct KeyShortcut: Codable, Equatable {
    var keyCode: UInt32
    var carbonModifiers: UInt32

    var displayString: String {
        var parts = ""
        if carbonModifiers & UInt32(controlKey) != 0 { parts += "⌃" }
        if carbonModifiers & UInt32(optionKey) != 0 { parts += "⌥" }
        if carbonModifiers & UInt32(shiftKey) != 0 { parts += "⇧" }
        if carbonModifiers & UInt32(cmdKey) != 0 { parts += "⌘" }
        parts += Self.keyName(for: keyCode)
        return parts
    }

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var mods: UInt32 = 0
        if flags.contains(.command) { mods |= UInt32(cmdKey) }
        if flags.contains(.option) { mods |= UInt32(optionKey) }
        if flags.contains(.control) { mods |= UInt32(controlKey) }
        if flags.contains(.shift) { mods |= UInt32(shiftKey) }
        return mods
    }

    static func keyName(for keyCode: UInt32) -> String {
        switch Int(keyCode) {
        case kVK_ANSI_A: return "A"
        case kVK_ANSI_B: return "B"
        case kVK_ANSI_C: return "C"
        case kVK_ANSI_D: return "D"
        case kVK_ANSI_E: return "E"
        case kVK_ANSI_F: return "F"
        case kVK_ANSI_G: return "G"
        case kVK_ANSI_H: return "H"
        case kVK_ANSI_I: return "I"
        case kVK_ANSI_J: return "J"
        case kVK_ANSI_K: return "K"
        case kVK_ANSI_L: return "L"
        case kVK_ANSI_M: return "M"
        case kVK_ANSI_N: return "N"
        case kVK_ANSI_O: return "O"
        case kVK_ANSI_P: return "P"
        case kVK_ANSI_Q: return "Q"
        case kVK_ANSI_R: return "R"
        case kVK_ANSI_S: return "S"
        case kVK_ANSI_T: return "T"
        case kVK_ANSI_U: return "U"
        case kVK_ANSI_V: return "V"
        case kVK_ANSI_W: return "W"
        case kVK_ANSI_X: return "X"
        case kVK_ANSI_Y: return "Y"
        case kVK_ANSI_Z: return "Z"
        case kVK_ANSI_0: return "0"
        case kVK_ANSI_1: return "1"
        case kVK_ANSI_2: return "2"
        case kVK_ANSI_3: return "3"
        case kVK_ANSI_4: return "4"
        case kVK_ANSI_5: return "5"
        case kVK_ANSI_6: return "6"
        case kVK_ANSI_7: return "7"
        case kVK_ANSI_8: return "8"
        case kVK_ANSI_9: return "9"
        case kVK_Space: return "Space"
        case kVK_Return: return "↩"
        case kVK_Tab: return "⇥"
        case kVK_Delete: return "⌫"
        case kVK_ForwardDelete: return "⌦"
        case kVK_Escape: return "⎋"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_ANSI_Minus: return "-"
        case kVK_ANSI_Equal: return "="
        case kVK_ANSI_LeftBracket: return "["
        case kVK_ANSI_RightBracket: return "]"
        case kVK_ANSI_Backslash: return "\\"
        case kVK_ANSI_Semicolon: return ";"
        case kVK_ANSI_Quote: return "'"
        case kVK_ANSI_Comma: return ","
        case kVK_ANSI_Period: return "."
        case kVK_ANSI_Slash: return "/"
        case kVK_ANSI_Grave: return "`"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        default: return "Key(\(keyCode))"
        }
    }
}

// MARK: - Global Shortcut Service

final class ShortcutService: ObservableObject {
    static let shared = ShortcutService()

    @Published var bindings: [String: KeyShortcut] = [:]
    @Published var isRecording: Bool = false {
        didSet {
            if isRecording {
                unregisterAllHotKeys()
            } else {
                registerAllHotKeys()
            }
        }
    }

    var onTrigger: ((AppShortcutAction) -> Void)?

    private var hotKeyRefs: [UInt32: EventHotKeyRef] = [:]
    private var eventHandlerRef: EventHandlerRef?

    private let storageURL: URL = {
        let dir = "\(FileManager.default.homeDirectoryForCurrentUser.path)/.config/overlay"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return URL(fileURLWithPath: "\(dir)/shortcuts.json")
    }()

    private init() {
        loadBindings()
    }

    func start(onTrigger: @escaping (AppShortcutAction) -> Void) {
        self.onTrigger = onTrigger
        installEventHandlerIfNeeded()
        registerAllHotKeys()
    }

    func stop() {
        unregisterAllHotKeys()
    }

    func binding(for action: AppShortcutAction) -> KeyShortcut? {
        bindings[action.rawValue]
    }

    func setBinding(_ shortcut: KeyShortcut?, for action: AppShortcutAction) {
        if let shortcut {
            // Remove duplicate binding from any other action so shortcuts stay unambiguous
            for (key, existing) in bindings where existing == shortcut && key != action.rawValue {
                bindings.removeValue(forKey: key)
            }
            bindings[action.rawValue] = shortcut
        } else {
            bindings.removeValue(forKey: action.rawValue)
        }
        saveBindings()
        if !isRecording {
            registerAllHotKeys()
        }
    }

    func resetToDefaults() {
        var defaults: [String: KeyShortcut] = [:]
        for action in AppShortcutAction.allCases {
            if let def = action.defaultBinding {
                defaults[action.rawValue] = def
            }
        }
        bindings = defaults
        saveBindings()
        if !isRecording {
            registerAllHotKeys()
        }
    }

    // MARK: - Carbon Registration

    private func installEventHandlerIfNeeded() {
        guard eventHandlerRef == nil else { return }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let userData, let event else { return noErr }
                let service = Unmanaged<ShortcutService>.fromOpaque(userData).takeUnretainedValue()
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
                    if let action = AppShortcutAction.allCases.first(where: { $0.hotKeyID == hkID.id }) {
                        service.onTrigger?(action)
                    }
                }
                return noErr
            },
            1,
            &eventType,
            selfPtr,
            &eventHandlerRef
        )
    }

    private func registerAllHotKeys() {
        unregisterAllHotKeys()
        for action in AppShortcutAction.allCases {
            guard let shortcut = bindings[action.rawValue] else { continue }
            var ref: EventHotKeyRef?
            let hkID = EventHotKeyID(signature: 0x4F564C59, id: action.hotKeyID)
            let status = RegisterEventHotKey(
                shortcut.keyCode,
                shortcut.carbonModifiers,
                hkID,
                GetApplicationEventTarget(),
                0,
                &ref
            )
            if status == noErr, let ref {
                hotKeyRefs[action.hotKeyID] = ref
            }
        }
    }

    private func unregisterAllHotKeys() {
        for (_, ref) in hotKeyRefs {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs.removeAll()
    }

    // MARK: - Persistence

    private func loadBindings() {
        if FileManager.default.fileExists(atPath: storageURL.path),
           let data = try? Data(contentsOf: storageURL),
           let decoded = try? JSONDecoder().decode([String: KeyShortcut].self, from: data) {
            self.bindings = decoded
        } else {
            var defaults: [String: KeyShortcut] = [:]
            for action in AppShortcutAction.allCases {
                if let def = action.defaultBinding {
                    defaults[action.rawValue] = def
                }
            }
            self.bindings = defaults
            saveBindings()
        }
    }

    private func saveBindings() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(bindings) {
            try? data.write(to: storageURL, options: .atomic)
        }
    }
}
