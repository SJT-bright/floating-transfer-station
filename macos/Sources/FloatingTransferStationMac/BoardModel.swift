import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

final class BoardModel: ObservableObject {
    static let textItemDragType = "com.oiawlm.station.text-item"

    @Published private(set) var items: [BoardItem]
    @Published var activeCategory: BoardCategory
    let defaultCaptureCategory: BoardCategory = .inbox
    @Published private(set) var settings: WindowSettings
    @Published private(set) var statusText = ""
    @Published private(set) var isImportingFiles = false
    var onCopySuccess: (() -> Void)?

    private let store: LocalStore
    private let boardWritesBlocked: Bool
    private let boardLoadWarning: String?
    private var clipboardTimer: Timer?
    private var lastPasteboardChangeCount: Int
    private let fileImportQueue = DispatchQueue(label: "com.oiawlm.station.file-import", qos: .userInitiated)
    private var pendingFileImports = 0
    private var preparingExports = Set<String>()

    init(
        store: LocalStore = LocalStore(),
        monitorsClipboard: Bool = true
    ) {
        self.store = store
        let backupURL = URL(fileURLWithPath: store.paths.boardFile.path + ".bak")
        let hasPrimaryBoard = FileManager.default.fileExists(atPath: store.paths.boardFile.path)
        let loadWarning = hasPrimaryBoard
            ? BoardPersistenceSafety.warning(for: store.paths.boardFile)
            : BoardPersistenceSafety.warning(for: backupURL)
        boardWritesBlocked = loadWarning != nil
        boardLoadWarning = loadWarning
        let loadedSettings = store.loadSettings()
        settings = loadedSettings
        let loadedItems = Self.initializeArrivalSequences(store.loadBoard())
        items = Self.normalized(Self.projectDeletedCategories(
            loadedItems,
            deletedCategoryIDs: Set(loadedSettings.deletedCategoryIDs)
        ))
        activeCategory = .inbox
        lastPasteboardChangeCount = NSPasteboard.general.changeCount
        if let loadWarning {
            statusText = loadWarning
        }

        if monitorsClipboard {
            startClipboardMonitoring()
        }
    }

    deinit {
        clipboardTimer?.invalidate()
    }

    func displayName(for category: BoardCategory) -> String {
        category == .files ? category.defaultDisplayName : settings.displayName(for: category)
    }

    func orderedItems(in category: BoardCategory) -> [BoardItem] {
        items
            .filter { $0.category == category }
            .sorted(by: Self.displayOrder)
    }

    func selectCategory(_ category: BoardCategory) {
        activeCategory = isDeletedCategory(category) || !categories.contains(category)
            ? .inbox
            : category
    }

    func searchNamedItems(_ query: String) -> [BoardItem] {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return [] }
        return items.filter {
            guard let name = $0.name, !name.isEmpty else { return false }
            return name.localizedStandardContains(query)
        }.sorted(by: Self.displayOrder)
    }

    func renameItem(_ id: UUID, to rawName: String) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let name: String? = trimmed.isEmpty ? nil : trimmed
        guard items[index].name != name else { return }
        _ = persistMutation(failureMessage: "名称未保存，请重试。") {
            items[index].name = name
        }
    }

    var categories: [BoardCategory] {
        var seen = Set<BoardCategory>()
        return (BoardCategory.visibleCases + settings.customCategories + items.map(\.category))
            .filter { !isDeletedCategory($0) && seen.insert($0).inserted }
    }

    @discardableResult
    func addCategory(named rawName: String) -> BoardCategory? {
        let name = String(rawName.trimmingCharacters(in: .whitespacesAndNewlines).prefix(6))
        guard !name.isEmpty else { return nil }
        let category = BoardCategory(rawValue: "Custom-" + UUID().uuidString.lowercased())
        var updated = settings
        updated.customCategories.append(category)
        updated.categoryNames[category.rawValue] = name
        do {
            try store.saveSettings(updated)
            settings = updated
            activeCategory = category
            showStatus("已添加“\(name)”，自动收集仍进入待分类。")
            return category
        } catch {
            showStatus("分类未保存，请重试。")
            return nil
        }
    }

    func canDeleteCategory(_ category: BoardCategory) -> Bool {
        category != .inbox
            && category != .files
            && !isDeletedCategory(category)
            && categories.contains(category)
    }

    @discardableResult
    func deleteCategory(_ category: BoardCategory) -> Bool {
        guard canDeleteCategory(category) else { return false }

        let categoryName = displayName(for: category)
        var updated = settings
        if !updated.deletedCategoryIDs.contains(category.rawValue) {
            updated.deletedCategoryIDs.append(category.rawValue)
        }
        updated.customCategories.removeAll { $0 == category }
        updated.categoryNames.removeValue(forKey: category.rawValue)

        do {
            // This settings write is the category deletion's single commit point.
            // Existing board records are projected into Inbox on every load/save.
            try store.saveSettings(updated)
            settings = updated
            items = Self.normalized(Self.projectDeletedCategories(
                items,
                deletedCategoryIDs: Set(updated.deletedCategoryIDs)
            ))
            activeCategory = .inbox
            showStatus("已删除分类“\(categoryName)”，其中内容已移入待分类。")
            return true
        } catch {
            showStatus("分类未删除，请重试。")
            return false
        }
    }

    func setSuccessSoundEnabled(_ enabled: Bool) {
        guard settings.successSoundEnabled != enabled else { return }
        var updated = settings
        updated.successSoundEnabled = enabled
        do {
            try store.saveSettings(updated)
            settings = updated
        } catch {
            showStatus("成功音效设置未保存，请重试。")
        }
    }

    func setInboxItemLimit(_ limit: Int?) {
        if let limit, limit <= 0 { return }
        guard settings.inboxItemLimit != limit else { return }
        var updated = settings
        updated.inboxItemLimit = limit
        do {
            try store.saveSettings(updated)
            settings = updated
        } catch {
            showStatus("待分类容量未保存，请重试。")
        }
    }

    func captureCurrentClipboard() {
        capturePasteboard(force: true)
    }

    func addText(_ rawText: String, to category: BoardCategory? = nil) {
        guard category != .files else { return }
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return
        }

        let target = resolvedCategory(category ?? defaultCaptureCategory)
        let item = BoardItem(
            kind: .text,
            category: target,
            order: 0,
            text: rawText
        )
        guard let retained = persistNewItems([item], in: target, failureMessage: "本次文字未保存，请重试。"),
              retained.contains(where: { $0.id == item.id }) else {
            return
        }
        showStatus("已保存到“\(displayName(for: target))”。")
        notifyCopySuccessIfEnabled()
    }

    func addImageFiles(_ urls: [URL], to category: BoardCategory? = nil) {
        if category == .files { importFiles(urls); return }
        let target = resolvedCategory(category ?? defaultCaptureCategory)
        enqueueImageImport(in: target, failureMessage: "拖入图片无法读取，请换一张静态图片重试。") { store, paths in
            try urls.filter(\.isFileURL).map { url in
                let id = UUID()
                let relativePath = try store.storeImageFile(url, id: id)
                paths.append(relativePath)
                return BoardItem(
                    id: id,
                    kind: .image,
                    category: target,
                    order: 0,
                    imageRelativePath: relativePath
                )
            }
        }
    }

    func addImages(_ images: [NSImage], to category: BoardCategory? = nil) {
        guard category != .files else { return }
        let target = resolvedCategory(category ?? defaultCaptureCategory)
        enqueueImageImport(in: target, failureMessage: "图片无法转换为本地 PNG，请重试。") { store, paths in
            try images.map { image in
                let id = UUID()
                let relativePath = try store.storeImage(image, id: id)
                paths.append(relativePath)
                return BoardItem(
                    id: id,
                    kind: .image,
                    category: target,
                    order: 0,
                    imageRelativePath: relativePath
                )
            }
        }
    }

    func addImageData(_ imageData: Data, to category: BoardCategory? = nil) {
        guard category != .files else { return }
        let target = resolvedCategory(category ?? defaultCaptureCategory)
        enqueueImageImport(in: target, failureMessage: "图片无法转换为本地 PNG，请重试。") { store, paths in
            let id = UUID()
            let relativePath = try store.storeImageData(imageData, id: id)
            paths.append(relativePath)
            return [BoardItem(
                id: id,
                kind: .image,
                category: target,
                order: 0,
                imageRelativePath: relativePath
            )]
        }
    }

    func togglePinned(_ id: UUID) {
        guard var item = items.first(where: { $0.id == id }) else {
            return
        }
        let category = item.category

        _ = persistMutation(failureMessage: "置顶状态未保存，请重试。") {
            var categoryItems = orderedItems(in: category)
            categoryItems.removeAll { $0.id == id }
            item.isPinned.toggle()
            let insertionIndex = item.isPinned
                ? 0
                : categoryItems.firstIndex(where: { !$0.isPinned }) ?? categoryItems.count
            categoryItems.insert(item, at: insertionIndex)
            replaceCategory(category, with: categoryItems)
        }
    }

    func move(_ id: UUID, to targetCategory: BoardCategory) {
        guard var item = items.first(where: { $0.id == id }),
              item.kind != .file, targetCategory != .files,
              !isDeletedCategory(targetCategory),
              item.category != targetCategory
        else {
            if isDeletedCategory(targetCategory) {
                showStatus("目标分类已删除，请重新选择分类。")
            }
            return
        }
        let sourceCategory = item.category
        var evicted: [BoardItem] = []

        if persistMutation(failureMessage: "移动未保存，请重试。", {
            var sourceItems = orderedItems(in: sourceCategory)
            sourceItems.removeAll { $0.id == id }
            replaceCategory(sourceCategory, with: sourceItems)

            item.category = targetCategory
            var targetItems = orderedItems(in: targetCategory)
            let insertionIndex = item.isPinned
                ? 0
                : targetItems.firstIndex(where: { !$0.isPinned }) ?? targetItems.count
            targetItems.insert(item, at: insertionIndex)
            replaceCategory(targetCategory, with: targetItems)
            if targetCategory == .inbox {
                evicted = enforceInboxItemLimit()
            }
        }) {
            cleanUpEvictedImages(evicted)
        }
    }

    @discardableResult
    func reorderText(_ sourceID: UUID, relativeTo targetID: UUID, after: Bool = false) -> Bool {
        guard sourceID != targetID,
              let source = items.first(where: { $0.id == sourceID }),
              source.kind == .text,
              let target = items.first(where: { $0.id == targetID }),
              source.category == target.category,
              source.isPinned == target.isPinned
        else {
            return false
        }

        return persistMutation(failureMessage: "文字顺序未保存，请重试。") {
            var categoryItems = orderedItems(in: source.category)
            guard let sourceIndex = categoryItems.firstIndex(where: { $0.id == sourceID }) else { return }
            categoryItems.remove(at: sourceIndex)
            guard let targetIndex = categoryItems.firstIndex(where: { $0.id == targetID }) else { return }
            categoryItems.insert(source, at: targetIndex + (after ? 1 : 0))
            replaceCategory(source.category, with: categoryItems)
        }
    }

    func reportTextReorderFailure() {
        showStatus("文字排序未完成，请重新拖动。")
    }

    @discardableResult
    func copyImage(_ id: UUID, to targetCategory: BoardCategory) -> Bool {
        let resolvedTarget = resolvedCategory(targetCategory)
        guard let source = items.first(where: { $0.id == id }),
              targetCategory != .files,
              source.kind == .image,
              source.category != resolvedTarget,
              let relativePath = source.imageRelativePath,
              let sourceURL = store.managedImageURL(relativePath: relativePath)
        else {
            return false
        }

        let copyID = UUID()
        let copiedRelativePath: String
        do {
            copiedRelativePath = try store.storeImageFile(sourceURL, id: copyID)
        } catch {
            showStatus("图片复制失败，请重试。")
            return false
        }

        let copiedItem = BoardItem(
            id: copyID,
            kind: .image,
            category: resolvedTarget,
            order: 0,
            imageRelativePath: copiedRelativePath,
            name: source.name
        )
        guard let retained = persistNewItems(
            [copiedItem],
            in: resolvedTarget,
            failureMessage: "图片复制未保存，请重试。"
        ) else {
            _ = store.deleteManagedImage(relativePath: copiedRelativePath)
            return false
        }
        guard retained.contains(where: { $0.id == copyID }) else { return false }

        showStatus("已复制到“\(displayName(for: resolvedTarget))”")
        notifyCopySuccessIfEnabled()
        return true
    }

    func delete(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else {
            return
        }

        if persistMutation(failureMessage: "删除未保存，请重试。", {
            items.removeAll { $0.id == id }
        }) {
            let imageRemoved = item.kind != .image || store.deleteManagedImage(relativePath: item.imageRelativePath)
            let fileRemoved = item.kind != .file || store.deleteManagedFile(relativePath: item.fileRelativePath)
            if !imageRemoved || !fileRemoved {
                showStatus("内容已从看板删除，但站内副本未能清理。")
            }
        }
    }

    func clearActiveCategory() {
        let category = activeCategory
        let removed = orderedItems(in: category).filter { !$0.isPinned }
        guard !removed.isEmpty else {
            return
        }

        if persistMutation(failureMessage: "清空未保存，请重试。", {
            items.removeAll { $0.category == category && !$0.isPinned }
        }) {
            let imageCleanupFailed = removed
                .filter { $0.kind == .image }
                .contains { !store.deleteManagedImage(relativePath: $0.imageRelativePath) }
            let fileCleanupFailed = removed
                .filter { $0.kind == .file }
                .contains { !store.deleteManagedFile(relativePath: $0.fileRelativePath) }
            if imageCleanupFailed || fileCleanupFailed {
                showStatus("分类已清空，但部分站内副本未能清理。")
            }
        }
    }

    func copyToClipboard(_ item: BoardItem) {
        if item.kind == .file {
            guard let url = readyFileExport(for: item) else { return }
            writeToClipboard(url as NSURL, successMessage: "已复制文件，可粘贴到其他应用。")
            return
        }

        switch item.kind {
        case .file:
            return
        case .text:
            guard let text = item.text else {
                return
            }
            writeToClipboard(text as NSString, successMessage: "已复制，可粘贴到其他应用。")
        case .image:
            guard let relativePath = item.imageRelativePath,
                  let url = store.managedImageURL(relativePath: relativePath),
                  let image = NSImage(contentsOf: url)
            else {
                showStatus("图片文件已经不存在。")
                return
            }
            writeToClipboard(image, successMessage: "已复制，可粘贴到其他应用。")
        }
    }

    private func writeToClipboard(_ object: NSPasteboardWriting, successMessage: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.writeObjects([object]) else {
            lastPasteboardChangeCount = pasteboard.changeCount
            showStatus("复制失败，请重试；本次未能写入系统剪贴板。")
            return
        }
        lastPasteboardChangeCount = pasteboard.changeCount
        showStatus(successMessage)
        notifyCopySuccessIfEnabled()
    }

    func dragProvider(for item: BoardItem, imageData: Data? = nil) -> NSItemProvider {
        switch item.kind {
        case .file:
            guard let url = readyFileExport(for: item) else { return NSItemProvider() }
            let provider = NSItemProvider(object: url as NSURL)
            provider.suggestedName = item.fileName ?? url.lastPathComponent
            return provider
        case .text:
            let provider = NSItemProvider(object: (item.text ?? "") as NSString)
            provider.suggestedName = "station-text-\(item.id.uuidString.lowercased())"
            provider.registerDataRepresentation(
                forTypeIdentifier: Self.textItemDragType,
                visibility: .ownProcess
            ) { completion in
                completion(Data(item.id.uuidString.utf8), nil)
                return nil
            }
            return provider
        case .image:
            guard let relativePath = item.imageRelativePath,
                  let managedURL = store.managedImageURL(relativePath: relativePath)
            else {
                return NSItemProvider()
            }

            do {
                // Every representation is bound to the same rendered PNG snapshot.
                let bytes = try imageData ?? Data(contentsOf: managedURL)
                guard NSBitmapImageRep(data: bytes) != nil else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                let exportURL = try store.exportImageForDrag(relativePath: relativePath, imageData: bytes)
                let provider = NSItemProvider(object: exportURL as NSURL)
                provider.suggestedName = exportURL.deletingPathExtension().lastPathComponent
                provider.registerDataRepresentation(forTypeIdentifier: UTType.png.identifier, visibility: .all) { completion in
                    completion(bytes, nil)
                    return nil
                }
                provider.registerFileRepresentation(forTypeIdentifier: UTType.png.identifier, fileOptions: [], visibility: .all) { completion in
                    completion(exportURL, false, nil)
                    return nil
                }
                return provider
            } catch {
                showStatus("图片导出副本创建失败，请重试。")
                return NSItemProvider()
            }
        }
    }

    func draggedImageID(from provider: NSItemProvider) -> UUID? {
        guard let suggestedName = provider.suggestedName else {
            return nil
        }
        return draggedImageID(fromFileName: suggestedName)
    }

    @discardableResult
    func copyDraggedImage(from pasteboard: NSPasteboard, to targetCategory: BoardCategory) -> Bool {
        // SwiftUI's bridged provider can advertise file-url but fail to load it.
        // Read the URL while the native drag pasteboard is still valid at mouse-up.
        guard let rawURL = pasteboard.string(forType: .fileURL),
              let url = URL(string: rawURL),
              url.isFileURL,
              let id = draggedImageID(fromFileName: url.lastPathComponent),
              let source = items.first(where: { $0.id == id })
        else {
            showStatus("无法识别这张拖动图片，请重试。")
            return false
        }
        guard let relativePath = source.imageRelativePath,
              store.isImageDragURL(url, relativePath: relativePath) else {
            showStatus("请从中转站内拖动图片到其他分类。")
            return false
        }
        return copyImage(id, to: targetCategory)
    }

    private func draggedImageID(fromFileName fileName: String) -> UUID? {
        let nameWithoutExtension = URL(fileURLWithPath: fileName)
            .deletingPathExtension()
            .lastPathComponent
        guard let id = UUID(uuidString: nameWithoutExtension),
              items.contains(where: { $0.id == id && $0.kind == .image })
        else {
            return nil
        }
        return id
    }

    func imageURL(for item: BoardItem) -> URL? {
        guard let relativePath = item.imageRelativePath else {
            return nil
        }
        return store.managedImageURL(relativePath: relativePath)
    }

    func fileURL(for item: BoardItem) -> URL? {
        guard item.kind == .file, let path = item.fileRelativePath else { return nil }
        return store.managedFileURL(relativePath: path)
    }

    func importFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        pendingFileImports += 1
        isImportingFiles = true
        showStatus("正在复制文件到中转站…")
        let store = self.store
        fileImportQueue.async { [self] in
            var imported: [BoardItem] = []
            var failed = false
            for url in urls {
                let id = UUID()
                var path: String?
                do {
                    let stored = try store.storeFile(url, id: id)
                    path = stored.relativePath
                    _ = try store.exportFileForDrag(relativePath: stored.relativePath)
                    imported.append(BoardItem(id: id, kind: .file, category: .files, order: 0,
                                              fileRelativePath: stored.relativePath,
                                              fileName: stored.name, fileSize: stored.size))
                } catch {
                    if let path { store.discardUnpublishedFile(relativePath: path) }
                    failed = true
                }
            }
            let results = imported
            let hadFailures = failed
            DispatchQueue.main.async {
                guard !results.isEmpty else {
                    self.completeFileImport()
                    self.showStatus("导入失败：请选择可读取的普通文件；暂不支持文件夹或快捷链接。")
                    return
                }
                if self.persistMutation(failureMessage: "文件未保存，请重试。", {
                    self.insertAtTopOfNormalRegion(self.assignArrivalSequences(to: results), in: .files)
                }) {
                    self.completeFileImport()
                    self.showStatus(hadFailures
                        ? "已导入 \(results.count) 个文件；部分文件无法读取，文件夹和链接不支持。"
                        : "已导入 \(results.count) 个文件，原文件不变。")
                    self.notifyCopySuccessIfEnabled()
                } else {
                    self.fileImportQueue.async {
                        results.forEach {
                            if let path = $0.fileRelativePath { store.discardUnpublishedFile(relativePath: path) }
                        }
                        DispatchQueue.main.async { self.completeFileImport() }
                    }
                }
            }
        }
    }

    private func completeFileImport() {
        pendingFileImports -= 1
        isImportingFiles = pendingFileImports > 0
    }

    private func readyFileExport(for item: BoardItem) -> URL? {
        guard let path = item.fileRelativePath, fileURL(for: item) != nil else {
            showStatus("文件已经不存在。")
            return nil
        }
        if let url = store.existingFileExport(relativePath: path) { return url }
        showStatus("正在准备文件副本，完成后请再次拖动或复制。")
        guard preparingExports.insert(path).inserted else { return nil }
        fileImportQueue.async { [self] in
            let result = Result { try self.store.exportFileForDrag(relativePath: path) }
            DispatchQueue.main.async {
                self.preparingExports.remove(path)
                switch result {
                case .success: self.showStatus("文件已准备好，请再次拖动或复制。")
                case .failure: self.showStatus("文件导出失败，请检查文件是否存在及磁盘空间。")
                }
            }
        }
        return nil
    }

    func renameCategory(_ category: BoardCategory, to rawName: String) {
        guard category != .files, !isDeletedCategory(category) else { return }
        let name = String(rawName.prefix(6))
        let previous = settings
        settings.categoryNames[category.rawValue] = name
        do {
            try store.saveSettings(settings)
        } catch {
            settings = previous
            showStatus("分类名称未保存，请重试。")
        }
    }

    func updateAppearance(_ appearance: PanelAppearance?) {
        var updated = settings
        updated.appearance = appearance?.normalized
        guard updated != settings else { return }
        do {
            try store.saveSettings(updated)
            settings = updated
        } catch {
            showStatus("外观设置未保存，请重试。")
        }
    }

    func updateWindowSettings(panelWidth: Double, height: Double, top: Double, origin: NSPoint? = nil) {
        var updated = settings
        updated.panelWidth = min(max(panelWidth, 280), 640)
        updated.windowHeight = max(height, 360)
        updated.top = max(top, 0)
        if let origin {
            updated.windowX = origin.x
            updated.windowY = origin.y
        }
        // AppKit may repeat move/resize notifications during layout. Publishing
        // each field separately used to invalidate every card, even unchanged.
        guard updated != settings else { return }
        do {
            try store.saveSettings(updated)
            settings = updated
        } catch {
            showStatus("窗口位置未保存，请重试。")
        }
    }

    func importProviders(_ providers: [NSItemProvider], to category: BoardCategory) {
        let group = DispatchGroup()
        let lock = NSLock()
        var fileURLs: [(Int, URL)] = []
        var images: [(Int, NSImage)] = []
        var texts: [(Int, String)] = []

        for (index, provider) in providers.enumerated() {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                group.enter()
                provider.loadItem(
                    forTypeIdentifier: UTType.fileURL.identifier,
                    options: nil
                ) { item, _ in
                    let url: URL?
                    if let value = item as? URL {
                        url = value
                    } else if let value = item as? NSURL {
                        url = value as URL
                    } else if let data = item as? Data,
                              let value = String(data: data, encoding: .utf8) {
                        url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines))
                    } else {
                        url = nil
                    }
                    if let url, url.isFileURL {
                        lock.lock()
                        fileURLs.append((index, url))
                        lock.unlock()
                    }
                    group.leave()
                }
                continue
            }

            if category == .files { continue }

            if provider.canLoadObject(ofClass: NSImage.self) {
                group.enter()
                provider.loadObject(ofClass: NSImage.self) { object, _ in
                    if let image = object as? NSImage {
                        lock.lock()
                        images.append((index, image))
                        lock.unlock()
                    }
                    group.leave()
                }
                continue
            }

            if provider.canLoadObject(ofClass: NSString.self) {
                group.enter()
                provider.loadObject(ofClass: NSString.self) { object, _ in
                    if let text = object as? String {
                        lock.lock()
                        texts.append((index, text))
                        lock.unlock()
                    }
                    group.leave()
                }
            }
        }

        group.notify(queue: .main) { [weak self] in
            guard let self else {
                return
            }
            let orderedFiles = fileURLs.sorted { $0.0 < $1.0 }.map(\.1)
            let orderedImages = images.sorted { $0.0 < $1.0 }.map(\.1)
            if category == .files {
                if orderedFiles.isEmpty {
                    self.showStatus("请从访达拖入文件，或点击“导入文件”。")
                } else {
                    self.importFiles(orderedFiles)
                }
            } else if !orderedFiles.isEmpty {
                self.addImageFiles(orderedFiles, to: category)
            } else if !orderedImages.isEmpty {
                self.addImages(orderedImages, to: category)
            } else if let text = texts.sorted(by: { $0.0 < $1.0 }).first?.1 {
                self.addText(text, to: category)
            } else {
                self.showStatus("这次拖入的内容不是可用图片或文字。")
            }
        }
    }

    private func startClipboardMonitoring() {
        let timer = Timer(timeInterval: 0.45, repeats: true) { [weak self] _ in
            self?.capturePasteboard(force: false)
        }
        RunLoop.main.add(timer, forMode: .common)
        clipboardTimer = timer
    }

    func capturePasteboard(_ pasteboard: NSPasteboard = .general, force: Bool) {
        guard force || pasteboard.changeCount != lastPasteboardChangeCount else {
            return
        }
        lastPasteboardChangeCount = pasteboard.changeCount
        let targetCategory = defaultCaptureCategory

        let objects = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) ?? []
        let fileURLs = objects.compactMap { ($0 as? NSURL) as URL? }
        if !fileURLs.isEmpty {
            let imageURLs = fileURLs.filter(Self.isSupportedImageFile)
            if !imageURLs.isEmpty {
                addImageFiles(imageURLs, to: targetCategory)
            }
            return
        }

        if let imageData = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff) {
            addImageData(imageData, to: targetCategory)
            return
        }

        if let image = NSImage(pasteboard: pasteboard) {
            addImages([image], to: targetCategory)
            return
        }

        if let text = pasteboard.string(forType: .string),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            addText(text, to: targetCategory)
        }
    }

    private func persistMutation(
        failureMessage: String,
        _ mutation: () -> Void
    ) -> Bool {
        guard !boardWritesBlocked else {
            showStatus(boardLoadWarning ?? "看板数据已保护，当前无法保存修改。")
            return false
        }
        let previous = items
        mutation()
        items = Self.projectDeletedCategories(items, deletedCategoryIDs: Set(settings.deletedCategoryIDs))
        items = Self.normalized(items)
        do {
            try store.saveBoard(items)
            return true
        } catch {
            items = previous
            showStatus(failureMessage)
            return false
        }
    }

    private func persistNewItems(
        _ newItems: [BoardItem],
        in requestedCategory: BoardCategory,
        failureMessage: String
    ) -> [BoardItem]? {
        guard !boardWritesBlocked else {
            showStatus(boardLoadWarning ?? "看板数据已保护，当前无法保存修改。")
            return nil
        }

        let previous = items
        let category = resolvedCategory(requestedCategory)
        let inserted = assignArrivalSequences(to: newItems).map { item -> BoardItem in
            var result = item
            result.category = category
            return result
        }
        insertAtTopOfNormalRegion(inserted, in: category)
        items = Self.projectDeletedCategories(items, deletedCategoryIDs: Set(settings.deletedCategoryIDs))
        items = Self.normalized(items)
        let evicted = category == .inbox ? enforceInboxItemLimit() : []
        items = Self.normalized(items)

        do {
            try store.saveBoard(items)
        } catch {
            items = previous
            showStatus(failureMessage)
            return nil
        }

        cleanUpEvictedImages(evicted)
        let retainedIDs = Set(items.map(\.id))
        return inserted.filter { retainedIDs.contains($0.id) }
    }

    private func enqueueImageImport(
        in category: BoardCategory,
        failureMessage: String,
        work: @escaping (LocalStore, inout [String]) throws -> [BoardItem]
    ) {
        let store = self.store
        let queue = fileImportQueue
        showStatus("正在处理图片…")
        queue.async { [weak self] in
            var paths: [String] = []
            let importedItems: [BoardItem]
            do {
                importedItems = try work(store, &paths)
            } catch {
                let cleanupFailed = paths.contains { !store.deleteManagedImage(relativePath: $0) }
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.showStatus(cleanupFailed
                        ? "\(failureMessage) 部分临时副本未能清理。"
                        : failureMessage)
                }
                return
            }

            DispatchQueue.main.async { [weak self] in
                guard let self else {
                    queue.async {
                        paths.forEach { _ = store.deleteManagedImage(relativePath: $0) }
                    }
                    return
                }
                guard !importedItems.isEmpty else {
                    self.showStatus("没有找到可用的图片。")
                    return
                }
                if let retained = self.persistNewItems(
                    importedItems,
                    in: category,
                    failureMessage: "图片未保存，请重试。"
                ) {
                    if !retained.isEmpty {
                        self.showStatus("已添加 \(retained.count) 张图片。")
                        self.notifyCopySuccessIfEnabled()
                    }
                    return
                }
                queue.async {
                    paths.forEach { _ = store.deleteManagedImage(relativePath: $0) }
                }
            }
        }
    }

    private func insertAtTopOfNormalRegion(
        _ newItems: [BoardItem],
        in category: BoardCategory
    ) {
        var categoryItems = orderedItems(in: category)
        let insertionIndex = categoryItems.firstIndex(where: { !$0.isPinned })
            ?? categoryItems.count
        categoryItems.insert(contentsOf: newItems, at: insertionIndex)
        replaceCategory(category, with: categoryItems)
    }

    private func enforceInboxItemLimit() -> [BoardItem] {
        guard let limit = settings.inboxItemLimit else { return [] }
        let unpinned = items.filter { $0.category == .inbox && !$0.isPinned }
        let excessCount = unpinned.count - limit
        guard excessCount > 0 else { return [] }

        let evicted = Array(unpinned.sorted { left, right in
            if left.createdAt != right.createdAt {
                return left.createdAt < right.createdAt
            }
            guard let leftSequence = left.arrivalSequence,
                  let rightSequence = right.arrivalSequence else {
                return left.arrivalSequence == nil && right.arrivalSequence != nil
            }
            return leftSequence < rightSequence
        }.prefix(excessCount))
        let evictedIDs = Set(evicted.map(\.id))
        items.removeAll { evictedIDs.contains($0.id) }
        return evicted
    }

    private func cleanUpEvictedImages(_ evicted: [BoardItem]) {
        let images = evicted.filter { $0.kind == .image }
        guard !images.isEmpty else { return }

        let imagePaths = images.compactMap(\.imageRelativePath)
        let hasMissingPath = imagePaths.count != images.count
        let store = self.store
        fileImportQueue.async { [weak self] in
            var failed = hasMissingPath
            for relativePath in imagePaths where !store.deleteManagedImage(relativePath: relativePath) {
                failed = true
            }
            guard failed else { return }
            DispatchQueue.main.async { [weak self] in
                self?.reportEvictedImageCleanupFailure()
            }
        }
    }

    private func replaceCategory(_ category: BoardCategory, with replacements: [BoardItem]) {
        items.removeAll { $0.category == category }
        items.append(contentsOf: replacements.enumerated().map { index, item in
            var replacement = item
            replacement.category = category
            replacement.order = index
            return replacement
        })
    }

    private func isDeletedCategory(_ category: BoardCategory) -> Bool {
        category != .inbox
            && category != .files
            && settings.deletedCategoryIDs.contains(category.rawValue)
    }

    private func resolvedCategory(_ category: BoardCategory) -> BoardCategory {
        isDeletedCategory(category) ? .inbox : category
    }

    private func assignArrivalSequences(to newItems: [BoardItem]) -> [BoardItem] {
        var sequencesByTimestamp: [Int64: Set<Int64>] = [:]
        for item in items {
            guard let sequence = item.arrivalSequence else { continue }
            let timestamp = Self.persistenceMillisecondKey(item.createdAt)
            sequencesByTimestamp[timestamp, default: []].insert(sequence)
        }
        for item in newItems {
            guard let sequence = item.arrivalSequence else { continue }
            let timestamp = Self.persistenceMillisecondKey(item.createdAt)
            sequencesByTimestamp[timestamp, default: []].insert(sequence)
        }

        return newItems.map { item in
            var result = item
            let timestamp = Self.persistenceMillisecondKey(item.createdAt)
            result.createdAt = Self.dateAtPersistenceMillisecondIfRepresentable(timestamp, from: item.createdAt)
            if result.arrivalSequence == nil {
                var usedSequences = sequencesByTimestamp[timestamp, default: []]
                result.arrivalSequence = Self.nextArrivalSequence(in: &usedSequences)
                sequencesByTimestamp[timestamp] = usedSequences
            }
            return result
        }
    }

    private static func nextArrivalSequence(in usedSequences: inout Set<Int64>) -> Int64 {
        if usedSequences.isEmpty {
            usedSequences.insert(0)
            return 0
        }
        if let highest = usedSequences.max(), highest < Int64.max {
            let next = highest + 1
            usedSequences.insert(next)
            return next
        }

        var candidate = Int64.min
        while usedSequences.contains(candidate) {
            guard candidate < Int64.max else { return Int64.max }
            candidate += 1
        }
        usedSequences.insert(candidate)
        return candidate
    }

    private func notifyCopySuccessIfEnabled() {
        guard settings.successSoundEnabled else { return }
        onCopySuccess?()
    }

    private func reportEvictedImageCleanupFailure() {
        let warning = "待分类容量已更新，但部分已淘汰图片副本未能清理。"
        let existing = statusText
        if ["失败", "未保存", "无法", "请重试", "未能"].contains(where: { existing.contains($0) }) {
            return
        }
        showStatus(existing.isEmpty ? warning : "\(existing)；\(warning)")
    }

    private func showStatus(_ message: String) {
        statusText = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            if self?.statusText == message {
                self?.statusText = ""
            }
        }
    }

    private static func normalized(_ source: [BoardItem]) -> [BoardItem] {
        var seen = Set<BoardCategory>()
        let categories = (BoardCategory.visibleCases + source.map(\.category))
            .filter { seen.insert($0).inserted }
        return categories.flatMap { category in
            source
                .filter { $0.category == category }
                .sorted(by: displayOrder)
                .enumerated()
                .map { index, item in
                    var result = item
                    result.order = index
                    return result
                }
        }
    }

    private static func initializeArrivalSequences(_ source: [BoardItem]) -> [BoardItem] {
        var result = source
        var groupedIndices: [Int64: [Int]] = [:]
        for (index, item) in source.enumerated() {
            groupedIndices[persistenceMillisecondKey(item.createdAt), default: []].append(index)
        }

        let orderedCategories = (BoardCategory.visibleCases + source.map(\.category))
        var categoryRanks: [BoardCategory: Int] = [:]
        for category in orderedCategories where categoryRanks[category] == nil {
            categoryRanks[category] = categoryRanks.count
        }

        for indices in groupedIndices.values {
            let missingIndices = indices.filter { result[$0].arrivalSequence == nil }
            guard !missingIndices.isEmpty else { continue }
            let orderedIndices = indices.sorted { leftIndex, rightIndex in
                let left = source[leftIndex]
                let right = source[rightIndex]
                let leftRank = categoryRanks[left.category] ?? Int.max
                let rightRank = categoryRanks[right.category] ?? Int.max
                if leftRank != rightRank { return leftRank < rightRank }
                if left.order != right.order { return left.order < right.order }
                return leftIndex < rightIndex
            }

            // Legacy records predate this field. Assign them stable values before
            // the oldest existing sequence, preserving every sequence already on disk.
            let existingSequences = Set(indices.compactMap { result[$0].arrivalSequence })
            var usedSequences = existingSequences
            let lowerBoundary = usedSequences.min() ?? 0
            var previousBoundary = lowerBoundary
            var precedingAssignments: [(index: Int, sequence: Int64)] = []
            for index in orderedIndices.reversed() where result[index].arrivalSequence == nil {
                guard let sequence = previousArrivalSequence(before: previousBoundary, used: usedSequences) else {
                    break
                }
                precedingAssignments.append((index, sequence))
                usedSequences.insert(sequence)
                previousBoundary = sequence
            }

            if precedingAssignments.count == missingIndices.count {
                for assignment in precedingAssignments {
                    result[assignment.index].arrivalSequence = assignment.sequence
                }
            } else {
                // The lower Int64 boundary may leave no room before existing values.
                // In that rare case, allocate a fresh increasing run without changing
                // any sequence that was already persisted.
                usedSequences = existingSequences
                let orderedMissingIndices = orderedIndices.filter { result[$0].arrivalSequence == nil }
                for index in orderedMissingIndices {
                    result[index].arrivalSequence = nextArrivalSequence(in: &usedSequences)
                }
            }
        }
        return result
    }

    private static func previousArrivalSequence(
        before boundary: Int64,
        used: Set<Int64>
    ) -> Int64? {
        var candidate = boundary
        while candidate > Int64.min {
            candidate -= 1
            if !used.contains(candidate) { return candidate }
        }
        return nil
    }

    private static func persistenceMillisecondKey(_ date: Date) -> Int64 {
        let milliseconds = (date.timeIntervalSince1970 * 1_000).rounded()
        if milliseconds.isNaN { return 0 }
        if milliseconds >= Double(Int64.max) { return .max }
        if milliseconds <= Double(Int64.min) { return .min }
        return Int64(milliseconds)
    }

    private static func dateAtPersistenceMillisecondIfRepresentable(
        _ timestamp: Int64,
        from originalDate: Date
    ) -> Date {
        let milliseconds = (originalDate.timeIntervalSince1970 * 1_000).rounded()
        guard milliseconds.isFinite,
              milliseconds > Double(Int64.min),
              milliseconds < Double(Int64.max) else {
            return originalDate
        }
        return date(atPersistenceMillisecond: timestamp)
    }

    private static func date(atPersistenceMillisecond timestamp: Int64) -> Date {
        Date(timeIntervalSince1970: Double(timestamp) / 1_000)
    }

    private static func projectDeletedCategories(
        _ source: [BoardItem],
        deletedCategoryIDs: Set<String>
    ) -> [BoardItem] {
        let hiddenIDs = deletedCategoryIDs.subtracting(Set([
            BoardCategory.inbox.rawValue,
            BoardCategory.files.rawValue
        ]))
        return source.map { item in
            guard item.kind != .file, hiddenIDs.contains(item.category.rawValue) else { return item }
            var projected = item
            projected.category = .inbox
            return projected
        }
    }

    private static func displayOrder(_ left: BoardItem, _ right: BoardItem) -> Bool {
        if left.isPinned != right.isPinned {
            return left.isPinned
        }
        if left.order != right.order {
            return left.order < right.order
        }
        return left.createdAt > right.createdAt
    }

    private static func isSupportedImageFile(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else {
            return false
        }
        return type.conforms(to: .image)
    }
}
