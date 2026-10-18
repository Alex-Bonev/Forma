import SwiftUI

/// STUB: replaced by the Product detail screen (Paper PD1 and PD2).
struct ProductDetailView: View {
    enum Mode {
        /// Opened from a shopping result. `projectID`: the room Add puts it in, if any. `category`: the shopping row's category.
        case shopping(projectID: UUID?, category: String)
        /// Opened from the cart: the product is already in that room.
        case inRoom(projectID: UUID, placementID: UUID)
    }
    let product: ShopProduct
    let mode: Mode
    var body: some View { Text(product.title) }
}
