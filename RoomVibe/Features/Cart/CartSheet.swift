import SwiftUI

/// Cart screen (Paper L and L2). One room's cart, or every room sectioned by room.
struct CartSheet: View {
    /// A room's cart; nil: every room, sectioned by room.
    let projectID: UUID?
    @Environment(ProjectStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var editingBudget = false

    private var motion: Animation? { reduceMotion ? nil : .spring(duration: 0.3, bounce: 0) }

    private var items: [CartItem] { RoomCart.items(in: store.projects, room: projectID) }
    private var budget: Double? { projectID.flatMap { id in store.projects.first { $0.id == id }?.budgetUSD } }
    private var roomName: String? { projectID.flatMap { id in store.projects.first { $0.id == id }?.name } }

    var body: some View {
        NavigationStack {
            Group {
                if items.isEmpty {
                    VStack(spacing: 0) { header; empty }
                } else {
                    // Everything scrolls so a long cart or large text never squeezes rows; only checkout stays pinned.
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            header
                            if projectID != nil, let budget { budgetCard(budget) }
                            list
                            totals
                        }
                    }
                    .safeAreaInset(edge: .bottom, spacing: 0) { checkoutBar }
                }
            }
            .animation(motion, value: items.map(\.id))
            .background(Theme.ground)
            .toolbar(.hidden, for: .navigationBar)
        }
        .sheet(isPresented: $editingBudget) {
            BudgetSheet(current: budget, picksTotal: RoomCart.subtotal(items).total,
                        note: "Your cart total stays the same. Only the budget changes.", applyTitle: "Update budget") { new in
                guard let id = projectID, var project = store.projects.first(where: { $0.id == id }) else { return }
                project.budgetUSD = new
                store.update(project)
            }
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
        .padding(.leading, 12).padding(.trailing, 24).padding(.top, 8)
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            if projectID == nil {
                ForEach(sections, id: \.id) { section in
                    sectionHeader(section.name, section.items)
                    rows(section.items)
                }
            } else {
                rows(items).padding(.top, 8)
                if let budget, let left = Optional(budget - RoomCart.subtotal(items).total), left > 0, left <= budget * 0.2 { warning(left: left, budget: budget) }
            }
        }
        .padding(.horizontal, 24).padding(.bottom, 16)
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
                VStack(spacing: 0) {
                    Divider().overlay(Theme.hairline)
                    NavigationLink {
                        ProductDetailView(product: item.product, mode: .inRoom(projectID: item.projectID, placementID: item.placement.id))
                    } label: { row(item) }
                    .buttonStyle(.plain)
                }
                .transition(.opacity.combined(with: .move(edge: .trailing)))
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
                Text(item.product.title).font(.forma(13, bold: true)).foregroundStyle(Theme.ink)
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                Text(item.product.retailer).font(.forma(11)).foregroundStyle(Theme.muted).lineLimit(1)
                HStack(spacing: 8) {
                    Text(item.product.price).font(.forma(13, bold: true)).foregroundStyle(Theme.ink)
                        .fixedSize(horizontal: true, vertical: false)
                    if let budget, budget > 0, let price = item.product.priceUSD {
                        HStack(spacing: 4) {
                            Circle().fill(Theme.sage.opacity(price / budget >= 0.5 ? 1 : 0.55)).frame(width: 8, height: 8)
                            Text("\(Int((price / budget * 100).rounded()))% of budget").font(.forma(10)).foregroundStyle(Theme.muted)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
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

    private func budgetCard(_ budget: Double) -> some View {
        let spent = RoomCart.subtotal(items).total
        let left = budget - spent
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(usd(spent)).font(.forma(20, bold: true)).foregroundStyle(Theme.ink)
                        .contentTransition(.numericText(value: spent))
                    Text("of \(usd(budget))").font(.forma(12)).foregroundStyle(Theme.muted)
                }
                Spacer()
                Button { editingBudget = true } label: {
                    HStack(spacing: 4) {
                        Text("Change").font(.forma(12))
                        Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(Theme.wood).frame(minHeight: 44).contentShape(Rectangle())
                }
                .padding(.vertical, -14)
                .accessibilityIdentifier("changeBudget")
            }
            BudgetBar(budget: budget, segments: items.map { .init(id: "\($0.id)", label: $0.product.title, amount: $0.product.priceUSD ?? 0) })
            if left < 0 {
                Text("Over budget by \(usd(-left)).").font(.forma(11)).foregroundStyle(Theme.terracotta)
            } else {
                Text("\(usd(left)) left. Prices exclude shipping and tax.").font(.forma(11)).foregroundStyle(Theme.muted)
            }
        }
        .padding(.vertical, 14).padding(.horizontal, 16)
        .background(Theme.sand, in: RoundedRectangle(cornerRadius: 20))
        .animation(reduceMotion ? nil : .spring(duration: 0.4, bounce: 0), value: spent)
        .padding(.horizontal, 24).padding(.top, 16)
    }

    private func warning(left: Double, budget: Double) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle").font(.system(size: 14)).foregroundStyle(Theme.terracotta)
            Text("Adding anything over \(usd(left)) goes past your \(usd(budget)) budget.")
                .font(.forma(11)).foregroundStyle(Theme.ink)
        }
        .padding(.vertical, 10).padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(hex: 0xF3E1D5), in: RoundedRectangle(cornerRadius: 16))
        .padding(.top, 16)
        .accessibilityElement(children: .combine)
    }

    private var totals: some View {
        let sub = RoomCart.subtotal(items)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Subtotal")
                Spacer()
                Text(usd(sub.total)).contentTransition(.numericText(value: sub.total))
            }
            .font(.forma(12)).foregroundStyle(Theme.muted)
            .accessibilityElement(children: .combine)
            if sub.unpriced > 0 {
                Text("\(sub.unpriced) without a listed price").font(.forma(11)).foregroundStyle(Theme.muted)
            }
            Text("Prices exclude shipping and tax.").font(.forma(11)).foregroundStyle(Theme.muted)
        }
        .animation(motion, value: sub.total)
        .padding(.horizontal, 24).padding(.bottom, 24)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var checkoutBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Agent checkout is not built: the button stays visible so the design reads, but inert.
            Button {} label: { Text("Check out") }
                .buttonStyle(PillButtonStyle())
                .disabled(true).opacity(0.5)
                .accessibilityIdentifier("checkout")
            Text("Checkout isn't available yet. Open each item's original listing to buy.")
                .font(.forma(11)).foregroundStyle(Theme.muted)
        }
        .padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.ground, ignoresSafeAreaEdges: .bottom)
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
