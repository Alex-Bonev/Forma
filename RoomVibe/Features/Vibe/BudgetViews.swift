import SwiftUI

/// STUB: replaced by the budget views (Paper BG1 to BG4). Signatures are fixed; other code already uses them.

/// Budget input with quick chips and "No limit" (Paper BG1). `amount` nil = no limit.
struct BudgetField: View {
    @Binding var amount: Double?
    var body: some View { Text("Budget") }
}

/// Segmented bar of what is spent against a budget (Paper BG2, BG5).
struct BudgetBar: View {
    struct Segment: Identifiable {
        let id: String
        let label: String
        let amount: Double
    }
    let budget: Double
    let segments: [Segment]
    var body: some View { Text("Bar") }
}

/// "Within budget" card: spent of budget, bar, legend, "Left to spend", Change (Paper BG2).
struct BudgetSummaryCard: View {
    let budget: Double
    let segments: [BudgetBar.Segment]
    var onChange: (() -> Void)? = nil
    var body: some View { Text("Summary") }
}

/// Near misses for one item that did not fit (Paper BG3). `options` are the item's products priced above what is left.
struct BudgetOptionsView: View {
    let itemName: String
    let category: String
    let projectID: UUID?
    let budget: Double
    let spent: Double
    let options: [ShopProduct]
    /// New budget that would fit the cheapest option.
    let onRaise: (Double) -> Void
    let onSkip: () -> Void
    var body: some View { Text(itemName) }
}

/// Change-budget sheet (Paper BG4). `onApply(nil)` = no limit.
struct BudgetSheet: View {
    let current: Double?
    /// What the picks (or the cart) add up to now, shown as "Picks now".
    let picksTotal: Double?
    var note = "Picks update right away. Products already found stay the same."
    var applyTitle = "Update budget"
    let onApply: (Double?) -> Void
    var body: some View { Text("Budget sheet") }
}
