import SwiftUI

enum Route: Hashable {
    /// `added`: placement to flag as "New" with a confirmation toast (after Add to room).
    case room(UUID, added: UUID? = nil)
    case object(UUID)
    case designer(UUID, opensCatalog: Bool = false)
    /// `applyTo`: a room to link the vibe to once it is saved (from the room's add-a-vibe sheet).
    case newVibe(applyTo: UUID? = nil)
    case vibe(UUID)
}

@Observable final class Router {
    var path: [Route] = []
}
