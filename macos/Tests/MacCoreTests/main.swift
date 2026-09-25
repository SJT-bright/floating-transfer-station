import AppKit
import Foundation
import UniformTypeIdentifiers
import QuartzCore

private struct TestFailure: Error, CustomStringConvertible {
    let description: String
}

@main
enum MacCoreTests {
    static func main() throws {
        try testNewContentStaysBelowPinsAndPersists()
        try testMovePreservesPinnedPartition()
        try testFourAssetCategoriesRemainDistinct()
        try testStoreReadsWindowsCompatibleLegacyJSON()
        try testEscapingManagedImagePathIsRejected()
        try testPanelGeometryKeepsCollapsedHandleSmallAndRightAligned()
        try testPanelGeometryClampsExpandedPanelToCompactBounds()
        try testVerticalRailDragStaysAttachedToRightEdge()
        try testPanelStaysExpandedWhileDragging()
        try testCopyImageToAnotherCategoryPreservesSourceAndPersists()
        try testImageDragProviderExportsImageAndFile()
        try testClipboardAlwaysGoesToInbox()
        try testCustomCategoriesPersistAndKeepItems()
        try testLongTextPreviewPreservesFullContent()
        try testRevealMotionDoesNotAnimateLayout()
        try testCollapseMotionDoesNotAnimateLayout()
        try testCollapseCancellationRejectsStaleCompletion()
        try testCollapseRunsOnHostedLayerAndFinishes()
        try testAppearancePersistsWithoutChangingCategories()
        try testNamesSearchAndPersistence()
        try testExpandedTextFitsActualLines()
        try testFreePositionAndBothEdgeSnapping()
        print("macOS core tests passed (22 tests)")
    }

    private static func testFreePositionAndBothEdgeSnapping() throws {
        let screen = NSRect(x: -1200, y: 40, width: 1200, height: 800)
        let free = NSRect(x: -800, y: 200, width: 408, height: 476)
        try check(PanelGeometry.positionedFrame(free, in: screen) == free, "free drag still forces edge docking")
        try check(!PanelGeometry.isDocked(free, in: screen), "floating window auto-collapses")
        let left = PanelGeometry.positionedFrame(NSRect(x: -1185, y: 200, width: 408, height: 476), in: screen)
        let right = PanelGeometry.positionedFrame(NSRect(x: -423, y: 200, width: 408, height: 476), in: screen)
        try check(left.minX == screen.minX && right.maxX == screen.maxX, "near-edge snap failed")
        try check(PanelGeometry.collapsedFrame(around: left, in: screen).minX == screen.minX, "left handle appears on right")
        try check(PanelGeometry.collapsedFrame(around: right, in: screen).maxX == screen.maxX, "right handle escaped edge")
        let beyond = PanelGeometry.positionedFrame(NSRect(x: -5000, y: 5000, width: 408, height: 476), in: screen)
        try check(screen.contains(beyond), "dragged window escaped usable screen")
        let outsideSnap = NSRect(x: screen.minX + 21, y: 200, width: 408, height: 476)
        try check(PanelGeometry.positionedFrame(outsideSnap, in: screen) == outsideSnap, "snap threshold prevents detaching")
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LocalStore(paths: AppPaths(dataDirectory: directory))
        let model = BoardModel(store: store, monitorsClipboard: false)
        model.updateWindowSettings(panelWidth: 338, height: 476, top: 164, origin: free.origin)
        try check(PanelGeometry.expandedFrame(settings: store.loadSettings(), in: screen) == free, "free position lost on reload")
    }

    private static func testExpandedTextFitsActualLines() throws {
        let threeLines = TextCardLayout.expandedHeight(text: "第一行\n第二行\n第三行", width: 280)
        try check(threeLines > 32 && threeLines < 65, "three lines still reserve a large blank area")
        try check(TextCardLayout.expandedHeight(text: "短文字", width: 280) == 32, "short text grew unnecessarily")
        let wrapping = String(repeating: "中文自动换行", count: 8)
        try check(TextCardLayout.expandedHeight(text: wrapping, width: 140) > TextCardLayout.expandedHeight(text: wrapping, width: 300), "height ignores actual wrapping width")
        try check(TextCardLayout.expandedHeight(text: String(repeating: "长文\n", count: 1000), width: 280) == 180, "long text exceeds scrolling height limit")
    }

    private static func testNamesSearchAndPersistence() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LocalStore(paths: AppPaths(dataDirectory: directory))
        let model = BoardModel(store: store, monitorsClipboard: false)
        model.addText("正文关键词", to: .inbox)
        let id = try require(model.items.first?.id, "missing item")
        try check(model.items.first?.name == nil && model.searchNamedItems("正文关键词").isEmpty, "unnamed body matched search")
        model.renameItem(id, to: "  人物 Hero  ")
        try check(model.searchNamedItems("hero").map(\.id) == [id], "named item did not match")
        try check(model.searchNamedItems("正文关键词").isEmpty && model.searchNamedItems("  ").isEmpty, "search used body or empty query")
        model.move(id, to: .prompt)
        try check(model.searchNamedItems("人物").map(\.id) == [id], "cross-category search failed")
        let reloaded = BoardModel(store: store, monitorsClipboard: false)
        try check(reloaded.items.first?.name == "人物 Hero" && reloaded.items.first?.text == "正文关键词", "name save altered text")
        reloaded.renameItem(id, to: "  ")
        try check(reloaded.searchNamedItems("Hero").isEmpty && store.loadBoard().first?.name == nil, "clearing name left searchable item")
        let legacy = BoardItem(kind: .text, category: .inbox, order: 0, text: "旧数据")
        let data = try JSONEncoder().encode(legacy)
        let decoded = try JSONDecoder().decode(BoardItem.self, from: data)
        try check(decoded.name == nil && decoded.text == "旧数据", "legacy item lost")
    }

    private static func testAppearancePersistsWithoutChangingCategories() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LocalStore(paths: AppPaths(dataDirectory: directory))
        let legacy = Data(#"{"panelWidth":420,"windowHeight":520,"top":90,"categoryNames":{"Inbox":"收藏"},"customCategories":["Custom-test"]}"#.utf8)
        let settings = try JSONDecoder().decode(WindowSettings.self, from: legacy)
        try check(settings.appearance == nil && settings.panelWidth == 420 && settings.customCategories.count == 1, "legacy settings were lost")
        try store.saveSettings(settings)
        let model = BoardModel(store: store, monitorsClipboard: false)
        let appearance = PanelAppearance(textBrightness: 0.8, textOpacity: 0.7, backgroundBrightness: 0.1, backgroundOpacity: 0.6)
        model.updateAppearance(appearance)
        try check(store.loadSettings().appearance == appearance, "appearance did not persist")
        try check(store.loadSettings().categoryNames == settings.categoryNames && store.loadSettings().customCategories == settings.customCategories, "appearance changed categories")
        model.updateAppearance(nil)
        try check(store.loadSettings() == settings, "reset changed unrelated settings")
        let invalid = PanelAppearance(textBrightness: -1, textOpacity: 0, backgroundBrightness: 5, backgroundOpacity: 2).normalized
        try check(invalid.textBrightness == 0 && invalid.textOpacity == 0.2 && invalid.backgroundBrightness == 1 && invalid.backgroundOpacity == 1, "appearance values not bounded")
    }

    private static func testCollapseMotionDoesNotAnimateLayout() throws {
        let normal = PanelCollapseMotion.animation(reduceMotion: false)
        let animations = normal.animations?.compactMap { $0 as? CABasicAnimation } ?? []
        try check(animations.map(\.keyPath) == ["opacity", "transform.translation.x"], "collapse must not animate frame/bounds")
        try check(normal.duration == 0.20, "collapse duration changed")
        try check(animations.allSatisfy { $0.duration == normal.duration }, "collapse components finish at different times")
        try check((animations.first?.fromValue as? NSNumber)?.doubleValue == 1, "collapse must start visible")
        try check((animations.first?.toValue as? NSNumber)?.doubleValue == 0, "collapse must fade out")
        try check((animations.last?.toValue as? NSNumber)?.doubleValue == 28, "collapse must move toward the right edge")
        let reduced = PanelCollapseMotion.animation(reduceMotion: true)
        try check(reduced.duration == 0.12 && reduced.animations?.count == 1, "reduced motion still slides")
        try check((reduced.animations?.first as? CABasicAnimation)?.keyPath == "opacity", "reduced collapse must only fade")
    }

    private static func testCollapseCancellationRejectsStaleCompletion() throws {
        let motion = PanelCollapseMotion()
        let layer = CALayer()
        layer.bounds = CGRect(x: 0, y: 0, width: 480, height: 560)
        let bounds = layer.bounds
        var completed = 0
        motion.start(on: layer, reduceMotion: false) { completed += 1 }
        let oldAnimation = try require(layer.animation(forKey: PanelCollapseMotion.animationKey), "collapse did not start")
        try check(motion.isRunning && completed == 0, "collapse committed before its animation finished")
        motion.cancel()
        try check(!motion.isRunning && layer.animation(forKey: PanelCollapseMotion.animationKey) == nil, "cancel did not remove collapse")
        try check(layer.bounds == bounds && CATransform3DIsIdentity(layer.transform) && layer.opacity == 1, "cancelled collapse left a hidden or shifted panel")

        motion.start(on: layer, reduceMotion: false) { completed += 1 }
        motion.animationDidStop(oldAnimation, finished: true)
        try check(motion.isRunning && completed == 0, "stale completion collapsed a reopened panel")
        let current = try require(layer.animation(forKey: PanelCollapseMotion.animationKey), "new collapse missing")
        motion.animationDidStop(current, finished: true)
        try check(completed == 1 && !motion.isRunning, "completed collapse did not commit exactly once")
        motion.animationDidStop(current, finished: true)
        try check(completed == 1, "collapse completion ran twice")
        try check(layer.bounds == bounds && CATransform3DIsIdentity(layer.transform) && layer.opacity == 1, "finished collapse left animation state behind")
    }

    private static func testCollapseRunsOnHostedLayerAndFinishes() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let window = NSWindow(
            contentRect: NSRect(x: -10000, y: -10000, width: 120, height: 80),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 120, height: 80))
        view.wantsLayer = true
        window.contentView = view
        window.orderFrontRegardless()
        let layer = try require(view.layer, "hosted layer missing")
        layer.backgroundColor = NSColor.systemBlue.cgColor
        let motion = PanelCollapseMotion()
        var completed = 0
        motion.start(on: layer, reduceMotion: false) { completed += 1 }
        CATransaction.flush()
        var observedIntermediateFrame = false
        let deadline = Date().addingTimeInterval(1)
        while motion.isRunning && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            if let frame = layer.presentation(), frame.opacity > 0 && frame.opacity < 1,
               frame.transform.m41 > 0 && frame.transform.m41 < 28 {
                observedIntermediateFrame = true
            }
        }
        try check(observedIntermediateFrame, "hosted collapse never displayed a partial slide/fade")
        try check(completed == 1 && !motion.isRunning, "native animation completion did not finish collapse")
        try check(layer.bounds == view.bounds && layer.opacity == 1 && CATransform3DIsIdentity(layer.transform), "hosted animation changed layout or left residual opacity")
    }

    private static func testRevealMotionDoesNotAnimateLayout() throws {
        let normal = PanelRevealMotion.animation(reduceMotion: false)
        let animations = normal.animations?.compactMap { $0 as? CABasicAnimation } ?? []
        try check(animations.map(\.keyPath) == ["opacity", "transform.translation.x"], "reveal must not animate frame/bounds")
        try check(normal.duration > 0 && normal.duration < 0.4, "reveal is missing or too slow")
        try check(animations.allSatisfy { $0.duration == normal.duration }, "reveal components do not share the intended duration")
        try check((animations.last?.toValue as? NSNumber)?.doubleValue == 0, "reveal leaves content shifted")
        let reduced = PanelRevealMotion.animation(reduceMotion: true)
        try check(reduced.animations?.count == 1, "reduced motion still slides")
        try check((reduced.animations?.first as? CABasicAnimation)?.keyPath == "opacity", "reduced motion should only fade")
        let layer = CALayer()
        layer.bounds = CGRect(x: 0, y: 0, width: 480, height: 560)
        let bounds = layer.bounds
        layer.add(normal, forKey: PanelRevealMotion.animationKey)
        layer.removeAnimation(forKey: PanelRevealMotion.animationKey)
        try check(layer.bounds == bounds && CATransform3DIsIdentity(layer.transform) && layer.opacity == 1, "interrupted reveal changed layout or visibility")
    }

    private static func testLongTextPreviewPreservesFullContent() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LocalStore(paths: AppPaths(dataDirectory: directory))
        let model = BoardModel(store: store, monitorsClipboard: false)
        let fullText = String(repeating: "中文👨‍👩‍👧‍👦e\u{301}\n", count: 3_000)
        model.addText(fullText)
        let item = try require(model.items.first, "long text not stored")
        try check(item.textPreview.count == 600, "preview exceeded its layout budget")
        try check(item.textPreview == String(fullText.prefix(600)), "preview broke Unicode characters")
        try check(store.loadBoard().first?.text == fullText, "preview truncated the stored text")
        let provider = model.dragProvider(for: item)
        var received: String?
        var finished = false
        provider.loadObject(ofClass: NSString.self) { value, _ in
            DispatchQueue.main.async {
                received = value as? String
                finished = true
            }
        }
        let deadline = Date().addingTimeInterval(3)
        while !finished && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        try check(finished && received == fullText, "drag exported only the preview")
    }

    private static func testClipboardAlwaysGoesToInbox() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LocalStore(paths: AppPaths(dataDirectory: directory))
        let model = BoardModel(store: store, monitorsClipboard: false)
        let custom = try require(model.addCategory(named: "道具"), "custom category missing")
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        let image = NSImage(size: NSSize(width: 8, height: 8), flipped: false) { rect in
            NSColor.systemBlue.setFill()
            rect.fill()
            return true
        }
        for category in [.customerOriginal, .reference, .prompt, custom] {
            model.selectCategory(category)
            pasteboard.clearContents()
            pasteboard.setString("自动文字", forType: .string)
            model.capturePasteboard(pasteboard, force: false)
            pasteboard.clearContents()
            pasteboard.writeObjects([image])
            model.capturePasteboard(pasteboard, force: false)
            try check(model.orderedItems(in: category).isEmpty, "clipboard leaked into selected category")
            try check(model.activeCategory == category, "capture changed the browsing category")
        }
        try check(model.orderedItems(in: .inbox).count == 8, "clipboard did not collect all content in Inbox")
        let filePath = try store.storeImage(image)
        let fileURL = try require(store.managedImageURL(relativePath: filePath), "missing file")
        pasteboard.clearContents()
        pasteboard.writeObjects([fileURL as NSURL])
        model.capturePasteboard(pasteboard, force: true)
        try check(model.orderedItems(in: .inbox).count == 9, "manual capture/file image missed Inbox")
    }

    private static func testCustomCategoriesPersistAndKeepItems() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LocalStore(paths: AppPaths(dataDirectory: directory))
        let model = BoardModel(store: store, monitorsClipboard: false)
        try check(model.addCategory(named: "  ") == nil, "blank category accepted")
        let custom = try require(model.addCategory(named: "道具资产"), "category creation failed")
        model.addText("待整理")
        let id = try require(model.orderedItems(in: .inbox).first?.id, "missing source")
        model.move(id, to: custom)
        model.addText("触发再次保存")
        model.renameCategory(custom, to: "物品")
        let reloaded = BoardModel(store: store, monitorsClipboard: false)
        try check(reloaded.categories == BoardCategory.visibleCases + [custom], "custom category not restored")
        try check(reloaded.displayName(for: custom) == "物品", "custom name not restored")
        try check(reloaded.orderedItems(in: custom).map(\.id) == [id], "normalization dropped custom items")
        let data = try JSONEncoder().encode(custom)
        try check(String(data: data, encoding: .utf8) == "\"\(custom.rawValue)\"", "category JSON is no longer a string")
        try store.saveSettings(.default)
        let recovered = BoardModel(store: store, monitorsClipboard: false)
        try check(recovered.categories.contains(custom), "category containing items disappeared after settings recovery")
        recovered.addText("新内容")
        try check(store.loadBoard().contains(where: { $0.id == id }), "recovered category items were lost on save")
    }

    private static func testNewContentStaysBelowPinsAndPersists() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LocalStore(paths: AppPaths(dataDirectory: directory))
        let model = BoardModel(store: store, monitorsClipboard: false)

        model.addText("先置顶", to: .inbox)
        let pinnedID = try require(model.orderedItems(in: .inbox).first?.id, "missing pinned item")
        model.togglePinned(pinnedID)
        model.addText("普通内容", to: .inbox)

        let items = model.orderedItems(in: .inbox)
        try check(items.map(\.text) == ["先置顶", "普通内容"], "normal item crossed pin partition")
        try check(items.map(\.isPinned) == [true, false], "pin state is incorrect")
        try check(items.map(\.order) == [0, 1], "category order is incorrect")

        let reloaded = BoardModel(store: store, monitorsClipboard: false)
            .orderedItems(in: .inbox)
        try check(reloaded.map(\.id) == items.map(\.id), "persisted item order changed")
        try check(reloaded.map(\.isPinned) == [true, false], "persisted pin state changed")
    }

    private static func testMovePreservesPinnedPartition() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = BoardModel(
            store: LocalStore(paths: AppPaths(dataDirectory: directory)),
            monitorsClipboard: false
        )

        model.addText("移动我", to: .inbox)
        let id = try require(model.orderedItems(in: .inbox).first?.id, "missing move source")
        model.togglePinned(id)
        model.move(id, to: .prompt)

        try check(model.orderedItems(in: .inbox).isEmpty, "source category was not cleared")
        let moved = try require(model.orderedItems(in: .prompt).first, "target item is missing")
        try check(moved.id == id && moved.isPinned && moved.order == 0, "move broke the pin partition")
    }

    private static func testFourAssetCategoriesRemainDistinct() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LocalStore(paths: AppPaths(dataDirectory: directory))
        try store.saveBoard([
            BoardItem(kind: .text, category: .customerOriginal, order: 0, text: "人物内容"),
            BoardItem(kind: .text, category: .reference, order: 0, text: "场景内容"),
            BoardItem(kind: .text, category: .prompt, order: 0, text: "提示词内容"),
            BoardItem(kind: .text, category: .inbox, order: 0, text: "待分类内容")
        ])

        let model = BoardModel(store: store, monitorsClipboard: false)
        try check(
            BoardCategory.visibleCases == [.customerOriginal, .reference, .prompt, .inbox],
            "the rail no longer contains the four requested categories"
        )
        try check(
            model.displayName(for: .customerOriginal) == "人物资产"
                && model.displayName(for: .reference) == "场景",
            "the restored asset category names changed"
        )
        try check(
            model.orderedItems(in: .customerOriginal).map(\.text) == ["人物内容"]
                && model.orderedItems(in: .reference).map(\.text) == ["场景内容"]
                && model.orderedItems(in: .prompt).map(\.text) == ["提示词内容"]
                && model.orderedItems(in: .inbox).map(\.text) == ["待分类内容"],
            "restored categories no longer keep their own content"
        )
        try check(
            store.loadBoard().count == 4,
            "restoring the four categories changed the persisted item count"
        )
    }

    private static func testStoreReadsWindowsCompatibleLegacyJSON() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let boardFile = directory.appendingPathComponent("board.json")
        try Data(
            """
            {
              "schemaVersion": 1,
              "items": [
                null,
                {
                  "id": "00000000-0000-0000-0000-000000000051",
                  "kind": "Text",
                  "category": "Inbox",
                  "order": 0,
                  "createdAt": "2026-08-22T00:00:00+00:00",
                  "text": "旧内容"
                }
              ]
            }
            """.utf8
        ).write(to: boardFile)

        let items = LocalStore(paths: AppPaths(dataDirectory: directory)).loadBoard()
        try check(items.count == 1, "legacy JSON did not recover its valid item")
        try check(items.first?.text == "旧内容", "legacy text changed")
        try check(items.first?.isPinned == false, "missing legacy pin state did not default to false")
    }

    private static func testEscapingManagedImagePathIsRejected() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LocalStore(paths: AppPaths(dataDirectory: directory))

        try check(store.managedImageURL(relativePath: "../outside.png") == nil, "escaping image path was accepted")
        try check(store.managedImageURL(relativePath: "images/inside.png") != nil, "managed image path was rejected")
    }

    private static func testPanelGeometryKeepsCollapsedHandleSmallAndRightAligned() throws {
        let screen = NSRect(x: 0, y: 24, width: 1512, height: 958)
        let expanded = PanelGeometry.expandedFrame(settings: .default, in: screen)
        let collapsed = PanelGeometry.collapsedFrame(around: expanded, in: screen)

        try check(collapsed.size == NSSize(width: 48, height: 140), "collapsed handle size changed")
        try check(collapsed.maxX == screen.maxX, "collapsed handle left the right screen edge")
        try check(collapsed.midY == expanded.midY, "collapsed handle moved away from the panel center")
    }

    private static func testPanelGeometryClampsExpandedPanelToCompactBounds() throws {
        let screen = NSRect(x: 0, y: 24, width: 1512, height: 958)
        let oversized = WindowSettings(panelWidth: 900, windowHeight: 900, top: -20)
        let frame = PanelGeometry.expandedFrame(settings: oversized, in: screen)

        try check(frame.width == 408, "expanded panel exceeded compact width")
        try check(frame.height == 476, "expanded panel exceeded compact height")
        try check(frame.maxX == screen.maxX, "expanded panel left the right screen edge")
        try check(frame.maxY == screen.maxY, "expanded panel top was not clamped")
    }

    private static func testVerticalRailDragStaysAttachedToRightEdge() throws {
        let screen = NSRect(x: 0, y: 24, width: 1512, height: 958)
        let size = NSSize(width: 408, height: 476)
        let dragged = PanelGeometry.verticallyDraggedExpandedFrame(
            size: size,
            startTop: 80,
            translationY: 200,
            in: screen
        )
        let draggedPastTop = PanelGeometry.verticallyDraggedExpandedFrame(
            size: size,
            startTop: 80,
            translationY: -500,
            in: screen
        )
        let draggedPastBottom = PanelGeometry.verticallyDraggedExpandedFrame(
            size: size,
            startTop: 80,
            translationY: 2_000,
            in: screen
        )
        let shiftedScreen = NSRect(x: -1_512, y: -900, width: 1_512, height: 900)
        let draggedOnShiftedScreen = PanelGeometry.verticallyDraggedExpandedFrame(
            size: size,
            startTop: 80,
            translationY: 120,
            in: shiftedScreen
        )

        try check(dragged.maxX == screen.maxX, "rail drag pulled the panel away from the right edge")
        try check(dragged.maxY == screen.maxY - 280, "rail drag did not follow the pointer vertically")
        try check(draggedPastTop.maxY == screen.maxY, "rail drag escaped above the visible screen")
        try check(draggedPastBottom.minY == screen.minY, "rail drag escaped below the visible screen")
        try check(
            draggedOnShiftedScreen.maxX == shiftedScreen.maxX,
            "rail drag left the right edge of a shifted screen"
        )
        try check(
            draggedOnShiftedScreen.minY >= shiftedScreen.minY
                && draggedOnShiftedScreen.maxY <= shiftedScreen.maxY,
            "rail drag escaped a shifted screen vertically"
        )
    }

    private static func testPanelStaysExpandedWhileDragging() throws {
        try check(
            !PanelInteractionPolicy.shouldCollapse(
                pressedMouseButtons: 1,
                hasAttachedSheet: false
            ),
            "panel collapsed during a drag"
        )
        try check(
            !PanelInteractionPolicy.shouldCollapse(
                pressedMouseButtons: 0,
                hasAttachedSheet: true
            ),
            "panel collapsed while a sheet was attached"
        )
        try check(
            PanelInteractionPolicy.shouldCollapse(
                pressedMouseButtons: 0,
                hasAttachedSheet: false
            ),
            "panel no longer collapses after the pointer leaves"
        )
        let panelFrame = NSRect(x: 1_000, y: 100, width: 442, height: 560)
        try check(
            !PanelInteractionPolicy.shouldScheduleCollapseAfterDrag(
                isExpanded: true,
                mouseLocation: NSPoint(x: 1_200, y: 300),
                panelFrame: panelFrame
            ),
            "panel scheduled a collapse while the pointer remained inside"
        )
        try check(
            PanelInteractionPolicy.shouldScheduleCollapseAfterDrag(
                isExpanded: true,
                mouseLocation: NSPoint(x: 1_450, y: 300),
                panelFrame: panelFrame
            ),
            "panel did not schedule a collapse after an outside release"
        )
    }

    private static func testImageDragProviderExportsImageAndFile() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let paths = AppPaths(dataDirectory: directory)
        let model = BoardModel(
            store: LocalStore(paths: paths),
            monitorsClipboard: false
        )
        let image = NSImage(
            size: NSSize(width: 8, height: 8),
            flipped: false
        ) { rect in
            NSColor.systemBlue.setFill()
            rect.fill()
            return true
        }
        model.addImages([image], to: .inbox)

        let item = try require(model.orderedItems(in: .inbox).first, "missing image item")
        let managedURL = try require(model.imageURL(for: item), "missing managed image URL")
        let provider = model.dragProvider(for: item)
        try check(
            provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
            "image drag no longer advertises a file URL to Jianying"
        )
        try check(
            provider.canLoadObject(ofClass: NSImage.self),
            "image drag no longer exports image data"
        )
        try check(
            model.draggedImageID(from: provider) == item.id,
            "image drag suggested name no longer resolves to its source item"
        )

        var loadFinished = false
        var receivedURL: URL?
        var receivedError: Error?
        provider.loadItem(
            forTypeIdentifier: UTType.fileURL.identifier,
            options: nil
        ) { value, error in
            receivedError = error
            if let url = value as? URL {
                receivedURL = url
            } else if let url = value as? NSURL {
                receivedURL = url as URL
            } else if let data = value as? Data,
                      let string = String(data: data, encoding: .utf8) {
                receivedURL = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            loadFinished = true
        }
        let timeout = Date().addingTimeInterval(3)
        while !loadFinished && Date() < timeout {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        try check(
            loadFinished,
            "Jianying-compatible file URL did not finish loading"
        )
        try check(receivedError == nil, "Jianying-compatible file URL failed to load")
        let exportedURL = try require(receivedURL, "Jianying-compatible provider returned no URL")
        try check(
            exportedURL.standardizedFileURL != managedURL.standardizedFileURL,
            "image drag returned the private managed file instead of its export copy"
        )
        try check(
            exportedURL.deletingLastPathComponent().standardizedFileURL
                == paths.dragExportsDirectory.standardizedFileURL,
            "image drag returned a file outside the persistent export directory"
        )
        let managedData = try Data(contentsOf: managedURL)
        let exportedData = try Data(contentsOf: exportedURL)
        try check(
            exportedData == managedData,
            "persistent drag copy does not match the managed image"
        )
    }

    private static func testCopyImageToAnotherCategoryPreservesSourceAndPersists() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LocalStore(paths: AppPaths(dataDirectory: directory))
        let model = BoardModel(store: store, monitorsClipboard: false)
        let image = NSImage(
            size: NSSize(width: 8, height: 8),
            flipped: false
        ) { rect in
            NSColor.systemGreen.setFill()
            rect.fill()
            return true
        }
        model.addImages([image], to: .inbox)

        let source = try require(model.orderedItems(in: .inbox).first, "missing copy source")
        let sourceURL = try require(model.imageURL(for: source), "missing copy source image")
        let sourceData = try Data(contentsOf: sourceURL)
        let exportURL = try store.exportImageForDrag(relativePath: source.imageRelativePath!)
        let pasteboard = NSPasteboard.withUniqueName()
        defer { pasteboard.releaseGlobally() }
        pasteboard.setString(exportURL.absoluteString, forType: .fileURL)
        model.selectCategory(.reference)
        try check(model.copyDraggedImage(from: pasteboard, to: .reference), "native pasteboard copy failed")

        let remainingSource = try require(
            model.orderedItems(in: .inbox).first,
            "copy removed the source image"
        )
        let copied = try require(
            model.orderedItems(in: .reference).first,
            "target category did not receive the copy"
        )
        let copiedURL = try require(model.imageURL(for: copied), "copied image file is missing")
        try check(remainingSource.id == source.id, "copy changed the source item")
        try check(copied.id != source.id, "copy reused the source item ID")
        try check(copied.imageRelativePath != source.imageRelativePath, "copy reused the managed image path")
        try check(!copied.isPinned && copied.order == 0, "copy did not enter the normal target region")
        let copiedData = try Data(contentsOf: copiedURL)
        try check(copiedData == sourceData, "copied image data changed")
        try check(
            !model.copyImage(source.id, to: .inbox),
            "dropping onto the source category created another copy"
        )

        let reloaded = BoardModel(store: store, monitorsClipboard: false)
        try check(reloaded.orderedItems(in: .inbox).map(\.id) == [source.id], "source did not persist")
        try check(reloaded.orderedItems(in: .reference).map(\.id) == [copied.id], "copy did not persist")
        pasteboard.clearContents()
        try check(!model.copyDraggedImage(from: pasteboard, to: .reference), "empty drag was accepted")
        let unrelatedURL = directory.appendingPathComponent(sourceURL.lastPathComponent)
        pasteboard.setString(unrelatedURL.absoluteString, forType: .fileURL)
        try check(!model.copyDraggedImage(from: pasteboard, to: .reference), "unrelated same-name file was accepted")
        try check(model.orderedItems(in: .reference).count == 1, "invalid drag changed target count")
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() {
            throw TestFailure(description: message)
        }
    }

    private static func require<Value>(_ value: Value?, _ message: String) throws -> Value {
        guard let value else {
            throw TestFailure(description: message)
        }
        return value
    }

    private static func makeTemporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("FloatingTransferStationMacTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
