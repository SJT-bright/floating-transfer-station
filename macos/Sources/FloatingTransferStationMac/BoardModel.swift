import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers

final class BoardModel: ObservableObject {
    @Published private(set) var items: [BoardItem]
    @Published var activeCategory: BoardCategory
    @Published var defaultCaptureCategory: BoardCategory
    @Published private(set) var settings: WindowSettings
    @Published private(set) var statusText = ""

    private let store: LocalStore
    private var clipboardTimer: Timer?
    private var lastPasteboardChangeCount: Int

    init(
        store: LocalStore = LocalStore(),
        monitorsClipboard: Bool = true
    ) {
        self.store = store
        items = Self.normalized(store.loadBoard())
        settings = store.loadSettings()
        activeCategory = .inbox
        defaultCaptureCategory = .inbox
        lastPasteboardChangeCount = NSPasteboard.general.changeCount

        if monitorsClipboard {
            startClipboardMonitoring()
        }
    }

    deinit {
        clipboardTimer?.invalidate()
    }

    func displayName(for category: BoardCategory) -> String {
        settings.displayName(for: category)
    }

    func orderedItems(in category: BoardCategory) -> [BoardItem] {
        items
            .filter { $0.category == category }
            .sorted(by: Self.displayOrder)
    }

    func selectCategory(_ category: BoardCategory) {
        activeCategory = category
        defaultCaptureCategory = category
        showStatus("新复制的内容将进入“\(displayName(for: category))”")
    }

    func captureCurrentClipboard() {
        capturePasteboard(force: true)
    }

    func addText(_ rawText: String, to category: BoardCategory? = nil) {
        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            return
        }

        let target = category ?? defaultCaptureCategory
        let item = BoardItem(
            kind: .text,
            category: target,
            order: 0,
            text: rawText
        )
        _ = persistMutation(failureMessage: "本次文字未保存，请重试。") {
            insertAtTopOfNormalRegion([item], in: target)
        }
    }

    func addImageFiles(_ urls: [URL], to category: BoardCategory? = nil) {
        let target = category ?? defaultCaptureCategory
        var storedItems: [BoardItem] = []

        do {
            for url in urls where url.isFileURL {
                let id = UUID()
                let relativePath = try store.storeImageFile(url, id: id)
                storedItems.append(BoardItem(
                    id: id,
                    kind: .image,
                    category: target,
                    order: 0,
                    imageRelativePath: relativePath
                ))
            }
        } catch {
            storedItems.forEach { _ = store.deleteManagedImage(relativePath: $0.imageRelativePath) }
            showStatus("拖入图片无法读取，请换一张静态图片重试。")
            return
        }

        guard !storedItems.isEmpty else {
            showStatus("没有找到可用的图片。")
            return
        }

        if !persistMutation(failureMessage: "图片未保存，请重试。", {
            insertAtTopOfNormalRegion(storedItems, in: target)
        }) {
            storedItems.forEach { _ = store.deleteManagedImage(relativePath: $0.imageRelativePath) }
        }
    }

    func addImages(_ images: [NSImage], to category: BoardCategory? = nil) {
        let target = category ?? defaultCaptureCategory
        var storedItems: [BoardItem] = []

        do {
            for image in images {
                let id = UUID()
                let relativePath = try store.storeImage(image, id: id)
                storedItems.append(BoardItem(
                    id: id,
                    kind: .image,
                    category: target,
                    order: 0,
                    imageRelativePath: relativePath
                ))
            }
        } catch {
            storedItems.forEach { _ = store.deleteManagedImage(relativePath: $0.imageRelativePath) }
            showStatus("图片无法转换为本地 PNG，请重试。")
            return
        }

        guard !storedItems.isEmpty else {
            return
        }

        if !persistMutation(failureMessage: "图片未保存，请重试。", {
            insertAtTopOfNormalRegion(storedItems, in: target)
        }) {
            storedItems.forEach { _ = store.deleteManagedImage(relativePath: $0.imageRelativePath) }
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
              item.category != targetCategory
        else {
            return
        }
        let sourceCategory = item.category

        _ = persistMutation(failureMessage: "移动未保存，请重试。") {
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
        }
    }

    @discardableResult
    func copyImage(_ id: UUID, to targetCategory: BoardCategory) -> Bool {
        guard let source = items.first(where: { $0.id == id }),
              source.kind == .image,
              source.category != targetCategory,
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
            category: targetCategory,
            order: 0,
            imageRelativePath: copiedRelativePath
        )
        guard persistMutation(failureMessage: "图片复制未保存，请重试。", {
            insertAtTopOfNormalRegion([copiedItem], in: targetCategory)
        }) else {
            _ = store.deleteManagedImage(relativePath: copiedRelativePath)
            return false
        }

        showStatus("已复制到“\(displayName(for: targetCategory))”")
        return true
    }

    func delete(_ id: UUID) {
        guard let item = items.first(where: { $0.id == id }) else {
            return
        }

        if persistMutation(failureMessage: "删除未保存，请重试。", {
            items.removeAll { $0.id == id }
        }) {
            _ = store.deleteManagedImage(relativePath: item.imageRelativePath)
        }
    }

    func clearActiveCategory() {
        let category = activeCategory
        let removed = orderedItems(in: category)
        guard !removed.isEmpty else {
            return
        }

        if persistMutation(failureMessage: "清空未保存，请重试。", {
            items.removeAll { $0.category == category }
        }) {
            removed.forEach { _ = store.deleteManagedImage(relativePath: $0.imageRelativePath) }
        }
    }

    func copyToClipboard(_ item: BoardItem) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        switch item.kind {
        case .text:
            guard let text = item.text else {
                return
            }
            pasteboard.writeObjects([text as NSString])
        case .image:
            guard let relativePath = item.imageRelativePath,
                  let url = store.managedImageURL(relativePath: relativePath),
                  let image = NSImage(contentsOf: url)
            else {
                showStatus("图片文件已经不存在。")
                return
            }
            pasteboard.writeObjects([image])
        }

        lastPasteboardChangeCount = pasteboard.changeCount
        showStatus("已复制，可粘贴到其他应用。")
    }

    func dragProvider(for item: BoardItem) -> NSItemProvider {
        switch item.kind {
        case .text:
            return NSItemProvider(object: (item.text ?? "") as NSString)
        case .image:
            guard let relativePath = item.imageRelativePath,
                  let managedURL = store.managedImageURL(relativePath: relativePath),
                  let image = NSImage(contentsOf: managedURL)
            else {
                return NSItemProvider()
            }

            let provider: NSItemProvider
            do {
                let exportURL = try store.exportImageForDrag(relativePath: relativePath)
                provider = NSItemProvider(contentsOf: exportURL) ?? NSItemProvider()
                provider.suggestedName = exportURL.deletingPathExtension().lastPathComponent
            } catch {
                showStatus("图片导出副本创建失败，请重试。")
                provider = NSItemProvider()
            }
            provider.registerObject(image, visibility: .all)
            return provider
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
              let source = items.first(where: { $0.id == id }),
              let managedURL = imageURL(for: source)
        else {
            showStatus("无法识别这张拖动图片，请重试。")
            return false
        }
        let exportURL = store.paths.dragExportsDirectory.appendingPathComponent(managedURL.lastPathComponent)
        guard url.standardizedFileURL == exportURL.standardizedFileURL
                || url.standardizedFileURL == managedURL.standardizedFileURL else {
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

    func renameCategory(_ category: BoardCategory, to rawName: String) {
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

    func updateWindowSettings(panelWidth: Double, height: Double, top: Double) {
        let previous = settings
        settings.panelWidth = min(max(panelWidth, 280), 640)
        settings.windowHeight = max(height, 360)
        settings.top = max(top, 0)
        do {
            try store.saveSettings(settings)
        } catch {
            settings = previous
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
            if !orderedFiles.isEmpty {
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

    private func capturePasteboard(force: Bool) {
        let pasteboard = NSPasteboard.general
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
        let previous = items
        mutation()
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

    private func replaceCategory(_ category: BoardCategory, with replacements: [BoardItem]) {
        items.removeAll { $0.category == category }
        items.append(contentsOf: replacements.enumerated().map { index, item in
            var replacement = item
            replacement.category = category
            replacement.order = index
            return replacement
        })
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
        return BoardCategory.visibleCases.flatMap { category in
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
