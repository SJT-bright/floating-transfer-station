import AppKit
import SwiftUI
import UniformTypeIdentifiers

private struct StationMaterial: NSViewRepresentable {
    var glass: Double
    var cornerRadius: CGFloat

    func makeNSView(context: Context) -> MaterialView { MaterialView(cornerRadius: cornerRadius) }

    func updateNSView(_ view: MaterialView, context: Context) {
        view.glass.alphaValue = glass
        view.glass.isHidden = glass == 0
        view.layer?.cornerRadius = cornerRadius
        if #available(macOS 26.0, *), let effect = view.glass as? NSGlassEffectView {
            effect.cornerRadius = cornerRadius
        }
    }

    final class MaterialView: NSView {
        let glass: NSView

        init(cornerRadius: CGFloat) {
            if #available(macOS 26.0, *) {
                let effect = NSGlassEffectView()
                effect.style = .clear
                effect.cornerRadius = cornerRadius
                effect.contentView = NSView()
                glass = effect
            } else {
                // Older systems keep the transparent lens, never a frosted fallback.
                glass = NSView()
            }
            super.init(frame: .zero)
            wantsLayer = true
            layer?.cornerRadius = cornerRadius
            layer?.masksToBounds = true
            glass.frame = bounds
            glass.autoresizingMask = [.width, .height]
            addSubview(glass)
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func layout() {
            super.layout()
            if glass.frame != bounds { glass.frame = bounds }
        }
    }
}

// Lightweight lens edges share the panel's single native glass pass.
private struct StationGlassLens: View {
    var cornerRadius: CGFloat
    var strength: Double
    var tint: Color = .clear
    var tintOpacity: Double = 0

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        shape
            .fill(tint.opacity(tintOpacity))
            .overlay {
                shape.fill(LinearGradient(stops: [
                    .init(color: .white.opacity(0.12 * strength), location: 0),
                    .init(color: .white.opacity(0.02 * strength), location: 0.20),
                    .init(color: .clear, location: 0.55),
                    .init(color: .black.opacity(0.06 * strength), location: 1)
                ], startPoint: .topLeading, endPoint: .bottomTrailing))
            }
            .overlay {
                shape.strokeBorder(LinearGradient(stops: [
                    .init(color: .white.opacity(0.85 * strength), location: 0),
                    .init(color: .white.opacity(0.32 * strength), location: 0.25),
                    .init(color: .black.opacity(0.18 * strength), location: 0.55),
                    .init(color: .white.opacity(0.55 * strength), location: 1)
                ], startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
            }
            .overlay {
                shape.inset(by: 1.5)
                    .stroke(LinearGradient(colors: [.black.opacity(0.14 * strength), .clear,
                                                    .white.opacity(0.20 * strength)],
                                           startPoint: .top, endPoint: .bottom), lineWidth: 1)
            }
            .allowsHitTesting(false)
    }
}

private struct StationHoverTracker: NSViewRepresentable {
    var onChange: (Bool) -> Void

    func makeNSView(context: Context) -> TrackingView { TrackingView() }

    func updateNSView(_ view: TrackingView, context: Context) {
        view.onChange = onChange
        view.synchronizeHoverState()
    }

    final class TrackingView: NSView {
        var onChange: ((Bool) -> Void)?
        private var hovering = false
        private var callbackGeneration: UInt64 = 0

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            let hoverRect = bounds.intersection(visibleRect)
            if !hoverRect.isEmpty {
                addTrackingArea(NSTrackingArea(rect: hoverRect,
                    options: [.mouseEnteredAndExited, .activeAlways, .enabledDuringMouseDrag],
                    owner: self, userInfo: nil))
            }
            synchronizeHoverState()
        }

        override func mouseEntered(with event: NSEvent) { setHovered(true) }
        override func mouseExited(with event: NSEvent) { setHovered(false) }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil { setHovered(false) }
            super.viewWillMove(toWindow: newWindow)
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            synchronizeHoverState()
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            if superview == nil { setHovered(false) }
            else { synchronizeHoverState() }
        }

        func synchronizeHoverState() {
            guard let window else {
                setHovered(false)
                return
            }
            let mousePoint = convert(window.mouseLocationOutsideOfEventStream, from: nil)
            let hoverRect = bounds.intersection(visibleRect)
            setHovered(!hoverRect.isEmpty && hoverRect.contains(mousePoint))
        }

        private func setHovered(_ value: Bool) {
            guard hovering != value else { return }
            hovering = value
            callbackGeneration &+= 1
            let generation = callbackGeneration
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.callbackGeneration == generation,
                      self.hovering == value
                else { return }
                self.onChange?(value)
            }
        }
    }
}

private struct StationHoverEffect: ViewModifier {
    var isPressed = false
    var isActive = false
    var cornerRadius: CGFloat = 11
    var highlightPadding: CGFloat = 3
    var neutralHover = false
    var activeHighlightOpacity = 0.22
    var activeStrokeOpacity = 0.45
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    func body(content: Content) -> some View {
        let active = isActive && isEnabled
        let neutralHighlight = neutralHover && isHovered && !active && isEnabled
        let accentHover = !neutralHover && isHovered && !active && isEnabled
        let highlighted = (isHovered || active) && isEnabled
        content
            .background {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(active
                        ? Color.accentColor.opacity(activeHighlightOpacity)
                        : neutralHighlight ? Color.primary.opacity(0.08)
                        : accentHover ? Color.accentColor.opacity(0.22) : Color.clear)
                    .padding(-highlightPadding)
                    .allowsHitTesting(false)
            }
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.white.opacity(highlighted && !neutralHighlight ? activeStrokeOpacity : 0), lineWidth: 0.8)
                    .padding(-highlightPadding)
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
    var cornerRadius: CGFloat = 11
    var highlightPadding: CGFloat = 3
    var neutralHover = false
    var activeHighlightOpacity = 0.22
    var activeStrokeOpacity = 0.45
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .modifier(StationHoverEffect(isPressed: configuration.isPressed,
                cornerRadius: cornerRadius, highlightPadding: highlightPadding,
                neutralHover: neutralHover, activeHighlightOpacity: activeHighlightOpacity,
                activeStrokeOpacity: activeStrokeOpacity))
            .opacity(isEnabled ? 1 : 0.4)
    }
}

private struct TextDragSurface: NSViewRepresentable {
    let itemID: UUID
    let text: String
    let name: String
    var onClick: (() -> Void)? = nil
    @Binding var activeTextDragID: UUID?

    func makeNSView(context: Context) -> TextDragSurfaceView {
        let view = TextDragSurfaceView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        update(view)
        return view
    }

    func updateNSView(_ view: TextDragSurfaceView, context: Context) {
        update(view)
    }

    private func update(_ view: TextDragSurfaceView) {
        view.itemID = itemID
        view.text = text
        view.name = name
        view.onClick = onClick
        view.onDragStarted = { id in activeTextDragID = id }
        view.onDragEnded = { id in
            if activeTextDragID == id { activeTextDragID = nil }
        }
    }
}

private final class TextDragSurfaceView: NSView, NSDraggingSource {
    var itemID = UUID()
    var text = ""
    var name = ""
    var onClick: (() -> Void)?
    var onDragStarted: ((UUID) -> Void)?
    var onDragEnded: ((UUID) -> Void)?

    private var mouseDownEvent: NSEvent?
    private var mouseDownPoint = NSPoint.zero
    private var dragThresholdCrossed = false
    private var activeDragID: UUID?

    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func shouldDelayWindowOrdering(for event: NSEvent) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden, let superview else { return nil }
        let localPoint = convert(point, from: superview)
        return bounds.contains(localPoint) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownEvent = event
        mouseDownPoint = convert(event.locationInWindow, from: nil)
        dragThresholdCrossed = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard !dragThresholdCrossed, let mouseDownEvent else { return }
        let point = convert(event.locationInWindow, from: nil)
        let dx = point.x - mouseDownPoint.x
        let dy = point.y - mouseDownPoint.y
        guard hypot(dx, dy) >= 3 else { return }
        dragThresholdCrossed = true
        beginTextDrag(using: mouseDownEvent)
    }

    override func mouseUp(with event: NSEvent) {
        if !dragThresholdCrossed { onClick?() }
        mouseDownEvent = nil
        dragThresholdCrossed = false
    }

    private func beginTextDrag(using event: NSEvent) {
        let pasteboardItem = NSPasteboardItem()
        let privateType = NSPasteboard.PasteboardType(BoardModel.textItemDragType)
        guard pasteboardItem.setString(text, forType: .string),
              pasteboardItem.setData(Data(itemID.uuidString.lowercased().utf8), forType: privateType),
              window != nil
        else { return }

        activeDragID = itemID
        onDragStarted?(itemID)

        let preview = makePreview()
        let previewSize = preview.size
        let previewFrame = NSRect(
            x: mouseDownPoint.x - previewSize.width / 2,
            y: mouseDownPoint.y - previewSize.height / 2,
            width: previewSize.width,
            height: previewSize.height
        )
        let draggingItem = NSDraggingItem(pasteboardWriter: pasteboardItem)
        draggingItem.setDraggingFrame(previewFrame, contents: preview)
        let session = beginDraggingSession(with: [draggingItem], event: event, source: self)
        session.draggingFormation = .none
        session.animatesToStartingPositionsOnCancelOrFail = true
    }

    private func makePreview() -> NSImage {
        let size = NSSize(width: 144, height: 28)
        let title = name.isEmpty ? "未命名内容" : name
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.labelColor
        ]
        return NSImage(size: size, flipped: false) { rect in
            let shape = NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7)
            NSColor.windowBackgroundColor.withAlphaComponent(0.94).setFill()
            shape.fill()
            NSColor.separatorColor.withAlphaComponent(0.55).setStroke()
            shape.lineWidth = 1
            shape.stroke()
            (title as NSString).draw(in: rect.insetBy(dx: 9, dy: 5), withAttributes: attributes)
            return true
        }
    }

    func draggingSession(
        _ session: NSDraggingSession,
        sourceOperationMaskFor context: NSDraggingContext
    ) -> NSDragOperation {
        context == .withinApplication ? .move : .copy
    }

    func draggingSession(
        _ session: NSDraggingSession,
        endedAt screenPoint: NSPoint,
        operation: NSDragOperation
    ) {
        finishTextDrag()
    }

    private func finishTextDrag() {
        if let activeDragID {
            onDragEnded?(activeDragID)
        }
        activeDragID = nil
        mouseDownEvent = nil
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
    @State private var confirmsCategoryDeletion = false
    @State private var categoryToDelete: BoardCategory?
    @State private var dropTargetCategory: BoardCategory?
    @State private var isAddingCategory = false
    @State private var newCategoryName = ""
    @State private var showsAppearance = false
    @State private var searchQuery = ""
    @State private var activeTextDragID: UUID?
    @State private var boardPage = 0

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
                StationMaterial(glass: appearance.glassIntensity, cornerRadius: 16)
                Color(white: appearance.backgroundBrightness).opacity(appearance.backgroundOpacity)
                StationGlassLens(cornerRadius: 16, strength: appearance.glassIntensity)
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
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
        .onChange(of: model.activeCategory) { _ in
            boardPage = 0
            dropTargetCategory = nil
        }
        .onChange(of: searchQuery) { _ in
            boardPage = 0
            dropTargetCategory = nil
        }
        .onChange(of: presentation.isExpanded) { isExpanded in
            if !isExpanded { dropTargetCategory = nil }
        }
        .onDisappear { dropTargetCategory = nil }
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
                .background(StationGlassLens(cornerRadius: 13,
                    strength: reduceTransparency ? 0 : appearance.glassIntensity,
                    tint: .black, tintOpacity: 0.08))
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
                if isSearching {
                    Text("搜索总览只查看；请进入同一分类上下拖动文字排序。")
                        .font(.caption2)
                        .foregroundStyle(textColor.opacity(0.72))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 6)
                }
                Divider()
                board
                statusBar
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onDrop(
                of: [UTType.fileURL.identifier, UTType.image.identifier, UTType.plainText.identifier,
                     BoardModel.textItemDragType],
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
        .alert("删除分类？", isPresented: $confirmsCategoryDeletion) {
            Button("取消", role: .cancel) { categoryToDelete = nil }
            Button("删除分类", role: .destructive) {
                if let categoryToDelete {
                    _ = model.deleteCategory(categoryToDelete)
                }
                categoryToDelete = nil
            }
        } message: {
            let name = categoryToDelete.map { model.displayName(for: $0) } ?? "此分类"
            Text("删除“\(name)”后，其中的文字和图片会迁回“待分类”。素材不会被永久删除。")
        }
    }

    private var collapsedHandle: some View {
        VStack(spacing: 5) {
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
                        .help("设置：交互 DIY、外观、成功音效、待分类容量")
            .accessibilityLabel("设置")
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
            let page = BoardPage(totalCount: visibleItems.count, requestedPage: boardPage)
            VStack(spacing: 0) {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(Array(visibleItems.enumerated())[page.range], id: \.element.id) { index, item in
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
                            ItemCard(model: model, presentation: presentation, item: item, showsCategory: isSearching,
                                     activeTextDragID: $activeTextDragID)
                        }
                    }
                    .padding(7)
                }
                .id("\(model.activeCategory.rawValue)-\(searchQuery)-\(page.index)")
                if page.pageCount > 1 {
                    Divider()
                    HStack {
                        Button("上一页") { boardPage = page.index - 1 }
                            .disabled(page.index == 0)
                        Spacer()
                        Text("\(page.index + 1) / \(page.pageCount) 页")
                            .monospacedDigit()
                        Spacer()
                        Button("下一页") { boardPage = page.index + 1 }
                            .disabled(page.index == page.pageCount - 1)
                    }
                    .font(.caption)
                    .buttonStyle(StationButtonStyle())
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                }
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
        VStack(spacing: 6) {
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
                    .frame(width: 28, height: 28)
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
        .padding(6)
        .frame(width: PanelGeometry.railWidth)
    }

    private var categoryButtons: some View {
        VStack(spacing: 6) {
            ForEach(model.categories.filter { $0 != .files }) { category in
                let isDropTarget = dropTargetCategory == category
                let isSelected = dropTargetCategory == nil && model.activeCategory == category
                let isHighlighted = isDropTarget || isSelected
                Button {
                    searchQuery = ""
                    model.selectCategory(category)
                } label: {
                    VStack(spacing: 4) {
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
                    .padding(.vertical, 5)
                    .background(
                        StationGlassLens(cornerRadius: 8,
                            strength: reduceTransparency || !isHighlighted
                                ? 0 : appearance.glassIntensity,
                            tint: .accentColor,
                            tintOpacity: isDropTarget ? 0.42 : isSelected ? 0.26 : 0)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(isDropTarget ? Color.accentColor.opacity(0.9) : .clear,
                                    lineWidth: 2)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
                .modifier(StationHoverEffect(isActive: isHighlighted,
                    cornerRadius: 8, highlightPadding: 0, neutralHover: true,
                    activeHighlightOpacity: 0, activeStrokeOpacity: 0))
                .scaleEffect(isDropTarget ? 1.03 : 1)
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
                    Divider()
                    Button("删除分类", role: .destructive) {
                        categoryToDelete = category
                        confirmsCategoryDeletion = true
                    }
                    .disabled(!model.canDeleteCategory(category))
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private var fileStationButton: some View {
        let isDropTarget = dropTargetCategory == .files
        let isSelected = dropTargetCategory == nil && model.activeCategory == .files
        let isHighlighted = isDropTarget || isSelected
        Button {
            searchQuery = ""
            model.selectCategory(.files)
        } label: {
            VStack(spacing: 3) {
                Image(systemName: "tray.and.arrow.down")
                    .font(.system(size: 13.6, weight: .medium))
                Text("文件中转站")
                    .font(.system(size: 10))
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                Text("\(model.orderedItems(in: .files).count)")
                    .font(.system(size: 9, design: .rounded))
                    .foregroundStyle(textColor.opacity(0.75))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .background(StationGlassLens(cornerRadius: 8,
                strength: reduceTransparency || !isHighlighted
                    ? 0 : appearance.glassIntensity,
                tint: .accentColor,
                tintOpacity: isDropTarget ? 0.42 : isSelected ? 0.26 : 0))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(
                isDropTarget ? Color.accentColor.opacity(0.9) : .clear, lineWidth: 2
            ))
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .modifier(StationHoverEffect(isActive: isHighlighted,
            cornerRadius: 8, highlightPadding: 0, neutralHover: true,
            activeHighlightOpacity: 0, activeStrokeOpacity: 0))
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
    @State private var inboxLimitEnabled = false
    @State private var inboxLimitDraft = ""
    @State private var inboxLimitMessage: String?

    private var appearance: PanelAppearance {
        model.settings.appearance ?? .defaults(isDark: colorScheme == .dark)
    }

    private var parsedInboxLimit: Int? {
        let value = inboxLimitDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty,
              value.unicodeScalars.allSatisfy({ $0.value >= 48 && $0.value <= 57 }),
              let limit = Int(value),
              limit > 0
        else { return nil }
        return limit
    }

    private func syncInboxLimitDraft() {
        inboxLimitEnabled = model.settings.inboxItemLimit != nil
        inboxLimitDraft = model.settings.inboxItemLimit.map(String.init) ?? ""
        inboxLimitMessage = nil
    }

    private func saveInboxLimit() {
        let limit: Int?
        if inboxLimitEnabled {
            guard let parsedInboxLimit else {
                inboxLimitMessage = "请输入大于 0 的正整数后再保存。"
                return
            }
            limit = parsedInboxLimit
        } else {
            limit = nil
        }

        model.setInboxItemLimit(limit)
        inboxLimitMessage = model.settings.inboxItemLimit == limit
            ? (limit.map { "已保存上限：\($0) 条。" } ?? "已保存为无限制。")
            : "设置未保存，请查看中转站状态提示后重试。"
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

    private func interactionToggle(_ title: String, key: WritableKeyPath<WindowSettings, Bool>) -> some View {
        Toggle(title, isOn: Binding(
            get: { model.settings[keyPath: key] },
            set: { model.setInteractionOption(key, enabled: $0) }
        ))
        .toggleStyle(.switch)
        .accessibilityLabel(title)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("设置与外观").font(.headline)
                Text("交互 DIY").font(.subheadline.weight(.semibold))
                interactionToggle("文字悬停自动展开", key: \.textHoverExpansionEnabled)
                Text("开启：移入标题展开、移出卡片收起；关闭：用右键菜单或快捷按钮手动展开和收起。")
                    .font(.caption).foregroundStyle(.secondary)
                interactionToggle("显示复制与置顶按钮", key: \.cardCopyPinButtonsEnabled)
                Text("每条文字、图片、文件的标题旁显示两个常用按钮，可单独关闭。")
                    .font(.caption).foregroundStyle(.secondary)
                interactionToggle("其他操作仅放在右键菜单", key: \.cardActionsInContextMenuOnly)
                Text("关闭后再显示全文、展开、移动和删除等按钮，右键菜单始终保留。")
                    .font(.caption).foregroundStyle(.secondary)
                interactionToggle("卡片悬停浮起与阴影", key: \.cardHoverLiftEnabled)
                Text("文字、图片和文件卡片统一提示；编辑、菜单和拖动期间暂停浮起。系统减少动态效果时只保留高亮和阴影。")
                    .font(.caption).foregroundStyle(.secondary)
                Divider()
                control("文字深浅", key: \.textBrightness, ends: "左侧黑色 · 右侧白色")
                control("文字不透明度", key: \.textOpacity, range: 0.2...1, ends: "左侧淡 · 右侧清晰")
                Divider()
                control("背景深浅", key: \.backgroundBrightness, ends: "左侧黑色 · 右侧白色")
                control("背景不透明度", key: \.backgroundOpacity, ends: "左侧透明 · 右侧实色")
                Divider()
                Group {
                    control("液态玻璃强度", key: \.glassIntensity, ends: "左侧关闭 · 右侧折射与弧面亮边增强")
                }
                .disabled(reduceTransparency)
                if reduceTransparency {
                    Text("系统已开启降低透明度，材质效果暂不显示。")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("清透玻璃，不叠加磨砂。降低背景不透明度可看见背后的颜色；系统 26 及以上版本支持原生折射，旧系统保留透明亮边。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Text("实时生效并自动保存，图片保持原样。")
                    .font(.caption).foregroundStyle(.secondary)
                Button("使用液态玻璃预设") { model.updateAppearance(.liquidGlass) }
                    .buttonStyle(.bordered)
                    .modifier(StationHoverEffect())
                Button("恢复系统默认") { model.updateAppearance(nil) }
                    .buttonStyle(.bordered)
                    .modifier(StationHoverEffect())

                Divider()
                Text("复制与待分类").font(.subheadline.weight(.semibold))
                Toggle("复制成功时播放提示音", isOn: Binding(
                    get: { model.settings.successSoundEnabled },
                    set: { model.setSuccessSoundEnabled($0) }
                ))
                .toggleStyle(.switch)
                .accessibilityLabel("复制成功时播放提示音")

                VStack(alignment: .leading, spacing: 8) {
                    Toggle("限制待分类数量", isOn: $inboxLimitEnabled)
                        .accessibilityLabel("限制待分类数量")
                    HStack(spacing: 8) {
                        if inboxLimitEnabled {
                            TextField("正整数", text: $inboxLimitDraft)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 100)
                                .onChange(of: inboxLimitDraft) { _ in inboxLimitMessage = nil }
                                .onSubmit(saveInboxLimit)
                            Text("条")
                                .foregroundStyle(.secondary)
                        } else {
                            Label("无限制", systemImage: "infinity")
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 4)
                        Button("保存容量", action: saveInboxLimit)
                            .buttonStyle(.bordered)
                            .disabled(inboxLimitEnabled && parsedInboxLimit == nil)
                    }
                    if inboxLimitEnabled && parsedInboxLimit == nil {
                        Text("请输入大于 0 的正整数。")
                            .font(.caption).foregroundStyle(.red)
                    }
                    Text("保存后不立即清理已有内容；下次新增时按先进先出淘汰未置顶项，置顶项不占额度。")
                        .font(.caption).foregroundStyle(.secondary)
                    if let inboxLimitMessage {
                        Text(inboxLimitMessage)
                            .font(.caption)
                            .foregroundStyle(inboxLimitMessage.hasPrefix("设置未保存")
                                ? Color.red : Color(nsColor: .secondaryLabelColor))
                    }
                }
            }
            .padding(20)
        }
        .frame(width: 320, height: 440)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear(perform: syncInboxLimitDraft)
    }
}

private struct ItemCardHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private enum TextDropEdge: Equatable {
    case above
    case below
}

private struct TextReorderDropDelegate: DropDelegate {
    let model: BoardModel
    let target: BoardItem
    let sortingEnabled: Bool
    let targetHeight: CGFloat
    @Binding var activeTextDragID: UUID?
    @Binding var highlightedEdge: TextDropEdge?

    private func internalTextProvider(from info: DropInfo) -> (provider: NSItemProvider, id: UUID)? {
        guard sortingEnabled,
              target.kind == .text || target.kind == .image,
              let provider = info.itemProviders(for: [BoardModel.textItemDragType]).first,
              let id = activeTextDragID,
              id != target.id,
              let source = model.items.first(where: { $0.id == id }),
              source.kind == .text,
              source.category == target.category,
              source.isPinned == target.isPinned
        else {
            return nil
        }
        return (provider, id)
    }

    private func edge(at location: CGPoint) -> TextDropEdge {
        location.y >= max(targetHeight, 1) / 2 ? .below : .above
    }

    func validateDrop(info: DropInfo) -> Bool {
        internalTextProvider(from: info) != nil
    }

    func dropEntered(info: DropInfo) {
        guard validateDrop(info: info) else { return }
        highlightedEdge = edge(at: info.location)
    }

    func dropExited(info: DropInfo) {
        highlightedEdge = nil
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        guard validateDrop(info: info) else {
            highlightedEdge = nil
            return nil
        }
        highlightedEdge = edge(at: info.location)
        return DropProposal(operation: .move)
    }

    func performDrop(info: DropInfo) -> Bool {
        guard let (provider, sourceID) = internalTextProvider(from: info) else {
            highlightedEdge = nil
            return false
        }
        let targetID = target.id
        let targetCategory = target.category
        let targetIsPinned = target.isPinned
        let insertionEdge = edge(at: info.location)
        activeTextDragID = nil
        highlightedEdge = nil

        provider.loadDataRepresentation(forTypeIdentifier: BoardModel.textItemDragType) { data, error in
            guard error == nil,
                  let data,
                  let rawID = String(data: data, encoding: .utf8),
                  let loadedID = UUID(uuidString: rawID),
                  loadedID == sourceID
            else {
                DispatchQueue.main.async { model.reportTextReorderFailure() }
                return
            }

            DispatchQueue.main.async {
                guard let currentSource = model.items.first(where: { $0.id == loadedID }),
                      currentSource.kind == .text,
                      currentSource.category == targetCategory,
                      currentSource.isPinned == targetIsPinned
                else {
                    model.reportTextReorderFailure()
                    return
                }
                guard model.reorderText(loadedID, relativeTo: targetID, after: insertionEdge == .below) else {
                    model.reportTextReorderFailure()
                    return
                }
            }
        }
        return true
    }
}

private struct ItemCard: View {
    @ObservedObject var model: BoardModel
    let presentation: PanelPresentation
    let item: BoardItem
    var showsCategory = false
    @Binding var activeTextDragID: UUID?
    @State private var showsFullText = false
    @StateObject private var disclosure = TextCardDisclosure()
    @State private var measuredCardHeight: CGFloat = 0
    @State private var textDropEdge: TextDropEdge?
    @State private var nameDraft = ""
    @State private var isRenamingItem = false
    @State private var isShowingContextMenu = false
    @State private var isCardHovered = false
    @FocusState private var isEditingName: Bool

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var appearance: PanelAppearance {
        model.settings.appearance ?? .defaults(isDark: colorScheme == .dark)
    }

    private var textColor: Color {
        Color(white: appearance.textBrightness).opacity(appearance.textOpacity)
    }

    private var hasName: Bool {
        !(item.name?.isEmpty ?? true)
    }

    private var isCardLifted: Bool {
        model.settings.cardHoverLiftEnabled && isCardHovered
            && !isRenamingItem && !isEditingName && !isShowingContextMenu
            && !showsFullText && activeTextDragID == nil
    }

    private var disclosureAnimation: Animation {
        disclosure.isExpanded
            ? .easeOut(duration: PanelMotionTiming.revealDuration(reduceMotion: reduceMotion))
            : .easeIn(duration: PanelMotionTiming.collapseDuration(reduceMotion: reduceMotion))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 5) {
                Group {
                    if isRenamingItem {
                        TextField("输入名称", text: $nameDraft)
                            .textFieldStyle(.plain)
                            .font(.system(size: TextCardLayout.titleFontSize, weight: .semibold))
                            .focused($isEditingName)
                            .onAppear {
                                // Focus only after SwiftUI has installed the new editor.
                                // Otherwise the title's mouse-up can restore the search field.
                                DispatchQueue.main.async {
                                    if isRenamingItem { isEditingName = true }
                                }
                            }
                            .onSubmit { finishNaming() }
                            .onChange(of: isEditingName) { focused in
                                if !focused { finishNaming() }
                            }
                    } else if item.kind == .text, hasName, let name = item.name {
                        draggableTextTitle(name, onClick: beginNaming)
                            .background(StationHoverTracker { hovered in
                                if hovered && model.settings.textHoverExpansionEnabled
                                    && activeTextDragID == nil && !isRenamingItem && !isShowingContextMenu {
                                    disclosure.enterDisclosure()
                                }
                            })
                            .help(model.settings.textHoverExpansionEnabled
                                ? "点击标题改名；移入标题展开正文，移出卡片收起；右键显示操作；拖动标题排序或拖出全文"
                                : "点击标题改名；右键展开或收起正文；拖动标题排序或拖出全文")
                    } else if item.kind == .text {
                        draggableTextTitle("添加名称", onClick: beginNaming)
                            .foregroundStyle(textColor.opacity(0.7))
                            .accessibilityAddTraits(.isButton)
                            .help("点击添加名称；右键显示操作；拖动标题排序或拖出全文")
                    } else if let name = item.name, hasName {
                        titleButton(name)
                    } else {
                        titleButton("添加名称")
                            .foregroundStyle(textColor.opacity(0.7))
                    }
                }
                .frame(maxWidth: .infinity, minHeight: 24, alignment: .leading)
                .layoutPriority(1)
                .onAppear { nameDraft = item.name ?? "" }
                .onDisappear { finishNaming() }
                if !isRenamingItem && (model.settings.cardCopyPinButtonsEnabled || !model.settings.cardActionsInContextMenuOnly) {
                    inlineActions
                }
            }

            if showsCategory {
                Text(model.displayName(for: item.category))
                    .font(.caption2)
                    .foregroundStyle(textColor.opacity(0.75))
            }

            if item.kind == .text {
                if !hasName || disclosure.isExpanded {
                    FullTextReader(text: item.text ?? "", compact: true, color: NSColor(textColor))
                        .frame(maxWidth: .infinity)
                        .clipped()
                        .transition(.opacity)
                        .help("在文字框内滚动查看正文；拖动名称可拖出全文")
                }
            } else if item.kind == .file {
                if let url = model.fileURL(for: item) {
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
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onDrag { model.dragProvider(for: item) }
                    .help("拖动文件到访达或其他应用")
                } else {
                    Label("文件副本已丢失", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(textColor.opacity(0.75))
                }
            } else if let url = model.imageURL(for: item) {
                StationImageCard(model: model, item: item, url: url)
            } else {
                Label("图片文件已丢失", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(textColor.opacity(0.75))
            }
        }
        .padding(7)
        // A fading native reader must not paint over the next card while
        // this card's animated height contracts.
        .clipped()
        .animation(disclosureAnimation, value: disclosure.isExpanded)
        .onAppear {
            disclosure.setAutomaticExpansionEnabled(model.settings.textHoverExpansionEnabled)
        }
        .onChange(of: model.settings.textHoverExpansionEnabled) { enabled in
            disclosure.setAutomaticExpansionEnabled(enabled)
        }
        .onChange(of: isRenamingItem) { _ in refreshDisclosureProtection() }
        .onChange(of: isEditingName) { _ in refreshDisclosureProtection() }
        .onChange(of: showsFullText) { _ in refreshDisclosureProtection() }
        .onChange(of: isShowingContextMenu) { _ in refreshDisclosureProtection() }
        .onChange(of: activeTextDragID) { _ in refreshDisclosureProtection() }
        .onDisappear {
            disclosure.cancelPendingCollapse()
            isCardHovered = false
            presentation.setContentEditing(false, itemID: item.id)
        }
        .foregroundStyle(textColor)
        .background(
            StationGlassLens(cornerRadius: 16,
                strength: reduceTransparency ? 0 : appearance.glassIntensity,
                tint: Color(white: appearance.backgroundBrightness),
                tintOpacity: appearance.backgroundOpacity * 0.20 + (isCardLifted ? 0.08 : 0))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(
                    item.isPinned
                        ? Color.accentColor.opacity(0.55)
                        : textColor.opacity(isCardLifted ? 0.25 : 0)
                )
                .allowsHitTesting(false)
        )
        .shadow(
            color: Color.black.opacity(isCardLifted ? 0.24 : colorScheme == .dark ? 0.16 : 0.08),
            radius: isCardLifted ? 14 : 10,
            x: 0,
            y: isCardLifted ? 7 : 4
        )
        .offset(y: isCardLifted && !reduceMotion ? -2 : 0)
        .animation(reduceMotion ? .easeOut(duration: 0.12)
            : .interactiveSpring(response: 0.25, dampingFraction: 1), value: isCardLifted)
        // Track the original, stationary bounds, not the lifted visual frame.
        .background(StationHoverTracker { hovered in
            isCardHovered = hovered
            disclosure.handleCardHover(hovered)
        })
        .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .background {
            GeometryReader { geometry in
                Color.clear.preference(key: ItemCardHeightPreferenceKey.self, value: geometry.size.height)
            }
        }
        .onPreferenceChange(ItemCardHeightPreferenceKey.self) { measuredCardHeight = $0 }
        .onDrop(of: [BoardModel.textItemDragType], delegate: TextReorderDropDelegate(
            model: model,
            target: item,
            sortingEnabled: !showsCategory,
            targetHeight: measuredCardHeight,
            activeTextDragID: $activeTextDragID,
            highlightedEdge: $textDropEdge
        ))
        .overlay(alignment: .top) {
            if (item.kind == .text || item.kind == .image) && !showsCategory && textDropEdge == .above {
                Capsule().fill(Color.accentColor).frame(height: 2).padding(.horizontal, 12).offset(y: -1)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .bottom) {
            if (item.kind == .text || item.kind == .image) && !showsCategory && textDropEdge == .below {
                Capsule().fill(Color.accentColor).frame(height: 2).padding(.horizontal, 12).offset(y: 1)
                    .allowsHitTesting(false)
            }
        }
        .contextMenu {
            Button(hasName ? "重命名" : "添加名称") { beginNaming() }
                .onAppear { isShowingContextMenu = true }
                .onDisappear { isShowingContextMenu = false }
            if item.kind == .text {
                Button("查看全文") { showsFullText = true }
                if hasName {
                    Button(disclosure.isExpanded ? "收起正文" : "展开正文") {
                        // An explicit menu action is allowed after releasing the
                        // menu's hover lock; editing/dragging protection still applies.
                        isShowingContextMenu = false
                        refreshDisclosureProtection()
                        disclosure.toggle()
                    }
                }
            }
            Divider()
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
            } else if let url = model.fileURL(for: item) {
                Button("在访达中显示") {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
            Divider()
            Button("删除", role: .destructive) {
                model.delete(item.id)
            }
        }
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

    private func saveName() {
        model.renameItem(item.id, to: nameDraft)
    }

    private var inlineActions: some View {
        HStack(spacing: 4) {
            if !model.settings.cardActionsInContextMenuOnly && item.kind == .text {
                if hasName {
                    cardAction(disclosure.isExpanded ? "收起正文" : "展开正文",
                               symbol: disclosure.isExpanded ? "chevron.down" : "chevron.right") {
                        disclosure.toggle()
                    }
                }
                cardAction("查看全文", symbol: "doc.text.magnifyingglass") { showsFullText = true }
            }
            if model.settings.cardCopyPinButtonsEnabled {
                cardAction(item.isPinned ? "取消置顶" : "置顶", symbol: item.isPinned ? "pin.fill" : "pin") {
                    model.togglePinned(item.id)
                }
                cardAction("复制", symbol: "doc.on.doc") { model.copyToClipboard(item) }
            }
            if !model.settings.cardActionsInContextMenuOnly {
                if item.kind != .file {
                    Menu {
                        ForEach(model.categories.filter { $0 != item.category && $0 != .files }) { category in
                            Button(model.displayName(for: category)) { model.move(item.id, to: category) }
                        }
                    } label: {
                        Image(systemName: "folder").frame(width: 20, height: 24)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help("移动到分类")
                    .accessibilityLabel("移动到分类")
                } else if let url = model.fileURL(for: item) {
                    cardAction("在访达中显示", symbol: "folder") {
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
                cardAction("删除", symbol: "trash") { model.delete(item.id) }
            }
        }
        .font(.system(size: 14))
        .fixedSize()
    }

    private func cardAction(_ title: String, symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 20, height: 24)
        }
        .buttonStyle(StationButtonStyle())
        .help(title)
        .accessibilityLabel(title)
    }

    private func titleButton(_ title: String) -> some View {
        Button(action: beginNaming) {
            Text(title)
                .font(.system(size: TextCardLayout.titleFontSize, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("点击标题改名；右键显示全部操作")
    }

    private func draggableTextTitle(_ title: String, onClick: @escaping () -> Void) -> some View {
        Button(action: onClick) {
            Text(title)
                .font(.system(size: TextCardLayout.titleFontSize, weight: .semibold))
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(1)
                .truncationMode(.tail)
        }
            .buttonStyle(.plain)
            .overlay {
                GeometryReader { geometry in
                    TextDragSurface(
                        itemID: item.id,
                        text: item.text ?? "",
                        name: item.name ?? "",
                        onClick: onClick,
                        activeTextDragID: $activeTextDragID
                    )
                    .frame(width: geometry.size.width, height: geometry.size.height)
                    .contentShape(Rectangle())
                    .allowsHitTesting(true)
                    .accessibilityHidden(true)
                }
            }
    }

    private func beginNaming() {
        // Hold the dock open before inserting/focusing the editor. Hover events
        // caused by layout changes or an IME must not tear down this card.
        presentation.setContentEditing(true, itemID: item.id)
        disclosure.setProtected(true)
        nameDraft = item.name ?? ""
        isRenamingItem = true
    }

    private func finishNaming() {
        guard isRenamingItem else { return }
        saveName()
        isRenamingItem = false
        refreshDisclosureProtection()
    }

    private func refreshDisclosureProtection() {
        disclosure.setProtected(isRenamingItem || isEditingName || showsFullText || isShowingContextMenu || activeTextDragID != nil)
        presentation.setContentEditing(isRenamingItem || showsFullText || isShowingContextMenu, itemID: item.id)
    }
}

private struct StationImageCard: View {
    let model: BoardModel
    let item: BoardItem
    let url: URL
    @State private var preview: ImagePreview?
    @State private var loading = true

    var body: some View {
        Group {
            if let preview {
                Image(nsImage: preview.image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .contentShape(Rectangle())
                    .onDrag { model.dragProvider(for: item, imageData: preview.data) } preview: {
                        Image(nsImage: preview.image)
                            .resizable()
                            .scaledToFit()
                            .frame(width: 160, height: 120)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                    }
                    .help("拖到其他分类复制，或拖到其他应用")
            } else if loading {
                ProgressView().frame(maxWidth: .infinity, minHeight: 60)
            } else {
                Label("图片文件已丢失或无法读取", systemImage: "exclamationmark.triangle")
                    .font(.caption)
            }
        }
        .task(id: url) {
            let loaded = await ImagePreviewStore.shared.load(url)
            guard !Task.isCancelled else { return }
            preview = loaded
            loading = false
        }
    }
}

private struct FullTextReader: NSViewRepresentable {
    let text: String
    var compact = false
    var color: NSColor = .labelColor

    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
        guard compact, let width = proposal.width else { return nil }
        return CGSize(width: width, height: TextCardLayout.twoLineHeight(text: text, width: width))
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
        textView.font = .systemFont(ofSize: compact ? TextCardLayout.bodyFontSize : 14)
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
        guard !containsInternalTextProvider(info) else { return false }
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
        guard !containsInternalTextProvider(info) else { return false }
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

    private func containsInternalTextProvider(_ info: DropInfo) -> Bool {
        !info.itemProviders(for: [BoardModel.textItemDragType]).isEmpty
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
        info.itemProviders(for: [UTType.fileURL.identifier])
            .first { model.draggedImageID(from: $0) != nil }
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
