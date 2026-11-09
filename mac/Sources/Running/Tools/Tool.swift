import SwiftUI

// The window is a home for several utilities. Each one is a `Tool`: a sidebar section with its
// pages. Running (processes + kept) is the first; a future one — say, keeping installed Mac
// apps up to date — adds a type here and lists itself in `ToolRegistry.all`.

struct ToolPage: Identifiable, Hashable {
    var route: Route
    var title: String
    var symbol: String
    var shortcut: KeyEquivalent?
    var id: Route { route }
}

@MainActor
protocol Tool {
    var id: String { get }
    var title: String { get }
    func pages(_ store: Store) -> [ToolPage]
    /// Count shown next to a page in the sidebar.
    func badge(_ page: ToolPage, _ store: Store) -> Int?
}

struct RunningTool: Tool {
    let id = "running"
    let title = "Running"
    func pages(_ store: Store) -> [ToolPage] {
        [
            ToolPage(route: .processes, title: "Processes", symbol: "list.bullet.rectangle.portrait", shortcut: "1"),
            ToolPage(route: .kept, title: "Kept", symbol: "bookmark", shortcut: "2"),
        ]
    }
    func badge(_ page: ToolPage, _ store: Store) -> Int? {
        switch page.route {
        case .processes: return store.loaded ? store.visibleCount : nil
        case .kept: return store.kept.count
        default: return nil
        }
    }
}

@MainActor
enum ToolRegistry {
    static let all: [any Tool] = [RunningTool()]
}
