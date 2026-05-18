import SwiftUI

extension View {
    /// Single-line, truncated, with a tooltip showing the full text.
    /// Drop-in replacement for `.lineLimit(1)` on a `Text` view where the
    /// content might overflow horizontally.
    func truncatedWithTooltip(_ full: String?, tail: Bool = true) -> some View {
        self
            .lineLimit(1)
            .truncationMode(tail ? .tail : .middle)
            .help(full ?? "")
    }
}
