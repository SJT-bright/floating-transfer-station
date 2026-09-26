import AppKit
import Combine
import QuartzCore

enum PanelRevealMotion {
    static let animationKey = "panelReveal"

    static func animation(reduceMotion: Bool, towardLeft: Bool = false) -> CAAnimationGroup {
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
            slide.fromValue = towardLeft ? -28 : 28
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
    private var previousRasterization: (enabled: Bool, scale: CGFloat)?

    var isRunning: Bool { token != nil }

    static func animation(reduceMotion: Bool, towardLeft: Bool = false) -> CAAnimationGroup {
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
            slide.toValue = towardLeft ? -28 : 28
            slide.duration = group.duration
            group.animations = [fade, slide]
        }
        group.timingFunction = CAMediaTimingFunction(name: .easeIn)
        group.fillMode = .forwards
        group.isRemovedOnCompletion = false
        return group
    }

    func start(on layer: CALayer, reduceMotion: Bool, towardLeft: Bool = false, completion: @escaping () -> Void) {
        cancel()
        let token = UUID().uuidString
        self.layer = layer
        self.token = token
        self.completion = completion
        previousRasterization = (layer.shouldRasterize, layer.rasterizationScale)
        layer.rasterizationScale = NSScreen.main?.backingScaleFactor ?? 2
        layer.shouldRasterize = true
        let animation = Self.animation(reduceMotion: reduceMotion, towardLeft: towardLeft)
        animation.setValue(token, forKey: Self.tokenKey)
        animation.delegate = self
        layer.add(animation, forKey: Self.animationKey)
    }

    func cancel() {
        token = nil
        completion = nil
        layer?.removeAnimation(forKey: Self.animationKey)
        if let layer, let previousRasterization {
            layer.shouldRasterize = previousRasterization.enabled
            layer.rasterizationScale = previousRasterization.scale
        }
        previousRasterization = nil
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
    @Published var isDockedLeft = false
    var isEditingAppearance = false

    var onHoverChanged: ((Bool) -> Void)?
    var onVerticalDragChanged: ((NSPoint) -> Void)?
    var onVerticalDragEnded: (() -> Void)?

    func handleHover(_ isInside: Bool) {
        onHoverChanged?(isInside)
    }

    func setExpanded(_ expanded: Bool) {
        isExpanded = expanded
    }

    func handleVerticalDragChanged(gestureStartMouse: NSPoint) {
        onVerticalDragChanged?(gestureStartMouse)
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

enum TextCardLayout {
    static func expandedHeight(text: String, width: CGFloat) -> CGFloat {
        let storage = NSTextStorage(string: text, attributes: [.font: NSFont.systemFont(ofSize: 13)])
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: max(1, width), height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        layout.ensureLayout(forBoundingRect: NSRect(x: 0, y: 0, width: max(1, width), height: 180), in: container)
        return min(180, max(32, ceil(layout.usedRect(for: container).height)))
    }
}

struct PanelGeometry {
    static func positionedFrame(_ frame: NSRect, in screen: NSRect, snap: Bool = true) -> NSRect {
        var result = frame
        result.size.width = min(frame.width, screen.width)
        result.size.height = min(frame.height, screen.height)
        result.origin.x = min(max(frame.minX, screen.minX), screen.maxX - result.width)
        result.origin.y = min(max(frame.minY, screen.minY), screen.maxY - result.height)
        if snap {
            if result.minX - screen.minX <= 20 { result.origin.x = screen.minX }
            else if screen.maxX - result.maxX <= 20 { result.origin.x = screen.maxX - result.width }
        }
        return result
    }

    static func isDocked(_ frame: NSRect, in screen: NSRect) -> Bool {
        abs(frame.minX - screen.minX) < 1 || abs(frame.maxX - screen.maxX) < 1
    }
    static let railWidth = 70.0
    static let collapsedSize = NSSize(width: 48, height: 140)

    static func expandedFrame(
        settings: WindowSettings,
        in visibleFrame: NSRect
    ) -> NSRect {
        let maximumWidth = max(0, min(408, visibleFrame.width))
        let minimumWidth = min(340, maximumWidth)
        let width = min(max(settings.panelWidth + railWidth, minimumWidth), maximumWidth)
        let maximumHeight = max(0, min(476, visibleFrame.height))
        let minimumHeight = min(400, maximumHeight)
        let height = min(max(settings.windowHeight, minimumHeight), maximumHeight)
        let top = min(max(settings.top, 0), max(0, visibleFrame.height - height))
        var frame = expandedFrame(
            size: NSSize(width: width, height: height),
            top: top,
            in: visibleFrame
        )
        if let x = settings.windowX, let y = settings.windowY, x.isFinite, y.isFinite {
            frame.origin = NSPoint(x: x, y: y)
        }
        return positionedFrame(frame, in: visibleFrame)
    }

    static func expandedFrame(
        size: NSSize,
        top: Double,
        in visibleFrame: NSRect
    ) -> NSRect {
        let width = min(max(size.width, min(340, visibleFrame.width)), min(408, visibleFrame.width))
        let height = min(max(size.height, min(400, visibleFrame.height)), min(476, visibleFrame.height))
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
            x: abs(expandedFrame.minX - visibleFrame.minX) < 1 ? visibleFrame.minX : expandedFrame.maxX - width,
            y: y,
            width: width,
            height: height
        )
    }
}
