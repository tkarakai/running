import SwiftUI

/// Window-level view state: which tool/page is showing, what the inspector shows, transient
/// modes. (Data and the selection live in Store, shared with the menu bar popover.)
@MainActor @Observable
final class UIState {
    var route: Route = .processes
    var inspectorTab: InspectorTab = .details
    var sortMenu = false
    var focusSearchTick = 0
    var focusListTick = 0
    var showShortcuts = false
    /// Shown on purpose while the window is too narrow for it to show by itself.
    var inspectorForced = false
    var sidebarVisibility: NavigationSplitViewVisibility = .all

    enum InspectorTab: String, CaseIterable, Identifiable {
        case details, output
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
    }

    func move(store: Store, by delta: Int) {
        let ids = route == .kept ? store.kept.map { ItemID.kept($0.index) } : Grouping.flatIDs(store.sections)
        guard !ids.isEmpty else { return }
        if route == .kept {
            let cur = store.keptSelection.flatMap { s in ids.firstIndex(of: .kept(s)) } ?? (delta > 0 ? -1 : ids.count)
            let next = max(0, min(ids.count - 1, cur + delta))
            if case .kept(let i) = ids[next] { store.keptSelection = i }
            return
        }
        let cur = store.selection.flatMap { ids.firstIndex(of: $0) } ?? (delta > 0 ? -1 : ids.count)
        store.selection = ids[max(0, min(ids.count - 1, cur + delta))]
    }

    func moveTo(store: Store, first: Bool) {
        if route == .kept {
            store.keptSelection = first ? store.kept.first?.index : store.kept.last?.index
            return
        }
        let ids = Grouping.flatIDs(store.sections)
        store.selection = first ? ids.first : ids.last
    }

    /// The key after `s`: t started, m memory, c CPU, n name, r reverse; anything else cancels.
    func sortKey(_ press: KeyPress, store: Store) -> KeyPress.Result {
        withAnimation(.snappy) { sortMenu = false }
        switch press.characters {
        case "t": store.setSort(.started)
        case "m": store.setSort(.memory)
        case "c": store.setSort(.cpu)
        case "n": store.setSort(.name)
        case "r": store.reverseSort()
        default: return .handled
        }
        let d = store.sortDesc ? store.sort.dirLabel.1 : store.sort.dirLabel.0
        store.flash("Sorted by \(store.sort.label.lowercased()) — \(d.lowercased())", .info)
        return .handled
    }
}

/// Pages in the sidebar. Running's own pages first; future utilities add their own cases
/// (see Tools/Tool.swift).
enum Route: Hashable {
    case processes
    case kept
    case tool(String)
    case settings
}
