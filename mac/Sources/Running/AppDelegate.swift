import AppKit
import SwiftUI

/// A menu bar app: a status item with a popover, and a full window opened from it. No Dock
/// icon (LSUIElement). The main menu isn't visible, but its key equivalents still work while
/// the window is key — that's where the ⌘ shortcuts live.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSPopoverDelegate, NSMenuItemValidation {
    let store = Store()
    let ui = UIState()
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var window: NSWindow?
    private var hotKey: HotKey?
    private var lastPopoverClose = Date.distantPast

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.setActivationPolicy(.accessory)
        buildMenu()
        setUpStatusItem()
        setUpPopover()
        store.start()
        observeCount()
        store.prefs.onHotKeyChange = { [weak self] in self?.updateHotKey() }
        updateHotKey()
        DebugChannel.install(self)
        NotificationCenter.default.addObserver(forName: .showShortcuts, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.showWindow(select: nil, route: nil)
                self?.ui.showShortcuts = true
            }
        }
        let args = ProcessInfo.processInfo.arguments
        if args.contains("--open-window") || !UserDefaults.standard.bool(forKey: "hasLaunched") {
            // First launch: show the window, so it's obvious where the app went.
            UserDefaults.standard.set(true, forKey: "hasLaunched")
            showWindow(select: nil, route: args.contains("--kept") ? .kept : nil)
        }
        if args.contains("--open-popover") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self.showPopover() }
        }
    }

    func applicationWillTerminate(_ note: Notification) { store.core.stop() }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showWindow(select: nil, route: nil)
        return false
    }

    // ── status item ──────────────────────────────────────────────────────
    private func setUpStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let b = statusItem.button else { return }
        b.image = AppArt.menuBarImage(count: nil)
        b.imagePosition = .imageLeading
        b.target = self
        b.action = #selector(statusClicked(_:))
        b.sendAction(on: [.leftMouseUp, .rightMouseUp])
        b.toolTip = "Running — what you started, across all your terminals (⌃⌥R)"
        b.setAccessibilityLabel("Running")
    }

    private func observeCount() {
        withObservationTracking {
            _ = store.rows
            _ = store.loaded
            _ = store.prefs.showCountInMenuBar
        } onChange: { [weak self] in
            DispatchQueue.main.async { self?.updateCount(); self?.observeCount() }
        }
        updateCount()
    }

    private func updateCount() {
        guard let b = statusItem?.button else { return }
        let n = store.userJobs.count
        if store.prefs.showCountInMenuBar && store.loaded {
            b.title = " \(n)"
            b.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize - 1, weight: .medium)
        } else {
            b.title = ""
        }
        b.setAccessibilityValue("\(n) running")
    }

    @objc private func statusClicked(_ sender: NSStatusBarButton) {
        let ev = NSApp.currentEvent
        if ev?.type == .rightMouseUp || ev?.modifierFlags.contains(.control) == true {
            showStatusMenu()
            return
        }
        togglePopover()
    }

    private func showStatusMenu() {
        let m = NSMenu()
        m.addItem(withTitle: "Open Running", action: #selector(openFromMenu), keyEquivalent: "").target = self
        m.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: "").target = self
        m.addItem(.separator())
        m.addItem(withTitle: "Quit Running", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        statusItem.menu = m
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    // ── popover ──────────────────────────────────────────────────────────
    private func setUpPopover() {
        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        let view = PopoverView(
            openWindow: { [weak self] sel, route in
                self?.popover.performClose(nil)
                self?.showWindow(select: sel, route: route)
            },
            close: { [weak self] in self?.popover.performClose(nil) }
        )
        .environment(store)
        .environment(ui)
        let host = NSHostingController(rootView: view)
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host
    }

    func togglePopover() {
        if popover.isShown { popover.performClose(nil) } else if Date().timeIntervalSince(lastPopoverClose) > 0.2 { showPopover() }
    }

    func showPopover() {
        guard let b = statusItem.button else { return }
        // Recreate the content each time so it opens fresh (filter cleared, focus in the search field).
        setUpPopover()
        store.popoverVisible = true
        NSApp.activate()
        popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func popoverDidClose(_ notification: Notification) {
        store.popoverVisible = false
        lastPopoverClose = Date()
    }

    private func updateHotKey() {
        hotKey = nil
        if store.prefs.hotKeyEnabled { hotKey = HotKey.controlOptionR { [weak self] in self?.togglePopover() } }
    }

    // ── main window ──────────────────────────────────────────────────────
    @objc func openFromMenu() { showWindow(select: nil, route: nil) }
    @objc func openSettings() { showWindow(select: nil, route: .settings) }

    func showWindow(select: ItemID?, route: Route?) {
        if let route { ui.route = route }
        if let select {
            store.selection = select
            if case .job(let pid) = select, let j = store.job(pid), j.kind == .app { store.showAll = true }
        }
        let w = window ?? makeWindow()
        window = w
        store.windowVisible = true
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
        ui.focusListTick += 1
    }

    private func makeWindow() -> NSWindow {
        let root = RootView().environment(store).environment(ui)
        let host = NSHostingController(rootView: root)
        host.sceneBridgingOptions = [.all]
        let w = NSWindow(contentViewController: host)
        w.title = "Running"
        w.identifier = NSUserInterfaceItemIdentifier("main")
        w.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        w.toolbarStyle = .unified
        w.titlebarSeparatorStyle = .automatic
        w.minSize = NSSize(width: 620, height: 400)
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.collectionBehavior.insert(.fullScreenPrimary)
        w.tabbingMode = .disallowed
        if !w.setFrameUsingName("RunningMain") {
            w.setContentSize(NSSize(width: 1180, height: 720))
            w.center()
        }
        w.setFrameAutosaveName("RunningMain")
        return w
    }

    func windowWillClose(_ notification: Notification) {
        if (notification.object as? NSWindow) === window { store.windowVisible = false }
    }

    func windowDidMiniaturize(_ notification: Notification) { store.windowVisible = false }
    func windowDidDeminiaturize(_ notification: Notification) { store.windowVisible = true }

    // ── main menu (invisible; its key equivalents are the ⌘ shortcuts) ────
    private func buildMenu() {
        let main = NSMenu()
        func sub(_ title: String, _ items: [NSMenuItem]) {
            let it = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            let m = NSMenu(title: title)
            items.forEach(m.addItem)
            it.submenu = m
            main.addItem(it)
        }
        func item(_ t: String, _ sel: Selector, _ key: String, _ mods: NSEvent.ModifierFlags = .command, target: AnyObject? = nil) -> NSMenuItem {
            let i = NSMenuItem(title: t, action: sel, keyEquivalent: key)
            i.keyEquivalentModifierMask = mods
            i.target = target ?? self
            return i
        }
        sub("Running", [
            item("Settings…", #selector(menuSettings), ","),
            .separator(),
            item("Hide Running", #selector(NSApplication.hide(_:)), "h", target: NSApp),
            item("Quit Running", #selector(NSApplication.terminate(_:)), "q", target: NSApp),
        ])
        sub("Edit", [
            item("Undo", Selector(("undo:")), "z", target: nil as AnyObject?),
            item("Redo", Selector(("redo:")), "z", [.command, .shift], target: nil as AnyObject?),
            .separator(),
            item("Cut", #selector(NSText.cut(_:)), "x", target: nil as AnyObject?),
            item("Copy", #selector(NSText.copy(_:)), "c", target: nil as AnyObject?),
            item("Paste", #selector(NSText.paste(_:)), "v", target: nil as AnyObject?),
            item("Select All", #selector(NSText.selectAll(_:)), "a", target: nil as AnyObject?),
            .separator(),
            item("Find", #selector(menuFind), "f"),
        ])
        sub("View", [
            item("Processes", #selector(menuProcesses), "1"),
            item("Kept", #selector(menuKept), "2"),
            .separator(),
            item("Show / Hide Inspector", #selector(menuInspector), "i"),
            item("Show / Hide Sidebar", #selector(menuSidebar), "s", [.command, .control]),
            item("Show App & System Servers", #selector(menuShowAll), "a", [.command, .shift]),
            .separator(),
            item("Refresh", #selector(menuRefresh), "r"),
            item("Keyboard Shortcuts", #selector(menuShortcuts), "/"),
        ])
        sub("Process", [
            item("Open Web Page", #selector(menuOpenWeb), "o"),
            item("Focus Terminal", #selector(menuFocus), "t", [.command, .shift]),
            item("Restart…", #selector(menuRestart), "r", [.command, .shift]),
            item("Stop", #selector(menuStop), "\u{8}"),
            item("Force Kill", #selector(menuKill), "\u{8}", [.command, .option]),
        ])
        sub("Window", [
            item("Close", #selector(NSWindow.performClose(_:)), "w", target: nil as AnyObject?),
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m", target: nil as AnyObject?),
            item("Zoom", #selector(NSWindow.performZoom(_:)), "", target: nil as AnyObject?),
        ])
        NSApp.mainMenu = main
    }

    @objc private func menuSettings() { showWindow(select: nil, route: .settings) }
    @objc private func menuFind() { if popover.isShown { return }; ui.focusSearchTick += 1 }
    @objc private func menuProcesses() { ui.route = .processes; ui.focusListTick += 1 }
    @objc private func menuKept() { ui.route = .kept; ui.focusListTick += 1 }
    @objc private func menuInspector() { store.prefs.inspectorShown.toggle() }
    @objc private func menuSidebar() { withAnimation { ui.sidebarVisibility = ui.sidebarVisibility == .detailOnly ? .all : .detailOnly } }
    @objc private func menuShowAll() { store.showAll.toggle() }
    @objc private func menuRefresh() { Task { await store.refresh() }; store.flash("Refreshed", .info) }
    @objc private func menuShortcuts() { ui.showShortcuts = true }

    private var current: (Job, Member?)? {
        if ui.route == .kept, let k = store.keptEntry(store.keptSelection), let j = store.liveJob(k) { return (j, nil) }
        guard ui.route == .processes, let j = store.selectedJob else { return nil }
        return (j, store.selectedMember)
    }
    @objc private func menuOpenWeb() { if let (j, m) = current { store.openWeb(j, member: m) } }
    @objc private func menuFocus() { if let (j, _) = current { store.focus(j) } }
    @objc private func menuRestart() { if let (j, m) = current, m == nil { store.restart(j) } }
    @objc private func menuStop() {
        if ui.route == .kept, store.liveJob(store.keptEntry(store.keptSelection) ?? KeptEntry.none) == nil, let k = store.keptEntry(store.keptSelection) { return store.confirmForget(k) }
        if let (j, m) = current { store.stop(j, member: m) }
    }
    @objc private func menuKill() { if let (j, m) = current { store.stop(j, member: m, force: true) } }

    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        // Text fields get ⌘⌫ (delete to line start) — don't steal it.
        if item.action == #selector(menuStop) || item.action == #selector(menuKill) {
            if NSApp.keyWindow?.firstResponder is NSTextView { return false }
        }
        return true
    }
}

extension KeptEntry {
    static let none = KeptEntry(index: -1, name: "", command: "", cwd: "", env: [:], note: "", ports: [], session: nil, kept: "", line: "", livePid: nil)
}
