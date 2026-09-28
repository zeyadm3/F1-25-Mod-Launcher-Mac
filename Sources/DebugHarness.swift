#if DEBUG
import AppKit
import SwiftUI

/// Debug builds only: lets a script drive the UI and snapshot the window without Accessibility or
/// Screen Recording access. Commands are read from $F1ML_DEBUG_DIR/command, one per line.
@MainActor
enum DebugHarness {
    static func start() {
        guard let path = ProcessInfo.processInfo.environment["F1ML_DEBUG_DIR"] else { return }
        let dir = URL(fileURLWithPath: path, isDirectory: true)
        let commandFile = dir.appendingPathComponent("command")
        Task { @MainActor in
            while true {
                if let text = try? String(contentsOf: commandFile, encoding: .utf8), !text.isEmpty {
                    try? FileManager.default.removeItem(at: commandFile)
                    for line in text.split(separator: "\n") { run(String(line), dir: dir) }
                    try? "done".write(to: dir.appendingPathComponent("ack"), atomically: true, encoding: .utf8)
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    private static func run(_ line: String, dir: URL) {
        let store = LauncherStore.shared
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        let argument = parts.count > 1 ? parts[1] : ""
        switch parts.first ?? "" {
        case "snap": snapshot(to: dir.appendingPathComponent("\(argument).png"))
        case "toggle": if let entry = store.allEntries.first(where: { $0.id == argument }) { store.toggle(entry) }
        case "favorite": if let entry = store.allEntries.first(where: { $0.id == argument }) { store.toggleFavorite(entry) }
        case "launch": store.launch(.launch)
        case "install": store.launch(.installOnly)
        case "restore": store.restoreNow()
        case "keep": store.keepModsInstalled()
        case "start": store.startGameAgain()
        case "search": store.search = argument
        case "filter": store.filter = argument == "favorites" ? .favorites : .all
        case "settings": store.showSettings = argument == "on"
        case "alert-ok": store.alert = nil
        case "dump": dump(to: dir.appendingPathComponent("state.txt"))
        case "activate": NSApp.activate(ignoringOtherApps: true)
        case "size":
            let size = argument.split(separator: "x").compactMap { Double($0) }
            if size.count == 2, let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) {
                window.setContentSize(NSSize(width: size[0], height: size[1]))
            }
        default: break
        }
    }

    private static func snapshot(to url: URL) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.canBecomeMain }) else { return }
        let target = window.attachedSheet ?? window
        guard let view = target.contentView?.superview ?? target.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    private static func dump(to url: URL) {
        let store = LauncherStore.shared
        let lines = [
            "phase=\(store.phase)",
            "status=\(store.status)",
            "gameRunning=\(store.gameRunning)",
            "sessionPending=\(store.sessionPending)",
            "selection=\(store.selection.sorted())",
            "installed=\(store.installedIDs.sorted())",
            "banner=\(store.banner?.text ?? "")",
            "alert=\(store.alert.map { "\($0.title): \($0.message)" } ?? "")",
            "entries=\(store.allEntries.map(\.id))",
            "problems=\(store.libraryProblems)",
        ]
        try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
    }
}
#endif
