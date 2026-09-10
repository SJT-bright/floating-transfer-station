import AppKit
import ServiceManagement
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let presentation = PanelPresentation()
    private var panel: NSPanel?
    private var model: BoardModel?
    private var launchAtLoginMenuItem: NSMenuItem?
    private var collapseWorkItem: DispatchWorkItem?
    private var expandedSize = NSSize(width: 442, height: 560)
    private var expandedTop = 80.0
    private var verticalDragStartTop: Double?
    private var verticalDragStartMouseY: Double?
    private var verticalDragVisibleFrame: NSRect?
    private var isProgrammaticTransition = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installMainMenu()

        let model = BoardModel()
        self.model = model
        let settings = model.settings
        let visibleFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let expandedFrame = PanelGeometry.expandedFrame(settings: settings, in: visibleFrame)
        expandedSize = expandedFrame.size
        expandedTop = visibleFrame.maxY - expandedFrame.maxY
        let collapsedFrame = PanelGeometry.collapsedFrame(
            around: expandedFrame,
            in: visibleFrame
        )

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
        panel.maxSize = NSSize(width: min(480, visibleFrame.width), height: min(560, visibleFrame.height))
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
        panel.contentView = hostingView
        panel.isReleasedWhenClosed = false
        self.panel = panel
        presentation.onHoverChanged = { [weak self] isInside in
            self?.handleHover(isInside)
        }
        presentation.onVerticalDragChanged = { [weak self] gestureStartMouseY in
            self?.handleVerticalDragChanged(gestureStartMouseY: gestureStartMouseY)
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

        expandedSize = panel.frame.size
        expandedTop = visibleFrame.maxY - panel.frame.maxY
        model.updateWindowSettings(
            panelWidth: panel.frame.width - PanelGeometry.railWidth,
            height: panel.frame.height,
            top: expandedTop
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
            guard let self else {
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

    private func handleVerticalDragChanged(gestureStartMouseY: Double) {
        guard let panel else {
            return
        }

        collapseWorkItem?.cancel()
        collapseWorkItem = nil
        if verticalDragStartTop == nil {
            guard let visibleFrame = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame else {
                return
            }
            verticalDragStartTop = expandedTop
            verticalDragStartMouseY = gestureStartMouseY
            verticalDragVisibleFrame = visibleFrame
            isProgrammaticTransition = true
        }

        guard let verticalDragStartTop,
              let verticalDragStartMouseY,
              let visibleFrame = verticalDragVisibleFrame
        else {
            return
        }
        let translationY = verticalDragStartMouseY - Double(NSEvent.mouseLocation.y)
        let expandedFrame = PanelGeometry.verticallyDraggedExpandedFrame(
            size: expandedSize,
            startTop: verticalDragStartTop,
            translationY: translationY,
            in: visibleFrame
        )
        expandedTop = visibleFrame.maxY - expandedFrame.maxY
        let targetFrame = presentation.isExpanded
            ? expandedFrame
            : PanelGeometry.collapsedFrame(around: expandedFrame, in: visibleFrame)
        panel.setFrame(targetFrame, display: true)
    }

    private func handleVerticalDragEnded() {
        guard verticalDragStartTop != nil else {
            return
        }

        verticalDragStartTop = nil
        verticalDragStartMouseY = nil
        verticalDragVisibleFrame = nil
        isProgrammaticTransition = false
        model?.updateWindowSettings(
            panelWidth: expandedSize.width - PanelGeometry.railWidth,
            height: expandedSize.height,
            top: expandedTop
        )

        if let panel,
           PanelInteractionPolicy.shouldScheduleCollapseAfterDrag(
               isExpanded: presentation.isExpanded,
               mouseLocation: NSEvent.mouseLocation,
               panelFrame: panel.frame
           ) {
            scheduleCollapse(after: 0.12)
        }
    }

    private func setExpanded(_ expanded: Bool) {
        guard let panel,
              let visibleFrame = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
        else {
            return
        }

        if presentation.isExpanded == expanded || verticalDragStartTop != nil {
            return
        }

        isProgrammaticTransition = true
        defer { isProgrammaticTransition = false }

        let expandedFrame = PanelGeometry.expandedFrame(
            size: expandedSize,
            top: expandedTop,
            in: visibleFrame
        )
        let targetFrame = expanded
            ? expandedFrame
            : PanelGeometry.collapsedFrame(around: expandedFrame, in: visibleFrame)

        // Never lay out a full board at the 56-point handle width, nor animate
        // through intermediate widths (long text reflows on every frame).
        if !expanded {
            presentation.setExpanded(false)
        }
        panel.minSize = expanded
            ? NSSize(width: min(380, visibleFrame.width), height: min(440, visibleFrame.height))
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
