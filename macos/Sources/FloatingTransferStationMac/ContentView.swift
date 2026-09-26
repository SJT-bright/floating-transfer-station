import AppKit
import SwiftUI
import UniformTypeIdentifiers

private struct StationMaterial: NSViewRepresentable {
    var frost: Double
    var glass: Double

    func makeNSView(context: Context) -> MaterialView { MaterialView() }

    func updateNSView(_ view: MaterialView, context: Context) {
        view.frost.alphaValue = frost
        view.frost.isHidden = frost == 0
        view.glass.alphaValue = glass
        view.glass.isHidden = glass == 0
    }

    final class MaterialView: NSView {
        let frost = NSVisualEffectView()
        let glass: NSView

        override init(frame frameRect: NSRect) {
            if #available(macOS 26.0, *) {
                let effect = NSGlassEffectView()
                effect.style = .clear
                effect.cornerRadius = 12
                glass = effect
            } else {
                let effect = NSVisualEffectView()
                effect.material = .hudWindow
                effect.blendingMode = .behindWindow
                effect.state = .active
                glass = effect
            }
            super.init(frame: frameRect)
            frost.material = .underWindowBackground
            frost.blendingMode = .behindWindow
            frost.state = .active
            wantsLayer = true
            layer?.cornerRadius = 12
            layer?.masksToBounds = true
            for effect in [frost, glass] {
                effect.frame = bounds
                effect.autoresizingMask = [.width, .height]
                addSubview(effect)
            }
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

private struct StationHoverTracker: NSViewRepresentable {
    var onChange: (Bool) -> Void

    func makeNSView(context: Context) -> TrackingView { TrackingView() }

    func updateNSView(_ view: TrackingView, context: Context) {
        view.onChange = onChange
    }

    final class TrackingView: NSView {
        var onChange: ((Bool) -> Void)?
        private var hovering = false

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(rect: .zero,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect, .enabledDuringMouseDrag],
                owner: self, userInfo: nil))
        }

        override func mouseEntered(with event: NSEvent) { setHovered(true) }
        override func mouseExited(with event: NSEvent) { setHovered(false) }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil { setHovered(false) }
            super.viewWillMove(toWindow: newWindow)
        }

        private func setHovered(_ value: Bool) {
            guard hovering != value else { return }
            hovering = value
            DispatchQueue.main.async { [weak self] in
                guard let self, self.hovering == value else { return }
                self.onChange?(value)
            }
        }
    }
}

private struct StationHoverEffect: ViewModifier {
    var isPressed = false
    var isActive = false
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    func body(content: Content) -> some View {
        let highlighted = (isHovered || isActive) && isEnabled
        content
            .background {
                RoundedRectangle(cornerRadius: 7)
                    .fill(Color.accentColor.opacity(highlighted ? 0.22 : 0))
                    .padding(-3)
                    .allowsHitTesting(false)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 7)
                    .stroke(Color.white.opacity(highlighted ? 0.45 : 0), lineWidth: 0.8)
                    .padding(-3)
                    .allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(highlighted ? 0.22 : 0), radius: highlighted ? 5 : 0, y: highlighted ? 3 : 0)
            .scaleEffect(reduceMotion ? 1 : isPressed && isEnabled ? 0.97 : highlighted ? 1.045 : 1)
            .offset(y: reduceMotion || isPressed ? 0 : highlighted ? -2 : 0)
            .animation(reduceMotion ? .easeOut(duration: 0.12) : .interactiveSpring(response: 0.25, dampingFraction: 1), value: highlighted)
            .animation(.easeOut(duration: 0.08), value: isPressed)
            // Keep the hover target stationary while its visual surface lifts.
            .background(StationHoverTracker { isHovered = $0 })
            .contentShape(Rectangle())
            .onDisappear { isHovered = false }
    }
}

private struct StationButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .modifier(StationHoverEffect(isPressed: configuration.isPressed))
            .opacity(isEnabled ? 1 : 0.4)
    }
}

struct ContentView: View {
    @GestureState private var isDraggingPanel = false
    @ObservedObject var model: BoardModel
    @ObservedObject var presentation: PanelPresentation

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @State private var isRenaming = false
    @State private var renameDraft = ""
    @State private var confirmsClear = false
    @State private var dropTargetCategory: BoardCategory?
    @State private var isAddingCategory = false
    @State private var newCategoryName = ""
    @State private var showsAppearance = false
    @State private var searchQuery = ""

    private var isSearching: Bool {
        !searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var appearance: PanelAppearance {
        model.settings.appearance ?? .defaults(isDark: colorScheme == .dark)
    }

    private var textColor: Color {
        Color(white: appearance.textBrightness).opacity(appearance.textOpacity)
    }

    private var translucentPanelBackground: some View {
        ZStack {
            if reduceTransparency {
                Color(nsColor: .windowBackgroundColor)
            } else {
                StationMaterial(frost: appearance.frostIntensity, glass: appearance.glassIntensity)
                Color(white: appearance.backgroundBrightness).opacity(appearance.backgroundOpacity)
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(LinearGradient(colors: [.white.opacity(0.75), .white.opacity(0.08),
                                                         .white.opacity(0.35)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing),
                                  lineWidth: 1)
                    .opacity(appearance.glassIntensity)
            }
        }
        .allowsHitTesting(false)
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
        .foregroundStyle(textColor)
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
            .updating($isDraggingPanel) { _, dragging, _ in
                dragging = true
            }
            .onChanged { value in
                let gestureStartMouse = NSPoint(
                    x: NSEvent.mouseLocation.x - value.translation.width,
                    y: NSEvent.mouseLocation.y + value.translation.height
                )
                presentation.handleVerticalDragChanged(
                    gestureStartMouse: gestureStartMouse
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
                if model.activeCategory == .files && !isSearching {
                    Button(action: chooseFiles) {
                        Label(model.isImportingFiles ? "正在导入文件…" : "导入文件", systemImage: "plus.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    .modifier(StationHoverEffect())
                    .disabled(model.isImportingFiles)
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
                }
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                    TextField("搜索名称（全部分类）", text: $searchQuery)
                        .textFieldStyle(.plain)
                        .accessibilityLabel("搜索名称")
                    if !searchQuery.isEmpty {
                        Button { searchQuery = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                        }
                        .buttonStyle(StationButtonStyle())
                        .accessibilityLabel("清除搜索")
                    }
                }
                .font(.system(size: 12))
                .padding(8)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 7))
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
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
        .alert("添加分类", isPresented: $isAddingCategory) {
            TextField("分类名称（最多 6 个字符）", text: $newCategoryName)
            Button("取消", role: .cancel) {}
            Button("添加") {
                model.addCategory(named: newCategoryName)
            }
            .disabled(newCategoryName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("复制内容始终进入待分类，你可以主动拖动图片到新分类。")
        }
        .alert("清空未置顶内容？", isPresented: $confirmsClear) {
            Button("取消", role: .cancel) {}
            Button("清空未置顶内容", role: .destructive) {
                model.clearActiveCategory()
            }
        } message: {
            Text("只删除当前分类中未置顶的内容及站内副本。置顶内容会保留，导入前的原文件不受影响。")
        }
    }

    private var collapsedHandle: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray.full.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Color.accentColor)

            Text("\(model.items.count)")
                .font(.system(size: 13, weight: .semibold, design: .rounded))
                .monospacedDigit()

            Capsule()
                .fill(Color.primary.opacity(0.14))
                .frame(width: 24, height: 1)

            Image(systemName: presentation.isDockedLeft ? "chevron.right.2" : "chevron.left.2")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(textColor.opacity(0.75))

            Text("移入")
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(textColor.opacity(0.75))
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
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(isSearching ? "搜索结果" : model.displayName(for: model.activeCategory))
                    .font(.headline)
                    .lineLimit(1)
                Text("\(isSearching ? model.searchNamedItems(searchQuery).count : model.orderedItems(in: model.activeCategory).count) 条内容")
                    .font(.caption)
                    .foregroundStyle(textColor.opacity(0.75))
            }

            Spacer(minLength: 8)

            Button {
                presentation.isEditingAppearance = true
                presentation.handleHover(true)
                showsAppearance = true
            } label: {
                Image(systemName: "circle.lefthalf.filled")
            }
            .help("外观设置：文字与背景")
            .accessibilityLabel("外观设置")
            .popover(isPresented: $showsAppearance, arrowEdge: .leading) {
                AppearanceEditor(model: model)
                    .foregroundStyle(Color.primary)
                    .onDisappear {
                        presentation.isEditingAppearance = false
                        presentation.handleHover(false)
                    }
            }

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
            .disabled(isSearching || model.activeCategory == .files)

            Button(role: .destructive) {
                confirmsClear = true
            } label: {
                Image(systemName: "trash")
            }
            .help("清空当前分类的未置顶内容（保留置顶）")
            .disabled(isSearching || !model.orderedItems(in: model.activeCategory).contains { !$0.isPinned })
        }
        .buttonStyle(StationButtonStyle())
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            LinearGradient(
                colors: [
                    Color(white: appearance.backgroundBrightness).opacity(appearance.backgroundOpacity * 0.2),
                    Color.clear
                ],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private func chooseFiles() {
        let parent = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible && !($0 is NSOpenPanel) })
        let previousPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.regular)
        defer { NSApp.setActivationPolicy(previousPolicy) }
        NSApp.activate(ignoringOtherApps: true)
        parent?.makeKeyAndOrderFront(nil)
        let picker = NSOpenPanel()
        picker.title = "导入文件到文件中转站"
        picker.prompt = "导入"
        picker.canChooseFiles = true
        picker.canChooseDirectories = false
        picker.allowsMultipleSelection = true
        picker.resolvesAliases = true
        presentation.isEditingAppearance = true
        let finish: (NSApplication.ModalResponse) -> Void = { response in
            presentation.isEditingAppearance = false
            if response == .OK {
                searchQuery = ""
                model.importFiles(picker.urls)
            }
            presentation.handleHover(false)
        }
        // A standalone modal panel owns keyboard focus independently of the
        // always-on-top utility window. AppKit continues pumping UI events.
        picker.level = .floating
        finish(picker.runModal())
    }

    @ViewBuilder
    private var board: some View {
        let visibleItems = isSearching ? model.searchNamedItems(searchQuery) : model.orderedItems(in: model.activeCategory)
        if visibleItems.isEmpty {
            VStack(spacing: 14) {
                Image(systemName: "square.and.arrow.down")
                    .font(.system(size: 38, weight: .light))
                    .foregroundStyle(textColor.opacity(0.75))
                    .padding(20)
                    .background(
                        Circle()
                            .fill(Color(white: appearance.backgroundBrightness).opacity(appearance.backgroundOpacity * 0.2))
                    )
                    .overlay(
                        Circle()
                            .stroke(Color.white.opacity(colorScheme == .dark ? 0.12 : 0.5))
                    )
                Text(isSearching ? "没有匹配的名称" : model.activeCategory == .files ? "把文件拖到这里，随时再拖出去" : "复制文字或图片，它会自动出现在这里")
                    .font(.callout)
                    .multilineTextAlignment(.center)
                Text(isSearching ? "只搜索你填写的名称，未命名内容不参与搜索" : model.activeCategory == .files ? "也可以点击“导入文件”多选文件，原文件保持不动" : "也可以把图片或文字直接拖进窗口")
                    .font(.caption)
                    .foregroundStyle(textColor.opacity(0.75))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(28)
        } else {
            ScrollView {
                LazyVStack(spacing: 8) {
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
                        ItemCard(model: model, item: item, showsCategory: isSearching)
                    }
                }
                .padding(9)
            }
        }
    }

    @ViewBuilder
    private var statusBar: some View {
        if !model.statusText.isEmpty {
            Divider()
            Text(model.statusText)
                .font(.caption)
                .foregroundStyle(textColor.opacity(0.75))
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(
                    Color(white: appearance.backgroundBrightness).opacity(appearance.backgroundOpacity * 0.2)
                )
        }
    }

    private var categoryRail: some View {
        VStack(spacing: 8) {
            HStack(spacing: 4) {
                Button {
                    newCategoryName = ""
                    isAddingCategory = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(maxWidth: .infinity, minHeight: 28)
                }
                .buttonStyle(StationButtonStyle())
                .help("添加分类")
                .accessibilityLabel("添加分类")

                Image(systemName: "arrow.up.and.down.and.arrow.left.and.right")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(textColor.opacity(0.85))
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
                    .modifier(StationHoverEffect(isActive: isDraggingPanel))
                    .help("按住拖动窗口")
                    .accessibilityLabel("拖动悬浮中转站")
                    .highPriorityGesture(panelVerticalDragGesture(minimumDistance: 8))
            }

            ScrollView {
                categoryButtons
            }

            Divider()
            fileStationButton
        }
        .padding(8)
        .frame(width: PanelGeometry.railWidth)
    }

    private var categoryButtons: some View {
        VStack(spacing: 8) {
            ForEach(model.categories.filter { $0 != .files }) { category in
                Button {
                    searchQuery = ""
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
                            .foregroundStyle(textColor.opacity(0.75))
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                    .contentShape(Rectangle())
                }
                .buttonStyle(StationButtonStyle())
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
        }
    }

    private var fileStationButton: some View {
        Button {
            searchQuery = ""
            model.selectCategory(.files)
        } label: {
            VStack(spacing: 4) {
                Image(systemName: "tray.and.arrow.down")
                    .font(.system(size: 17, weight: .medium))
                Text("文件中转站")
                    .font(.system(size: 10))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                Text("\(model.orderedItems(in: .files).count)")
                    .font(.system(size: 9, design: .rounded))
                    .foregroundStyle(textColor.opacity(0.75))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(StationButtonStyle())
        .background(RoundedRectangle(cornerRadius: 10).fill(
            dropTargetCategory == .files ? Color.accentColor.opacity(0.42)
                : model.activeCategory == .files ? Color.accentColor.opacity(0.16) : .clear
        ))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(
            dropTargetCategory == .files ? Color.accentColor.opacity(0.9) : .clear, lineWidth: 2
        ))
        .animation(.easeOut(duration: 0.12), value: dropTargetCategory)
        .accessibilityLabel("文件中转站")
        .help("导入或拖入文件，保留原文件")
        .onDrop(of: [UTType.fileURL.identifier], delegate: FileStationDropDelegate(
            model: model, targetedCategory: $dropTargetCategory
        ))
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
        default:
            return "folder"
        }
    }
}

private struct AppearanceEditor: View {
    @ObservedObject var model: BoardModel
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var appearance: PanelAppearance {
        model.settings.appearance ?? .defaults(isDark: colorScheme == .dark)
    }

    private func control(_ title: String, key: WritableKeyPath<PanelAppearance, Double>,
                         range: ClosedRange<Double> = 0...1, ends: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(title)
                Spacer()
                Text("\(Int((appearance[keyPath: key] * 100).rounded()))%")
                    .monospacedDigit().foregroundStyle(.secondary)
            }
            Slider(value: Binding(
                get: { appearance[keyPath: key] },
                set: { value in
                    var updated = appearance
                    updated[keyPath: key] = (value * 100).rounded() / 100
                    model.updateAppearance(updated)
                }
            ), in: range)
            .accessibilityLabel(title)
            Text(ends).font(.caption2).foregroundStyle(.secondary)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("外观设置").font(.headline)
            control("文字深浅", key: \.textBrightness, ends: "左侧黑色 · 右侧白色")
            control("文字不透明度", key: \.textOpacity, range: 0.2...1, ends: "左侧淡 · 右侧清晰")
            Divider()
            control("背景深浅", key: \.backgroundBrightness, ends: "左侧黑色 · 右侧白色")
            control("背景不透明度", key: \.backgroundOpacity, ends: "左侧透明 · 右侧实色")
            Divider()
            Group {
                control("磨砂强度", key: \.frostIntensity, ends: "关闭 · 背景磨砂混合增强")
                control("液态玻璃强度", key: \.glassIntensity, ends: "关闭 · 玻璃透光与边缘高光增强")
            }
            .disabled(reduceTransparency)
            if reduceTransparency {
                Text("系统已开启降低透明度，材质效果暂不显示。")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("背景不透明度越低，材质越明显。macOS 26 使用原生液态玻璃，旧系统使用兼容材质。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("实时生效并自动保存，图片保持原样。").font(.caption).foregroundStyle(.secondary)
            Button("恢复系统默认") { model.updateAppearance(nil) }
                .buttonStyle(.bordered)
                .modifier(StationHoverEffect())
        }
        .padding(20)
        .frame(width: 300)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct ItemCard: View {
    @ObservedObject var model: BoardModel
    let item: BoardItem
    var showsCategory = false
    @State private var showsFullText = false
    @State private var isTextExpanded = false
    @State private var nameDraft = ""
    @State private var isRenamingItem = false
    @FocusState private var isEditingName: Bool

    @Environment(\.colorScheme) private var colorScheme

    private var appearance: PanelAppearance {
        model.settings.appearance ?? .defaults(isDark: colorScheme == .dark)
    }

    private var textColor: Color {
        Color(white: appearance.textBrightness).opacity(appearance.textOpacity)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                Label(
                    item.kind == .file ? "文件" : item.kind == .image ? "图片" : "文字",
                    systemImage: item.kind == .file ? "doc" : item.kind == .image ? "photo" : "text.alignleft"
                )
                .font(.caption)
                .foregroundStyle(textColor.opacity(0.75))
                .onDrag { model.dragProvider(for: item) }
                .help("拖动原始内容到其他应用")

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

                if item.kind != .file {
                    Menu {
                        ForEach(model.categories.filter { $0 != item.category && $0 != .files }) { category in
                            Button(model.displayName(for: category)) {
                                model.move(item.id, to: category)
                            }
                        }
                    } label: {
                        Image(systemName: "folder")
                    }
                    .menuStyle(.borderlessButton)
                    .buttonStyle(.borderless)
                    .fixedSize()
                    .modifier(StationHoverEffect())
                    .help("移动到其他分类")
                }

                Button(role: .destructive) {
                    model.delete(item.id)
                } label: {
                    Image(systemName: "trash")
                }
                .help("删除")
            }
            .buttonStyle(StationButtonStyle())

            HStack(spacing: 6) {
                if isRenamingItem {
                    TextField("输入名称", text: $nameDraft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .focused($isEditingName)
                        .onAppear { isEditingName = true }
                        .onSubmit { finishNaming() }
                        .onChange(of: isEditingName) { focused in
                            if !focused { finishNaming() }
                        }
                } else if let name = item.name, !name.isEmpty {
                    if item.kind == .text && item.category != .inbox {
                        Button {
                            isTextExpanded.toggle()
                        } label: {
                            Label(name, systemImage: isTextExpanded ? "chevron.down" : "chevron.right")
                                .lineLimit(1)
                        }
                        .buttonStyle(StationButtonStyle())
                        .accessibilityLabel(isTextExpanded ? "收起\(name)" : "展开\(name)")
                    } else {
                        Text(name).lineLimit(1)
                    }
                } else {
                    Button("添加名称") { beginNaming() }
                        .buttonStyle(StationButtonStyle())
                        .foregroundStyle(textColor.opacity(0.7))
                }
                Spacer(minLength: 0)
                if !isRenamingItem {
                    Button { beginNaming() } label: {
                        Image(systemName: "pencil")
                    }
                    .buttonStyle(StationButtonStyle())
                    .accessibilityLabel("给内容命名")
                }
            }
            .font(.system(size: 12))
            .onAppear { nameDraft = item.name ?? "" }
            .onDisappear { if isRenamingItem { saveName() } }

            if showsCategory {
                Text(model.displayName(for: item.category))
                    .font(.caption2)
                    .foregroundStyle(textColor.opacity(0.75))
            }

            if item.kind == .text {
                if item.category == .inbox || item.name == nil || isTextExpanded {
                    FullTextReader(text: item.text ?? "", compact: true, color: NSColor(textColor), expanded: isTextExpanded)
                        .frame(maxWidth: .infinity)
                        .clipped()
                        .help("在文字框内滚动查看完整内容；拖动左上角“文字”可拖出全文")
                    Button {
                        isTextExpanded.toggle()
                    } label: {
                        Label(isTextExpanded ? (item.category != .inbox && item.name != nil ? "收起为名称" : "收起为两行") : "展开文字",
                              systemImage: isTextExpanded ? "chevron.up" : "chevron.down")
                    }
                    .font(.caption)
                    .buttonStyle(StationButtonStyle())
                    Button("查看全文") { showsFullText = true }
                        .font(.caption)
                        .buttonStyle(StationButtonStyle())
                        .sheet(isPresented: $showsFullText) {
                            VStack(spacing: 12) {
                                HStack {
                                    Text("文字全文").font(.headline)
                                    Spacer()
                                    Button("复制全文") { model.copyToClipboard(item) }
                                        .buttonStyle(.bordered)
                                        .modifier(StationHoverEffect())
                                    Button("关闭") { showsFullText = false }
                                        .buttonStyle(.bordered)
                                        .modifier(StationHoverEffect())
                                        .keyboardShortcut(.cancelAction)
                                }
                                FullTextReader(text: item.text ?? "")
                            }
                            .padding(16)
                            .frame(width: 420, height: 440)
                        }
                }
            } else if item.kind == .file {
                if let url = model.fileURL(for: item) {
                    HStack(spacing: 10) {
                        Image(nsImage: NSWorkspace.shared.icon(forFile: url.path))
                            .resizable()
                            .scaledToFit()
                            .frame(width: 32, height: 32)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(item.fileName ?? url.lastPathComponent)
                                .font(.system(size: 12, weight: .medium))
                                .lineLimit(2)
                                .truncationMode(.middle)
                            if let size = item.fileSize {
                                Text(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                                    .font(.caption2)
                                    .foregroundStyle(textColor.opacity(0.75))
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onDrag { model.dragProvider(for: item) }
                    .help("拖动文件到 Finder 或其他应用")
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    } label: {
                        Label("在 Finder 中显示", systemImage: "folder")
                    }
                    .font(.caption)
                    .buttonStyle(StationButtonStyle())
                } else {
                    Label("文件副本已丢失", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(textColor.opacity(0.75))
                }
            } else if let url = model.imageURL(for: item),
                      let image = NSImage(contentsOf: url) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 180)
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
                    .foregroundStyle(textColor.opacity(0.75))
            }
        }
        .padding(9)
        .foregroundStyle(textColor)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(white: appearance.backgroundBrightness).opacity(appearance.backgroundOpacity * 0.45))
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
            if item.kind != .file {
                Menu("移动到") {
                    ForEach(model.categories.filter { $0 != item.category && $0 != .files }) { category in
                        Button(model.displayName(for: category)) {
                            model.move(item.id, to: category)
                        }
                    }
                }
            }
            Divider()
            Button("删除", role: .destructive) {
                model.delete(item.id)
            }
        }
    }

    private func saveName() {
        model.renameItem(item.id, to: nameDraft)
    }

    private func beginNaming() {
        nameDraft = item.name ?? ""
        isRenamingItem = true
    }

    private func finishNaming() {
        guard isRenamingItem else { return }
        saveName()
        isRenamingItem = false
    }
}

private struct FullTextReader: NSViewRepresentable {
    let text: String
    var compact = false
    var color: NSColor = .labelColor
    var expanded = false

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        guard compact, let width = proposal.width else { return nil }
        return CGSize(width: width, height: expanded ? TextCardLayout.expandedHeight(text: text, width: width) : 32)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        if compact { scrollView.scrollerStyle = .overlay }
        let textView = NSTextView(frame: .zero)
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: compact ? 13 : 14)
        textView.textColor = color
        textView.textContainerInset = compact ? .zero : NSSize(width: 8, height: 8)
        if compact { textView.textContainer?.lineFragmentPadding = 0 }
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(width: 400, height: CGFloat.greatestFiniteMagnitude)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.layoutManager?.allowsNonContiguousLayout = true
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        textView.textColor = color
        if textView.string != text { textView.string = text }
    }
}

private struct BoardDropDelegate: DropDelegate {
    let model: BoardModel
    let category: BoardCategory

    func validateDrop(info: DropInfo) -> Bool {
        if category == .files {
            return !info.itemProviders(for: [UTType.fileURL.identifier]).isEmpty
        }
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
        if category == .files {
            let providers = info.itemProviders(for: [UTType.fileURL.identifier])
            guard !providers.isEmpty else { return false }
            model.importProviders(providers, to: .files)
            return true
        }
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

    func dropUpdated(info: DropInfo) -> DropProposal? {
        validateDrop(info: info) ? DropProposal(operation: .copy) : nil
    }

    private func internalImageProvider(from info: DropInfo) -> NSItemProvider? {
        info.itemProviders(for: [UTType.fileURL.identifier])
            .first(where: { model.draggedImageID(from: $0) != nil })
    }
}

private struct FileStationDropDelegate: DropDelegate {
    let model: BoardModel
    @Binding var targetedCategory: BoardCategory?

    func validateDrop(info: DropInfo) -> Bool {
        !info.itemProviders(for: [UTType.fileURL.identifier]).isEmpty
    }

    func dropEntered(info: DropInfo) {
        if validateDrop(info: info) { targetedCategory = .files }
    }

    func dropExited(info: DropInfo) {
        if targetedCategory == .files { targetedCategory = nil }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        validateDrop(info: info) ? DropProposal(operation: .copy) : nil
    }

    func performDrop(info: DropInfo) -> Bool {
        targetedCategory = nil
        let providers = info.itemProviders(for: [UTType.fileURL.identifier])
        guard !providers.isEmpty else { return false }
        model.importProviders(providers, to: .files)
        return true
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
        guard provider(from: info) != nil else {
            targetedCategory = nil
            return false
        }
        targetedCategory = nil
        return model.copyDraggedImage(from: NSPasteboard(name: .drag), to: category)
    }
}
