import SwiftUI

/// Cart screen (Paper L and L2). One room's cart, or every room sectioned by room.
struct CartSheet: View {
    /// A room's cart; nil: every room, sectioned by room.
    let projectID: UUID?
    @Environment(ProjectStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    private var items: [CartItem] { RoomCart.items(in: store.projects, room: projectID) }
    private var roomName: String? { projectID.flatMap { id in store.projects.first { $0.id == id }?.name } }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                if items.isEmpty { empty } else { list; footer }
            }
            .background(Theme.ground)
            .toolbar(.hidden, for: .navigationBar)
        }
        .presentationDetents([.large])
        .presentationBackground(Theme.ground)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 4) {
                Button { dismiss() } label: {
                    Image(systemName: "chevron.down").font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.wood)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Close cart")
                Text("Cart").font(.forma(24, bold: true, relativeTo: .title)).foregroundStyle(Theme.ink)
                Spacer()
                Text(String(format: "%02d", items.count)).font(.forma(12)).foregroundStyle(Theme.muted)
                    .contentTransition(.numericText(value: Double(items.count)))
                    .accessibilityLabel("\(items.count) item\(items.count == 1 ? "" : "s")")
            }
            Text(roomName.map { "Added to \($0)" } ?? "Everything added to your rooms")
                .font(.forma(11)).foregroundStyle(Theme.muted).padding(.leading, 48)
        }
        .padding(.horizontal, 12).padding(.top, 8)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if projectID == nil {
                    ForEach(sections, id: \.id) { section in
                        sectionHeader(section.name, section.items)
                        rows(section.items)
                    }
                } else {
                    rows(items).padding(.top, 8)
                }
            }
            .padding(.horizontal, 24).padding(.bottom, 16)
        }
    }

    private var sections: [(id: UUID, name: String, items: [CartItem])] {
        var order: [UUID] = []
        for i in items where !order.contains(i.projectID) { order.append(i.projectID) }
        return order.map { id in
            let group = items.filter { $0.projectID == id }
            return (id, group[0].roomName, group)
        }
    }

    private func sectionHeader(_ name: String, _ group: [CartItem]) -> some View {
        let sub = RoomCart.subtotal(group)
        return HStack {
            Text(name).font(.forma(13, bold: true)).foregroundStyle(Theme.ink)
            Spacer()
            Text("\(group.count) item\(group.count == 1 ? "" : "s") · \(usd(sub.total))")
                .font(.forma(11)).foregroundStyle(Theme.muted)
        }
        .padding(.top, 20).padding(.bottom, 8)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    private func rows(_ group: [CartItem]) -> some View {
        VStack(spacing: 0) {
            ForEach(group) { item in
                Divider().overlay(Theme.hairline)
                NavigationLink {
                    ProductDetailView(product: item.product, mode: .inRoom(projectID: item.projectID, placementID: item.placement.id))
                } label: { row(item) }
                .buttonStyle(.plain)
            }
            Divider().overlay(Theme.hairline)
        }
    }

    private func row(_ item: CartItem) -> some View {
        HStack(spacing: 14) {
            AsyncImage(url: item.product.imageURL) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Theme.sand.overlay(Image(systemName: "photo").foregroundStyle(Theme.muted))
            }
            .frame(width: 72, height: 72).clipShape(RoundedRectangle(cornerRadius: 16))
            .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(item.product.title).font(.forma(13, bold: true)).foregroundStyle(Theme.ink).lineLimit(2)
                Text(item.product.retailer).font(.forma(11)).foregroundStyle(Theme.muted).lineLimit(1)
                Text(item.product.price).font(.forma(13, bold: true)).foregroundStyle(Theme.ink)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.wood)
        }
        .padding(.vertical, 14)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(item.product.title), \(item.product.retailer), \(item.product.price)")
        .accessibilityHint("Opens product details")
    }

    private var footer: some View {
        let sub = RoomCart.subtotal(items)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Subtotal")
                Spacer()
                Text(usd(sub.total))
            }
            .font(.forma(12)).foregroundStyle(Theme.muted)
            .accessibilityElement(children: .combine)
            if sub.unpriced > 0 {
                Text("\(sub.unpriced) without a listed price").font(.forma(11)).foregroundStyle(Theme.muted)
            }
            Text("Prices exclude shipping and tax.").font(.forma(11)).foregroundStyle(Theme.muted)
            // Agent checkout is not built: the button stays visible so the design reads, but inert.
            Button {} label: { Text("Check out") }
                .buttonStyle(PillButtonStyle())
                .disabled(true).opacity(0.5)
                .padding(.top, 4)
                .accessibilityIdentifier("checkout")
            Text("Checkout isn't available yet. Open each item's original listing to buy.")
                .font(.forma(11)).foregroundStyle(Theme.muted)
        }
        .padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.ground)
        .overlay(alignment: .top) { Theme.hairline.frame(height: 1) }
    }

    private var empty: some View {
        VStack(spacing: 8) {
            Spacer()
            Text("Nothing in your cart yet.").font(.forma(14, bold: true)).foregroundStyle(Theme.ink)
            Text("Add products from Shop a vibe.").font(.forma(12)).foregroundStyle(Theme.muted)
            Spacer()
        }
        .multilineTextAlignment(.center).frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    private func usd(_ value: Double) -> String {
        value.formatted(.currency(code: "USD").precision(.fractionLength(value.rounded() == value ? 0 : 2)))
    }
}
