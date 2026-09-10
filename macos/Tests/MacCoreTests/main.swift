import AppKit
import Foundation
import UniformTypeIdentifiers

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
        print("macOS core tests passed (14 tests)")
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

        try check(collapsed.size == NSSize(width: 56, height: 164), "collapsed handle size changed")
        try check(collapsed.maxX == screen.maxX, "collapsed handle left the right screen edge")
        try check(collapsed.midY == expanded.midY, "collapsed handle moved away from the panel center")
    }

    private static func testPanelGeometryClampsExpandedPanelToCompactBounds() throws {
        let screen = NSRect(x: 0, y: 24, width: 1512, height: 958)
        let oversized = WindowSettings(panelWidth: 900, windowHeight: 900, top: -20)
        let frame = PanelGeometry.expandedFrame(settings: oversized, in: screen)

        try check(frame.width == 480, "expanded panel exceeded compact width")
        try check(frame.height == 560, "expanded panel exceeded compact height")
        try check(frame.maxX == screen.maxX, "expanded panel left the right screen edge")
        try check(frame.maxY == screen.maxY, "expanded panel top was not clamped")
    }

    private static func testVerticalRailDragStaysAttachedToRightEdge() throws {
        let screen = NSRect(x: 0, y: 24, width: 1512, height: 958)
        let size = NSSize(width: 442, height: 560)
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
