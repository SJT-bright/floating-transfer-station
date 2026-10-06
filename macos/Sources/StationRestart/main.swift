import AppKit
import Darwin

private let stationIdentifier = "com.oiawlm.floating-transfer-station.mac"
private let executableName = "FloatingTransferStationMac"

private enum RestartFailure: Error {
    case invalidTarget, anotherRestart, recoveryUnavailable, unableToStop, unableToLaunch
}

private func targetURL() throws -> URL {
    let args = CommandLine.arguments
    let helper = Bundle.main.bundleURL.resolvingSymlinksInPath()
    let target: URL
    if args.count == 3, args[1] == "--app" {
        target = URL(fileURLWithPath: args[2]).resolvingSymlinksInPath()
    } else if args.count == 1 {
        let parent = helper.deletingLastPathComponent()
        target = parent.lastPathComponent == "Helpers"
            ? parent.deletingLastPathComponent().deletingLastPathComponent()
            : parent.appendingPathComponent("悬浮中转站.app")
    } else {
        throw RestartFailure.invalidTarget
    }
    guard let bundle = Bundle(url: target), bundle.bundleIdentifier == stationIdentifier,
          bundle.executableURL?.lastPathComponent == executableName,
          FileManager.default.isExecutableFile(atPath: target.appendingPathComponent("Contents/MacOS/\(executableName)").path)
    else { throw RestartFailure.invalidTarget }
    return target
}

private func runningTargets(_ target: URL) -> [NSRunningApplication] {
    NSWorkspace.shared.runningApplications.filter {
        !$0.isTerminated && $0.bundleIdentifier == stationIdentifier &&
        $0.bundleURL?.resolvingSymlinksInPath() == target &&
        $0.executableURL?.resolvingSymlinksInPath() == target.appendingPathComponent("Contents/MacOS/\(executableName)")
    }
}

private func waitForExit(_ target: URL, seconds: TimeInterval) -> Bool {
    let deadline = Date().addingTimeInterval(seconds)
    while !runningTargets(target).isEmpty, Date() < deadline {
        RunLoop.current.run(until: Date().addingTimeInterval(0.05))
    }
    return runningTargets(target).isEmpty
}

private func restart() throws {
    let target = try targetURL()
    let manager = FileManager.default
    let base = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("悬浮中转站")
    let recovery = base.appendingPathComponent("Recovery")
    try manager.createDirectory(at: recovery, withIntermediateDirectories: true)
    let descriptor = Darwin.open(recovery.appendingPathComponent("restart.lock").path, O_CREAT | O_RDWR, 0o600)
    guard descriptor >= 0 else { throw RestartFailure.recoveryUnavailable }
    defer { Darwin.close(descriptor) }
    guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else { throw RestartFailure.anotherRestart }

    // The recovery utility runs independently from the station's UI thread.
    // Keep a snapshot of saved metadata; never delete or rewrite formal assets.
    let snapshot = recovery.appendingPathComponent("restart-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString)")
    try manager.createDirectory(at: snapshot, withIntermediateDirectories: true)
    for name in ["board.json", "board.json.bak", "settings.json", "settings.json.bak"] {
        let source = base.appendingPathComponent("Data/\(name)")
        if manager.fileExists(atPath: source.path) {
            try manager.copyItem(at: source, to: snapshot.appendingPathComponent(name))
        }
    }

    for app in runningTargets(target) { _ = app.terminate() }
    if !waitForExit(target, seconds: 2) {
        // Reacquire identity before forcing a stop; never use a name-wide kill.
        for app in runningTargets(target) { _ = app.forceTerminate() }
        guard waitForExit(target, seconds: 3) else { throw RestartFailure.unableToStop }
    }

    let launch = Process()
    launch.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    launch.arguments = [target.path]
    try launch.run()
    launch.waitUntilExit()
    guard launch.terminationStatus == 0 else { throw RestartFailure.unableToLaunch }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
do {
    try restart()
} catch RestartFailure.anotherRestart {
    // A second double click must not interrupt a restart already in progress.
    exit(0)
} catch {
    let alert = NSAlert()
    alert.messageText = "未能重启悬浮中转站"
    switch error {
    case RestartFailure.invalidTarget:
        alert.informativeText = "请把“重启悬浮中转站.app”和“悬浮中转站.app”放在同一文件夹后再试。"
    case RestartFailure.unableToStop:
        alert.informativeText = "原应用仍未退出，未启动第二份应用。请在活动监视器中结束悬浮中转站后重新打开。"
    case RestartFailure.unableToLaunch:
        alert.informativeText = "原应用已退出，但重新打开失败。请手动打开悬浮中转站。"
    default:
        alert.informativeText = "未能备份已保存内容，已停止重启操作。\(error.localizedDescription)"
    }
    alert.runModal()
    exit(1)
}
