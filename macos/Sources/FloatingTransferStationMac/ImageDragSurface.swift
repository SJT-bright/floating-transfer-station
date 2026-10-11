import AppKit
import SwiftUI

struct ImageDragSurface: NSViewRepresentable {
    let model: BoardModel
    let itemID: UUID
    let preview: NSImage
    let onActivity: (Bool) -> Void

    func makeNSView(context: Context) -> ImageDragSurfaceView {
        let view = ImageDragSurfaceView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ view: ImageDragSurfaceView, context: Context) {
        view.prepare = { completion in model.prepareImageDrag(startingAt: itemID, completion: completion) }
        view.preview = preview
        view.onActivity = onActivity
        view.setAccessibilityLabel("拖动图片；已勾选时一起拖动全部已选图片")
    }

    static func dismantleNSView(_ view: ImageDragSurfaceView, coordinator: ()) {
        view.cancelPreparation()
    }
}

final class ImageDragSurfaceView: NSView, NSDraggingSource {
    var prepare: ((@escaping ([ImageDragSnapshot]?) -> Void) -> Void)?
    var preview: NSImage?
    var onActivity: ((Bool) -> Void)?
    private var downEvent: NSEvent?
    private var downPoint = NSPoint.zero
    private var generation = UUID()
    private var started = false
    private var dragging = false

    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func shouldDelayWindowOrdering(for event: NSEvent) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, let superview else { return nil }
        return bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        downEvent = event
        downPoint = convert(event.locationInWindow, from: nil)
        generation = UUID()
        started = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !started, let downEvent else { return }
        let point = convert(event.locationInWindow, from: nil)
        guard hypot(point.x - downPoint.x, point.y - downPoint.y) >= 3 else { return }
        started = true
        onActivity?(true)
        let request = generation
        prepare? { [weak self] snapshots in
            guard let self, self.generation == request else { return }
            guard let snapshots, !snapshots.isEmpty, self.window != nil,
                  NSEvent.pressedMouseButtons & 1 != 0 else {
                self.cancelPreparation()
                return
            }
            self.dragging = true
            let draggingItems = snapshots.enumerated().map { index, snapshot in
                let item = NSDraggingItem(pasteboardWriter: snapshot.pasteboardItem())
                let image = index == 0 ? self.preview : NSWorkspace.shared.icon(forFile: snapshot.url.path)
                let offset = CGFloat(min(index, 5)) * 5
                item.setDraggingFrame(NSRect(x: self.downPoint.x - 48 + offset,
                                             y: self.downPoint.y - 36 - offset,
                                             width: 96, height: 72), contents: image)
                return item
            }
            let session = self.beginDraggingSession(with: draggingItems, event: downEvent, source: self)
            session.draggingFormation = .pile
            session.animatesToStartingPositionsOnCancelOrFail = true
        }
    }

    override func mouseUp(with event: NSEvent) {
        if !dragging { cancelPreparation() }
        downEvent = nil
    }

    func cancelPreparation() {
        generation = UUID()
        if started && !dragging { onActivity?(false) }
        started = false
        downEvent = nil
    }

    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation {
        .copy
    }

    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) {
        dragging = false
        cancelPreparation()
        onActivity?(false)
    }
}
