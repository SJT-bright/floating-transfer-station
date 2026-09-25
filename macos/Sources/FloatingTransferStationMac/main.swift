import AppKit
import ServiceManagement
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let presentation = PanelPresentation()
    private var panel: NSPanel?
    private var model: BoardModel?
    private var launchAtLoginMenuItem: NSMenuItem?
    private var collapseWorkItem: DispatchWorkItem?
    private let collapseMotion = PanelCollapseMotion()
    private var expandedSize = NSSize(width: 408, height: 476)
    private var expandedTop = 80.0
    private var dragStartFrame: NSRect?
    private var dragStartMouse: NSPoint?
    private var expandedOrigin = NSPoint.zero
    private var isProgrammaticTransition = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installMainMenu()

        let model = BoardModel()
        self.model = model
        let settings = model.settings
        let savedPoint = NSPoint(x: settings.windowX ?? .greatestFiniteMagnitude, y: settings.windowY ?? .greatestFiniteMagnitude)
        let visibleFrame = NSScreen.screens.first(where: { $0.visibleFrame.contains(savedPoint) })?.visibleFrame ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let expandedFrame = PanelGeometry.expandedFrame(settings: settings, in: visibleFrame)
        expandedOrigin = expandedFrame.origin
        expandedSize = expandedFrame.size
        expandedTop = visibleFrame.maxY - expandedFrame.maxY
        let docked = PanelGeometry.isDocked(expandedFrame, in: visibleFrame)
        presentation.isDockedLeft = abs(expandedFrame.minX - visibleFrame.minX) < 1
        presentation.setExpanded(!docked)
        let collapsedFrame = docked ? PanelGeometry.collapsedFrame(
            around: expandedFrame,
            in: visibleFrame
        ) : expandedFrame

        let panel = NSPanel(
            contentRect: collapsedFrame,
            styleMask: [.titled, .fullSizeContentView, .utilityWindow],
            backing: .buffered,
            defer: false
        )
        panel.title = "悬浮中转站"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isMovable = false
        panel.isMovableByWindowBackground = false
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.minSize = PanelGeometry.collapsedSize
        panel.maxSize = NSSize(width: min(408, visibleFrame.width), height: min(476, visibleFrame.height))
        if !docked {
            panel.styleMask.insert(.resizable)
            panel.minSize = NSSize(width: min(340, visibleFrame.width), height: min(400, visibleFrame.height))
        }
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.delegate = self
        let hostingView = NSHostingView(
            rootView: ContentView(model: model, presentation: presentation)
        )
        // The panel owns its size. Content-derived window constraints otherwise
        // fight the narrow handle while SwiftUI measures the expanded board.
        hostingView.sizingOptions = []
        hostingView.wantsLayer = true
        panel.contentView = hostingView
        panel.isReleasedWhenClosed = false
        self.panel = panel
        presentation.onHoverChanged = { [weak self] isInside in
            self?.handleHover(isInside)
        }
        presentation.onVerticalDragChanged = { [weak self] gestureStartMouse in
            self?.handleVerticalDragChanged(gestureStartMouse: gestureStartMouse)
        }
        presentation.onVerticalDragEnded = { [weak self] in
            self?.handleVerticalDragEnded()
        }

        panel.setFrame(collapsedFrame, display: true)
        panel.orderFrontRegardless()
        configureLaunchAtLogin()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func windowDidMove(_ notification: Notification) {
        saveWindowFrame()
    }

    func windowDidResize(_ notification: Notification) {
        saveWindowFrame()
    }

    private func saveWindowFrame() {
        guard presentation.isExpanded,
              !isProgrammaticTransition,
              let panel,
              let model,
              let visibleFrame = panel.screen?.visibleFrame
        else {
            return
        }

        expandedOrigin = panel.frame.origin
        expandedSize = panel.frame.size
        expandedTop = visibleFrame.maxY - panel.frame.maxY
        model.updateWindowSettings(
            panelWidth: panel.frame.width - PanelGeometry.railWidth,
            height: panel.frame.height,
            top: expandedTop,
            origin: expandedOrigin
        )
    }

    private func handleHover(_ isInside: Bool) {
        collapseWorkItem?.cancel()
        collapseWorkItem = nil

        if isInside {
            setExpanded(true)
            return
        }

        scheduleCollapse(after: 0.38)
    }

    private func scheduleCollapse(after delay: TimeInterval) {
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.isDocked, !self.presentation.isEditingAppearance else {
                return
            }

            let shouldCollapse = PanelInteractionPolicy.shouldCollapse(
                pressedMouseButtons: NSEvent.pressedMouseButtons,
                hasAttachedSheet: self.panel?.attachedSheet != nil
            )
            if shouldCollapse {
                self.setExpanded(false)
            } else if self.panel?.attachedSheet == nil {
                self.scheduleCollapse(after: 0.12)
            }
        }
        collapseWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func handleVerticalDragChanged(gestureStartMouse: NSPoint) {
        guard let panel else { return }
        collapseWorkItem?.cancel()
        collapseWorkItem = nil
        collapseMotion.cancel()
        if dragStartFrame == nil {
            if !presentation.isExpanded { applyExpanded(true) }
            panel.contentView?.layer?.removeAnimation(forKey: PanelRevealMotion.animationKey)
            dragStartFrame = panel.frame
            dragStartMouse = gestureStartMouse
            isProgrammaticTransition = true
        }
        guard let start = dragStartFrame, let mouse = dragStartMouse,
              let screen = NSScreen.screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) })
                ?? panel.screen ?? NSScreen.main else { return }
        let candidate = start.offsetBy(dx: NSEvent.mouseLocation.x - mouse.x,
                                       dy: NSEvent.mouseLocation.y - mouse.y)
        let frame = PanelGeometry.positionedFrame(candidate, in: screen.visibleFrame)
        expandedOrigin = frame.origin
        presentation.isDockedLeft = abs(frame.minX - screen.visibleFrame.minX) < 1
        expandedSize = frame.size
        expandedTop = screen.visibleFrame.maxY - frame.maxY
        panel.setFrame(frame, display: true)
    }

    private func handleVerticalDragEnded() {
        guard dragStartFrame != nil else { return }
        dragStartFrame = nil
        dragStartMouse = nil
        isProgrammaticTransition = false
        saveWindowFrame()
        if let panel, !panel.frame.contains(NSEvent.mouseLocation) {
            scheduleCollapse(after: 0.12)
        }
    }

    private var isDocked: Bool {
        guard let panel, let screen = panel.screen ?? NSScreen.main else { return true }
        return PanelGeometry.isDocked(NSRect(origin: expandedOrigin, size: expandedSize), in: screen.visibleFrame)
    }

    private func setExpanded(_ expanded: Bool) {
        if expanded {
            collapseMotion.cancel()
        }
        guard presentation.isExpanded != expanded,
              dragStartFrame == nil,
              let panel
        else {
            return
        }

        if expanded {
            applyExpanded(true)
            return
        }
        guard isDocked, !collapseMotion.isRunning, !presentation.isEditingAppearance else {
            return
        }
        guard let layer = panel.contentView?.layer else {
            applyExpanded(false)
            return
        }
        layer.removeAnimation(forKey: PanelRevealMotion.animationKey)
        collapseMotion.start(
            on: layer,
            reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
            towardLeft: presentation.isDockedLeft
        ) { [weak self] in
            guard let self, let panel = self.panel,
                  !self.presentation.isEditingAppearance, self.isDocked,
                  !panel.frame.contains(NSEvent.mouseLocation),
                  self.dragStartFrame == nil
            else {
                return
            }
            if PanelInteractionPolicy.shouldCollapse(
                pressedMouseButtons: NSEvent.pressedMouseButtons,
                hasAttachedSheet: panel.attachedSheet != nil
            ) {
                self.applyExpanded(false)
            } else if panel.attachedSheet == nil {
                self.scheduleCollapse(after: 0.12)
            }
        }
    }

    private func applyExpanded(_ expanded: Bool) {
        guard let panel,
              let visibleFrame = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
        else {
            return
        }

        if presentation.isExpanded == expanded || dragStartFrame != nil {
            return
        }

        isProgrammaticTransition = true
        defer { isProgrammaticTransition = false }
        panel.contentView?.layer?.removeAnimation(forKey: PanelRevealMotion.animationKey)

        let expandedFrame = PanelGeometry.positionedFrame(
            NSRect(origin: expandedOrigin, size: expandedSize), in: visibleFrame
        )
        expandedOrigin = expandedFrame.origin
        expandedSize = expandedFrame.size
        let targetFrame = expanded
            ? expandedFrame
            : PanelGeometry.collapsedFrame(around: expandedFrame, in: visibleFrame)

        // Never lay out a full board at the 48-point handle width, nor animate
        // through intermediate widths (long text reflows on every frame).
        if !expanded {
            presentation.setExpanded(false)
        }
        panel.minSize = expanded
            ? NSSize(width: min(340, visibleFrame.width), height: min(400, visibleFrame.height))
            : PanelGeometry.collapsedSize
        if expanded {
            panel.styleMask.insert(.resizable)
        } else {
            panel.styleMask.remove(.resizable)
        }
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.setFrame(targetFrame, display: false)
        if expanded {
            presentation.setExpanded(true)
            panel.contentView?.layoutSubtreeIfNeeded()
            // Animate only compositing, never the frame/bounds used by text layout.
            panel.contentView?.layer?.add(
                PanelRevealMotion.animation(
                    reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion,
                    towardLeft: presentation.isDockedLeft
                ),
                forKey: PanelRevealMotion.animationKey
            )
        }
    }

    private func configureLaunchAtLogin() {
        let service = SMAppService.mainApp
        if service.status == .notRegistered || service.status == .notFound {
            do {
                try service.register()
            } catch {
                NSLog("Unable to enable launch at login: %@", error.localizedDescription)
            }
        }

        switch service.status {
        case .enabled:
            launchAtLoginMenuItem?.title = "开机启动：已开启"
        case .requiresApproval:
            launchAtLoginMenuItem?.title = "开机启动：需要系统批准"
        case .notRegistered, .notFound:
            launchAtLoginMenuItem?.title = "开机启动：设置失败"
        @unknown default:
            launchAtLoginMenuItem?.title = "开机启动：状态未知"
        }
    }

    private func installMainMenu() {
        let mainMenu = NSMenu()
        let applicationItem = NSMenuItem()
        mainMenu.addItem(applicationItem)

        let applicationMenu = NSMenu()
        applicationMenu.addItem(
            withTitle: "关于悬浮中转站",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        applicationMenu.addItem(.separator())
        let launchAtLoginItem = NSMenuItem(
            title: "开机启动：正在设置",
            action: nil,
            keyEquivalent: ""
        )
        launchAtLoginItem.isEnabled = false
        applicationMenu.addItem(launchAtLoginItem)
        launchAtLoginMenuItem = launchAtLoginItem
        applicationMenu.addItem(.separator())
        applicationMenu.addItem(
            withTitle: "退出悬浮中转站",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        applicationItem.submenu = applicationMenu
        NSApp.mainMenu = mainMenu
    }
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
application.run()
