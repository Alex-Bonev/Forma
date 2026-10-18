import SwiftUI

enum Route: Hashable {
    /// `added`: placement to flag as "New" with a confirmation toast (after Add to room).
    case room(UUID, added: UUID? = nil)
    /// `picks`: open "Add to a room" on arrival (straight after scanning it from Home).
    case object(UUID, picks: Bool = false)
    case designer(UUID, opensCatalog: Bool = false)
}

@Observable final class Router {
    var path: [Route] = []
}
