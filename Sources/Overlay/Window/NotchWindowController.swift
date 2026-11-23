import AppKit
import SwiftUI
import Combine

/// A borderless floating NSPanel that stays above the menu bar and passes mouse clicks through
/// everywhere outside the active notch/expanded pill area.
final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class NotchWindowController: NSWindowController {
    private let appState: AppState
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var collapseWorkItem: DispatchWorkItem?
    private var cancellables = Set<AnyCancellable>()

    static let windowWidth: CGFloat = 680
    static let windowHeight: CGFloat = 340

    // Stage 1: Very slim default idle strip (dots only)
    static let idleWidth: CGFloat = 136
    static let idleHeight: CGFloat = 14

    // Stage 2: Peek pill on immediate hover (shows live network speed/totals + mini widgets)
    static let peekWidth: CGFloat = 344
    static let peekHeight: CGFloat = 38

    // Stage 3: Full interactive panel on click
    static let expandedWidth: CGFloat = 648
    static let expandedHeight: CGFloat = 246

    init(appState: AppState) {
        self.appState = appState

        let panel = NotchPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.windowWidth, height: Self.windowHeight),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        panel.isFloatingPanel = true
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 3)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle
        ]

        let rootView = NotchRootView()
            .environmentObject(appState)
            .environmentObject(appState.systemAudio)
            .environmentObject(appState.inputAudio)
            .environmentObject(appState.perAppMixer)
            .environmentObject(appState.mediaService)
            .environmentObject(appState.notificationService)
            .environmentObject(appState.vpnService)
            .environmentObject(appState.networkMonitor)
            .environmentObject(appState.timerService)
            .environmentObject(appState.clipboardService)

        let hostingView = NSHostingView(rootView: rootView)
        hostingView.frame = NSRect(x: 0, y: 0, width: Self.windowWidth, height: Self.windowHeight)
        panel.contentView = hostingView

        super.init(window: panel)

        positionAtTopCenter()
        installMouseMonitors()
        observeScreenChanges()
        observeExpandState()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let m = globalMouseMonitor { NSEvent.removeMonitor(m) }
        if let m = localMouseMonitor { NSEvent.removeMonitor(m) }
    }

    func positionAtTopCenter() {
        guard let screen = NSScreen.main ?? NSScreen.screens.first, let window else { return }
        let screenFrame = screen.frame
        let x = screenFrame.midX - (Self.windowWidth / 2)
        let y = screenFrame.maxY - Self.windowHeight
        window.setFrame(NSRect(x: x, y: y, width: Self.windowWidth, height: Self.windowHeight), display: true)
    }

    private func observeScreenChanges() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.positionAtTopCenter()
        }
    }

    private func observeExpandState() {
        appState.$displayState
            .receive(on: DispatchQueue.main)
            .sink { [weak self] state in
                guard let self, let window = self.window else { return }
                if state == .expanded {
                    window.ignoresMouseEvents = false
                }
            }
            .store(in: &cancellables)

        appState.notificationService.$isReplying
            .receive(on: DispatchQueue.main)
            .sink { [weak self] replying in
                guard let self, let window = self.window else { return }
                if replying {
                    window.ignoresMouseEvents = false
                    NSApp.activate(ignoringOtherApps: true)
                    window.makeKey()
                }
            }
            .store(in: &cancellables)
    }

    private func installMouseMonitors() {
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .leftMouseDragged]) { [weak self] event in
            self?.handleMouseEvent(event)
        }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { [weak self] event in
            self?.handleMouseEvent(event)
            return event
        }
    }

    private func isDraggingFileFromFinderOrApp() -> Bool {
        let dragPB = NSPasteboard(name: .drag)
        if let types = dragPB.types,
           types.contains(.fileURL) || types.contains(NSPasteboard.PasteboardType("NSFilenamesPboardType")) {
            return true
        }
        return dragPB.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
    }

    private func handleMouseEvent(_ event: NSEvent) {
        guard let window else { return }
        let mouseLocation = NSEvent.mouseLocation // Screen coordinates (origin bottom-left)
        let frame = window.frame

        // Auto-open Clips -> Files shelf when dragging a file near the top-center notch!
        if event.type == .leftMouseDragged && isDraggingFileFromFinderOrApp() {
            let dragTriggerRect = NSRect(
                x: frame.midX - 240,
                y: frame.maxY - 120,
                width: 480,
                height: 120
            )
            if dragTriggerRect.contains(mouseLocation) {
                collapseWorkItem?.cancel()
                collapseWorkItem = nil
                window.ignoresMouseEvents = false
                if appState.enabledTabs.contains(.clipboard) {
                    appState.selectedTab = .clipboard
                    appState.clipboardService.clipsMode = .files
                }
                if appState.displayState != .expanded {
                    appState.setDisplayState(.expanded)
                }
                return
            }
        }

        let state = appState.displayState
        let hasTimerAlarm = appState.timerService.isAlarmRinging && state != .expanded
        let hasNotifPopup = (appState.notificationService.activePopup != nil || hasTimerAlarm) && state != .expanded
        let activeW: CGFloat
        let activeH: CGFloat
        if hasNotifPopup {
            activeW = 410
            activeH = CGFloat(appState.prefs.idleHeight) + (appState.notificationService.isReplying ? 148 : 112)
        } else {
            switch state {
            case .idle:
                activeW = Self.idleWidth + 28
                activeH = CGFloat(appState.prefs.idleHeight) + 10
            case .peek:
                activeW = Self.peekWidth + 20
                activeH = Self.peekHeight + 12
            case .expanded:
                activeW = Self.expandedWidth + 16
                activeH = CGFloat(appState.prefs.expandedHeight) + 16
            }
        }

        let activeRect = NSRect(
            x: frame.midX - activeW / 2,
            y: frame.maxY - activeH,
            width: activeW,
            height: activeH
        )

        let inside = activeRect.contains(mouseLocation)

        // Toggle click-through dynamically so windows beneath the transparent area remain clickable
        if window.ignoresMouseEvents == inside {
            window.ignoresMouseEvents = !inside
        }

        // Track hover over the under-notch notification popup to pause/resume its 3-second auto-dismiss
        if hasNotifPopup {
            let popupTopY = frame.maxY - CGFloat(appState.prefs.idleHeight) - 6
            let popupRect = NSRect(
                x: frame.midX - 200,
                y: frame.maxY - activeH,
                width: 400,
                height: max(60, activeH - CGFloat(appState.prefs.idleHeight))
            )
            let insidePopup = popupRect.contains(mouseLocation) && mouseLocation.y <= popupTopY
            appState.notificationService.setHovering(insidePopup)

            if event.type == .leftMouseDown && !inside && appState.notificationService.isReplying {
                appState.notificationService.dismissPopup()
                return
            }
            if insidePopup {
                return // Don't auto-expand to peek while interacting with the notification popup
            }
        }

        // If user clicked outside while expanded, unpin and collapse back to idle
        if event.type == .leftMouseDown && !inside && state != .idle {
            appState.isPinned = false
            appState.setDisplayState(.idle)
            return
        }

        if inside {
            collapseWorkItem?.cancel()
            collapseWorkItem = nil
            // Immediately transition idle -> peek on hover (do NOT auto-open full panel until clicked)
            if state == .idle {
                appState.setDisplayState(.peek)
            }
        } else {
            if state == .peek {
                if collapseWorkItem == nil {
                    let work = DispatchWorkItem { [weak self] in
                        guard let self else { return }
                        self.collapseWorkItem = nil
                        if self.appState.displayState == .peek {
                            self.appState.setDisplayState(.idle)
                        }
                    }
                    collapseWorkItem = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
                }
            } else if state == .expanded && !appState.isPinned {
                if collapseWorkItem == nil {
                    let work = DispatchWorkItem { [weak self] in
                        guard let self else { return }
                        self.collapseWorkItem = nil
                        if !self.appState.isPinned {
                            self.appState.setDisplayState(.idle)
                        }
                    }
                    collapseWorkItem = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + appState.prefs.collapseDelay, execute: work)
                }
            }
        }
    }
}
