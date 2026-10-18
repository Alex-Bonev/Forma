import SwiftUI

/// STUB: replaced by the custom vibe dropdown (the card only; callers place it and own the open state).
/// Used by the fullscreen room's vibe pill and by the vibe header on Shop a vibe.
struct VibeDropdownMenu: View {
    /// Small caps line at the top, e.g. "VIBE FOR LIVING ROOM". Empty hides it.
    var header = ""
    /// The vibe shown with a check. nil = none selected.
    var selected: UUID?
    /// Show a last row that clears the choice ("Remove vibe from room" and similar).
    var clearTitle: String? = nil
    var newTitle = "New vibe from photos"
    let onSelect: (UUID) -> Void
    let onClear: () -> Void
    let onNew: () -> Void
    var body: some View { Text("Vibes") }
}
