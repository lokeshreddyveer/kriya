import SwiftUI

/// The tab strip at the top of a pane: the segmented picker in a bordered, softly filled frame.
extension View {
    func paneTabBar(maxWidth: CGFloat? = nil) -> some View {
        // The frame is as wide as the tabs inside it, on every screen. (`maxWidth` is kept so existing callers still compile.)
        self
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            .padding(3)
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.16), lineWidth: 1))
    }

    /// A solid strip above a pane's content, so rows scrolling past never show behind the tabs.
    func paneHeader() -> some View {
        self
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .background(Color(nsColor: .windowBackgroundColor))
            .overlay(alignment: .bottom) { Divider() }
            .zIndex(1)
    }
}

/// The menu that holds a pane's reset, import and export actions: a plain, labelled button instead of a bare "⋯".
struct MoreMenuLabel: View {
    var body: some View {
        Label("More", systemImage: "ellipsis")
            .labelStyle(.titleAndIcon)
    }
}
