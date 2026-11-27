import AppKit
import SwiftUI
import Combine

final class TerminalFloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class TerminalWindowController: NSWindowController {
    private static var shared: TerminalWindowController?

    let terminalService: TerminalService
    private let appState: AppState
    private var cancellables = Set<AnyCancellable>()
    private var dragStartMouse: NSPoint? = nil
    private var dragStartOrigin: NSPoint? = nil
    private var resizeStartMouse: NSPoint? = nil
    private var resizeStartFrame: NSRect? = nil

    static func toggle(appState: AppState) {
        if let existing = shared, existing.window?.isVisible == true {
            existing.hidePanel()
        } else {
            show(appState: appState)
        }
    }

    static func show(appState: AppState) {
        let controller: TerminalWindowController
        if let existing = shared {
            controller = existing
        } else {
            controller = TerminalWindowController(appState: appState)
            shared = controller
        }

        appState.terminalService.ensureAtLeastOneTab()
        controller.applyWindowBehavior()
        controller.applyFrame(animated: false)

        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
        controller.window?.makeKeyAndOrderFront(nil)
        appState.terminalService.isWindowVisible = true

        // Focus the active SwiftTerm view so user can type immediately
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            if let tv = appState.terminalService.activeTab?.terminalView {
                controller.window?.makeFirstResponder(tv)
            }
        }
    }

    static func hide() {
        shared?.hidePanel()
    }

    private init(appState: AppState) {
        self.appState = appState
        self.terminalService = appState.terminalService

        let w = CGFloat(appState.terminalService.prefs.panelWidth)
        let h = CGFloat(appState.terminalService.prefs.panelHeight)
        let panel = TerminalFloatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: w, height: h),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = false // Handled cleanly by our header drag gesture

        super.init(window: panel)

        let root = TerminalPanelRootView(
            terminalService: appState.terminalService,
            onSnapToNotch: { [weak self] in self?.snapToNotch() },
            onHide: { [weak self] in self?.hidePanel() },
            onDragChanged: { [weak self] in self?.handleScreenDragChanged() },
            onDragEnded: { [weak self] in self?.handleScreenDragEnded() },
            onResizeChanged: { [weak self] in self?.handleScreenResizeChanged() },
            onResizeEnded: { [weak self] in self?.handleScreenResizeEnded() },
            onBehaviorChanged: { [weak self] in self?.applyWindowBehavior() },
            onSizePreset: { [weak self] w, h in self?.setSize(width: w, height: h) }
        )

        let hosting = NSHostingView(rootView: root)
        hosting.frame = NSRect(x: 0, y: 0, width: w, height: h)
        hosting.autoresizingMask = [.width, .height]
        panel.contentView = hosting

        applyWindowBehavior()
        applyFrame(animated: false)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func hidePanel() {
        window?.orderOut(nil)
        terminalService.isWindowVisible = false
    }

    func applyWindowBehavior() {
        guard let window else { return }
        let p = terminalService.prefs

        if p.alwaysOnTopFullScreen {
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 2)
        } else {
            window.level = .normal
        }

        var behavior: NSWindow.CollectionBehavior = [.stationary, .ignoresCycle]
        if p.alwaysOnTopFullScreen {
            behavior.insert(.fullScreenAuxiliary)
        }
        if p.singleScreenOnly {
            // Stay on the single desktop/space where opened
            behavior.insert(.moveToActiveSpace)
        } else {
            // Follow across all desktops & full-screen spaces
            behavior.insert(.canJoinAllSpaces)
        }
        window.collectionBehavior = behavior
    }

    func snapToNotch() {
        terminalService.updatePreferences {
            $0.isDockedUnderNotch = true
            $0.customX = nil
            $0.customY = nil
        }
        applyFrame(animated: true)
    }

    func setSize(width: Double, height: Double) {
        terminalService.updatePreferences {
            $0.panelWidth = max(460, min(1200, width))
            $0.panelHeight = max(220, min(720, height))
        }
        applyFrame(animated: true)
    }

    private func applyFrame(animated: Bool) {
        guard let window else { return }
        let screen = NSScreen.main ?? NSScreen.screens.first
        let sFrame = screen?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let w = CGFloat(terminalService.prefs.panelWidth)
        let h = CGFloat(terminalService.prefs.panelHeight)

        let targetOrigin: NSPoint
        if terminalService.prefs.isDockedUnderNotch {
            let notchOffset = CGFloat(appState.prefs.idleHeight) + 8
            targetOrigin = NSPoint(
                x: sFrame.midX - w / 2,
                y: sFrame.maxY - notchOffset - h
            )
        } else if let cx = terminalService.prefs.customX, let cy = terminalService.prefs.customY {
            targetOrigin = NSPoint(x: cx, y: cy)
        } else {
            targetOrigin = NSPoint(
                x: sFrame.midX - w / 2,
                y: sFrame.maxY - 46 - h
            )
        }

        let rect = NSRect(origin: targetOrigin, size: NSSize(width: w, height: h))
        window.setFrame(rect, display: true, animate: animated)
    }

    private func handleScreenDragChanged() {
        guard let window else { return }
        let mouse = NSEvent.mouseLocation
        if dragStartMouse == nil || dragStartOrigin == nil {
            dragStartMouse = mouse
            dragStartOrigin = window.frame.origin
            return
        }
        guard let startMouse = dragStartMouse, let startOrigin = dragStartOrigin else { return }
        let newOrigin = NSPoint(
            x: startOrigin.x + (mouse.x - startMouse.x),
            y: startOrigin.y + (mouse.y - startMouse.y)
        )
        window.setFrameOrigin(newOrigin)
        terminalService.prefs.isDockedUnderNotch = false
        terminalService.prefs.customX = Double(newOrigin.x)
        terminalService.prefs.customY = Double(newOrigin.y)
    }

    private func handleScreenDragEnded() {
        dragStartMouse = nil
        dragStartOrigin = nil
        terminalService.updatePreferences { _ in }
    }

    private func handleScreenResizeChanged() {
        guard let window else { return }
        let mouse = NSEvent.mouseLocation
        if resizeStartMouse == nil || resizeStartFrame == nil {
            resizeStartMouse = mouse
            resizeStartFrame = window.frame
            return
        }
        guard let startMouse = resizeStartMouse, let startFrame = resizeStartFrame else { return }
        let dw = mouse.x - startMouse.x
        let dh = startMouse.y - mouse.y // Screen Y increases upward; dragging down decreases mouse.y -> increases height

        let newW = max(460, min(1200, startFrame.width + dw))
        let newH = max(220, min(720, startFrame.height + dh))
        var frame = startFrame
        frame.size = NSSize(width: newW, height: newH)
        frame.origin.y = startFrame.maxY - newH
        if terminalService.prefs.isDockedUnderNotch {
            frame.origin.x = startFrame.midX - newW / 2
        }
        window.setFrame(frame, display: true, animate: false)
        terminalService.prefs.panelWidth = Double(newW)
        terminalService.prefs.panelHeight = Double(newH)
    }

    private func handleScreenResizeEnded() {
        resizeStartMouse = nil
        resizeStartFrame = nil
        terminalService.updatePreferences { _ in }
    }
}

// MARK: - SwiftTerm NSViewRepresentable Wrapper

private struct SwiftTermHostView: NSViewRepresentable {
    let session: TerminalTabSession

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        container.wantsLayer = true
        container.layer?.backgroundColor = NSColor.clear.cgColor
        attachTerminalView(to: container)
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if session.terminalView.superview !== nsView {
            attachTerminalView(to: nsView)
        }
        DispatchQueue.main.async {
            nsView.window?.makeFirstResponder(session.terminalView)
        }
    }

    private func attachTerminalView(to container: NSView) {
        container.subviews.forEach { $0.removeFromSuperview() }
        let tv = session.terminalView
        tv.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(tv)
        NSLayoutConstraint.activate([
            tv.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            tv.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            tv.topAnchor.constraint(equalTo: container.topAnchor),
            tv.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
    }
}

// MARK: - Minimal Frosted Terminal Panel UI

private struct TerminalPanelRootView: View {
    @ObservedObject var terminalService: TerminalService

    let onSnapToNotch: () -> Void
    let onHide: () -> Void
    let onDragChanged: () -> Void
    let onDragEnded: () -> Void
    let onResizeChanged: () -> Void
    let onResizeEnded: () -> Void
    let onBehaviorChanged: () -> Void
    let onSizePreset: (Double, Double) -> Void

    @State private var showOptions: Bool = false

    var body: some View {
        let theme = terminalService.currentTheme
        let bgColor = Color(nsColor: theme.background)
        let shape = RoundedRectangle(cornerRadius: 18, style: .continuous)

        ZStack(alignment: .bottomTrailing) {
            shape
                .fill(.ultraThinMaterial)
                .overlay(shape.fill(bgColor.opacity(terminalService.prefs.opacity)))
                .overlay(
                    shape.stroke(
                        LinearGradient(
                            colors: [Color.white.opacity(0.20), Color.white.opacity(0.06)],
                            startPoint: .top,
                            endPoint: .bottom
                        ),
                        lineWidth: 1
                    )
                )

            VStack(spacing: 0) {
                topTabAndControlBar
                Divider().overlay(Color.white.opacity(0.08))
                terminalContentArea
            }
            .clipShape(shape)

            // Subtle bottom-right drag-to-resize grip
            resizeCornerHandle
        }
        .preferredColorScheme(.dark)
    }

    private var topTabAndControlBar: some View {
        HStack(spacing: 6) {
            // Draggable Tabs Strip
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(terminalService.tabs) { tab in
                        terminalTabPill(tab)
                    }

                    Button {
                        _ = terminalService.createNewTab()
                    } label: {
                        Image(systemName: "plus")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(Color.white.opacity(0.7))
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(Color.white.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                    .help("New Terminal Tab")
                }
                .padding(.vertical, 2)
            }

            Spacer(minLength: 4)

            // Quick Placement & Window Mode Controls
            HStack(spacing: 4) {
                if !terminalService.prefs.isDockedUnderNotch {
                    Button {
                        onSnapToNotch()
                    } label: {
                        Image(systemName: "dock.arrow.up.rectangle")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundColor(.cyan)
                            .frame(width: 24, height: 22)
                            .background(Capsule().fill(Color.cyan.opacity(0.16)))
                    }
                    .buttonStyle(.plain)
                    .help("Dock Under Notch")
                }

                // Always on Top (incl. Full-Screen) toggle
                Button {
                    terminalService.updatePreferences { $0.alwaysOnTopFullScreen.toggle() }
                    onBehaviorChanged()
                } label: {
                    let on = terminalService.prefs.alwaysOnTopFullScreen
                    Image(systemName: on ? "pin.fill" : "pin")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(on ? .cyan : Color.white.opacity(0.5))
                        .frame(width: 24, height: 22)
                        .background(Capsule().fill(on ? Color.cyan.opacity(0.18) : Color.white.opacity(0.07)))
                }
                .buttonStyle(.plain)
                .help(terminalService.prefs.alwaysOnTopFullScreen ? "Always on Top (Even Full-Screen): ON" : "Always on Top: OFF")

                // All Desktops vs Single Screen Only toggle
                Button {
                    terminalService.updatePreferences { $0.singleScreenOnly.toggle() }
                    onBehaviorChanged()
                } label: {
                    let single = terminalService.prefs.singleScreenOnly
                    Image(systemName: single ? "display" : "rectangle.on.rectangle")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(single ? .orange : Color.white.opacity(0.65))
                        .frame(width: 24, height: 22)
                        .background(Capsule().fill(single ? Color.orange.opacity(0.18) : Color.white.opacity(0.07)))
                }
                .buttonStyle(.plain)
                .help(terminalService.prefs.singleScreenOnly ? "Single Screen / Space Only" : "Show on All Desktops & Screens")

                // Options Popover (Theme, Font, nvim App Font, Size, Opacity)
                Button {
                    showOptions.toggle()
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundColor(showOptions ? .cyan : Color.white.opacity(0.7))
                        .frame(width: 24, height: 22)
                        .background(Capsule().fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showOptions, arrowEdge: .bottom) {
                    TerminalOptionsPopover(
                        terminalService: terminalService,
                        onBehaviorChanged: onBehaviorChanged,
                        onSizePreset: onSizePreset,
                        onSnapToNotch: onSnapToNotch
                    )
                }

                // Hide Panel (keeps all terminal sessions alive!)
                Button {
                    onHide()
                } label: {
                    Image(systemName: "chevron.up")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(Color.white.opacity(0.7))
                        .frame(width: 24, height: 22)
                        .background(Capsule().fill(Color.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .help("Hide Terminal (sessions stay alive)")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.black.opacity(0.24))
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { _ in
                    onDragChanged()
                }
                .onEnded { _ in
                    onDragEnded()
                }
        )
    }

    private func terminalTabPill(_ tab: TerminalTabSession) -> some View {
        let active = terminalService.activeTabID == tab.id
        let bg: Color = active ? Color.white.opacity(0.14) : Color.white.opacity(0.04)
        let fg: Color = active ? .white : Color.white.opacity(0.6)
        let dotColor: Color = tab.isRunning ? (tab.isTUIAppActive ? .cyan : .green) : .red

        return HStack(spacing: 5) {
            Circle()
                .fill(dotColor)
                .frame(width: 5.5, height: 5.5)

            Button {
                terminalService.activeTabID = tab.id
            } label: {
                Text(tab.title)
                    .font(.system(size: 10.5, weight: active ? .bold : .medium, design: .monospaced))
                    .foregroundColor(fg)
                    .lineLimit(1)
                    .frame(maxWidth: 130, alignment: .leading)
            }
            .buttonStyle(.plain)

            Button {
                terminalService.closeTab(tab.id)
                if terminalService.tabs.isEmpty {
                    onHide()
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(Color.white.opacity(0.45))
                    .frame(width: 14, height: 14)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(bg))
    }

    @ViewBuilder
    private var terminalContentArea: some View {
        if let active = terminalService.activeTab {
            SwiftTermHostView(session: active)
                .id(active.id)
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
        } else {
            VStack(spacing: 8) {
                Text("No terminal session open")
                    .font(.system(size: 12))
                    .foregroundColor(Color.white.opacity(0.5))
                Button("New Terminal") {
                    _ = terminalService.createNewTab()
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .padding(.vertical, 5)
                .background(Capsule().fill(Color.cyan.opacity(0.24)))
                .foregroundColor(.cyan)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var resizeCornerHandle: some View {
        Image(systemName: "arrow.up.left.and.arrow.down.right")
            .font(.system(size: 9, weight: .bold))
            .foregroundColor(Color.white.opacity(0.35))
            .padding(7)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { _ in
                        onResizeChanged()
                    }
                    .onEnded { _ in
                        onResizeEnded()
                    }
            )
    }
}

// MARK: - Terminal Appearance, Font, & Placement Options Popover

private struct TerminalOptionsPopover: View {
    @ObservedObject var terminalService: TerminalService
    let onBehaviorChanged: () -> Void
    let onSizePreset: (Double, Double) -> Void
    let onSnapToNotch: () -> Void

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 11) {
                Text("Terminal Options")
                    .font(.system(size: 12.5, weight: .bold))
                    .foregroundColor(.white)

                // Color Palette Swatches
                VStack(alignment: .leading, spacing: 5) {
                    Text("Color Palette")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundColor(Color.white.opacity(0.6))
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 6)], spacing: 6) {
                        ForEach(TerminalTheme.allThemes) { theme in
                            themeButton(theme)
                        }
                    }
                }

                Divider().overlay(Color.white.opacity(0.08))

                // Cursor Style, Blink & Color
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 8) {
                        Text("Cursor")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundColor(Color.white.opacity(0.7))
                            .frame(width: 68, alignment: .leading)

                        HStack(spacing: 4) {
                            cursorShapeBtn("Block", shape: "block", glyph: "█")
                            cursorShapeBtn("Line", shape: "underline", glyph: "▁")
                            cursorShapeBtn("Bar", shape: "bar", glyph: "▏")
                        }

                        Spacer()

                        Toggle("Blink", isOn: Binding(
                            get: { terminalService.prefs.cursorBlink },
                            set: { v in terminalService.updatePreferences { $0.cursorBlink = v } }
                        ))
                        .toggleStyle(.checkbox)
                        .font(.system(size: 10.5, weight: .medium))
                    }

                    HStack(spacing: 8) {
                        Text("Cursor Color")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundColor(Color.white.opacity(0.6))
                            .frame(width: 68, alignment: .leading)

                        HStack(spacing: 6) {
                            cursorColorSwatch("theme", label: "Auto", color: Color(nsColor: terminalService.currentTheme.cursor))
                            cursorColorSwatch("#FFFFFF", label: "White", color: .white)
                            cursorColorSwatch("#38BDF8", label: "Cyan", color: Color(red: 0.22, green: 0.74, blue: 0.97))
                            cursorColorSwatch("#4ADE80", label: "Green", color: Color(red: 0.29, green: 0.87, blue: 0.50))
                            cursorColorSwatch("#FBBF24", label: "Amber", color: Color(red: 0.98, green: 0.75, blue: 0.14))
                            cursorColorSwatch("#FF79C6", label: "Pink", color: Color(red: 1.0, green: 0.47, blue: 0.78))
                        }
                        Spacer()
                    }
                }

                Divider().overlay(Color.white.opacity(0.08))

            // Primary Font & Size
            HStack(spacing: 8) {
                Text("Font")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color.white.opacity(0.7))
                    .frame(width: 68, alignment: .leading)

                Picker("", selection: Binding(
                    get: { terminalService.prefs.fontName },
                    set: { v in terminalService.updatePreferences { $0.fontName = v } }
                )) {
                    ForEach(terminalService.availableMonospaceFonts, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)

                Stepper("\(Int(terminalService.prefs.fontSize))pt", value: Binding(
                    get: { terminalService.prefs.fontSize },
                    set: { v in terminalService.updatePreferences { $0.fontSize = max(10, min(22, v)) } }
                ), in: 10...22, step: 1)
                .font(.system(size: 10.5, design: .monospaced))
            }

            // App-Specific Font (e.g. nvim / vim / htop)
            HStack(spacing: 8) {
                Text("nvim Font")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color.white.opacity(0.7))
                    .frame(width: 68, alignment: .leading)

                Picker("", selection: Binding(
                    get: { terminalService.prefs.tuiAppFontName },
                    set: { v in terminalService.updatePreferences { $0.tuiAppFontName = v } }
                )) {
                    Text("Same as Primary").tag("Same as Primary")
                    ForEach(terminalService.availableMonospaceFonts, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)
            }

            // Nerd Font Icon Fallback
            HStack(spacing: 8) {
                Text("Icon Font")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color.white.opacity(0.7))
                    .frame(width: 68, alignment: .leading)

                Picker("", selection: Binding(
                    get: { terminalService.prefs.nerdFallbackFontName },
                    set: { v in terminalService.updatePreferences { $0.nerdFallbackFontName = v } }
                )) {
                    ForEach(terminalService.availableMonospaceFonts, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)
            }

            // Glass Opacity
            HStack(spacing: 8) {
                Text("Opacity")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color.white.opacity(0.7))
                    .frame(width: 68, alignment: .leading)
                Slider(value: Binding(
                    get: { terminalService.prefs.opacity },
                    set: { v in terminalService.updatePreferences { $0.opacity = v } }
                ), in: 0.60...1.0)
                .tint(.cyan)
                Text("\(Int(round(terminalService.prefs.opacity * 100)))%")
                    .font(.system(size: 10, design: .monospaced))
                    .frame(width: 34, alignment: .trailing)
            }

            // Size Presets
            HStack(spacing: 6) {
                Text("Size")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(Color.white.opacity(0.7))
                    .frame(width: 68, alignment: .leading)
                presetSizeBtn("Compact", 540, 260)
                presetSizeBtn("Default", 700, 360)
                presetSizeBtn("Wide", 880, 420)
                presetSizeBtn("Tall", 760, 520)
            }

            Divider().overlay(Color.white.opacity(0.08))

                // Line Spacing
                HStack(spacing: 8) {
                    Text("Line Space")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Color.white.opacity(0.7))
                        .frame(width: 68, alignment: .leading)
                    Slider(value: Binding(
                        get: { terminalService.prefs.lineSpacing },
                        set: { v in terminalService.updatePreferences { $0.lineSpacing = v } }
                    ), in: 1.0...1.4, step: 0.05)
                    .tint(.cyan)
                    Text(String(format: "%.2fx", terminalService.prefs.lineSpacing))
                        .font(.system(size: 10, design: .monospaced))
                        .frame(width: 34, alignment: .trailing)
                }

                // Bell Style
                HStack(spacing: 8) {
                    Text("Bell")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(Color.white.opacity(0.7))
                        .frame(width: 68, alignment: .leading)
                    Picker("", selection: Binding(
                        get: { terminalService.prefs.bellStyle },
                        set: { v in terminalService.updatePreferences { $0.bellStyle = v } }
                    )) {
                        Text("Off").tag("none")
                        Text("Visual").tag("visual")
                        Text("Sound").tag("sound")
                        Text("Both").tag("soundAndVisual")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }

                // Window Placement & Full-Screen Behavior
                Toggle("Option (⌥) as Meta Key", isOn: Binding(
                    get: { terminalService.prefs.optionAsMeta },
                    set: { v in terminalService.updatePreferences { $0.optionAsMeta = v } }
                ))
                .font(.system(size: 11, weight: .medium))

                Toggle("Mouse Reporting (nvim / tmux)", isOn: Binding(
                    get: { terminalService.prefs.allowMouseReporting },
                    set: { v in terminalService.updatePreferences { $0.allowMouseReporting = v } }
                ))
                .font(.system(size: 11, weight: .medium))

                Toggle("Always on Top (Even Full-Screen)", isOn: Binding(
                    get: { terminalService.prefs.alwaysOnTopFullScreen },
                    set: { v in
                        terminalService.updatePreferences { $0.alwaysOnTopFullScreen = v }
                        onBehaviorChanged()
                    }
                ))
                .font(.system(size: 11, weight: .medium))

                Toggle("Single Screen / Space Only", isOn: Binding(
                    get: { terminalService.prefs.singleScreenOnly },
                    set: { v in
                        terminalService.updatePreferences { $0.singleScreenOnly = v }
                        onBehaviorChanged()
                    }
                ))
                .font(.system(size: 11, weight: .medium))

                if !terminalService.prefs.isDockedUnderNotch {
                    Button("Snap Back Under Notch") {
                        onSnapToNotch()
                    }
                    .font(.system(size: 11, weight: .bold))
                    .foregroundColor(.cyan)
                    .buttonStyle(.plain)
                }
            }
            .padding(14)
        }
        .frame(width: 330)
        .frame(maxHeight: 500)
        .preferredColorScheme(.dark)
    }

    private func cursorShapeBtn(_ title: String, shape: String, glyph: String) -> some View {
        let selected = terminalService.prefs.cursorShape == shape
        return Button {
            terminalService.updatePreferences { $0.cursorShape = shape }
        } label: {
            HStack(spacing: 3) {
                Text(glyph)
                    .font(.system(size: 9.5, design: .monospaced))
                Text(title)
                    .font(.system(size: 10, weight: selected ? .bold : .medium))
            }
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.white.opacity(selected ? 0.16 : 0.06)))
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(selected ? Color.cyan : Color.white.opacity(0.08), lineWidth: 1))
            .foregroundColor(.white)
        }
        .buttonStyle(.plain)
    }

    private func cursorColorSwatch(_ hex: String, label: String, color: Color) -> some View {
        let selected = terminalService.prefs.cursorColorHex == hex
        return Button {
            terminalService.updatePreferences { $0.cursorColorHex = hex }
        } label: {
            Circle()
                .fill(color)
                .frame(width: 15, height: 15)
                .overlay(
                    Circle()
                        .stroke(selected ? Color.white : Color.white.opacity(0.2), lineWidth: selected ? 2 : 1)
                )
                .overlay(
                    hex == "theme"
                        ? Text("A").font(.system(size: 8, weight: .bold)).foregroundColor(.black.opacity(0.75))
                        : nil
                )
        }
        .buttonStyle(.plain)
        .help(label)
    }

    private func themeButton(_ theme: TerminalTheme) -> some View {
        let selected = terminalService.prefs.themeID == theme.id
        let stroke: Color = selected ? .cyan : Color.white.opacity(0.10)
        return Button {
            terminalService.updatePreferences { $0.themeID = theme.id }
        } label: {
            HStack(spacing: 6) {
                Circle()
                    .fill(Color(nsColor: theme.background))
                    .overlay(Circle().stroke(Color(nsColor: theme.cursor), lineWidth: 1.5))
                    .frame(width: 12, height: 12)
                Text(theme.name)
                    .font(.system(size: 10, weight: selected ? .bold : .medium))
                    .foregroundColor(.white)
                    .lineLimit(1)
                Spacer()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.white.opacity(selected ? 0.14 : 0.05)))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(stroke, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    private func presetSizeBtn(_ title: String, _ w: Double, _ h: Double) -> some View {
        Button(title) {
            onSizePreset(w, h)
        }
        .font(.system(size: 10, weight: .semibold))
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(Capsule().fill(Color.white.opacity(0.10)))
        .foregroundColor(.white)
        .buttonStyle(.plain)
    }
}
