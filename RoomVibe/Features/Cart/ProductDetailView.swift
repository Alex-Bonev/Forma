import SwiftUI

/// Product detail (Paper PD1 while shopping, PD2 from the cart).
struct ProductDetailView: View {
    enum Mode {
        /// Opened from a shopping result. `projectID`: the room Add puts it in, if any. `category`: the shopping row's category.
        case shopping(projectID: UUID?, category: String)
        /// Opened from the cart: the product is already in that room.
        case inRoom(projectID: UUID, placementID: UUID)
    }
    let product: ShopProduct
    let mode: Mode

    @Environment(ProjectStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    private var projectID: UUID? {
        switch mode {
        case .shopping(let id, _): id
        case .inRoom(let id, _): id
        }
    }
    private var project: Project? { store.projects.first { $0.id == projectID } }
    private var host: String? { product.productURL.host()?.replacingOccurrences(of: "www.", with: "") }

    private var size: String? {
        guard let d = product.dimensionsCm, d.count == 3, d.allSatisfy({ $0 > 0 }) else { return nil }
        return d.map { $0.formatted(.number.precision(.fractionLength(0...1))) }.joined(separator: " × ") + " cm"
    }

    private var rows: [(String, String)] {
        [("Size", size), ("Category", product.category), ("Store", product.retailer), ("Listing", host)]
            .compactMap { label, value in value.flatMap { $0.isEmpty ? nil : (label, $0) } }
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    backButton
                    hero.padding(.top, 16)
                    header.padding(.top, 20)
                    details.padding(.top, 22)
                    // Richer scraped details (description, material, color, stock, returns) go here once the backend sends them.
                    Text("Details come from the store's listing. Check the original listing before you buy.")
                        .font(.forma(10)).foregroundStyle(Theme.muted)
                        .padding(.top, 16)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
            }
            actions
        }
        .background(Theme.ground)
        .foregroundStyle(Theme.ink)
        .navigationBarBackButtonHidden()
        .toolbar(.hidden, for: .navigationBar)
    }

    private var backButton: some View {
        Button { dismiss() } label: {
            Image(systemName: "chevron.left").font(.system(size: 16, weight: .semibold)).foregroundStyle(Theme.wood)
                .frame(width: 44, height: 44).background(Theme.sand, in: Circle())
        }
        .padding(.top, 12)
        .accessibilityLabel("Back")
    }

    private var hero: some View {
        RoundedRectangle(cornerRadius: 24).fill(Theme.tiles[0])
            .frame(height: 300)
            .overlay {
                AsyncImage(url: product.imageURL) { image in
                    image.resizable().scaledToFill()
                } placeholder: { Color.clear }
            }
            .clipShape(RoundedRectangle(cornerRadius: 24))
            .accessibilityHidden(true)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text([product.retailer, host].compactMap { $0 }.joined(separator: " · "))
                    .font(.forma(11)).foregroundStyle(Theme.muted).lineLimit(1)
                if case .inRoom = mode, let name = project?.name {
                    Text("In \(name)")
                        .font(.forma(10, bold: true)).lineLimit(1)
                        .padding(.horizontal, 8).frame(height: 22)
                        .background(Theme.sand, in: Capsule())
                        .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 1))
                }
            }
            Text(product.title).font(.forma(20, bold: true))
            Text(product.price).font(.forma(24, bold: true))
        }
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Details").font(.forma(13, bold: true)).padding(.bottom, 8)
            ForEach(rows, id: \.0) { label, value in
                Divider().overlay(Theme.hairline)
                HStack(alignment: .top) {
                    Text(label).foregroundStyle(Theme.muted)
                    Spacer(minLength: 16)
                    Text(value).multilineTextAlignment(.trailing)
                }
                .font(.forma(12)).padding(.vertical, 10)
            }
            Divider().overlay(Theme.hairline)
        }
    }

    private var actions: some View {
        VStack(spacing: 10) {
            switch mode {
            case .shopping(_, let category):
                if let projectID {
                    let added = RoomCart.contains(product, in: project)
                    Button {
                        RoomCart.add([(product, category)], to: projectID, store: store)
                    } label: {
                        Label(added ? "Added to room" : "Add to room", systemImage: added ? "checkmark" : "plus")
                    }
                    .buttonStyle(PillButtonStyle())
                    .disabled(added)
                    .accessibilityLabel(added ? "Added to room" : "Add to room")
                    .accessibilityIdentifier("addToRoom")
                }
                listingLink(filled: false)
            case .inRoom(let projectID, let placementID):
                listingLink(filled: true)
                Button {
                    RoomCart.remove(placement: placementID, from: projectID, store: store)
                    dismiss()
                } label: {
                    Label("Remove from room", systemImage: "trash")
                }
                .buttonStyle(PillButtonStyle(filled: false))
                .accessibilityLabel("Remove from room")
                .accessibilityIdentifier("removeFromRoom")
            }
        }
        .padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 12)
        .background(Theme.ground)
        .overlay(alignment: .top) { Theme.hairline.frame(height: 1) }
    }

    private func listingLink(filled: Bool) -> some View {
        Link(destination: product.productURL) {
            Label("Go to original listing", systemImage: "arrow.up.right").labelStyle(TrailingIconLabelStyle())
        }
        .buttonStyle(PillButtonStyle(filled: filled))
        .accessibilityLabel("Go to original listing")
        .accessibilityIdentifier("originalListing")
    }
}

private struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) { configuration.title; configuration.icon }
    }
}
