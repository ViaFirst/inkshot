import SwiftUI

/// Which card is under the pointer. A shared object instead of @State: the @State macro
/// plugin is only shipped with full Xcode, and this project builds with Command Line Tools.
final class HoverTracker: ObservableObject {
    @Published var id: UUID?
}

struct HistoryView: View {
    @ObservedObject var store: HistoryStore
    @ObservedObject var hover: HoverTracker
    var onOpen: (HistoryItem) -> Void

    private let columns = [GridItem(.adaptive(minimum: 210), spacing: 14, alignment: .top)]

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Picker(L("Keep last:"), selection: $store.limit) {
                    ForEach(HistoryStore.limitChoices, id: \.self) { n in
                        Text(String(format: L("%d screenshots"), n)).tag(n)
                    }
                }
                .fixedSize()
                Text(L("Pinned screenshots are never deleted automatically."))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()
                Button { store.revealFolder() } label: {
                    Label(L("Show in Finder"), systemImage: "folder")
                }
            }
            .padding(12)

            Divider()

            if store.items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "photo.on.rectangle.angled").font(.system(size: 36)).foregroundStyle(.tertiary)
                    Text(L("No screenshots yet")).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, alignment: .leading, spacing: 14, pinnedViews: []) {
                        if !store.pinned.isEmpty {
                            Section(header: header(L("Pinned"), count: store.pinned.count)) {
                                cards(store.pinned)
                            }
                        }
                        Section(header: header(L("Recent"), count: store.recent.count)) {
                            cards(store.recent)
                        }
                    }
                    .padding(14)
                }
            }
        }
        .frame(minWidth: 600, minHeight: 400)
    }

    private func header(_ title: String, count: Int) -> some View {
        HStack {
            Text(title).font(.headline)
            Text("\(count)").font(.callout).foregroundStyle(.secondary)
            Spacer()
        }
        .padding(.top, 4)
    }

    private func cards(_ list: [HistoryItem]) -> some View {
        ForEach(list) { item in
            HistoryCard(item: item, store: store, hover: hover, onOpen: onOpen)
        }
    }
}

private struct HistoryCard: View {
    let item: HistoryItem
    @ObservedObject var store: HistoryStore
    @ObservedObject var hover: HoverTracker
    var onOpen: (HistoryItem) -> Void

    private var hovering: Bool { hover.id == item.id }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topTrailing) {
                thumbnail
                    .frame(maxWidth: .infinity)
                    .frame(height: 140)
                    .background(Color.primary.opacity(0.05))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.1)))
                    .contentShape(Rectangle())
                    .onTapGesture(count: 2) { onOpen(item) }
                    .onDrag { NSItemProvider(contentsOf: store.finalURL(item)) ?? NSItemProvider() }
                    .help(L("Double-click to edit, drag to share"))

                Button { store.togglePin(item) } label: {
                    Image(systemName: item.pinned ? "pin.fill" : "pin")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(item.pinned ? Color.accentColor : Color.primary)
                        .frame(width: 26, height: 26)
                        .background(.regularMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .padding(6)
                .opacity(item.pinned || hovering ? 1 : 0)
                .help(item.pinned ? L("Unpin") : L("Pin (never delete automatically)"))
            }

            HStack(alignment: .center, spacing: 6) {
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.callout)
                        .lineLimit(1)
                    Text("\(item.width) × \(item.height)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Button { store.copy(item) } label: { Image(systemName: "doc.on.doc") }
                    .buttonStyle(.borderless)
                    .help(L("Copy"))
                Menu {
                    actions
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help(L("More actions"))
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(hovering ? 0.06 : 0)))
        .onHover { inside in
            if inside { hover.id = item.id } else if hover.id == item.id { hover.id = nil }
        }
        .contextMenu { actions }
    }

    @ViewBuilder private var thumbnail: some View {
        if let image = store.thumbnail(item) {
            Image(nsImage: image).resizable().scaledToFit().id(item.revision)
        } else {
            Image(systemName: "photo").foregroundStyle(.tertiary)
        }
    }

    @ViewBuilder private var actions: some View {
        Button(L("Open in Editor")) { onOpen(item) }
        Button(L("Copy")) { store.copy(item) }
        Button(L("Show in Finder")) { store.reveal(item) }
        Divider()
        Button(item.pinned ? L("Unpin") : L("Pin")) { store.togglePin(item) }
        Button(L("Delete"), role: .destructive) { store.delete(item) }
    }
}
