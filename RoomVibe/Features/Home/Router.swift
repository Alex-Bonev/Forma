import SwiftUI

enum Route: Hashable {
    /// `added`: placement to flag as "New" with a confirmation toast (after Add to room).
    case room(UUID, added: UUID? = nil)
    case object(UUID)
    case designer(UUID, opensCatalog: Bool = false)
}

@Observable final class Router {
    var path: [Route] = []
}
