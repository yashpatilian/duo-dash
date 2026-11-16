import SwiftUI

/// Stand-in for screens that later build steps will fill in.
struct ComingSoonView: View {
    let item: DockItem
    let step: Int
    let detail: String

    var body: some View {
        Card(padding: 24) {
            EmptyStateView(symbol: item.symbol, title: item.title,
                           message: "\(detail)\n\nComing in build step \(step).")
        }
    }
}
