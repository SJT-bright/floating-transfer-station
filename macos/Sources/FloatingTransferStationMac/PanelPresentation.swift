import AppKit
import Combine

final class PanelPresentation: ObservableObject {
    @Published private(set) var isExpanded = false

    var onHoverChanged: ((Bool) -> Void)?
    var onVerticalDragChanged: ((Double) -> Void)?
    var onVerticalDragEnded: (() -> Void)?

    func handleHover(_ isInside: Bool) {
        onHoverChanged?(isInside)
    }

    func setExpanded(_ expanded: Bool) {
        isExpanded = expanded
    }

    func handleVerticalDragChanged(gestureStartMouseY: Double) {
        onVerticalDragChanged?(gestureStartMouseY)
    }

    func handleVerticalDragEnded() {
        onVerticalDragEnded?()
    }
}

struct PanelInteractionPolicy {
    static func shouldCollapse(
        pressedMouseButtons: Int,
        hasAttachedSheet: Bool
    ) -> Bool {
        pressedMouseButtons == 0 && !hasAttachedSheet
    }

    static func shouldScheduleCollapseAfterDrag(
        isExpanded: Bool,
        mouseLocation: NSPoint,
        panelFrame: NSRect
    ) -> Bool {
        isExpanded && !panelFrame.contains(mouseLocation)
    }
}

struct PanelGeometry {
    static let railWidth = 82.0
    static let collapsedSize = NSSize(width: 56, height: 164)

    static func expandedFrame(
        settings: WindowSettings,
        in visibleFrame: NSRect
    ) -> NSRect {
        let maximumWidth = max(0, min(480, visibleFrame.width))
        let minimumWidth = min(380, maximumWidth)
        let width = min(max(settings.panelWidth + railWidth, minimumWidth), maximumWidth)
        let maximumHeight = max(0, min(560, visibleFrame.height))
        let minimumHeight = min(440, maximumHeight)
        let height = min(max(settings.windowHeight, minimumHeight), maximumHeight)
        let top = min(max(settings.top, 0), max(0, visibleFrame.height - height))
        return expandedFrame(
            size: NSSize(width: width, height: height),
            top: top,
            in: visibleFrame
        )
    }

    static func expandedFrame(
        size: NSSize,
        top: Double,
        in visibleFrame: NSRect
    ) -> NSRect {
        let width = min(max(size.width, min(380, visibleFrame.width)), min(480, visibleFrame.width))
        let height = min(max(size.height, min(440, visibleFrame.height)), min(560, visibleFrame.height))
        let clampedTop = min(max(top, 0), max(0, visibleFrame.height - height))
        return NSRect(
            x: visibleFrame.maxX - width,
            y: visibleFrame.maxY - clampedTop - height,
            width: width,
            height: height
        )
    }

    static func verticallyDraggedExpandedFrame(
        size: NSSize,
        startTop: Double,
        translationY: Double,
        in visibleFrame: NSRect
    ) -> NSRect {
        expandedFrame(
            size: size,
            top: startTop + translationY,
            in: visibleFrame
        )
    }

    static func collapsedFrame(
        around expandedFrame: NSRect,
        in visibleFrame: NSRect
    ) -> NSRect {
        let width = min(collapsedSize.width, visibleFrame.width)
        let height = min(collapsedSize.height, visibleFrame.height)
        let preferredY = expandedFrame.midY - (height / 2)
        let y = min(max(preferredY, visibleFrame.minY), visibleFrame.maxY - height)
        return NSRect(
            x: visibleFrame.maxX - width,
            y: y,
            width: width,
            height: height
        )
    }
}
