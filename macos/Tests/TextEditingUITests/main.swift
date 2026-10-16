import AppKit
import SwiftUI

@main
enum TextEditingUITests {
    static let delegate = TestDelegate()
    static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        app.delegate = delegate
        app.run()
    }
}

final class TestDelegate: NSObject, NSApplicationDelegate {
    private var window: NSWindow?
    private var model: BoardModel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard CommandLine.arguments.count == 2,
              CommandLine.arguments[1].contains("/artifacts/body-edit-qa-") else {
            fatalError("Pass a dedicated artifacts/body-edit-qa-* directory; formal data is never used.")
        }
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let store = LocalStore(paths: AppPaths(dataDirectory: directory.appendingPathComponent("data"),
                                             dragExportsDirectory: directory.appendingPathComponent("exports")))
        let model = BoardModel(store: store, monitorsClipboard: false)
        if model.items.isEmpty {
            model.addText("第一行原文：正文可以独立修改。\n第二行原文：名称和置顶保持不变。", to: .prompt)
            let id = model.items[0].id
            model.renameItem(id, to: "正文编辑验收")
            model.togglePinned(id)
        }
        model.selectCategory(.prompt)
        self.model = model
        let presentation = PanelPresentation()
        presentation.setExpanded(true)
        let window = NSWindow(contentRect: NSRect(x: 240, y: 280, width: 400, height: 448),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "正文编辑验收（隔离数据）"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: ContentView(model: model, presentation: presentation))
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}
