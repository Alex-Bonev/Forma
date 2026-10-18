import SwiftUI

enum Route: Hashable {
    /// `added`: placement to flag as "New" with a confirmation toast (after Add to room).
    case room(UUID, added: UUID? = nil)
    /// `picks`: open "Add to a room" on arrival (straight after scanning it from Home).
    case object(UUID, picks: Bool = false)
    /// `framing`: open on choosing the Make it real angle.
    case designer(UUID, opensCatalog: Bool = false, framing: Bool = false)
    /// `applyTo`: a room to link the vibe to once it is saved (from the room's add-a-vibe sheet).
    case newVibe(applyTo: UUID? = nil)
    case vibe(UUID)
}

@Observable final class Router {
    var path: [Route] = []
}
