import RealityKit

/// Generic furniture the user can drop in when RoomPlan missed something. Models are the bundled Kenney
/// Furniture Kit USDZs (Resources/DemoData/Furniture), stretched to a realistic real-world size.
struct CatalogItem: Identifiable {
    let id: String          // stored in Placement.catalogItem
    let name: String
    let model: String       // Furniture/<model>.usdz
    let size: SIMD3<Float>  // meters (width, height, depth)
    let symbol: String

    static let all: [CatalogItem] = [
        // Placeholder to size by hand (Edit) and later swap for a real scan (Scan).
        .init(id: "custom_box", name: "Custom Box", model: "custom_box", size: [0.5, 0.5, 0.5], symbol: "cube"),
        .init(id: "sofa", name: "Sofa", model: "sofa", size: [2.0, 0.85, 0.9], symbol: "sofa"),
        .init(id: "sofa_corner", name: "Corner Sofa", model: "sofa_corner", size: [2.4, 0.85, 1.6], symbol: "sofa"),
        .init(id: "armchair", name: "Armchair", model: "sofa_single", size: [0.85, 0.85, 0.85], symbol: "chair.lounge"),
        .init(id: "chair", name: "Chair", model: "chair", size: [0.45, 0.9, 0.5], symbol: "chair"),
        .init(id: "desk_chair", name: "Desk Chair", model: "chair_swivel", size: [0.6, 1.0, 0.6], symbol: "chair"),
        .init(id: "coffee_table", name: "Coffee Table", model: "table_coffee", size: [1.1, 0.45, 0.6], symbol: "table.furniture"),
        .init(id: "dining_table", name: "Dining Table", model: "table", size: [1.6, 0.75, 0.9], symbol: "table.furniture"),
        .init(id: "round_table", name: "Round Table", model: "table_round", size: [1.0, 0.75, 1.0], symbol: "circle"),
        .init(id: "side_table", name: "Side Table", model: "sideTable", size: [0.5, 0.55, 0.5], symbol: "square"),
        .init(id: "desk", name: "Desk", model: "desk", size: [1.2, 0.75, 0.6], symbol: "desktopcomputer"),
        .init(id: "bed", name: "Bed", model: "bed", size: [1.6, 0.55, 2.1], symbol: "bed.double"),
        .init(id: "bookshelf", name: "Bookshelf", model: "storage_shelf", size: [0.9, 1.8, 0.35], symbol: "books.vertical"),
        .init(id: "cabinet", name: "Cabinet", model: "storage_cabinet", size: [0.9, 1.8, 0.45], symbol: "cabinet"),
        .init(id: "tv_console", name: "TV Console", model: "storage_low", size: [1.4, 0.55, 0.45], symbol: "tv"),
        .init(id: "tv", name: "TV", model: "television", size: [1.2, 0.75, 0.2], symbol: "tv"),
        .init(id: "plant", name: "Plant", model: "plant", size: [0.5, 1.1, 0.5], symbol: "leaf"),
        .init(id: "floor_lamp", name: "Floor Lamp", model: "lamp", size: [0.4, 1.6, 0.4], symbol: "lamp.floor"),
        .init(id: "rug", name: "Rug", model: "rug", size: [2.0, 0.02, 1.4], symbol: "rectangle"),
        .init(id: "bench", name: "Bench", model: "bench", size: [1.2, 0.45, 0.4], symbol: "rectangle.split.3x1"),
        .init(id: "trash", name: "Trash Can", model: "trashcan", size: [0.3, 0.5, 0.3], symbol: "trash"),
        .init(id: "box", name: "Box", model: "box", size: [0.5, 0.4, 0.4], symbol: "shippingbox"),
    ]

    static func item(_ id: String?) -> CatalogItem? { all.first { $0.id == id } }

    /// Model at real size, facing +Z like RoomPlan objects, sitting on y = 0. Box stand-in if the file is missing.
    @MainActor
    func entity() async -> Entity {
        let holder = Entity()
        if let model = await RoomBuilder.furnitureTemplate(self.model) {
            let b = model.visualBounds(relativeTo: nil)
            model.position = -b.center
            holder.addChild(model)
            holder.scale = size / simd_max(b.extents, SIMD3(repeating: 0.001))
            holder.orientation = simd_quatf(angle: .pi, axis: [0, 1, 0])   // Kenney models face -Z
        } else {
            holder.addChild(ModelEntity(mesh: .generateBox(size: size, cornerRadius: 0.02),
                                        materials: [RoomBuilder.material(.lightGray)]))
        }
        holder.position.y = size.y / 2
        let wrapper = Entity()   // unscaled, so selection disc and bounds behave like scanned objects
        wrapper.addChild(holder)
        return wrapper
    }
}
