import SwiftUI

/// STUB: replaced by the Cart screen (Paper L and L2).
struct CartSheet: View {
    /// A room's cart; nil: every room, sectioned by room.
    let projectID: UUID?
    var body: some View { Text("Cart").presentationDetents([.large]) }
}
