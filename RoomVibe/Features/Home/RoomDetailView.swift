import SwiftUI

/// Paper "D · Room detail": name, size, orbit preview, what's in the room.
struct RoomDetailView: View {
    let projectID: UUID
    var added: UUID? = nil
    @Environment(ProjectStore.self) private var store
    @Environment(Router.self) private var router
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var confirmRescan = false
    @State private var rescanning = false
    @State private var toastVisible = false

    private var project: Project? { store.projects.first { $0.id == projectID } }

    var body: some View {
        if let project, let room = store.room(for: project) {
            let (lo, hi) = RoomBuilder.bounds(room)
            let height = room.walls.map(\.dimensions.y).max() ?? (hi.y - lo.y)
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    DetailBar(backTitle: added == nil ? "Rooms" : "Library", actionTitle: "Rescan", actionIcon: "arrow.clockwise",
                              actionDisabled: !Capabilities.canScanRoom,
                              back: { dismiss() }, action: { confirmRescan = true })
                    NameField(text: $name, commit: rename)
                    HStack {
                        Measure(label: "Width", value: String(format: "%.1f m", hi.x - lo.x))
                        Measure(label: "Depth", value: String(format: "%.1f m", hi.z - lo.z))
                        Measure(label: "Height", value: String(format: "%.1f m", height))
                    }
                    StageCard {
                        DesignerView(projectID: projectID, style: .card) { router.path.append(.designer(projectID)) }
                    }
                    .overlay(alignment: .topLeading) {
                        if toastVisible, let n = addedName(project) { Toast(text: "\(n) added").padding(12).transition(.opacity.combined(with: .move(edge: .top))) }
                    }
                    contents(project, room: room)
                }
                .padding(.horizontal, 24).padding(.top, 8).padding(.bottom, 32)
            }
            .scrollIndicators(.hidden)
            .scrollDismissesKeyboard(.interactively)
            .background(Theme.ground.ignoresSafeArea())
            .toolbar(.hidden, for: .navigationBar)
            .onAppear { name = project.name }
            .task {
                guard added != nil else { return }
                withAnimation(.easeOut(duration: 0.3)) { toastVisible = true }
                try? await Task.sleep(for: .seconds(2.5))
                withAnimation(.easeOut(duration: 0.3)) { toastVisible = false }
            }
            .sheet(isPresented: $confirmRescan) { rescanSheet(project) }
            .fullScreenCover(isPresented: $rescanning) {
                RoomScanView { fresh in replace(project, with: fresh) }
            }
        } else {
            ContentUnavailableView("Room not found", systemImage: "cube.transparent")
        }
    }

    private func contents(_ project: Project, room: RoomModel) -> some View {
        let n = roomItemCount(project, room: room)
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("In this room").font(.forma(13, bold: true))
                Text("\(n)").font(.forma(12)).foregroundStyle(Theme.muted)
                Spacer()
                Button { router.path.append(.designer(projectID, opensCatalog: true)) } label: {
                    Label("Add object", systemImage: "plus").font(.forma(12))
                }
            }
            .foregroundStyle(Theme.ink).padding(.bottom, 8)
            if let summary = shoppedSummary(project) {
                Text(summary).font(.forma(11)).foregroundStyle(Theme.muted).padding(.bottom, 8)
                    .accessibilityIdentifier("shoppedSummary")
            }
            ForEach(project.placements) { p in
                let item = CatalogItem.item(p.catalogItem)
                let object = store.objects.first { $0.id == p.objectID }
                ItemRow(name: p.product?.title ?? item?.name ?? object?.name ?? "Item",
                        symbol: p.product != nil ? "bag" : item?.symbol ?? "chair.lounge",
                        size: (item?.size ?? object?.boundingBox ?? .zero) * (p.scale ?? .one), isNew: p.id == added,
                        product: p.product)
                    .onTapGesture { router.path.append(.designer(projectID)) }
            }
            ForEach(Array(room.objects.enumerated()), id: \.offset) { i, box in
                if !(project.hiddenRoomObjects?.contains(i) ?? false) && !(project.removedRoomObjects?.contains(i) ?? false) {
                    ItemRow(name: box.label == RoomModel.markedLabel ? "Marked item" : box.label.capitalized,
                            symbol: "cube.transparent", size: box.dimensions, isNew: false)
                        .onTapGesture { router.path.append(.designer(projectID)) }
                }
            }
            if n == 0 {
                Text("Nothing here yet. Add an object from your library.")
                    .font(.forma(12)).foregroundStyle(Theme.muted).padding(.vertical, 12)
            }
        }
    }

    /// "3 shopped products · $612.97 before shipping and tax" for the products added from Vibe shopping; nil when none.
    private func shoppedSummary(_ project: Project) -> String? {
        let products = project.placements.compactMap(\.product)
        guard !products.isEmpty else { return nil }
        let priced = products.compactMap(\.priceUSD)
        var text = products.count == 1 ? "1 shopped product" : "\(products.count) shopped products"
        if !priced.isEmpty {
            text += " · " + priced.reduce(0, +).formatted(.currency(code: "USD"))
            if priced.count < products.count { text += " + unpriced" }
            text += " before shipping and tax"
        }
        return text
    }

    private func addedName(_ project: Project) -> String? {
        guard let p = project.placements.first(where: { $0.id == added }) else { return nil }
        return CatalogItem.item(p.catalogItem)?.name ?? store.objects.first { $0.id == p.objectID }?.name
    }

    private func rename() {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var project, !n.isEmpty, n != project.name else { name = project?.name ?? name; return }
        project.name = n
        store.update(project)
    }

    /// Paper "F · Room rescan confirm".
    private func rescanSheet(_ project: Project) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Rescan \(project.name.lowercased())?").font(.forma(20, bold: true))
            Text("The current scan will be replaced. Items you placed stay in the room.")
                .font(.forma(13)).foregroundStyle(Theme.muted).padding(.bottom, 16)
            Button("Start rescan") { confirmRescan = false; rescanning = true }.buttonStyle(PillButtonStyle())
            Button("Cancel") { confirmRescan = false }.buttonStyle(PillButtonStyle(filled: false))
        }
        .foregroundStyle(Theme.ink)
        .padding(.horizontal, 24).padding(.top, 28)
        .frame(maxHeight: .infinity, alignment: .top)
        .presentationDetents([.height(290)])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(32)
        .presentationBackground(Theme.ground)
    }

    /// RoomScanView saves a new project; carry the old one's placements and name over, then drop the old one.
    private func replace(_ old: Project, with fresh: Project) {
        var next = fresh
        next.name = old.name
        next.placements = old.placements
        next.wallFinish = old.wallFinish
        next.floorFinish = old.floorFinish
        store.update(next)
        store.delete(old)
        router.path = router.path.map { $0 == .room(old.id) ? .room(next.id) : $0 }
    }
}

private struct ItemRow: View {
    let name: String, symbol: String, size: SIMD3<Float>, isNew: Bool
    /// Set for products added from Vibe shopping: price and store under the size, and a link to the listing.
    var product: ShopProduct? = nil
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 17)).foregroundStyle(Theme.wood)
                .frame(width: 40, height: 40).background(Theme.tiles[1], in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 2) {
                Text(name).font(.forma(14, bold: true)).foregroundStyle(Theme.ink).lineLimit(1)
                Text(String(format: "%.0f × %.0f × %.0f cm", size.x * 100, size.z * 100, size.y * 100))
                    .font(.forma(11)).foregroundStyle(Theme.muted)
                if let product {
                    Text("\(product.price) · \(product.retailer)").font(.forma(11)).foregroundStyle(Theme.muted).lineLimit(1)
                }
            }
            if isNew {
                Text("New").font(.forma(11)).foregroundStyle(Theme.onSage)
                    .padding(.horizontal, 10).frame(height: 24).background(Theme.sage, in: Capsule())
            }
            Spacer(minLength: 8)
            if let product {
                Link(destination: product.productURL) {
                    Image(systemName: "arrow.up.right.square").font(.system(size: 17)).foregroundStyle(Theme.wood)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Open product \(product.title)")
            }
            Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.wood)
        }
        .padding(.vertical, 10)
        .overlay(alignment: .top) { Theme.hairline.frame(height: 1) }
        .contentShape(Rectangle())
    }
}
