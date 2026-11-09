import AppKit
import SwiftUI

/// A menu bar app: a status item with a popover, and a full window opened from it. Launched
/// as LSUIElement (no Dock icon); while the window is open it becomes a regular app — Dock
/// icon, ⌘-Tab, its menu bar — and goes back to the menu bar alone when the window closes.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSPopoverDelegate, NSMenuItemValidation {
    let store = Store()
    let ui = UIState()
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private var window: NSWindow?
    private var hotKey: HotKey?
    private var windowHotKey: HotKey?
    private var shownCount: Int?? = .none
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
        b.imagePosition = .imageOnly
        b.target = self
        b.action = #selector(statusClicked(_:))
        b.sendAction(on: [.leftMouseUp, .rightMouseUp])
        b.toolTip = "Running — what you started, across all your terminals (⌃⌥R; the window: ⇧⌃⌥R)"
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
        let count: Int? = store.prefs.showCountInMenuBar && store.loaded ? n : nil
        if shownCount != .some(count) {
            shownCount = .some(count)
            b.image = AppArt.menuBarImage(count: count)
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
        windowHotKey = nil
        guard store.prefs.hotKeyEnabled else { return }
        hotKey = HotKey.controlOptionR { [weak self] in self?.togglePopover() }
        windowHotKey = HotKey.shiftControlOptionR { [weak self] in self?.toggleWindow() }
    }

    var hotKeysRegistered: [Bool] { [hotKey != nil, windowHotKey != nil] }

    /// ⇧⌃⌥R: bring the window forward, or put it away if it's already in front.
    func toggleWindow() {
        if let w = window, w.isVisible, w.isKeyWindow, NSApp.isActive { w.performClose(nil) } else {
            if popover.isShown { popover.performClose(nil) }
            showWindow(select: nil, route: nil)
        }
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
        // A regular app while the window is open: in the Dock and ⌘-Tab, so it's easy to get
        // back to after switching away.
        let wasAccessory = NSApp.activationPolicy() != .regular
        if wasAccessory { NSApp.setActivationPolicy(.regular) }
        if w.isMiniaturized { w.deminiaturize(nil) }
        w.makeKeyAndOrderFront(nil)
        // From a global shortcut another app is in front, and the polite NSApp.activate() can be
        // turned down — the window would open behind it. Put it on top regardless, and insist.
        w.orderFrontRegardless()
        bringToFront()
        // Right after leaving accessory mode activation can be ignored once more; retry.
        if wasAccessory { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in self?.bringToFront() } }
        ui.focusListTick += 1
    }

    private func bringToFront() {
        guard !NSApp.isActive || window?.isKeyWindow != true else { return }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
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
        w.hidesOnDeactivate = false
        if !w.setFrameUsingName("RunningMain") {
            w.setContentSize(NSSize(width: 1180, height: 720))
            w.center()
        }
        w.setFrameAutosaveName("RunningMain")
        return w
    }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === window else { return }
        store.windowVisible = false
        // Back to the menu bar only. Deferred so the close finishes first; the app that was in
        // front before becomes active again.
        DispatchQueue.main.async { [weak self] in
            guard self?.window?.isVisible != true, self?.window?.isMiniaturized != true else { return }
            NSApp.setActivationPolicy(.accessory)
        }
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
            item("About Running", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), "", target: NSApp),
            .separator(),
            item("Settings…", #selector(menuSettings), ","),
            .separator(),
            item("Hide Running", #selector(NSApplication.hide(_:)), "h", target: NSApp),
            item("Hide Others", #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option], target: NSApp),
            item("Show All", #selector(NSApplication.unhideAllApplications(_:)), "", target: NSApp),
            .separator(),
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
            item("Close", #selector(menuClose), "w"),
            item("Minimize", #selector(NSWindow.performMiniaturize(_:)), "m", target: nil as AnyObject?),
            item("Zoom", #selector(NSWindow.performZoom(_:)), "", target: nil as AnyObject?),
            .separator(),
            item("Running", #selector(openFromMenu), "r", [.control, .option, .shift]),
        ])
        NSApp.mainMenu = main
        NSApp.windowsMenu = main.items.last?.submenu
    }

    /// ⌘W: closes whatever's in front — a sheet, the popover, Settings' shortcuts list, or the window.
    @objc private func menuClose() {
        if popover.isShown { return popover.performClose(nil) }
        guard let w = NSApp.keyWindow ?? window else { return }
        if w.attachedSheet != nil {
            // SwiftUI owns its sheets; close the one that has nothing to lose, leave forms alone.
            if ui.showShortcuts { ui.showShortcuts = false } else { NSSound.beep() }
            return
        }
        w.performClose(nil)
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
