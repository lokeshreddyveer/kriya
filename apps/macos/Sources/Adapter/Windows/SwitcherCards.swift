import AppKit
import SwiftUI

/// What a card needs to be drawn, with nothing of the window behind it, so it can be drawn (and looked at) on its own.
struct SwitcherCardData: Identifiable {
    let id: String
    let appName: String
    let title: String
    let icon: NSImage?
    let thumbnail: NSImage?
    let isMinimized: Bool
    /// The app is hidden (⌘H), so its windows are not on screen.
    var isHidden = false

    var fullLabel: String { title.isEmpty || title == appName ? appName : "\(appName)  ·  \(title)" }
}

/// The window switcher's cards: a dark glass panel with a large preview of each window, the app's icon on it, the window's
/// title under it, and the chosen window ringed. Looks the same whether or not Screen Recording lets previews be taken.
/// Pointing at a card chooses it (once the mouse has moved) and shows a close button; typed letters show above the cards.
struct SwitcherCardsView: View {
    let cards: [SwitcherCardData]
    let selected: Int
    let columns: Int
    var metrics = SwitcherMetrics()
    var query = ""
    var onChoose: (Int) -> Void = { _ in }
    var onHover: (Int) -> Void = { _ in }
    var onClose: (Int) -> Void = { _ in }

    var body: some View {
        let grid = Array(repeating: GridItem(.fixed(metrics.cardWidth), spacing: metrics.spacing), count: max(columns, 1))
        VStack(spacing: 0) {
            if !query.isEmpty { searchPill }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVGrid(columns: grid, spacing: metrics.spacing) {
                        ForEach(Array(cards.enumerated()), id: \.element.id) { index, card in
                            SwitcherCard(card: card, selected: index == selected, metrics: metrics, number: index < 9 && query.isEmpty ? index + 1 : nil,
                                         onClose: { onClose(index) })
                                .id(card.id)
                                .onTapGesture { onChoose(index) }
                                .onHover { inside in if inside { onHover(index) } }
                        }
                    }
                    .padding(.horizontal, metrics.padding).padding(.top, query.isEmpty ? metrics.padding : 12).padding(.bottom, 10)
                }
                .scrollIndicators(.hidden)
                .onChange(of: selected) { _, new in
                    if cards.indices.contains(new) { withAnimation(.smooth(duration: 0.12)) { proxy.scrollTo(cards[new].id) } }
                }
                .overlay { if cards.isEmpty { Text(query.isEmpty ? "No open windows" : "No window matches “\(query)”").foregroundStyle(.white.opacity(0.6)) } }
            }
            Text(cards.indices.contains(selected) ? cards[selected].fullLabel : " ")
                .font(.system(size: 13, weight: .medium)).foregroundStyle(.white.opacity(0.9)).lineLimit(1)
                .padding(.horizontal, 24).frame(maxWidth: .infinity).frame(height: metrics.hintHeight)
        }
        // The glass is filled straight into the rounded shape, so nothing of it shows outside the corners.
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .background(Color.black.opacity(0.42), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).strokeBorder(Color.white.opacity(0.16), lineWidth: 1))
        .environment(\.colorScheme, .dark)
        .animation(.smooth(duration: 0.14), value: selected)
        .animation(.smooth(duration: 0.18), value: cards.map(\.id))
    }

    private var searchPill: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 13)).foregroundStyle(.white.opacity(0.6))
            Text(query).font(.system(size: 15)).foregroundStyle(.white).lineLimit(1)
            Spacer(minLength: 0)
            Text("⌫ erase  ⎋ clear").font(.system(size: 11)).foregroundStyle(.white.opacity(0.4))
        }
        .padding(.horizontal, 14).frame(height: 32)
        .background(Color.white.opacity(0.1), in: Capsule())
        .padding(.horizontal, metrics.padding).padding(.top, 14)
        .transition(.opacity)
    }
}

private struct SwitcherCard: View {
    let card: SwitcherCardData
    let selected: Bool
    let metrics: SwitcherMetrics
    let number: Int?
    let onClose: () -> Void
    @State private var hovering = false

    var body: some View {
        VStack(spacing: 8) {
            ZStack(alignment: .bottomLeading) {
                preview
                if card.thumbnail != nil, let icon = card.icon {
                    Image(nsImage: icon).resizable().frame(width: metrics.badge, height: metrics.badge).shadow(color: .black.opacity(0.4), radius: 3, y: 1).padding(8)
                }
                if card.isMinimized || card.isHidden {
                    Image(systemName: card.isHidden ? "eye.slash.fill" : "minus.circle.fill").font(.system(size: 14)).foregroundStyle(.white.opacity(0.85))
                        .padding(8).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }
                if hovering {
                    Button(action: onClose) {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 18)).symbolRenderingMode(.palette)
                            .foregroundStyle(.white, Color.black.opacity(0.6))
                    }
                    .buttonStyle(.plain).help("Close this window").accessibilityLabel("Close the window \(card.title.isEmpty ? card.appName : card.title)")
                    .padding(6).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .transition(.opacity)
                }
                if let number, selected || hovering {
                    Text("\(number)").font(.system(size: 11, weight: .semibold, design: .rounded)).foregroundStyle(.white)
                        .frame(width: 20, height: 20).background(Color.black.opacity(0.55), in: Circle())
                        .padding(8).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                }
            }
            .frame(width: metrics.previewWidth, height: metrics.previewHeight)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
            .opacity(card.isMinimized || card.isHidden ? 0.6 : 1)

            Text(card.title.isEmpty ? card.appName : card.title)
                .font(.system(size: metrics.titleSize, weight: selected ? .semibold : .regular)).foregroundStyle(.white.opacity(selected ? 1 : 0.78))
                .lineLimit(1).frame(maxWidth: .infinity)
        }
        .padding(8)
        .frame(width: metrics.cardWidth, height: metrics.cardHeight, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 17, style: .continuous).fill(Color.white.opacity(selected ? 0.16 : (hovering ? 0.07 : 0))))
        .overlay(RoundedRectangle(cornerRadius: 17, style: .continuous).strokeBorder(Color.white.opacity(selected ? 0.85 : 0), lineWidth: 2.5))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .animation(.smooth(duration: 0.12), value: hovering)
    }

    @ViewBuilder
    private var preview: some View {
        if let picture = card.thumbnail {
            Image(nsImage: picture).resizable().aspectRatio(contentMode: .fill)
                .transition(.opacity)
        } else {
            ZStack {
                LinearGradient(colors: [Color.white.opacity(0.14), Color.white.opacity(0.05)], startPoint: .top, endPoint: .bottom)
                if let icon = card.icon { Image(nsImage: icon).resizable().frame(width: 64 * metrics.scale, height: 64 * metrics.scale).shadow(color: .black.opacity(0.35), radius: 6, y: 2) }
            }
        }
    }
}
