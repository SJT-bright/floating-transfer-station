import AppKit
import Combine
import SwiftUI

@main
enum PerformanceTests {
    static func main() throws {
        setbuf(stdout, nil)
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("station-performance-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LocalStore(paths: AppPaths(dataDirectory: directory))
        let items = (0..<1800).map { index in
            BoardItem(kind: .text, category: .inbox, order: index,
                      text: String(repeating: "长文字应保留完整内容，列表最多显示两行。", count: 80),
                      name: index.isMultiple(of: 5) ? "素材\(index)" : nil)
        }
        try store.saveBoard(items)
        let model = BoardModel(store: store, monitorsClipboard: false)
        model.updateWindowSettings(panelWidth: 320, height: 448, top: 80, origin: NSPoint(x: 100, y: 100))
        var notifications = 0
        let subscription = model.objectWillChange.sink { notifications += 1 }
        for _ in 0..<100 {
            model.updateWindowSettings(panelWidth: 320, height: 448, top: 80, origin: NSPoint(x: 100, y: 100))
        }
        print("identical window notifications: \(notifications)")
        subscription.cancel()
        guard notifications == 0 else { throw TestError.failed("unchanged window settings repeatedly invalidate the whole board") }
        var checked = Set<Int>()
        for index in 0..<45 {
            let page = BoardPage(totalCount: items.count, requestedPage: index)
            guard page.range.count <= BoardPage.capacity else { throw TestError.failed("unbounded page") }
            checked.formUnion(page.range)
        }
        guard checked == Set(0..<1800), BoardPage(totalCount: 0, requestedPage: 99).range.isEmpty,
              BoardPage(totalCount: 41, requestedPage: 99).range == 40..<41
        else { throw TestError.failed("pagination omitted records or did not clamp after deletion") }
        let original = String(repeating: "完整文字不应被截断", count: 10000)
        let longHeight = TextCardLayout.twoLineHeight(text: original, width: 250)
        guard longHeight > 0, longHeight < 40 else { throw TestError.failed("long-text measurement is not bounded to two lines") }
        try autoreleasepool {
            let space = CGColorSpace(name: CGColorSpace.displayP3)!
            let context = CGContext(data: nil, width: 2400, height: 1600, bitsPerComponent: 8, bytesPerRow: 0,
                                    space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(CGColor(colorSpace: space, components: [0.8, 0.1, 0.3, 1])!)
            context.fill(CGRect(x: 0, y: 0, width: 2400, height: 1600))
            let data = NSBitmapImageRep(cgImage: context.makeImage()!).representation(using: .png, properties: [:])!
            let originalProfile = NSBitmapImageRep(data: data)?.cgImage?.colorSpace?.copyICCData()
            guard let preview = ImagePreviewStore.decode(data), preview.data == data,
                  let image = preview.image.cgImage(forProposedRect: nil, context: nil, hints: nil),
                  image.width <= 720, image.height <= 720,
                  originalProfile != nil, image.colorSpace?.copyICCData() == originalProfile
            else { throw TestError.failed("bounded preview changed original bytes or color space") }
            print("bounded image preview retains original PNG bytes and Display P3 profile")
        }

        let presentation = PanelPresentation()
        presentation.setExpanded(true)
        let view = NSHostingView(rootView: ContentView(model: model, presentation: presentation))
        view.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 400, height: 448),
                              styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
        window.contentView = view
        window.orderFront(nil)
        let started = Date()
        for _ in 0..<30 {
            presentation.setExpanded(false)
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
            presentation.setExpanded(true)
            view.layoutSubtreeIfNeeded()
            RunLoop.current.run(until: Date().addingTimeInterval(0.04))
        }
        let elapsed = Date().timeIntervalSince(started)
        print("1800-record board, 30 reopen cycles: \(String(format: "%.2f", elapsed)) seconds")
        guard elapsed < 15 else { throw TestError.failed("reopening a large board exceeded the UI work budget") }
        window.orderOut(nil)
        print("macOS performance tests passed")
    }
}

private enum TestError: Error { case failed(String) }
