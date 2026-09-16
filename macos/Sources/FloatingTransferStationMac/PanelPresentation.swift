import AppKit
import Combine
import QuartzCore

enum PanelRevealMotion {
    static let animationKey = "panelReveal"

    static func animation(reduceMotion: Bool) -> CAAnimationGroup {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        let group = CAAnimationGroup()
        group.duration = reduceMotion ? 0.12 : 0.24
        fade.duration = group.duration
        if reduceMotion {
            group.animations = [fade]
        } else {
            let slide = CABasicAnimation(keyPath: "transform.translation.x")
            slide.fromValue = 28
            slide.toValue = 0
            slide.duration = group.duration
            group.animations = [fade, slide]
        }
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        return group
    }
}

final class PanelCollapseMotion: NSObject, CAAnimationDelegate {
    static let animationKey = "panelCollapse"
    private static let tokenKey = "collapseToken"
    private weak var layer: CALayer?
    private var token: String?
    private var completion: (() -> Void)?

    var isRunning: Bool { token != nil }

    static func animation(reduceMotion: Bool) -> CAAnimationGroup {
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 1
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.duration = reduceMotion ? 0.12 : 0.20
        fade.duration = group.duration
        if reduceMotion {
            group.animations = [fade]
        } else {
            let slide = CABasicAnimation(keyPath: "transform.translation.x")
            slide.fromValue = 0
            slide.toValue = 28
            slide.duration = group.duration
            group.animations = [fade, slide]
        }
        group.timingFunction = CAMediaTimingFunction(name: .easeIn)
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false
        return group
    }

    func start(on layer: CALayer, reduceMotion: Bool, completion: @escaping () -> Void) {
        cancel()
        let token = UUID().uuidString
        self.layer = layer
        self.token = token
        self.completion = completion
        let animation = Self.animation(reduceMotion: reduceMotion)
        animation.setValue(token, forKey: Self.tokenKey)
        animation.delegate = self
        layer.add(animation, forKey: Self.animationKey)
    }

    func cancel() {
        token = nil
        completion = nil
        layer?.removeAnimation(forKey: Self.animationKey)
        layer = nil
    }

    func animationDidStop(_ animation: CAAnimation, finished flag: Bool) {
        guard let token, animation.value(forKey: Self.tokenKey) as? String == token else {
            return
        }
        let callback = flag ? completion : nil
        cancel()
        callback?()
    }
}

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
