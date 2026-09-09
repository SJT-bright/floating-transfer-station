import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @ObservedObject var model: BoardModel
    @ObservedObject var presentation: PanelPresentation

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var isRenaming = false
    @State private var renameDraft = ""
    @State private var confirmsClear = false
    @State private var dropTargetCategory: BoardCategory?

    private var translucentPanelBackground: Color {
        if reduceTransparency {
            return Color(nsColor: .windowBackgroundColor)
        }

        return colorScheme == .dark
            ? Color.black.opacity(0.34)
            : Color.white.opacity(0.34)
    }

    var body: some View {
        Group {
            if presentation.isExpanded {
                expandedPanel
            } else {
                collapsedHandle
            }
        }
        .contentShape(Rectangle())
        .onHover(perform: presentation.handleHover)
        .onTapGesture {
            if !presentation.isExpanded {
                presentation.handleHover(true)
            }
        }
    }

    private func panelVerticalDragGesture(
        minimumDistance: CGFloat
    ) -> some Gesture {
        DragGesture(minimumDistance: minimumDistance, coordinateSpace: .global)
            .onChanged { value in
                let gestureStartMouseY = Double(
                    NSEvent.mouseLocation.y + value.translation.height
                )
                presentation.handleVerticalDragChanged(
                    gestureStartMouseY: gestureStartMouseY
                )
            }
            .onEnded { _ in
                presentation.handleVerticalDragEnded()
            }
    }

    private var expandedPanel: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                toolbar
                Divider()
                board
                statusBar
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onDrop(
                of: [UTType.fileURL.identifier, UTType.image.identifier, UTType.plainText.identifier],
                delegate: BoardDropDelegate(model: model, category: model.activeCategory)
            )

            Divider()
            categoryRail
        }
        .background {
            translucentPanelBackground.ignoresSafeArea()
        }
        .alert("重命名分类", isPresented: $isRenaming) {
            TextField("最多 6 个字符", text: $renameDraft)
            Button("取消", role: .cancel) {}
            Button("保存") {
                model.renameCategory(model.activeCategory, to: renameDraft)
            }
        } message: {
            Text("分类名可以留空，最多保留 6 个可见字符。")
        }
        .alert("清空当前分类？", isPresented: $confirmsClear) {
            Button("取消", role: .cancel) {}
            Button("清空", role: .destructive) {
                model.clearActiveCategory()
            }
        } message: {
            Text("这会删除当前分类里的所有文字和应用管理的图片副本。")
        }
    }

    private var collapsedHandle: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray.full.fill")
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(Color.accentColor)

            Text("\(model.items.count)")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()

            Capsule()
                .fill(Color.primary.opacity(0.14))
                .frame(width: 24, height: 1)

            Image(systemName: "chevron.left.2")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            Text("移入")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background {
            translucentPanelBackground.ignoresSafeArea()
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("悬浮中转站，已有 \(model.items.count) 条内容")
        .accessibilityHint("将鼠标移入以展开")
        .highPriorityGesture(panelVerticalDragGesture(minimumDistance: 8))
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.displayName(for: model.activeCategory))
                    .font(.headline)
                    .lineLimit(1)
                Text("\(model.orderedItems(in: model.activeCategory).count) 条内容")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Button {
                model.captureCurrentClipboard()
            } label: {
                Image(systemName: "doc.on.clipboard")
            }
            .help("立即收取当前剪贴板")

            Button {
                renameDraft = model.displayName(for: model.activeCategory)
                isRenaming = true
            } label: {
                Image(systemName: "pencil")
            }
            .help("重命名当前分类")

            Button(role: .destructive) {
                confirmsClear = true
            } label: {
                Image(systemName: "trash")
            }
            .help("清空当前分类")
            .disabled(model.orderedItems(in: model.activeCategory).isEmpty)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(
            LinearGradient(
                colors: [
                    Color.white.opacity(colorScheme == .dark ? 0.055 : 0.24),
                    Color.clear
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    @ViewBuilder
    private var board: some View {
        let visibleItems = model.orderedItems(in: model.activeCategory)
        if visibleItems.isEmpty {
            VStack(spacing: 14) {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 38, weight: .light))
                    .foregroundStyle(.secondary)
                    .padding(20)
                    .background(
                        Circle()
                            .fill(Color.white.opacity(colorScheme == .dark ? 0.055 : 0.3))
                    )
                    .overlay(
                        Circle()
                            .stroke(Color.white.opacity(colorScheme == .dark ? 0.12 : 0.5))
                    )
                Text("复制文字或图片，它会自动出现在这里")
                    .font(.callout)
                    .multilineTextAlignment(.center)
                Text("也可以把图片或文字直接拖进窗口")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(28)
        } else {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(Array(visibleItems.enumerated()), id: \.element.id) { index, item in
                        if index > 0,
                           visibleItems[index - 1].isPinned,
                           !item.isPinned {
                            HStack(spacing: 8) {
                                Rectangle()
                                    .frame(height: 1)
                                Text("普通")
                                    .font(.caption2)
                                Rectangle()
                                    .frame(height: 1)
                            }
                            .foregroundStyle(.quaternary)
                            .padding(.horizontal, 4)
                        }
                        ItemCard(model: model, item: item)
                    }
                }
                .padding(12)
            }
        }
    }

    @ViewBuilder
    private var statusBar: some View {
        if !model.statusText.isEmpty {
            Divider()
            Text(model.statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    Color.white.opacity(colorScheme == .dark ? 0.055 : 0.3)
                )
        }
    }

    private var categoryRail: some View {
        VStack(spacing: 8) {
            ForEach(BoardCategory.visibleCases) { category in
                Button {
                    model.selectCategory(category)
                } label: {
                    VStack(spacing: 5) {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: icon(for: category))
                                .font(.system(size: 17, weight: .medium))
                            if model.defaultCaptureCategory == category {
                                Circle()
                                    .fill(Color.accentColor)
                                    .frame(width: 7, height: 7)
                                    .offset(x: 7, y: -4)
                            }
                        }
                        Text(model.displayName(for: category).isEmpty ? "未命名" : model.displayName(for: category))
                            .font(.caption2)
                            .lineLimit(2)
                            .multilineTextAlignment(.center)
                        Text("\(model.orderedItems(in: category).count)")
                            .font(.system(size: 9, design: .rounded))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .background(
                    RoundedRectangle(cornerRadius: 10)
                        .fill(
                            dropTargetCategory == category
                                ? Color.accentColor.opacity(0.42)
                                : model.activeCategory == category
                                    ? Color.accentColor.opacity(0.16)
                                    : Color.clear
                        )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(
                            dropTargetCategory == category
                                ? Color.accentColor.opacity(0.9)
                                : Color.clear,
                            lineWidth: 2
                        )
                )
                .scaleEffect(dropTargetCategory == category ? 1.03 : 1)
                .animation(.easeOut(duration: 0.12), value: dropTargetCategory)
                .onDrop(
                    of: [UTType.fileURL.identifier],
                    delegate: CategoryCopyDropDelegate(
                        model: model,
                        category: category,
                        targetedCategory: $dropTargetCategory
                    )
                )
                .contextMenu {
                    Button("重命名") {
                        model.selectCategory(category)
                        renameDraft = model.displayName(for: category)
                        isRenaming = true
                    }
                }
            }

            VStack(spacing: 5) {
                Spacer(minLength: 8)
                Capsule()
                    .fill(Color.secondary.opacity(0.45))
                    .frame(width: 24, height: 3)
                Image(systemName: "arrow.up.and.down")
                    .font(.system(size: 10, weight: .semibold))
                Text("按住拖动")
                    .font(.system(size: 9, weight: .medium))
            }
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
            .accessibilityElement(children: .combine)
            .accessibilityLabel("上下拖动悬浮中转站")
        }
        .padding(8)
        .frame(width: 82)
        .help("按住最右侧栏上下拖动")
        .contentShape(Rectangle())
        .highPriorityGesture(panelVerticalDragGesture(minimumDistance: 8))
    }

    private func icon(for category: BoardCategory) -> String {
        switch category {
        case .customerOriginal:
            return "person.crop.rectangle"
        case .reference:
            return "macwindow"
        case .prompt:
            return "text.quote"
        case .inbox:
            return "tray"
        }
    }
}

private struct ItemCard: View {
    @ObservedObject var model: BoardModel
    let item: BoardItem

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Label(
                    item.kind == .image ? "图片" : "文字",
                    systemImage: item.kind == .image ? "photo" : "text.alignleft"
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                Spacer()

                Button {
                    model.togglePinned(item.id)
                } label: {
                    Image(systemName: item.isPinned ? "pin.fill" : "pin")
                }
                .help(item.isPinned ? "取消置顶" : "置顶")

                Button {
                    model.copyToClipboard(item)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .help("复制")

                Menu {
                    ForEach(BoardCategory.visibleCases.filter { $0 != item.category }) { category in
                        Button(model.displayName(for: category)) {
                            model.move(item.id, to: category)
                        }
                    }
                } label: {
                    Image(systemName: "folder")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("移动到其他分类")

                Button(role: .destructive) {
                    model.delete(item.id)
                } label: {
                    Image(systemName: "trash")
                }
                .help("删除")
            }
            .buttonStyle(.borderless)

            if item.kind == .text {
                Text(item.text ?? "")
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onDrag {
                        model.dragProvider(for: item)
                    }
            } else if let url = model.imageURL(for: item),
                      let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 220)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
                    .onDrag {
                        model.dragProvider(for: item)
                    } preview: {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 160, height: 120)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .help("拖到其他分类复制，或拖到其他应用")
            } else {
                Label("图片文件已丢失", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(11)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.white.opacity(colorScheme == .dark ? 0.075 : 0.48))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(
                    item.isPinned
                        ? Color.accentColor.opacity(0.55)
                        : Color.white.opacity(colorScheme == .dark ? 0.14 : 0.72)
                )
        )
        .shadow(
            color: Color.black.opacity(colorScheme == .dark ? 0.16 : 0.08),
            radius: 10,
            x: 0,
            y: 4
        )
        .contentShape(RoundedRectangle(cornerRadius: 12))
        .contextMenu {
            Button(item.isPinned ? "取消置顶" : "置顶") {
                model.togglePinned(item.id)
            }
            Button("复制") {
                model.copyToClipboard(item)
            }
            Menu("移动到") {
                ForEach(BoardCategory.visibleCases.filter { $0 != item.category }) { category in
                    Button(model.displayName(for: category)) {
                        model.move(item.id, to: category)
                    }
                }
            }
            Divider()
            Button("删除", role: .destructive) {
                model.delete(item.id)
            }
        }
    }
}

private struct BoardDropDelegate: DropDelegate {
    let model: BoardModel
    let category: BoardCategory

    func validateDrop(info: DropInfo) -> Bool {
        guard internalImageProvider(from: info) == nil else {
            return false
        }
        return !info.itemProviders(for: [
            UTType.fileURL.identifier,
            UTType.image.identifier,
            UTType.plainText.identifier
        ]).isEmpty
    }

    func performDrop(info: DropInfo) -> Bool {
        guard internalImageProvider(from: info) == nil else {
            return false
        }
        let providers = info.itemProviders(for: [
            UTType.fileURL.identifier,
            UTType.image.identifier,
            UTType.plainText.identifier
        ])
        guard !providers.isEmpty else {
            return false
        }
        model.importProviders(providers, to: category)
        return true
    }

    private func internalImageProvider(from info: DropInfo) -> NSItemProvider? {
        info.itemProviders(for: [UTType.fileURL.identifier])
            .first(where: { model.draggedImageID(from: $0) != nil })
    }
}

private struct CategoryCopyDropDelegate: DropDelegate {
    let model: BoardModel
    let category: BoardCategory
    @Binding var targetedCategory: BoardCategory?

    private func provider(from info: DropInfo) -> NSItemProvider? {
        info.itemProviders(for: [UTType.fileURL.identifier]).first
    }

    func validateDrop(info: DropInfo) -> Bool {
        category != model.activeCategory && provider(from: info) != nil
    }

    func dropEntered(info: DropInfo) {
        if validateDrop(info: info) {
            targetedCategory = category
        }
    }

    func dropExited(info: DropInfo) {
        if targetedCategory == category {
            targetedCategory = nil
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        validateDrop(info: info) ? DropProposal(operation: .copy) : nil
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let provider = provider(from: info) else {
            targetedCategory = nil
            return false
        }
        targetedCategory = nil
        model.copyDraggedImageProvider(provider, to: category)
        return true
    }
}
