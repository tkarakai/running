import AppKit
import ScreenCaptureKit
import SwiftUI

/// Test hooks for driving the app from a script (only with RUNNING_DEBUG=1):
///   notifyutil-style distributed notification "io.github.tkarakai.running.debug" with a JSON
///   `object` string: {"cmd":"snapshot","path":"/tmp/x.png"} · {"cmd":"key","chars":"x","keyCode":7}
///   {"cmd":"popover"} · {"cmd":"window"} · {"cmd":"size","w":900,"h":600}
/// Snapshots are taken of our own windows (no screen-recording permission needed).
@MainActor
enum DebugChannel {
    static let name = Notification.Name("io.github.tkarakai.running.debug")

    static func install(_ delegate: AppDelegate) {
        guard ProcessInfo.processInfo.environment["RUNNING_DEBUG"] == "1" else { return }
        DistributedNotificationCenter.default().addObserver(forName: name, object: nil, queue: .main) { note in
            guard let s = note.object as? String, let d = s.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any], let cmd = o["cmd"] as? String else { return }
            MainActor.assumeIsolated { handle(cmd, o, delegate) }
        }
    }

    /// Our own windows via ScreenCaptureKit (no permission needed for the current process),
    /// so Liquid Glass and materials render as on screen.
    static func capture(_ w: NSWindow, path: String) async {
        do {
            let content = try await SCShareableContent.currentProcess
            guard let sw = content.windows.first(where: { $0.windowID == CGWindowID(w.windowNumber) }) else { return }
            let filter = SCContentFilter(desktopIndependentWindow: sw)
            let cfg = SCStreamConfiguration()
            cfg.width = Int(sw.frame.width * 2)
            cfg.height = Int(sw.frame.height * 2)
            cfg.showsCursor = false
            let img = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: cfg)
            let rep = NSBitmapImageRep(cgImage: img)
            try rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        } catch {
            // No capture permission: draw the view hierarchy instead (glass shows up blank).
            guard let view = w.contentView?.superview ?? w.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        }
    }

    static func handle(_ cmd: String, _ o: [String: Any], _ delegate: AppDelegate) {
        switch cmd {
        case "snapshot":
            let path = o["path"] as? String ?? "/tmp/running-snap.png"
            let which = o["which"] as? String ?? "key"
            let win: NSWindow? = which == "popover"
                ? NSApp.windows.first { $0.className.contains("Popover") && $0.isVisible }
                : NSApp.windows.first { $0.isVisible && $0.identifier?.rawValue == "main" } ?? NSApp.keyWindow
            guard let w = win else { return }
            Task { await capture(w, path: path) }
        case "key":
            let chars = o["chars"] as? String ?? ""
            let code = UInt16(o["keyCode"] as? Int ?? 0)
            var flags: NSEvent.ModifierFlags = []
            for m in (o["mods"] as? [String] ?? []) {
                switch m { case "cmd": flags.insert(.command); case "shift": flags.insert(.shift); case "opt": flags.insert(.option); case "ctrl": flags.insert(.control); default: break }
            }
            guard let w = NSApp.keyWindow ?? NSApp.windows.first(where: { $0.isVisible }) else { return }
            if flags.contains(.command), let e = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                                                  windowNumber: w.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code),
               NSApp.mainMenu?.performKeyEquivalent(with: e) == true { return }
            for type in [NSEvent.EventType.keyDown, .keyUp] {
                if let e = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                            windowNumber: w.windowNumber, context: nil, characters: chars, charactersIgnoringModifiers: chars.lowercased() == chars ? chars : chars,
                                            isARepeat: false, keyCode: code) {
                    NSApp.sendEvent(e)
                }
            }
        case "render":
            // Draw a piece of the UI in a plain offscreen window (no glass, which can't be cached).
            let path = o["path"] as? String ?? "/tmp/running-render.png"
            let w = o["w"] as? Double ?? 360, h = o["h"] as? Double ?? 900
            let store = delegate.store, ui = delegate.ui
            let content: AnyView
            switch o["view"] as? String {
            case "sidebar": content = AnyView(Sidebar())
            case "kept": content = AnyView(KeptInspector())
            case "keptlist": content = AnyView(KeptView())
            case "procs": content = AnyView(ProcessesView())
            case "popover": content = AnyView(PopoverView(openWindow: { _, _ in }, close: {}))
            case "output": content = AnyView(InspectorView().onAppear { ui.inspectorTab = .output })
            case "settings": content = AnyView(SettingsView())
            case "shortcuts": content = AnyView(ShortcutsView())
            case "keep":
                if let d = store.keepDraft?.draft {
                    content = AnyView(KeepForm(mode: .keep(pid: 0), title: d.title, name: d.name, command: d.command, cwd: d.cwd, note: d.note, env: d.env))
                } else { content = AnyView(Text("no draft")) }
            default: content = AnyView(InspectorView())
            }
            let host = NSHostingView(rootView: content.environment(store).environment(ui).frame(width: w, height: h).background(Color(nsColor: .windowBackgroundColor)))
            let win = NSWindow(contentRect: NSRect(x: -5000, y: 0, width: w, height: h), styleMask: [.borderless], backing: .buffered, defer: false)
            win.contentView = host
            win.appearance = NSApp.effectiveAppearance
            win.orderFrontRegardless()
            DispatchQueue.main.asyncAfter(deadline: .now() + (o["delay"] as? Double ?? 1.5)) {
                let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
                host.cacheDisplay(in: host.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
                win.orderOut(nil)
            }
        case "dump":
            var out: [String: Any] = ["sidebar": "\(delegate.ui.sidebarVisibility)", "inspectorPref": delegate.store.prefs.inspectorShown, "route": "\(delegate.ui.route)",
                                      "selection": "\(String(describing: delegate.store.selection))", "rows": delegate.store.rows.count, "toast": delegate.store.toast?.text ?? "",
                                      "confirm": delegate.store.confirmation?.title ?? "", "kept": delegate.store.kept.map(\.name)]
            if let w = NSApp.windows.first(where: { $0.identifier?.rawValue == "main" }) {
                out["frame"] = NSStringFromRect(w.frame)
                func walk(_ v: NSView, _ d: Int) -> [String] {
                    guard d < 7 else { return [] }
                    let me = "\(String(repeating: " ", count: d))\(type(of: v)) \(Int(v.frame.minX)),\(Int(v.frame.width))x\(Int(v.frame.height))\(v.isHidden ? " hidden" : "")"
                    return [me] + v.subviews.flatMap { walk($0, d + 1) }
                }
                if let c = w.contentView { out["views"] = walk(c, 0).prefix(60).joined(separator: "\n") }
            }
            let path = o["path"] as? String ?? "/tmp/running-dump.json"
            if let d = try? JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted]) { try? d.write(to: URL(fileURLWithPath: path)) }
        case "popover": delegate.showPopover()
        case "window": delegate.showWindow(select: nil, route: nil)
        case "size":
            if let w = NSApp.windows.first(where: { $0.isVisible && $0.identifier?.rawValue == "main" }) {
                let f = w.frame
                w.setFrame(NSRect(x: f.minX, y: f.maxY - CGFloat(o["h"] as? Double ?? 600), width: CGFloat(o["w"] as? Double ?? 900), height: CGFloat(o["h"] as? Double ?? 600)), display: true)
            }
        case "route":
            switch o["to"] as? String {
            case "kept": delegate.ui.route = .kept
            case "settings": delegate.ui.route = .settings
            default: delegate.ui.route = .processes
            }
        case "select":
            if let pid = o["pid"] as? Int { delegate.store.selection = .job(pid) }
        case "appearance":
            NSApp.appearance = NSAppearance(named: (o["dark"] as? Bool ?? false) ? .darkAqua : .aqua)
        default: break
        }
    }
}
