import AppKit
import CoreGraphics
import Foundation
import ImageIO
import ObjectiveC
import UniformTypeIdentifiers

private struct FeatureTestFailure: Error, CustomStringConvertible {
    let description: String
}

@main
enum FeatureTests {
    static func main() {
        let tests: [(String, () throws -> Void)] = [
            ("legacy settings, feature defaults, reload and invalid limits", testSettingsCompatibilityAndLimits),
            ("success feedback follows saved single and batched content", testSuccessFeedback),
            ("clipboard success feedback uses a private pasteboard", testClipboardFeedbackWithoutSystemClipboard),
            ("Inbox limit keeps old data until the next FIFO insertion", testInboxCapacityFIFOAndUnlimitedMode),
            ("over-capacity image batch keeps its ordered suffix", testOverCapacityImageBatchKeepsOrderedSuffix),
            ("same-millisecond FIFO preserves existing sequences after reorder and reload", testSameMillisecondFIFOAfterReorderAndReload),
            ("failed capacity save preserves the evicted managed image", testInboxCapacitySaveFailurePreservesImage),
            ("deleting default and custom categories preserves all content", testCategoryDeletionPreservesContentAndReloads),
            ("category deletion rolls back when settings cannot be saved", testCategoryDeletionSaveFailure),
            ("an in-flight image import resolves a deleted target to Inbox", testImportFinishingAfterCategoryDeletion),
            ("text reordering respects partitions and exports full public text", testTextReorderingAndProvider),
            ("failed reorder restores the previous order", testTextReorderSaveFailure)
        ]

        var failures = 0
        for (name, test) in tests {
            do {
                try test()
                print("PASS: \(name)")
            } catch {
                failures += 1
                print("FAIL: \(name): \(error)")
            }
        }
        print("macOS feature tests: \(tests.count - failures)/\(tests.count) passed")
        if failures > 0 { exit(1) }
    }

    private static func testSettingsCompatibilityAndLimits() throws {
        try withTemporaryStore { _, paths, store in
            let legacy = Data(
                #"{"panelWidth":420,"windowHeight":520,"top":90,"categoryNames":{"Inbox":"收藏"},"customCategories":["Custom-old"]}"#.utf8
            )
            try FileManager.default.createDirectory(
                at: paths.dataDirectory,
                withIntermediateDirectories: true
            )
            try legacy.write(to: paths.settingsFile)

            let oldSettings = store.loadSettings()
            try check(oldSettings.successSoundEnabled, "legacy settings did not default success sound to enabled")
            try check(oldSettings.inboxItemLimit == nil, "legacy settings did not default Inbox capacity to unlimited")
            try check(oldSettings.deletedCategoryIDs.isEmpty, "legacy settings invented deleted categories")
            try check(oldSettings.panelWidth == 420 && oldSettings.customCategories == [BoardCategory(rawValue: "Custom-old")],
                      "legacy settings fields were lost")

            let model = BoardModel(store: store, monitorsClipboard: false)
            model.setSuccessSoundEnabled(false)
            model.setInboxItemLimit(7)
            let reloaded = LocalStore(paths: paths).loadSettings()
            try check(!reloaded.successSoundEnabled && reloaded.inboxItemLimit == 7,
                      "new settings did not survive reload")
            try check(reloaded.categoryNames == oldSettings.categoryNames
                          && reloaded.customCategories == oldSettings.customCategories,
                      "saving new settings changed legacy category settings")

            model.setInboxItemLimit(0)
            model.setInboxItemLimit(-4)
            try check(model.settings.inboxItemLimit == 7, "setter accepted a non-positive capacity")
            model.setInboxItemLimit(nil)
            try check(LocalStore(paths: paths).loadSettings().inboxItemLimit == nil,
                      "unlimited capacity did not survive reload")

            for invalidValue in [0, -1] {
                let invalidJSON = Data(#"{"inboxItemLimit":\#(invalidValue)}"#.utf8)
                let decoded = try JSONDecoder().decode(WindowSettings.self, from: invalidJSON)
                try check(decoded.inboxItemLimit == nil, "decoded invalid capacity \(invalidValue) as a finite limit")
            }
        }
    }

    private static func testSuccessFeedback() throws {
        try withTemporaryStore { directory, paths, store in
            let model = BoardModel(store: store, monitorsClipboard: false)
            var successes = 0
            model.onCopySuccess = { successes += 1 }

            model.addText("单条成功")
            try check(successes == 1 && model.orderedItems(in: .inbox).count == 1,
                      "a saved text item did not produce exactly one success callback")

            model.addImages([imageFixture(), imageFixture()], to: .inbox)
            try waitUntil { model.orderedItems(in: .inbox).filter { $0.kind == .image }.count == 2 }
            try check(successes == 2, "a saved image batch did not produce exactly one callback")

            let firstFile = directory.appendingPathComponent("first.txt")
            let secondFile = directory.appendingPathComponent("second.txt")
            try Data("first".utf8).write(to: firstFile)
            try Data("second".utf8).write(to: secondFile)
            model.importFiles([firstFile, secondFile])
            try waitUntil { !model.isImportingFiles }
            try check(model.orderedItems(in: .files).count == 2 && successes == 3,
                      "a saved file batch did not produce exactly one callback")

            model.setSuccessSoundEnabled(false)
            model.addText("关闭音效")
            try check(successes == 3, "disabled success sound still invoked its callback")
            model.setSuccessSoundEnabled(true)

            let failedStoreModel = BoardModel(store: LocalStore(paths: paths), monitorsClipboard: false)
            var failedSaveSuccesses = 0
            failedStoreModel.onCopySuccess = { failedSaveSuccesses += 1 }
            let previousItems = failedStoreModel.items
            try withBlockedWrite(at: paths.boardFile) {
                failedStoreModel.addText("不得保存")
                try check(failedStoreModel.items == previousItems,
                          "failed board save did not restore the pre-existing in-memory items")
                try check(failedSaveSuccesses == 0, "failed board save emitted success feedback")
            }
            try check(LocalStore(paths: paths).loadBoard().allSatisfy { $0.text != "不得保存" },
                      "failed board save appeared after the blocked path was restored")
        }
    }

    private static func testSameMillisecondFIFOAfterReorderAndReload() throws {
        try withTemporaryStore { _, paths, store in
            let sameMillisecond = Date(timeIntervalSince1970: 1_700_000_000.123)
            let firstArrival = BoardItem(
                kind: .text,
                category: .inbox,
                order: 0,
                createdAt: sameMillisecond,
                text: "同毫秒先到"
            )
            let secondArrival = BoardItem(
                kind: .text,
                category: .inbox,
                order: 1,
                createdAt: sameMillisecond,
                arrivalSequence: 0,
                text: "同毫秒后到"
            )
            try store.saveBoard([firstArrival, secondArrival])

            let model = BoardModel(store: store, monitorsClipboard: false)
            let sequencedFirst = try require(
                model.items.first(where: { $0.id == firstArrival.id })?.arrivalSequence,
                "legacy same-millisecond item did not receive an arrival sequence"
            )
            let sequencedSecond = try require(
                model.items.first(where: { $0.id == secondArrival.id })?.arrivalSequence,
                "second legacy item did not receive an arrival sequence"
            )
            try check(sequencedFirst < sequencedSecond,
                      "same-millisecond records were not sequenced in their original arrival order")
            try check(sequencedSecond == 0,
                      "initializing a missing same-millisecond sequence overwrote an existing sequence")
            try check(model.reorderText(secondArrival.id, relativeTo: firstArrival.id),
                      "manual reorder failed for same-millisecond records")

            let reloaded = BoardModel(store: LocalStore(paths: paths), monitorsClipboard: false)
            try check(reloaded.orderedItems(in: .inbox).map(\.id)
                          == [secondArrival.id, firstArrival.id],
                      "manual display order did not survive reload")
            try check(reloaded.items.first(where: { $0.id == firstArrival.id })?.arrivalSequence == sequencedFirst
                          && reloaded.items.first(where: { $0.id == secondArrival.id })?.arrivalSequence == sequencedSecond,
                      "reload changed same-millisecond arrival sequences")

            reloaded.setInboxItemLimit(2)
            reloaded.addText("同毫秒组之后到达")
            let survivingIDs = Set(reloaded.orderedItems(in: .inbox).map(\.id))
            try check(!survivingIDs.contains(firstArrival.id)
                          && survivingIDs.contains(secondArrival.id)
                          && reloaded.orderedItems(in: .inbox).contains(where: { $0.text == "同毫秒组之后到达" }),
                      "FIFO eviction followed manual order instead of the persisted arrival sequence")
        }
    }

    private static func testOverCapacityImageBatchKeepsOrderedSuffix() throws {
        try withTemporaryStore { directory, paths, store in
            let images = [
                try pngFixture(red: 0.12, green: 0.24, blue: 0.36),
                try pngFixture(red: 0.24, green: 0.36, blue: 0.48),
                try pngFixture(red: 0.36, green: 0.48, blue: 0.60),
                try pngFixture(red: 0.48, green: 0.60, blue: 0.72)
            ]
            let imageURLs = try images.enumerated().map { entry in
                let (index, imageData) = entry
                let url = directory.appendingPathComponent("batch-image-\(index).png")
                try imageData.write(to: url)
                return url
            }
            let model = BoardModel(store: store, monitorsClipboard: false)
            model.setInboxItemLimit(2)
            model.addImageFiles(imageURLs, to: .inbox)

            try waitUntil {
                let items = model.orderedItems(in: .inbox)
                return items.count == 2 && items.allSatisfy { $0.kind == .image }
            }
            try waitUntil {
                (try? FileManager.default.contentsOfDirectory(
                    at: paths.imagesDirectory,
                    includingPropertiesForKeys: nil
                ).count) == 2
            }

            let retainedData = try model.orderedItems(in: .inbox).map { item -> Data in
                let relativePath = try require(item.imageRelativePath, "retained batch image has no path")
                let url = try require(store.managedImageURL(relativePath: relativePath),
                                      "retained batch image path is not managed")
                return try Data(contentsOf: url)
            }
            try check(retainedData == Array(images.suffix(2)),
                      "over-capacity import did not retain the input suffix in input order")
        }
    }

    private static func testInboxCapacitySaveFailurePreservesImage() throws {
        try withTemporaryStore { directory, paths, store in
            let originalURL = directory.appendingPathComponent("capacity-failure-original.png")
            let imageData = try pngFixture()
            try imageData.write(to: originalURL)
            let imageID = UUID()
            let imagePath = try store.storeImageFile(originalURL, id: imageID)
            let image = BoardItem(
                id: imageID,
                kind: .image,
                category: .inbox,
                order: 0,
                createdAt: Date(timeIntervalSince1970: 100),
                imageRelativePath: imagePath
            )
            try store.saveBoard([image])

            let model = BoardModel(store: LocalStore(paths: paths), monitorsClipboard: false)
            model.setInboxItemLimit(1)
            let previousItems = model.items
            let storedImageURL = try require(store.managedImageURL(relativePath: imagePath),
                                             "missing managed image before failed capacity save")
            var successes = 0
            model.onCopySuccess = { successes += 1 }

            try withBlockedWrite(at: paths.boardFile) {
                model.addText("保存失败时不得淘汰图片")
                try check(model.items == previousItems,
                          "failed capacity save did not restore the original board")
                try check(FileManager.default.fileExists(atPath: storedImageURL.path),
                          "failed capacity save removed the managed image")
                try check(successes == 0,
                          "failed capacity save emitted success feedback")
            }

            pumpMainRunLoop(for: 0.2)
            try check(FileManager.default.fileExists(atPath: storedImageURL.path),
                      "failed capacity save asynchronously deleted the managed image")
            let storedImageAfterFailure = try Data(contentsOf: storedImageURL)
            try check(storedImageAfterFailure == imageData,
                      "failed capacity save asynchronously deleted or changed the managed image")
            try check(FileManager.default.fileExists(atPath: originalURL.path),
                      "failed capacity save deleted the external source image")
            let originalAfterFailure = try Data(contentsOf: originalURL)
            try check(originalAfterFailure == imageData,
                      "failed capacity save altered the external source image")
            try check(LocalStore(paths: paths).loadBoard().map(\.id) == [imageID],
                      "failed capacity save changed the persisted board after the blocker was removed")
        }
    }

    private static func testClipboardFeedbackWithoutSystemClipboard() throws {
        try withTemporaryStore { _, _, store in
            let model = BoardModel(store: store, monitorsClipboard: false)
            model.addText("剪贴板完整正文")
            let item = try require(model.orderedItems(in: .inbox).first, "missing clipboard fixture")
            var successes = 0
            model.onCopySuccess = { successes += 1 }

            let privatePasteboard = NSPasteboard.withUniqueName()
            defer { privatePasteboard.releaseGlobally() }
            try withGeneralPasteboardRedirected(to: privatePasteboard) {
                model.copyToClipboard(item)
            }
            try check(privatePasteboard.string(forType: .string) == "剪贴板完整正文",
                      "clipboard action did not write the full text to its isolated pasteboard")
            try check(successes == 1, "successful clipboard write did not signal exactly once")

            model.copyToClipboard(BoardItem(
                kind: .image,
                category: .inbox,
                order: 0,
                imageRelativePath: "images/missing.png"
            ))
            try check(successes == 1, "failed clipboard copy emitted success feedback")
        }
    }

    private static func testInboxCapacityFIFOAndUnlimitedMode() throws {
        try withTemporaryStore { directory, paths, store in
            let originalURL = directory.appendingPathComponent("external-original.png")
            let originalPNG = try pngFixture()
            try originalPNG.write(to: originalURL)
            let oldImageID = UUID()
            let oldImagePath = try store.storeImageFile(originalURL, id: oldImageID)
            let exportedImageURL = try store.exportImageForDrag(relativePath: oldImagePath)

            let pinned = BoardItem(
                kind: .text,
                category: .inbox,
                order: 0,
                createdAt: Date(timeIntervalSince1970: 100),
                text: "置顶旧项",
                isPinned: true
            )
            let newest = BoardItem(
                kind: .text,
                category: .inbox,
                order: 1,
                createdAt: Date(timeIntervalSince1970: 400),
                text: "较新但排在前面"
            )
            let middle = BoardItem(
                kind: .text,
                category: .inbox,
                order: 2,
                createdAt: Date(timeIntervalSince1970: 300),
                text: "中间日期"
            )
            let oldestImage = BoardItem(
                id: oldImageID,
                kind: .image,
                category: .inbox,
                order: 3,
                createdAt: Date(timeIntervalSince1970: 200),
                imageRelativePath: oldImagePath
            )
            try store.saveBoard([pinned, newest, middle, oldestImage])

            let model = BoardModel(store: store, monitorsClipboard: false)
            model.setInboxItemLimit(2)
            try check(model.orderedItems(in: .inbox).count == 4,
                      "changing capacity immediately removed existing records")
            let storedImageURL = try require(store.managedImageURL(relativePath: oldImagePath),
                                             "missing managed FIFO image")

            model.addText("触发容量淘汰")
            let trigger = try require(model.orderedItems(in: .inbox).first(where: { $0.text == "触发容量淘汰" }),
                                      "new item was not saved")
            try check(Set(model.orderedItems(in: .inbox).map(\.id)) == Set([pinned.id, newest.id, trigger.id]),
                      "capacity did not evict the two oldest unpinned records by createdAt")
            try check(FileManager.default.fileExists(atPath: originalURL.path),
                      "capacity eviction deleted the external image source")
            let originalAfterEviction = try Data(contentsOf: originalURL)
            try check(originalAfterEviction == originalPNG,
                      "capacity eviction altered or deleted the external image source")
            try waitUntil { !FileManager.default.fileExists(atPath: storedImageURL.path) }
            try check(FileManager.default.fileExists(atPath: exportedImageURL.path),
                      "capacity eviction deleted the exported image still used by other apps")
            let exportedImageData = try Data(contentsOf: exportedImageURL)
            try check(exportedImageData == originalPNG,
                      "capacity eviction changed the exported image copy")

            model.setInboxItemLimit(1)
            try check(model.orderedItems(in: .inbox).count == 3,
                      "lowering capacity immediately removed existing records")
            model.addText("第二次触发")
            let afterSecondInsert = model.orderedItems(in: .inbox)
            try check(afterSecondInsert.first(where: \.isPinned)?.id == pinned.id,
                      "pinned content was counted against capacity or evicted")
            try check(afterSecondInsert.filter { !$0.isPinned }.count == 1
                          && afterSecondInsert.contains(where: { $0.text == "第二次触发" }),
                      "capacity did not retain only the newest unpinned item")

            model.setInboxItemLimit(nil)
            model.addText("无限模式一")
            model.addText("无限模式二")
            try check(model.orderedItems(in: .inbox).filter { !$0.isPinned }.count == 3,
                      "unlimited mode evicted unpinned content")
            let reloaded = BoardModel(store: LocalStore(paths: paths), monitorsClipboard: false)
            try check(reloaded.settings.inboxItemLimit == nil
                          && reloaded.orderedItems(in: .inbox).count == model.orderedItems(in: .inbox).count,
                      "unlimited mode or surviving content did not persist")
        }
    }

    private static func testCategoryDeletionPreservesContentAndReloads() throws {
        try withTemporaryStore { _, paths, store in
            let categoryCreator = BoardModel(store: store, monitorsClipboard: false)
            let custom = try require(categoryCreator.addCategory(named: "自建分类"), "custom category creation failed")
            let imageData = try pngFixture()
            let imageID = UUID()
            let imagePath = try store.storeImageData(imageData, id: imageID)
            let fullText = String(repeating: "保留完整的文字与 Unicode 👨‍👩‍👧‍👦\n", count: 240)
            let referenceDate = Date(timeIntervalSince1970: 1_800_000_000)
            let fixtures = [
                BoardItem(id: UUID(), kind: .text, category: .customerOriginal, order: 0,
                          createdAt: referenceDate, text: fullText, isPinned: true, name: "人物资料"),
                BoardItem(id: UUID(), kind: .text, category: .reference, order: 0,
                          createdAt: referenceDate.addingTimeInterval(1), text: "场景正文", name: "场景名"),
                BoardItem(id: imageID, kind: .image, category: .prompt, order: 0,
                          createdAt: referenceDate.addingTimeInterval(2), imageRelativePath: imagePath,
                          isPinned: true, name: "原始图片"),
                BoardItem(id: UUID(), kind: .text, category: custom, order: 0,
                          createdAt: referenceDate.addingTimeInterval(3), text: fullText,
                          isPinned: true, name: "自建正文")
            ]
            try store.saveBoard(fixtures)

            let model = BoardModel(store: store, monitorsClipboard: false)
            let deletable = [BoardCategory.customerOriginal, .reference, .prompt, custom]
            for category in deletable {
                try check(model.canDeleteCategory(category), "category \(category.rawValue) was not deletable")
            }
            try check(!model.canDeleteCategory(.inbox) && !model.deleteCategory(.inbox),
                      "Inbox could be deleted")
            try check(!model.canDeleteCategory(.files) && !model.deleteCategory(.files),
                      "fixed file station could be deleted")

            model.selectCategory(custom)
            for category in deletable {
                model.selectCategory(category)
                try check(model.deleteCategory(category), "deletion failed for \(category.rawValue)")
            }
            try check(model.activeCategory == .inbox, "deleting the active category did not return to Inbox")
            try check(deletable.allSatisfy { !model.categories.contains($0) },
                      "a deleted category remained visible")
            try check(model.orderedItems(in: .inbox).count == fixtures.count,
                      "deleting categories dropped content")

            for original in fixtures {
                let moved = try require(model.items.first(where: { $0.id == original.id }),
                                        "deleted category lost item \(original.id)")
                try check(moved.category == .inbox && moved.id == original.id
                              && moved.kind == original.kind
                              && moved.createdAt == original.createdAt
                              && moved.isPinned == original.isPinned
                              && moved.name == original.name
                              && moved.text == original.text
                              && moved.imageRelativePath == original.imageRelativePath,
                          "deletion changed preserved fields for \(original.id)")
            }
            let storedImage = try require(store.managedImageURL(relativePath: imagePath), "missing managed image")
            let storedImageData = try Data(contentsOf: storedImage)
            try check(storedImageData == imageData,
                      "deleting an image category removed or changed its managed image")

            let firstReload = BoardModel(store: LocalStore(paths: paths), monitorsClipboard: false)
            try check(deletable.allSatisfy { !firstReload.categories.contains($0) },
                      "deleted categories reappeared after reload")
            try check(Set(firstReload.orderedItems(in: .inbox).map(\.id)) == Set(fixtures.map(\.id)),
                      "deleted-category items did not project to Inbox after reload")
            firstReload.addText("删除后正常保存")
            let secondReload = BoardModel(store: LocalStore(paths: paths), monitorsClipboard: false)
            try check(deletable.allSatisfy { !secondReload.categories.contains($0) }
                          && Set(secondReload.orderedItems(in: .inbox).map(\.id)).isSuperset(of: Set(fixtures.map(\.id))),
                      "a later board save caused deleted categories or their items to regress")
        }
    }

    private static func testCategoryDeletionSaveFailure() throws {
        try withTemporaryStore { _, paths, store in
            let creator = BoardModel(store: store, monitorsClipboard: false)
            let custom = try require(creator.addCategory(named: "保留分类"), "custom category creation failed")
            let item = BoardItem(kind: .text, category: custom, order: 0, text: "不能丢", isPinned: true, name: "保留名")
            try store.saveBoard([item])
            let model = BoardModel(store: LocalStore(paths: paths), monitorsClipboard: false)
            model.selectCategory(custom)

            try withBlockedWrite(at: paths.settingsFile) {
                try check(!model.deleteCategory(custom), "category deletion succeeded with an unwritable settings path")
                try check(model.settings.customCategories.contains(custom)
                              && !model.settings.deletedCategoryIDs.contains(custom.rawValue)
                              && model.categories.contains(custom),
                          "failed settings save left category state deleted")
                try check(model.activeCategory == custom
                              && model.orderedItems(in: custom).map(\.id) == [item.id],
                          "failed settings save moved or dropped the category's content")
            }

            let settings = LocalStore(paths: paths).loadSettings()
            let reloaded = BoardModel(store: LocalStore(paths: paths), monitorsClipboard: false)
            try check(settings.customCategories.contains(custom)
                          && !settings.deletedCategoryIDs.contains(custom.rawValue)
                          && reloaded.orderedItems(in: custom).map(\.id) == [item.id],
                      "failed deletion persisted after restoring the isolated settings path")
        }
    }

    private static func testImportFinishingAfterCategoryDeletion() throws {
        try withTemporaryStore { _, paths, store in
            let model = BoardModel(store: store, monitorsClipboard: false)
            let custom = try require(model.addCategory(named: "导入目标"), "custom import target creation failed")
            let imageData = try pngFixture()

            // The image work runs off-main; deleting synchronously before pumping the main run loop
            // makes its eventual commit observe the persisted deleted-category marker.
            model.addImageData(imageData, to: custom)
            try check(model.deleteCategory(custom), "target category deletion failed while import was pending")
            try waitUntil { model.orderedItems(in: .inbox).contains(where: { $0.kind == .image }) }
            let imported = try require(model.orderedItems(in: .inbox).first(where: { $0.kind == .image }),
                                       "in-flight image did not resolve to Inbox")
            try check(imported.category == .inbox && !model.categories.contains(custom),
                      "in-flight image resurrected its deleted target")

            let reloaded = BoardModel(store: LocalStore(paths: paths), monitorsClipboard: false)
            try check(reloaded.orderedItems(in: .inbox).map(\.id).contains(imported.id)
                          && !reloaded.categories.contains(custom),
                      "in-flight import routing did not survive reload")
        }
    }

    private static func testTextReorderingAndProvider() throws {
        try withTemporaryStore { _, paths, store in
            let fullText = String(repeating: "完整拖出正文 中文👨‍👩‍👧‍👦\n", count: 900)
            let first = BoardItem(kind: .text, category: .prompt, order: 2, text: "第一项")
            let second = BoardItem(kind: .text, category: .prompt, order: 3, text: "第二项")
            let third = BoardItem(kind: .text, category: .prompt, order: 4, text: fullText, name: "完整内容")
            let pinnedFirst = BoardItem(kind: .text, category: .prompt, order: 0, text: "置顶一", isPinned: true)
            let pinnedSecond = BoardItem(kind: .text, category: .prompt, order: 1, text: "置顶二", isPinned: true)
            let imagePath = try store.storeImageData(pngFixture(), id: UUID())
            let imageID = UUID(uuidString: URL(fileURLWithPath: imagePath).deletingPathExtension().lastPathComponent)
                ?? UUID()
            let image = BoardItem(id: imageID, kind: .image, category: .prompt, order: 5,
                                  imageRelativePath: imagePath)
            let crossCategory = BoardItem(kind: .text, category: .inbox, order: 0, text: "另一分类")
            try store.saveBoard([pinnedFirst, pinnedSecond, first, second, third, image, crossCategory])

            let model = BoardModel(store: store, monitorsClipboard: false)
            try check(model.reorderText(third.id, relativeTo: first.id), "text could not move upward")
            try check(Array(model.orderedItems(in: .prompt).filter { !$0.isPinned }.map(\.id).prefix(3))
                          == [third.id, first.id, second.id],
                      "upward text move did not land before the target")
            try check(model.reorderText(third.id, relativeTo: second.id, after: true),
                      "text could not move downward")
            try check(Array(model.orderedItems(in: .prompt).filter { !$0.isPinned }.map(\.id).prefix(3))
                          == [first.id, second.id, third.id],
                      "downward text move did not land after the target")
            try check(model.reorderText(second.id, relativeTo: image.id),
                      "text could not reorder relative to an image card")
            try check(model.reorderText(second.id, relativeTo: image.id, after: true),
                      "text could not move below an image card")
            try check(!model.reorderText(first.id, relativeTo: first.id), "self-drop was accepted")
            try check(!model.reorderText(first.id, relativeTo: crossCategory.id), "cross-category reorder was accepted")
            try check(!model.reorderText(first.id, relativeTo: pinnedFirst.id), "normal text crossed into the pinned partition")
            try check(!model.reorderText(pinnedFirst.id, relativeTo: first.id), "pinned text crossed into the normal partition")
            try check(!model.reorderText(image.id, relativeTo: first.id), "image was accepted as a text drag source")
            try check(model.reorderText(pinnedSecond.id, relativeTo: pinnedFirst.id),
                      "pinned text could not reorder within its own partition")

            let persistedOrder = model.orderedItems(in: .prompt).map(\.id)
            let reloaded = BoardModel(store: LocalStore(paths: paths), monitorsClipboard: false)
            try check(reloaded.orderedItems(in: .prompt).map(\.id) == persistedOrder,
                      "text reordering did not persist through reload")
            try check(model.activeCategory == .inbox, "reordering changed the single active category")

            let provider = reloaded.dragProvider(for: try require(
                reloaded.items.first(where: { $0.id == third.id }), "reloaded full-text item missing"
            ))
            try check(provider.canLoadObject(ofClass: NSString.self), "text drag lost its public NSString representation")
            try check(provider.suggestedName == "station-text-\(third.id.uuidString.lowercased())",
                      "text provider source identity is unstable")
            let publicText = try loadPublicText(provider)
            try check(publicText == fullText, "public text representation exported a preview instead of full text")
            let privateTextID = try loadDataRepresentation(
                provider,
                typeIdentifier: BoardModel.textItemDragType
            )
            try check(String(data: privateTextID, encoding: .utf8) == third.id.uuidString,
                      "private text drag representation did not contain the source UUID as UTF-8")
        }
    }

    private static func testTextReorderSaveFailure() throws {
        try withTemporaryStore { _, paths, store in
            let first = BoardItem(kind: .text, category: .reference, order: 0, text: "保留顺序一")
            let second = BoardItem(kind: .text, category: .reference, order: 1, text: "保留顺序二")
            try store.saveBoard([first, second])
            let model = BoardModel(store: LocalStore(paths: paths), monitorsClipboard: false)
            let before = model.orderedItems(in: .reference).map(\.id)
            try withBlockedWrite(at: paths.boardFile) {
                try check(!model.reorderText(second.id, relativeTo: first.id),
                          "reorder reported success after board save failed")
                try check(model.orderedItems(in: .reference).map(\.id) == before,
                          "failed reorder did not restore in-memory order")
            }
            try check(LocalStore(paths: paths).loadBoard().filter { $0.category == .reference }.map(\.id) == before,
                      "failed reorder changed persisted order after restoring the isolated board path")
        }
    }

    private static func withTemporaryStore(
        _ body: (URL, AppPaths, LocalStore) throws -> Void
    ) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("station-feature-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let paths = AppPaths(dataDirectory: directory.appendingPathComponent("data", isDirectory: true))
        try body(directory, paths, LocalStore(paths: paths))
    }

    private static func withBlockedWrite<Result>(at url: URL, body: () throws -> Result) throws -> Result {
        let fileManager = FileManager.default
        let original: Data? = fileManager.fileExists(atPath: url.path)
            ? try Data(contentsOf: url)
            : nil
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        try fileManager.createDirectory(at: url, withIntermediateDirectories: false)
        defer {
            try? fileManager.removeItem(at: url)
            if let original {
                try? original.write(to: url, options: .atomic)
            }
        }
        return try body()
    }

    private static func withGeneralPasteboardRedirected<Result>(
        to pasteboard: NSPasteboard,
        body: () throws -> Result
    ) throws -> Result {
        let selector = NSSelectorFromString("generalPasteboard")
        guard let method = class_getClassMethod(NSPasteboard.self, selector) else {
            throw FeatureTestFailure(description: "NSPasteboard general pasteboard method is unavailable")
        }
        let replacementBlock: @convention(block) (AnyObject) -> AnyObject = { _ in pasteboard }
        let replacement = imp_implementationWithBlock(replacementBlock)
        let previous = method_setImplementation(method, replacement)
        defer {
            _ = method_setImplementation(method, previous)
            _ = imp_removeBlock(replacement)
        }
        return try body()
    }

    private static func imageFixture() -> NSImage {
        NSImage(size: NSSize(width: 8, height: 8), flipped: false) { rect in
            NSColor.systemPurple.setFill()
            rect.fill()
            return true
        }
    }

    private static func pngFixture(
        red: CGFloat = 0.72,
        green: CGFloat = 0.18,
        blue: CGFloat = 0.43
    ) throws -> Data {
        guard let colorSpace = CGColorSpace(name: CGColorSpace.displayP3),
              let context = CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8,
                                      bytesPerRow: 32, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw FeatureTestFailure(description: "PNG fixture graphics context unavailable")
        }
        context.setFillColor(red: red, green: green, blue: blue, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        guard let rendered = context.makeImage() else {
            throw FeatureTestFailure(description: "PNG fixture image unavailable")
        }
        let bytes = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(bytes, UTType.png.identifier as CFString, 1, nil) else {
            throw FeatureTestFailure(description: "PNG fixture writer unavailable")
        }
        CGImageDestinationAddImage(destination, rendered, nil)
        try check(CGImageDestinationFinalize(destination), "PNG fixture could not be finalized")
        return bytes as Data
    }

    private static func loadPublicText(_ provider: NSItemProvider) throws -> String {
        var result: String?
        var failure: Error?
        var finished = false
        provider.loadObject(ofClass: NSString.self) { object, error in
            DispatchQueue.main.async {
                result = object as? String
                failure = error
                finished = true
            }
        }
        try waitUntil { finished }
        if let failure { throw failure }
        return try require(result, "public text provider returned no string")
    }

    private static func loadDataRepresentation(
        _ provider: NSItemProvider,
        typeIdentifier: String
    ) throws -> Data {
        var result: Data?
        var failure: Error?
        var finished = false
        provider.loadDataRepresentation(forTypeIdentifier: typeIdentifier) { data, error in
            DispatchQueue.main.async {
                result = data
                failure = error
                finished = true
            }
        }
        try waitUntil { finished }
        if let failure { throw failure }
        return try require(result, "private drag provider returned no data")
    }

    private static func pumpMainRunLoop(for duration: TimeInterval) {
        let deadline = Date().addingTimeInterval(duration)
        while Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
    }

    private static func waitUntil(timeout: TimeInterval = 8, _ predicate: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
        }
        try check(predicate(), "asynchronous feature operation timed out")
    }

    private static func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw FeatureTestFailure(description: message) }
    }

    private static func require<Value>(_ value: Value?, _ message: String) throws -> Value {
        guard let value else { throw FeatureTestFailure(description: message) }
        return value
    }
}
