import SwiftUI

// MARK: - Card Style

/// Standard card appearance used throughout Biosense — rounded background
/// with system-grouped secondary fill.  Replace inline
/// `.padding().background(...).clipShape(...)` chains with `.biosenseCardStyle()`.
struct BiosenseCardStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding()
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

extension View {
    func biosenseCardStyle() -> some View {
        modifier(BiosenseCardStyle())
    }
}
