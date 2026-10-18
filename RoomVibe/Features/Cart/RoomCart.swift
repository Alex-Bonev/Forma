import SwiftUI

/// One shopped product that sits in a room. The cart is not stored: it is every `Placement.product` across the rooms.
struct CartItem: Identifiable {
    let projectID: UUID
    let roomName: String
    let placement: Placement
    let product: ShopProduct
    var id: UUID { placement.id }
}

@MainActor
enum RoomCart {
    /// `room`: only that room's items; nil: every room, in room order.
    static func items(in projects: [Project], room: UUID? = nil) -> [CartItem] {
        projects.filter { room == nil || $0.id == room }.flatMap { project in
            project.placements.compactMap { p in
                p.product.map { CartItem(projectID: project.id, roomName: project.name, placement: p, product: $0) }
            }
        }
    }

    static func count(in projects: [Project], room: UUID? = nil) -> Int { items(in: projects, room: room).count }

    /// Sum of the listings that give a USD price, and how many items have none.
    static func subtotal(_ items: [CartItem]) -> (total: Double, unpriced: Int) {
        (items.compactMap(\.product.priceUSD).reduce(0, +), items.filter { $0.product.priceUSD == nil }.count)
    }

    static func contains(_ product: ShopProduct, in project: Project?) -> Bool {
        project?.placements.contains { $0.product?.productURL == product.productURL } ?? false
    }

    /// Drops the products into the room as their closest catalog items, in one store update so the Designer spawns them
    /// together. Products already in the room are skipped. Each listing photo is kept now, while it is reachable.
    static func add(_ picks: [(product: ShopProduct, category: String)], to projectID: UUID, store: ProjectStore) {
        guard var project = store.projects.first(where: { $0.id == projectID }) else { return }
        var added: [Placement] = []
        for pick in picks where !contains(pick.product, in: project) {
            let p = Placement.forProduct(pick.product, category: pick.product.category ?? pick.category)
            project.placements.append(p)
            added.append(p)
        }
        store.update(project)
        Task { for p in added { if let product = p.product { await ProductPhotos.cache(product, placement: p.id, project: projectID) } } }
    }

    static func remove(placement: UUID, from projectID: UUID, store: ProjectStore) {
        guard var project = store.projects.first(where: { $0.id == projectID }) else { return }
        project.placements.removeAll { $0.id == placement }
        store.update(project)
    }
}
