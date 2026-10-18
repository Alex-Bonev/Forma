import SwiftUI

private func money(_ value: Double) -> String {
    value.formatted(.currency(code: "USD").precision(.fractionLength(value.rounded() == value ? 0 : 2)))
}

private let segmentPalette = [Theme.sage, Color(hex: 0xB7BFA6), Color(hex: 0xD3D8C6)]
private let chipBorder = Color(hex: 0xD8CCBB)
private let overPillFill = Color(hex: 0xF3E1D5)
private let overPillStroke = Color(hex: 0xC98F6B)

/// Same color the bar paints for segment `index`; the last one turns terracotta when over budget.
private func segmentColor(_ index: Int, count: Int, over: Bool) -> Color {
    over && index == count - 1 ? Theme.terracotta : segmentPalette[index % segmentPalette.count]
}

/// Budget input with quick chips and "No limit" (Paper BG1). `amount` nil = no limit.
struct BudgetField: View {
    @Binding var amount: Double?
    @State private var text = ""
    @FocusState private var focused: Bool
    var large = false

    private static let quick: [(id: String, label: String, value: Double?)] = [
        ("400", "$400", 400), ("800", "$800", 800), ("1200", "$1,200", 1200), ("none", "No limit", nil),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !large {
                HStack(alignment: .firstTextBaseline) {
                    Text("Budget").font(.forma(13, bold: true))
                    Spacer()
                    Text("Optional").font(.forma(11)).foregroundStyle(Theme.muted)
                }
                .accessibilityElement(children: .combine)
            }
            amountField
            chips
            if !large {
                Text(amount.map { "The picks will always add up to \(money($0)) or less. Prices exclude shipping and tax." }
                     ?? "No limit. The agents pick the best match for each item.")
                    .font(.forma(11)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "sparkle").font(.system(size: 12)).foregroundStyle(Theme.sage)
                        .padding(.top, 2).accessibilityHidden(true)
                    Text("If you type a budget in your description (\"under $800\"), we fill it in here for you.")
                        .font(.forma(11)).foregroundStyle(Theme.wood)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 10).padding(.horizontal, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.sand, in: RoundedRectangle(cornerRadius: 16))
                .padding(.top, 6)
            }
        }
        .foregroundStyle(Theme.ink)
        .onAppear { text = Self.string(amount) }
        .onChange(of: amount) { _, new in
            // Chips and external edits push into the field; typing already matches, so skip it.
            if Self.parse(text) != new { text = Self.string(new) }
        }
    }

    private var amountField: some View {
        let size: CGFloat = large ? 26 : 24
        return HStack(spacing: 6) {
            Text("$").font(.forma(size, bold: true))
            TextField("", text: $text, prompt: Text("No limit").font(.forma(size, bold: true)).foregroundStyle(Theme.muted))
                .font(.forma(size, bold: true))
                .keyboardType(.decimalPad)
                .focused($focused)
                .accessibilityIdentifier("budgetAmount")
                .accessibilityLabel("Budget amount in dollars")
                .onChange(of: text) { _, new in
                    let parsed = Self.parse(new)
                    if parsed != amount { amount = parsed }
                }
            if !text.isEmpty {
                Button { text = ""; amount = nil } label: {
                    Image(systemName: "xmark").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.wood)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("Clear budget")
            }
        }
        .padding(.leading, 16).padding(.trailing, 4)
        .frame(minHeight: large ? 60 : 56)
        .background(Theme.sand, in: RoundedRectangle(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20).strokeBorder(Theme.sage, lineWidth: 1.5))
        .contentShape(Rectangle())
        .onTapGesture { focused = true }
    }

    private var chips: some View {
        BudgetChipFlow(spacing: 6) {
            ForEach(Self.quick, id: \.id) { chip in
                let selected = amount == chip.value
                Button {
                    amount = chip.value
                    focused = false
                } label: {
                    Text(chip.label)
                        .font(.forma(12, bold: selected))
                        .foregroundStyle(selected ? Theme.onSage : Theme.wood)
                        .padding(.horizontal, 14).frame(minHeight: 32)
                        .background(selected ? Theme.sage : .clear, in: Capsule())
                        .overlay { if !selected { Capsule().strokeBorder(chipBorder, lineWidth: 1) } }
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("budgetChip-\(chip.id)")
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }

    private static func string(_ v: Double?) -> String {
        guard let v else { return "" }
        return v.rounded() == v ? String(Int(v)) : String(v)
    }

    private static func parse(_ s: String) -> Double? {
        let v = Double(s.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces))
        return v.flatMap { $0 > 0 ? $0 : nil }
    }
}

/// Wraps chips onto new lines like the Paper flex-wrap row.
private struct BudgetChipFlow: Layout {
    var spacing: CGFloat
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width ?? .infinity, subviews: subviews).size
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let r = arrange(width: bounds.width, subviews: subviews)
        for (sub, p) in zip(subviews, r.points) {
            sub.place(at: CGPoint(x: bounds.minX + p.x, y: bounds.minY + p.y), proposal: .unspecified)
        }
    }
    private func arrange(width: CGFloat, subviews: Subviews) -> (size: CGSize, points: [CGPoint]) {
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, maxX: CGFloat = 0
        var pts: [CGPoint] = []
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > 0, x + sz.width > width { x = 0; y += rowH + spacing; rowH = 0 }
            pts.append(CGPoint(x: x, y: y))
            x += sz.width + spacing; rowH = max(rowH, sz.height); maxX = max(maxX, x - spacing)
        }
        return (CGSize(width: maxX, height: y + rowH), pts)
    }
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

    private var total: Double { segments.reduce(0) { $0 + $1.amount } }

    var body: some View {
        GeometryReader { geo in
            let shown = segments.filter { $0.amount > 0 }
            let denom = max(budget, total, 1)
            let avail = geo.size.width - CGFloat(max(shown.count - 1, 0)) * 2
            HStack(spacing: 2) {
                ForEach(Array(shown.enumerated()), id: \.element.id) { i, seg in
                    Rectangle()
                        .fill(segmentColor(i, count: shown.count, over: total > budget))
                        .frame(width: max(0, avail * seg.amount / denom))
                }
                Spacer(minLength: 0)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .leading)
            .background(Theme.hairline)
            .clipShape(Capsule())
        }
        .frame(height: 10)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(money(total)) of \(money(budget))")
    }
}

/// "Within budget" card: spent of budget, bar, legend, "Left to spend", Change (Paper BG2).
struct BudgetSummaryCard: View {
    let budget: Double
    let segments: [BudgetBar.Segment]
    var onChange: (() -> Void)? = nil

    private var spent: Double { segments.reduce(0) { $0 + $1.amount } }
    private var over: Bool { spent > budget }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                HStack(spacing: 6) {
                    Image(systemName: over ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(over ? Theme.terracotta : Theme.sage)
                        .accessibilityHidden(true)
                    Text(over ? "Over budget" : "Within budget")
                        .font(.forma(12, bold: true))
                        .foregroundStyle(over ? Theme.terracotta : Theme.ink)
                }
                Spacer()
                if let onChange {
                    Button(action: onChange) {
                        HStack(spacing: 4) {
                            Text("Change").font(.forma(12))
                            Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold))
                        }
                        .foregroundStyle(Theme.wood)
                        .frame(minHeight: 44).contentShape(Rectangle())
                    }
                    .accessibilityIdentifier("changeBudget")
                    .accessibilityLabel("Change budget")
                }
            }
            .padding(.vertical, -8)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(money(spent)).font(.forma(32, bold: true))
                Text("of \(money(budget))").font(.forma(13)).foregroundStyle(Theme.muted)
            }
            .foregroundStyle(Theme.ink)
            .accessibilityElement(children: .combine)
            BudgetBar(budget: budget, segments: segments)
            VStack(spacing: 6) {
                let shown = segments.filter { $0.amount > 0 }
                ForEach(Array(shown.enumerated()), id: \.element.id) { i, seg in
                    legendRow(dot: AnyView(Circle().fill(segmentColor(i, count: shown.count, over: over))),
                              label: seg.label, value: money(seg.amount), muted: false)
                }
                legendRow(dot: AnyView(Circle().fill(Theme.hairline).overlay(Circle().strokeBorder(chipBorder, lineWidth: 1))),
                          label: "Left to spend", value: money(max(0, budget - spent)), muted: true)
            }
            Text("Prices exclude shipping and tax.").font(.forma(10)).foregroundStyle(Theme.muted)
        }
        .padding(.top, 18).padding(.bottom, 16).padding(.horizontal, 18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.sand, in: RoundedRectangle(cornerRadius: 24))
    }

    private func legendRow(dot: AnyView, label: String, value: String, muted: Bool) -> some View {
        HStack(spacing: 8) {
            dot.frame(width: 10, height: 10)
            Text(label).font(.forma(11)).lineLimit(1)
            Spacer(minLength: 8)
            Text(value).font(.forma(11))
        }
        .foregroundStyle(muted ? Theme.muted : Theme.ink)
        .accessibilityElement(children: .combine)
    }
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

    private var left: Double { max(0, budget - spent) }
    private var raiseTo: Double? {
        options.compactMap(\.priceUSD).min().map { (spent + $0).rounded(.up) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                summary
                VStack(alignment: .leading, spacing: 6) {
                    Text("Nothing fits the \(money(left)) left").font(.forma(18, bold: true))
                    Text(options.isEmpty
                         ? "No other products came back."
                         : "These are close. Your picks stay within \(money(budget)) until you choose one.")
                        .font(.forma(11)).foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.top, 22)
                if !options.isEmpty {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 12, alignment: .top),
                                        GridItem(.flexible(), alignment: .top)], spacing: 18) {
                        ForEach(options) { card($0) }
                    }
                    .padding(.top, 18)
                }
            }
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 24)
        }
        .background(Theme.ground)
        .toolbar {
            ToolbarItem(placement: .principal) {
                Text(itemName).font(.forma(14, bold: true)).foregroundStyle(Theme.ink).lineLimit(1)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom, spacing: 0) { bottomBar }
    }

    private var summary: some View {
        VStack(spacing: 8) {
            HStack {
                Text("\(money(spent)) of \(money(budget))").font(.forma(12, bold: true))
                Spacer()
                Text("\(money(left)) left").font(.forma(12)).foregroundStyle(Theme.muted)
            }
            BudgetBar(budget: budget, segments: [.init(id: "spent", label: "Spent", amount: spent)])
        }
        .padding(.vertical, 12).padding(.horizontal, 14)
        .background(Theme.sand, in: RoundedRectangle(cornerRadius: 18))
        .accessibilityElement(children: .combine)
    }

    private func card(_ p: ShopProduct) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Color(hex: 0xE6DCCF)
                .frame(height: 150)
                .overlay {
                    AsyncImage(url: p.imageURL) { phase in
                        if let image = phase.image { image.resizable().scaledToFill() }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Theme.hairline, lineWidth: 1))
                .overlay(alignment: .topLeading) {
                    if let price = p.priceUSD {
                        Text("Over by \(money(max(0, price - left)))")
                            .font(.forma(10, bold: true)).foregroundStyle(Theme.terracotta)
                            .padding(.horizontal, 8).frame(minHeight: 22)
                            .background(overPillFill, in: Capsule())
                            .overlay(Capsule().strokeBorder(overPillStroke, lineWidth: 1))
                            .padding(8)
                    }
                }
                .accessibilityHidden(true)
            Text(p.title).font(.forma(11)).lineLimit(2)
                .frame(maxWidth: .infinity, minHeight: 28, alignment: .topLeading)
            HStack(alignment: .firstTextBaseline) {
                Text(p.price).font(.forma(13, bold: true))
                Spacer(minLength: 4)
                Text(p.retailer).font(.forma(10)).foregroundStyle(Theme.muted).lineLimit(1)
            }
            NavigationLink {
                ProductDetailView(product: p, mode: .shopping(projectID: projectID, category: category))
            } label: {
                Text("Open").font(.forma(12)).foregroundStyle(Color(hex: 0x242321))
                    .frame(maxWidth: .infinity, minHeight: 44)
                    .overlay(Capsule().strokeBorder(Color(hex: 0x242321), lineWidth: 1).frame(height: 32))
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Open \(p.title)")
        }
        .accessibilityElement(children: .contain)
    }

    private var bottomBar: some View {
        VStack(spacing: 10) {
            if let n = raiseTo {
                Button { onRaise(n) } label: { Text("Raise budget to \(money(n))") }
                    .buttonStyle(PillButtonStyle())
                    .accessibilityIdentifier("raiseBudget")
            }
            Button(action: onSkip) { Text("Skip this item") }
                .buttonStyle(PillButtonStyle(filled: false))
                .accessibilityIdentifier("skipItem")
        }
        .padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 12)
        .frame(maxWidth: .infinity)
        .background(Theme.ground)
        .overlay(alignment: .top) { Theme.hairline.frame(height: 1) }
    }
}

/// Change-budget sheet (Paper BG4). `onApply(nil)` = no limit.
struct BudgetSheet: View {
    let current: Double?
    /// What the picks (or the cart) add up to now, shown as "Picks now".
    let picksTotal: Double?
    var note = "Picks update right away. Products already found stay the same."
    var applyTitle = "Update budget"
    let onApply: (Double?) -> Void

    @State private var amount: Double?
    @Environment(\.dismiss) private var dismiss

    init(current: Double?, picksTotal: Double?, note: String = "Picks update right away. Products already found stay the same.",
         applyTitle: String = "Update budget", onApply: @escaping (Double?) -> Void) {
        self.current = current
        self.picksTotal = picksTotal
        self.note = note
        self.applyTitle = applyTitle
        self.onApply = onApply
        _amount = State(initialValue: current)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Change your budget").font(.forma(22, bold: true))
                Text(note).font(.forma(11)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            BudgetField(amount: $amount, large: true)
            if let picksTotal {
                HStack {
                    Text("Picks now").font(.forma(11)).foregroundStyle(Theme.muted)
                    Spacer()
                    Text(amount.map { "\(money(picksTotal)) of \(money($0))" } ?? money(picksTotal))
                        .font(.forma(11, bold: true))
                }
                .accessibilityElement(children: .combine)
            }
            VStack(spacing: 10) {
                Button { onApply(amount); dismiss() } label: { Text(applyTitle) }
                    .buttonStyle(PillButtonStyle())
                    .accessibilityIdentifier("applyBudget")
                Button { dismiss() } label: { Text("Cancel") }
                    .buttonStyle(PillButtonStyle(filled: false))
                    .accessibilityIdentifier("cancelBudget")
            }
        }
        .foregroundStyle(Theme.ink)
        .padding(.horizontal, 24).padding(.top, 24).padding(.bottom, 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Theme.ground)
        .presentationDetents([.height(500), .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Theme.ground)
    }
}
