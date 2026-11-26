import Foundation
import AppKit
import Combine
import CoreText
import SwiftTerm

// MARK: - Color Palettes

struct TerminalTheme: Identifiable, Equatable {
    let id: String
    let name: String
    let background: NSColor
    let foreground: NSColor
    let cursor: NSColor
    let ansi16: [SwiftTerm.Color]

    static func hex(_ value: UInt32) -> NSColor {
        let r = CGFloat((value >> 16) & 0xFF) / 255.0
        let g = CGFloat((value >> 8) & 0xFF) / 255.0
        let b = CGFloat(value & 0xFF) / 255.0
        return NSColor(srgbRed: r, green: g, blue: b, alpha: 1.0)
    }

    static func stColor(_ value: UInt32) -> SwiftTerm.Color {
        let r = UInt16((value >> 16) & 0xFF) * 257
        let g = UInt16((value >> 8) & 0xFF) * 257
        let b = UInt16(value & 0xFF) * 257
        return SwiftTerm.Color(red: r, green: g, blue: b)
    }

    static let allThemes: [TerminalTheme] = [
        TerminalTheme(
            id: "obsidian",
            name: "Obsidian Glass",
            background: hex(0x0B0E14),
            foreground: hex(0xE6EDF3),
            cursor: hex(0x38BDF8),
            ansi16: [
                stColor(0x1E222A), stColor(0xFF5F6D), stColor(0x34D399), stColor(0xFBBF24),
                stColor(0x38BDF8), stColor(0xC084FC), stColor(0x22D3EE), stColor(0xCBD5E1),
                stColor(0x475569), stColor(0xFB7185), stColor(0x4ADE80), stColor(0xFDE047),
                stColor(0x60A5FA), stColor(0xD8B4FE), stColor(0x67E8F9), stColor(0xF8FAFC)
            ]
        ),
        TerminalTheme(
            id: "tokyonight",
            name: "Tokyo Night",
            background: hex(0x1A1B26),
            foreground: hex(0xC0CAF5),
            cursor: hex(0x7AA2F7),
            ansi16: [
                stColor(0x15161E), stColor(0xF7768E), stColor(0x9ECE6A), stColor(0xE0AF68),
                stColor(0x7AA2F7), stColor(0xBB9AF7), stColor(0x7DCFFF), stColor(0xA9B1D6),
                stColor(0x414868), stColor(0xF7768E), stColor(0x9ECE6A), stColor(0xE0AF68),
                stColor(0x7AA2F7), stColor(0xBB9AF7), stColor(0x7DCFFF), stColor(0xC0CAF5)
            ]
        ),
        TerminalTheme(
            id: "catppuccin",
            name: "Catppuccin Mocha",
            background: hex(0x1E1E2E),
            foreground: hex(0xCDD6F4),
            cursor: hex(0xF5E0DC),
            ansi16: [
                stColor(0x45475A), stColor(0xF38BA8), stColor(0xA6E3A1), stColor(0xF9E2AF),
                stColor(0x89B4FA), stColor(0xF5C2E7), stColor(0x94E2D5), stColor(0xBAC2DE),
                stColor(0x585B70), stColor(0xF38BA8), stColor(0xA6E3A1), stColor(0xF9E2AF),
                stColor(0x89B4FA), stColor(0xF5C2E7), stColor(0x94E2D5), stColor(0xA6ADC8)
            ]
        ),
        TerminalTheme(
            id: "dracula",
            name: "Dracula",
            background: hex(0x191A21),
            foreground: hex(0xF8F8F2),
            cursor: hex(0xFF79C6),
            ansi16: [
                stColor(0x21222C), stColor(0xFF5555), stColor(0x50FA7B), stColor(0xF1FA8C),
                stColor(0xBD93F9), stColor(0xFF79C6), stColor(0x8BE9FD), stColor(0xF8F8F2),
                stColor(0x6272A4), stColor(0xFF6E6E), stColor(0x69FF94), stColor(0xFFFFA5),
                stColor(0xD6ACFF), stColor(0xFF92DF), stColor(0xA4FFFF), stColor(0xFFFFFF)
            ]
        ),
        TerminalTheme(
            id: "nord",
            name: "Nord",
            background: hex(0x242933),
            foreground: hex(0xECEFF4),
            cursor: hex(0x88C0D0),
            ansi16: [
                stColor(0x3B4252), stColor(0xBF616A), stColor(0xA3BE8C), stColor(0xEBCB8B),
                stColor(0x81A1C1), stColor(0xB48EAD), stColor(0x88C0D0), stColor(0xE5E9F0),
                stColor(0x4C566A), stColor(0xBF616A), stColor(0xA3BE8C), stColor(0xEBCB8B),
                stColor(0x81A1C1), stColor(0xB48EAD), stColor(0x8FBCBB), stColor(0xECEFF4)
            ]
        ),
        TerminalTheme(
            id: "gruvbox",
            name: "Gruvbox Dark",
            background: hex(0x1D2021),
            foreground: hex(0xEBDBB2),
            cursor: hex(0xFE8019),
            ansi16: [
                stColor(0x282828), stColor(0xCC241D), stColor(0x98971A), stColor(0xD79921),
                stColor(0x458588), stColor(0xB16286), stColor(0x689D6A), stColor(0xA89984),
                stColor(0x928374), stColor(0xFB4934), stColor(0xB8BB26), stColor(0xFABD2F),
                stColor(0x83A598), stColor(0xD3869B), stColor(0x8EC07C), stColor(0xEBDBB2)
            ]
        )
    ]

    static func named(_ id: String) -> TerminalTheme {
        allThemes.first(where: { $0.id == id }) ?? allThemes[0]
    }
}

// MARK: - Preferences

struct TerminalPreferences: Codable, Equatable {
    var themeID: String = "obsidian"
    var fontName: String = "SF Mono"
    var fontSize: Double = 13.0
    var tuiAppFontName: String = "Same as Primary" // Specific font for nvim / vim / htop / lazygit
    var nerdFallbackFontName: String = "Hack Nerd Font Mono"
    var opacity: Double = 0.88
    var panelWidth: Double = 700
    var panelHeight: Double = 360
    var isDockedUnderNotch: Bool = true
    var alwaysOnTopFullScreen: Bool = true
    var singleScreenOnly: Bool = false
    var customX: Double? = nil
    var customY: Double? = nil

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        themeID = try c.decodeIfPresent(String.self, forKey: .themeID) ?? "obsidian"
        fontName = try c.decodeIfPresent(String.self, forKey: .fontName) ?? "SF Mono"
        fontSize = try c.decodeIfPresent(Double.self, forKey: .fontSize) ?? 13.0
        tuiAppFontName = try c.decodeIfPresent(String.self, forKey: .tuiAppFontName) ?? "Same as Primary"
        nerdFallbackFontName = try c.decodeIfPresent(String.self, forKey: .nerdFallbackFontName) ?? "Hack Nerd Font Mono"
        opacity = try c.decodeIfPresent(Double.self, forKey: .opacity) ?? 0.88
        panelWidth = try c.decodeIfPresent(Double.self, forKey: .panelWidth) ?? 700
        panelHeight = try c.decodeIfPresent(Double.self, forKey: .panelHeight) ?? 360
        isDockedUnderNotch = try c.decodeIfPresent(Bool.self, forKey: .isDockedUnderNotch) ?? true
        alwaysOnTopFullScreen = try c.decodeIfPresent(Bool.self, forKey: .alwaysOnTopFullScreen) ?? true
        singleScreenOnly = try c.decodeIfPresent(Bool.self, forKey: .singleScreenOnly) ?? false
        customX = try c.decodeIfPresent(Double.self, forKey: .customX)
        customY = try c.decodeIfPresent(Double.self, forKey: .customY)
    }
}

// MARK: - Persistent Terminal Tab Session

final class TerminalTabSession: NSObject, Identifiable, ObservableObject, LocalProcessTerminalViewDelegate {
    let id = UUID()
    @Published var title: String
    @Published var currentDirectory: String
    @Published var isRunning: Bool = true
    @Published var isTUIAppActive: Bool = false

    let terminalView: LocalProcessTerminalView
    private weak var service: TerminalService?

    @MainActor
    init(index: Int, service: TerminalService, startDirectory: String? = nil) {
        self.title = "zsh \(index)"
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        self.currentDirectory = startDirectory ?? home
        self.service = service
        self.terminalView = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 680, height: 320))
        super.init()

        terminalView.processDelegate = self
        terminalView.optionAsMetaKey = true
        terminalView.allowMouseReporting = true
        terminalView.customBlockGlyphs = true

        service.applyAppearance(to: self)
        launchShell()
    }

    func launchShell() {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let shellName = URL(fileURLWithPath: shell).lastPathComponent
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "NotchPulse"
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        let envStrings = env.map { "\($0.key)=\($0.value)" }

        isRunning = true
        terminalView.startProcess(
            executable: shell,
            args: ["-l"],
            environment: envStrings,
            execName: "-\(shellName)",
            currentDirectory: currentDirectory
        )
    }

    func terminateProcess() {
        isRunning = false
        terminalView.terminate()
    }

    // MARK: - LocalProcessTerminalViewDelegate

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        let clean = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        DispatchQueue.main.async {
            self.title = clean
            let lower = clean.lowercased()
            let tuiKeywords = ["nvim", "vim", "vi ", "htop", "btop", "lazygit", "tmux", "ranger", "yazi", "less", "man "]
            let nowTUI = tuiKeywords.contains(where: { lower.contains($0) })
            if self.isTUIAppActive != nowTUI {
                self.isTUIAppActive = nowTUI
                self.service?.applyFont(to: self)
            }
        }
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {
        guard let dir = directory, !dir.isEmpty else { return }
        let cleaned = dir.replacingOccurrences(of: "file://", with: "").removingPercentEncoding ?? dir
        DispatchQueue.main.async {
            self.currentDirectory = cleaned
        }
    }

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        DispatchQueue.main.async {
            self.isRunning = false
            self.title = "\(self.title) (exited)"
        }
    }
}

// MARK: - Terminal Service (Session Manager + Fonts + Themes)

final class TerminalService: ObservableObject {
    @Published var tabs: [TerminalTabSession] = []
    @Published var activeTabID: UUID? = nil
    @Published var isWindowVisible: Bool = false
    @Published var prefs = TerminalPreferences()
    @Published var availableMonospaceFonts: [String] = []

    private let prefsURL: URL = {
        let dir = "\(FileManager.default.homeDirectoryForCurrentUser.path)/.config/overlay"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return URL(fileURLWithPath: "\(dir)/terminal.json")
    }()

    private var tabCounter: Int = 0

    var activeTab: TerminalTabSession? {
        if let id = activeTabID, let found = tabs.first(where: { $0.id == id }) {
            return found
        }
        return tabs.first
    }

    var currentTheme: TerminalTheme {
        TerminalTheme.named(prefs.themeID)
    }

    init() {
        let loaded = Self.loadPreferencesStatic()
        self.prefs = loaded
        self.availableMonospaceFonts = Self.discoverMonospaceFonts()

        // Auto-select an installed Nerd Font for nvim / TUI apps & new installs so LazyVim icons render out of the box
        let firstNerdFont = availableMonospaceFonts.first(where: { $0.lowercased().contains("nerd") })
        if !FileManager.default.fileExists(atPath: prefsURL.path), let nerd = firstNerdFont {
            prefs.fontName = nerd
        } else if !availableMonospaceFonts.contains(prefs.fontName), let first = availableMonospaceFonts.first {
            prefs.fontName = first
        }
        if prefs.tuiAppFontName == "Same as Primary", let nerd = firstNerdFont {
            prefs.tuiAppFontName = nerd
        }
    }

    @MainActor
    func ensureAtLeastOneTab() {
        if tabs.isEmpty {
            _ = createNewTab()
        }
    }

    @MainActor
    @discardableResult
    func createNewTab(directory: String? = nil) -> TerminalTabSession {
        tabCounter += 1
        let startDir = directory ?? activeTab?.currentDirectory
        let session = TerminalTabSession(index: tabCounter, service: self, startDirectory: startDir)
        tabs.append(session)
        activeTabID = session.id
        return session
    }

    @MainActor
    func closeTab(_ id: UUID) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        let removed = tabs.remove(at: idx)
        removed.terminateProcess()
        if activeTabID == id {
            if !tabs.isEmpty {
                let nextIdx = min(idx, tabs.count - 1)
                activeTabID = tabs[nextIdx].id
            } else {
                activeTabID = nil
            }
        }
    }

    @MainActor
    func updatePreferences(_ mutate: (inout TerminalPreferences) -> Void) {
        mutate(&prefs)
        savePreferences()
        for tab in tabs {
            applyAppearance(to: tab)
        }
    }

    @MainActor
    func applyAppearance(to tab: TerminalTabSession) {
        let theme = currentTheme
        let tv = tab.terminalView
        tv.installColors(theme.ansi16)
        tv.nativeForegroundColor = theme.foreground
        tv.nativeBackgroundColor = theme.background.withAlphaComponent(CGFloat(prefs.opacity))
        tv.caretColor = theme.cursor
        applyFont(to: tab)
    }

    @MainActor
    func applyFont(to tab: TerminalTabSession) {
        let chosenName: String
        if tab.isTUIAppActive && prefs.tuiAppFontName != "Same as Primary" {
            chosenName = prefs.tuiAppFontName
        } else {
            chosenName = prefs.fontName
        }
        let size = CGFloat(prefs.fontSize)
        let baseFont = resolveFont(named: chosenName, size: size)
        let fallbackName = prefs.nerdFallbackFontName
        if !fallbackName.isEmpty && fallbackName != chosenName {
            let fallbackDesc = NSFontDescriptor(fontAttributes: [.family: fallbackName])
            let cascaded = baseFont.fontDescriptor.addingAttributes([.cascadeList: [fallbackDesc]])
            if let finalFont = NSFont(descriptor: cascaded, size: size) {
                tab.terminalView.font = finalFont
                return
            }
        }
        tab.terminalView.font = baseFont
    }

    private func resolveFont(named name: String, size: CGFloat) -> NSFont {
        if name == "SF Mono" || name == ".SF NS Mono" {
            return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        }
        if let f = NSFont(name: name, size: size) {
            return f
        }
        // Try matching by family name via NSFontManager
        let members = NSFontManager.shared.availableMembers(ofFontFamily: name) ?? []
        if let first = members.first, let psName = first[0] as? String, let f = NSFont(name: psName, size: size) {
            return f
        }
        return NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
    }

    private static func discoverMonospaceFonts() -> [String] {
        var families = Set<String>()
        families.insert("SF Mono")
        let fm = NSFontManager.shared
        for family in fm.availableFontFamilies {
            let lower = family.lowercased()
            let looksMonospace = lower.contains("mono") || lower.contains("nerd") ||
                lower.contains("menlo") || lower.contains("courier") ||
                lower.contains("consolas") || lower.contains("fira") ||
                lower.contains("hack") || lower.contains("meslo") ||
                lower.contains("jetbrains") || lower.contains("cascadia") ||
                lower.contains("iosevka") || lower.contains("inconsolata") ||
                lower.contains("source code")
            if looksMonospace {
                families.insert(family)
            }
        }
        return families.sorted { a, b in
            let aNerd = a.lowercased().contains("nerd")
            let bNerd = b.lowercased().contains("nerd")
            if aNerd != bNerd { return aNerd }
            if a == "SF Mono" { return true }
            if b == "SF Mono" { return false }
            return a.localizedCaseInsensitiveCompare(b) == .orderedAscending
        }
    }

    private static func loadPreferencesStatic() -> TerminalPreferences {
        let url = URL(fileURLWithPath: "\(FileManager.default.homeDirectoryForCurrentUser.path)/.config/overlay/terminal.json")
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode(TerminalPreferences.self, from: data) else {
            return TerminalPreferences()
        }
        return decoded
    }

    private func savePreferences() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(prefs) {
            try? data.write(to: prefsURL, options: .atomic)
        }
    }
}
