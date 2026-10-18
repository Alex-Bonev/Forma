import Foundation
import simd

/// "Feng-shui-ify": a few seeded simulated-annealing agents race to rearrange the movable furniture; best layout wins.
/// Pure x/z math on footprints (no RealityKit), so it runs off the main actor and is testable with plain `swiftc`.
///
/// Conventions: room x/z in scene meters (room centered on origin). `yaw` is radians about +Y; at 0 the front faces +Z,
/// so front = (sin yaw, cos yaw) and the item's local +X = (cos yaw, -sin yaw). `half` is the unrotated half footprint.
enum FengShui {
    struct Item: Sendable {
        var id: UUID
        var kind: Kind
        var half: SIMD2<Float>      // footprint half-extents in the item's own x/z (unrotated), meters
        var position: SIMD2<Float>  // room x/z
        var yaw: Float              // radians about +Y; front = (sin yaw, cos yaw)
        var movable: Bool           // false = obstacle only (locked placements, fixtures)
        var height: Float = 1       // m; storage taller than `tallStorage` shouldn't block windows
        var label = ""              // shown in the note ("sofa has the command seat")
    }

    enum Kind: Sendable {
        case anchor /* sofa, bed, desk */, seat, table, storage, screen, plant, lamp, rug /* flat: others may overlap */, other

        /// RoomPlan labels ("sofa", "television", "storage", ...) and catalog ids / model names ("coffee_table", "sofa_single", ...).
        static func from(_ label: String) -> Kind {
            let s = label.lowercased().replacingOccurrences(of: " ", with: "_").replacingOccurrences(of: "-", with: "_")
            func has(_ words: String...) -> Bool { words.contains { s.contains($0) } }
            if has("rug", "carpet", "mat") { return .rug }
            if has("sofa_single", "chair", "bench", "stool", "seat", "ottoman", "pouf") { return .seat }   // before sofa / desk
            if has("console", "media", "tv_stand") { return .storage }                                  // before tv
            if s == "tv" || has("tv_", "television", "screen", "monitor") { return .screen }
            if has("sofa", "couch", "bed", "desk") { return .anchor }
            if has("table") { return .table }
            if has("storage", "shelf", "book", "cabinet", "dresser", "wardrobe", "drawer", "fridge", "refrigerator", "stove",
                   "oven", "dishwasher", "washer", "dryer", "sink", "vanity", "fireplace", "bathtub", "toilet") { return .storage }
            if has("plant", "flower", "tree") { return .plant }
            if has("lamp", "light") { return .lamp }
            return .other
        }

        var hugsWall: Bool { self == .anchor || self == .storage || self == .screen }
    }

    struct Opening: Sendable {
        var center: SIMD2<Float>
        var width: Float
        var inward: SIMD2<Float>    // unit normal into the room
        var isDoor: Bool            // false = window
    }

    struct Room: Sendable {
        var outline: [SIMD2<Float>]   // floor polygon x/z, 3+ points, any winding
        var openings: [Opening]
    }

    struct Pose: Equatable, Sendable {
        var position: SIMD2<Float>
        var yaw: Float
    }

    struct Result: Sendable {
        var poses: [UUID: Pose]   // movable items only
        var before: Float
        var after: Float
        var note: String          // one short playful line for the undo bar
        var improved: Bool
    }

    // MARK: - Tuning

    static let wall: Float = 0.04          // wall half-thickness: footprints stay this far inside the outline
    static let doorSwing: Float = 0.9      // m kept clear in front of each door
    static let chiWidth: Float = 0.6       // door-to-center corridor width
    static let breathing: Float = 0.45     // preferred gap between items
    static let tallStorage: Float = 1.2
    static let lowTable: Float = 0.6       // tables under this are coffee tables; anything taller blocks a view
    static let person: Float = 0.25        // walkway half-width: paths need ~0.5 m between padded footprints
    static let cell: Float = 0.2           // circulation grid

    /// Penalty weights (score = -Σ weight·term). Hard-ish terms dominate so the soft ones only rank legal layouts.
    private enum W {
        static let inside: Float = 30, overlap: Float = 40, door: Float = 20   // hard-ish: per m outside / m² + depth overlapped
        static let clearance: Float = 15   // hard-ish: someone has to sit there / open it
        static let circulation: Float = 6  // per seat or storage front you can't walk to from a door
        static let command: Float = 3, chi: Float = 2, wall: Float = 2, window: Float = 2, view: Float = 3
        static let facing: Float = 1.5, breathing: Float = 1.5, balance: Float = 1, rug: Float = 1
        static let move: Float = 0.15   // per m moved: keeps the room recognizable
    }

    // MARK: - API

    /// Higher is better (0 = perfect; typically a few negative points for a decent room).
    static func score(_ items: [Item], in room: Room) -> Float { -breakdown(items, in: room).total }

    /// Weighted penalty per heuristic for the layout as given (tests, tuning).
    static func breakdown(_ items: [Item], in room: Room) -> Terms { Ctx(items, room).terms(State(items)) }

    static func arrange(_ items: [Item], in room: Room, agents: Int = 6, iterations: Int = 2000, seed: UInt64 = 0) async -> Result {
        let ctx = Ctx(items, room)
        let start = State(items)
        let beforeTerms = ctx.terms(start)
        let before = -beforeTerms.total
        let original = Dictionary(uniqueKeysWithValues: items.filter(\.movable).map { ($0.id, Pose(position: $0.position, yaw: $0.yaw)) })
        let unchanged = Result(poses: original, before: before, after: before, note: "Already in harmony", improved: false)
        guard !ctx.movable.isEmpty, room.outline.count >= 3 else { return unchanged }

        let runs = await withTaskGroup(of: (Int, State, Float).self) { group in
            for a in 0..<max(agents, 1) {
                group.addTask {
                    var rng = SplitMix64(seed: seed &+ UInt64(a))
                    let initial = a == 0 ? start : ctx.randomized(start, &rng)
                    let (s, p) = ctx.anneal(initial, iterations: iterations, &rng)
                    return (a, s, p)
                }
            }
            var all: [(Int, State, Float)] = []
            for await r in group { all.append(r) }
            return all
        }
        // Completion order varies; ties go to the lowest agent so the same seed always gives the same room.
        guard let best = runs.min(by: { ($0.2, $0.0) < ($1.2, $1.0) }), -best.2 > before + 0.05 else { return unchanged }

        var poses: [UUID: Pose] = [:]
        for i in ctx.movable { poses[items[i].id] = Pose(position: best.1.pos[i], yaw: best.1.yaw[i]) }
        let afterTerms = ctx.terms(best.1)
        return Result(poses: poses, before: before, after: -best.2, note: ctx.note(beforeTerms, afterTerms), improved: true)
    }

    // MARK: - Internals

    /// Poses being searched; parallel to the item list.
    struct State: Sendable {
        var pos: [SIMD2<Float>]
        var yaw: [Float]
        init(_ items: [Item]) { pos = items.map(\.position); yaw = items.map(\.yaw) }
    }

    /// Weighted penalty per heuristic, kept apart so the note can name what improved most.
    struct Terms {
        var inside: Float = 0, overlap: Float = 0, door: Float = 0, clearance: Float = 0, circulation: Float = 0
        var command: Float = 0, chi: Float = 0, wall: Float = 0, window: Float = 0, view: Float = 0, facing: Float = 0
        var breathing: Float = 0, balance: Float = 0, rug: Float = 0, move: Float = 0
        var total: Float {
            inside + overlap + door + clearance + circulation + command + chi + wall + window + view + facing + breathing + balance
                + rug + move
        }
    }

    private struct Edge: Sendable { var a: SIMD2<Float>, dir: SIMD2<Float>, len: Float, n: SIMD2<Float> }

    /// Everything that doesn't change between candidate layouts: room geometry and who plays which role.
    private struct Ctx: Sendable {
        let items: [Item]
        let outline: [SIMD2<Float>]
        let edges: [Edge]
        let lo: SIMD2<Float>, hi: SIMD2<Float>
        let center: SIMD2<Float>
        let doors: [Opening], windows: [Opening]
        let movable: [Int]
        let main: Int?        // largest anchor (bed > sofa > desk by size): gets the command position
        let coffee: Int?      // largest low table, kept in front of `main` (smaller low ones are side tables)
        let seats: [Int], tables: [Int], anchors: [Int], screens: [Int], rugs: [Int]
        let consoles: [Int]   // low storage a screen likes to sit beside
        let hub: [Int: Int]   // seat -> the table or anchor it belonged to in the original room (dining chairs stay at their table)
        let viewers: [Int]    // main anchor + the seats grouped with it: they watch the screen
        let chiSamples: [SIMD2<Float>]
        let grid: (lo: SIMD2<Float>, nx: Int, nz: Int, open: [Bool])   // floor cells a person fits in, ignoring furniture
        let starts: [Int]     // grid cells just inside each door

        init(_ items: [Item], _ room: Room) {
            self.items = items
            outline = room.outline
            var edges: [Edge] = []
            if outline.count >= 3 {
                for i in outline.indices {
                    let a = outline[i], ab = outline[(i + 1) % outline.count] - a, len = simd_length(ab)
                    guard len > 1e-3 else { continue }
                    let dir = ab / len
                    var n = SIMD2(-dir.y, dir.x)
                    if !FloorClamp.contains(a + ab / 2 + n * 0.01, outline) { n = -n }   // point it into the room
                    edges.append(Edge(a: a, dir: dir, len: len, n: n))
                }
            }
            self.edges = edges
            lo = outline.reduce(SIMD2(repeating: .greatestFiniteMagnitude)) { simd_min($0, $1) }
            hi = outline.reduce(SIMD2(repeating: -.greatestFiniteMagnitude)) { simd_max($0, $1) }
            center = Self.centroid(outline)
            doors = room.openings.filter(\.isDoor)
            windows = room.openings.filter { !$0.isDoor }
            movable = items.indices.filter { items[$0].movable }
            func of(_ k: Kind) -> [Int] { items.indices.filter { items[$0].kind == k } }
            seats = of(.seat); tables = of(.table); anchors = of(.anchor); screens = of(.screen); rugs = of(.rug)
            let area = { (i: Int) in items[i].half.x * items[i].half.y }
            consoles = items.indices.filter { items[$0].kind == .storage && items[$0].height <= FengShui.tallStorage }
            let main = anchors.max { area($0) < area($1) }
            let coffee = main == nil ? nil : tables.filter { items[$0].height < FengShui.lowTable }.max { area($0) < area($1) }
            self.main = main; self.coffee = coffee
            // Group seats by where they started: a chair near the dining table is a dining chair, the rest join the sofa.
            var hub: [Int: Int] = [:]
            let seats = seats, tables = tables, anchors = anchors   // locals: closures can't capture a half-built self
            for i in seats {
                let hubs = tables.filter { items[$0].height >= FengShui.lowTable } + anchors   // dining height, not side tables
                let near = hubs.map { j in (j, Self.gap(items[i].position, Self.aabb(items[i].half, items[i].yaw),
                                                                      items[j].position, Self.aabb(items[j].half, items[j].yaw))) }
                    .min { $0.1 < $1.1 }
                hub[i] = near.flatMap { $0.1 < 0.8 ? $0.0 : nil } ?? main ?? near?.0
            }
            self.hub = hub
            viewers = main.map { m in [m] + seats.filter { hub[$0] == m } } ?? []
            // Points along each door -> room center corridor; furniture near them blocks the chi.
            var samples: [SIMD2<Float>] = []
            for d in doors {
                let a = d.center + d.inward * 0.3, ab = center - a, steps = Int(simd_length(ab) / 0.25)
                for s in 0...max(steps, 0) { samples.append(a + ab * (Float(s) / Float(max(steps, 1)))) }
            }
            chiSamples = samples
            let span = outline.count >= 3 ? (hi - lo) / FengShui.cell : .zero   // no outline: a single closed cell
            let nx = max(Int(span.x.rounded(.up)), 1), nz = max(Int(span.y.rounded(.up)), 1)
            var open = [Bool](repeating: false, count: nx * nz)
            for z in 0..<nz {
                for x in 0..<nx {
                    let c = lo + (SIMD2(Float(x), Float(z)) + 0.5) * FengShui.cell
                    let d = edges.map { e in simd_distance(c, e.a + e.dir * simd_clamp(simd_dot(c - e.a, e.dir), 0, e.len)) }.min() ?? 0
                    open[z * nx + x] = FloorClamp.contains(c, outline) && d > FengShui.person * 0.6
                }
            }
            grid = (lo, nx, nz, open)
            let g = (lo: lo, nx: nx, nz: nz)
            starts = room.openings.filter(\.isDoor).compactMap { d in Self.cellIndex(d.center + d.inward * 0.45, g) }
        }

        static func cellIndex(_ p: SIMD2<Float>, _ g: (lo: SIMD2<Float>, nx: Int, nz: Int)) -> Int? {
            let x = Int(((p.x - g.lo.x) / FengShui.cell).rounded(.down)), z = Int(((p.y - g.lo.y) / FengShui.cell).rounded(.down))
            return x >= 0 && z >= 0 && x < g.nx && z < g.nz ? z * g.nx + x : nil
        }

        /// How deep the clear zone in front of an item must be (0 = none): legroom, a desk chair, opening a cabinet.
        func useDepth(_ i: Int) -> Float {
            switch items[i].kind {
            case .seat: return 0.45
            case .storage: return 0.5
            case .anchor:
                let l = items[i].label.lowercased()
                return l.contains("bed") ? 0.6 : l.contains("desk") ? 0.7 : 0.45
            default: return 0
            }
        }

        /// May `j` stand in `i`'s use zone? The coffee table in front of the sofa group; a seat's own table; a chair at a desk.
        func mayUse(_ i: Int, _ j: Int) -> Bool {
            let ki = items[i].kind, kj = items[j].kind
            if kj == .rug { return true }
            if kj == .table { return j == hub[i] || j == coffee && (i == main || viewers.contains(i) || ki == .seat && hub[i] == main) }
            if ki == .anchor, kj == .seat { return hub[j] == i && items[i].label.lowercased().contains("desk") }
            return false
        }

        static func centroid(_ p: [SIMD2<Float>]) -> SIMD2<Float> {
            guard p.count >= 3 else { return .zero }
            var a: Float = 0, c = SIMD2<Float>.zero
            for i in p.indices {
                let u = p[i], v = p[(i + 1) % p.count], k = u.x * v.y - v.x * u.y
                a += k; c += (u + v) * k
            }
            return abs(a) < 1e-6 ? p.reduce(.zero, +) / Float(p.count) : c / (3 * a)
        }

        /// Distance to the nearest wall and that wall's inward normal.
        func nearestWall(_ p: SIMD2<Float>) -> (d: Float, n: SIMD2<Float>, e: Int) {
            var best: (d: Float, n: SIMD2<Float>, e: Int) = (.greatestFiniteMagnitude, .zero, 0)
            for (k, e) in edges.enumerated() {
                let t = simd_clamp(simd_dot(p - e.a, e.dir), 0, e.len), d = simd_distance(p, e.a + e.dir * t)
                if d < best.d { best = (d, e.n, k) }
            }
            return best
        }

        static func front(_ yaw: Float) -> SIMD2<Float> { SIMD2(sin(yaw), cos(yaw)) }
        /// Half extents of the yaw-rotated footprint's axis-aligned box: cheap and conservative for overlap tests.
        static func aabb(_ h: SIMD2<Float>, _ yaw: Float) -> SIMD2<Float> {
            let c = abs(cos(yaw)), s = abs(sin(yaw))
            return SIMD2(c * h.x + s * h.y, s * h.x + c * h.y)
        }
        /// Overlap of two boxes as area plus depth (depth so thin slivers still hurt), plus a flat step so even a few mm
        /// of contact costs more than the soft terms gain from it.
        static func overlap(_ c1: SIMD2<Float>, _ h1: SIMD2<Float>, _ c2: SIMD2<Float>, _ h2: SIMD2<Float>) -> Float {
            let o = simd_min(h1 + h2 - abs(c1 - c2), simd_min(h1, h2) * 2)
            return o.x > 0.001 && o.y > 0.001 ? o.x * o.y + 0.5 * min(o.x, o.y) + 0.05 : 0
        }
        static func gap(_ c1: SIMD2<Float>, _ h1: SIMD2<Float>, _ c2: SIMD2<Float>, _ h2: SIMD2<Float>) -> Float {
            simd_length(simd_max(abs(c1 - c2) - h1 - h2, .zero))
        }
        static func dir(_ v: SIMD2<Float>) -> SIMD2<Float> { simd_length(v) > 1e-4 ? simd_normalize(v) : .zero }

        func terms(_ s: State) -> Terms {
            var t = Terms()
            let n = items.count
            let box = (0..<n).map { Self.aabb(items[$0].half, s.yaw[$0]) }
            let f = s.yaw.map(Self.front)
            func flat(_ i: Int) -> Bool { items[i].kind == .rug }

            for i in movable {
                // Inside: rotated corners within the outline (inset by the wall), and no outline vertex poking into the box.
                let h = items[i].half, p = s.pos[i], r = SIMD2(f[i].y, -f[i].x)
                for c in [p + r * h.x + f[i] * h.y, p - r * h.x + f[i] * h.y, p + r * h.x - f[i] * h.y, p - r * h.x - f[i] * h.y] {
                    let d = nearestWall(c).d
                    t.inside += FloorClamp.contains(c, outline) ? max(0, FengShui.wall - d) : 1 + d
                }
                for v in outline {
                    let q = v - p, x = abs(simd_dot(q, r)) - h.x, z = abs(simd_dot(q, f[i])) - h.y
                    if x < -0.01, z < -0.01 { t.inside += 0.5 - max(x, z) }
                }
                t.move += simd_distance(p, items[i].position)
            }

            var mass = SIMD2<Float>.zero, massW: Float = 0
            for i in 0..<n {
                if !flat(i) {
                    let a = box[i].x * box[i].y
                    mass += s.pos[i] * a; massW += a
                }
                for j in (i + 1)..<max(n, i + 1) where items[i].movable || items[j].movable {
                    if flat(i) != flat(j) { continue }   // rugs go under anything, just not under other rugs
                    let o = Self.overlap(s.pos[i], box[i], s.pos[j], box[j])
                    t.overlap += o
                    guard o == 0, !flat(i) else { continue }
                    let g = Self.gap(s.pos[i], box[i], s.pos[j], box[j])
                    guard g < breathing else { continue }
                    let ki = items[i].kind, kj = items[j].kind
                    let pair: Set<Kind> = [ki, kj]
                    if pair == [.seat, .table] || pair == [.screen, .storage] || pair == [.anchor, .table] { continue }   // meant to be close
                    if ki == .seat, kj == .seat, hub[i] == hub[j], hub[i].map({ items[$0].kind == .table }) == true { continue }   // side by side at a table
                    t.breathing += (breathing - g) * (pair.contains(.plant) || pair.contains(.lamp) ? 0.5 : 1)
                }
                guard items[i].movable, !flat(i) else { continue }
                for d in doors {   // swing zone
                    let tan = SIMD2(d.inward.y, -d.inward.x)
                    let zh = abs(tan) * (d.width / 2) + abs(d.inward) * (doorSwing / 2)
                    t.door += Self.overlap(d.center + d.inward * (doorSwing / 2), zh, s.pos[i], box[i])
                }
                for q in chiSamples {
                    let d = simd_length(simd_max(abs(q - s.pos[i]) - box[i], .zero))
                    if d < chiWidth / 2 { t.chi += (chiWidth / 2 - d) * 0.5 }
                }
                if items[i].kind == .storage, items[i].height > tallStorage {
                    for w in windows {
                        let tan = SIMD2(w.inward.y, -w.inward.x)
                        let zh = abs(tan) * (w.width / 2) + abs(w.inward) * 0.25
                        t.window += Self.overlap(w.center + w.inward * 0.25, zh, s.pos[i], box[i])
                    }
                }
            }
            if massW > 0 { t.balance = simd_distance(mass / massW, center) }

            // Backs to walls, facing in.
            for i in movable where items[i].kind.hugsWall {
                let back = s.pos[i] - f[i] * items[i].half.y, w = nearestWall(back)
                let v = min(w.d, 2) + 0.5 * (1 - simd_dot(f[i], w.n))
                if i == main { t.command += v } else { t.wall += v }
            }
            // Command position: sees the door, but isn't in line with it.
            if let m = main, items[m].movable {
                let p = s.pos[m]
                if screens.isEmpty { t.command += 0.5 * (1 - simd_dot(f[m], Self.dir(center - p))) }   // else it faces the screen
                if let d = doors.min(by: { simd_distance($0.center, p) < simd_distance($1.center, p) }) {
                    t.command += max(0, 0.2 - simd_dot(f[m], Self.dir(d.center - p))) * 2
                    let q = p - d.center, along = simd_dot(q, d.inward), side = abs(simd_dot(q, SIMD2(d.inward.y, -d.inward.x)))
                    let reach = d.width / 2 + items[m].half.x
                    if along > 0, side < reach { t.command += 1 - side / reach }
                }
            }
            // Facing: screens toward the main anchor (and it back), seats toward the nearest table/anchor, coffee table in front.
            if let m = main {
                for i in screens {
                    let v = s.pos[m] - s.pos[i], d = simd_length(v)
                    t.facing += 1 - simd_dot(f[i], Self.dir(v)) + max(0, 1.5 - d) + max(0, d - 3.5) * 0.5
                    t.facing += 1.5 * (1 - simd_dot(f[m], Self.dir(-v)))
                }
            }
            // Screens beside low storage (the TV console), same way round.
            for i in screens {
                guard let c = consoles.min(by: { Self.gap(s.pos[i], box[i], s.pos[$0], box[$0]) < Self.gap(s.pos[i], box[i], s.pos[$1], box[$1]) })
                else { break }
                t.facing += 0.5 * Self.gap(s.pos[i], box[i], s.pos[c], box[c]) + 0.3 * (1 - simd_dot(f[i], f[c]))
            }
            if let m = main {
                if let c = coffee {
                    let target = s.pos[m] + f[m] * (items[m].half.y + 0.45 + items[c].half.y)
                    t.facing += simd_distance(s.pos[c], target) + 0.3 * (1 - abs(simd_dot(f[c], f[m])))
                }
            }
            // Seats stay with their group: tucked at their table, or around the sofa's coffee table (beside or across, never behind).
            for i in seats {
                guard let h = hub[i] else { continue }
                if items[h].kind == .table {
                    let edge = simd_clamp(s.pos[i], s.pos[h] - box[h], s.pos[h] + box[h])   // nearest point of the table
                    t.facing += 1 - simd_dot(f[i], Self.dir(edge - s.pos[i]))
                    t.facing += max(0, Self.gap(s.pos[i], box[i], s.pos[h], box[h]) - 0.25) * 6   // pulled up to it
                    let off = simd_max(abs(s.pos[i] - s.pos[h]) - box[h], .zero)
                    t.facing += 3 * min(off.x, off.y)   // along an edge, not off a corner
                } else {
                    let focus = coffee.map { s.pos[$0] } ?? s.pos[h] + f[h] * (items[h].half.y + 0.8)
                    let v = s.pos[i] - s.pos[h], d = simd_length(v)
                    t.facing += 0.5 * (1 - simd_dot(f[i], Self.dir(focus - s.pos[i])))
                    t.facing += max(0, 1.0 - d) + max(0, d - 2.8) * 0.5
                    t.facing += 2 * max(0, 0.1 - simd_dot(f[h], Self.dir(v)))   // behind the sofa's back: out of the circle
                }
            }
            // No sitting with your back to a nearby door.
            for i in seats {
                guard let d = doors.min(by: { simd_distance($0.center, s.pos[i]) < simd_distance($1.center, s.pos[i]) }),
                      simd_distance(d.center, s.pos[i]) < 3.5 else { continue }
                t.facing += 0.5 * max(0, -simd_dot(f[i], Self.dir(d.center - s.pos[i])) - 0.5)
            }
            // Use zones: the strip in front of a seat, bed, desk or cabinet stays clear (two chairs nose to tail is unusable).
            for i in 0..<n {
                let depth = useDepth(i)
                guard depth > 0 else { continue }
                let zc = s.pos[i] + f[i] * (items[i].half.y + depth / 2), zh = Self.aabb(SIMD2(items[i].half.x, depth / 2), s.yaw[i])
                for j in 0..<n where j != i && (items[i].movable || items[j].movable) && !mayUse(i, j) {
                    t.clearance += Self.overlap(zc, zh, s.pos[j], box[j])
                }
            }
            // Sightlines: nothing tall between the sofa group and the screen.
            for v in viewers {
                for sc in screens {
                    let a = s.pos[v], b = s.pos[sc], ab = b - a, len2 = max(simd_length_squared(ab), 1e-6)
                    for j in 0..<n where j != v && j != sc && !flat(j) && items[j].height > FengShui.lowTable {
                        let q = a + ab * simd_clamp(simd_dot(s.pos[j] - a, ab) / len2, 0.15, 0.85)   // ends belong to viewer / screen
                        let r = min(box[j].x, box[j].y), d = simd_distance(q, s.pos[j])
                        if d < r { t.view += r - d }
                    }
                }
            }
            t.circulation = unreachable(s, box: box, f: f)
            for i in movable where items[i].kind == .plant { t.facing += 0.3 * min(nearestWall(s.pos[i]).d, 1) }   // corners, edges
            for i in movable where items[i].kind == .lamp {
                let near = (anchors + seats).map { Self.gap(s.pos[i], box[i], s.pos[$0], box[$0]) }.min() ?? 0
                t.facing += 0.3 * max(0, near - 0.5)
            }
            // Rugs ground the seating group.
            let group = ([main, coffee].compactMap { $0 } + seats)
            if !group.isEmpty {
                let g = group.reduce(SIMD2<Float>.zero) { $0 + s.pos[$1] } / Float(group.count)
                for i in rugs where items[i].movable { t.rug += simd_distance(s.pos[i], g) }
            }

            t.inside *= W.inside; t.overlap *= W.overlap; t.door *= W.door; t.command *= W.command; t.chi *= W.chi
            t.clearance *= W.clearance; t.circulation *= W.circulation; t.view *= W.view
            t.wall *= W.wall; t.window *= W.window; t.facing *= W.facing; t.breathing *= W.breathing
            t.balance *= W.balance; t.rug *= W.rug; t.move *= W.move
            return t
        }

        /// Fronts of seats, anchors and storage nobody can walk to from a door: flood fill over padded footprints.
        func unreachable(_ s: State, box: [SIMD2<Float>], f: [SIMD2<Float>]) -> Float {
            guard !starts.isEmpty else { return 0 }
            let g = (lo: grid.lo, nx: grid.nx, nz: grid.nz), cell = FengShui.cell
            var open = grid.open
            for j in items.indices where items[j].kind != .rug {
                let lo = s.pos[j] - box[j] - FengShui.person, hi = s.pos[j] + box[j] + FengShui.person
                let x0 = max(Int(((lo.x - g.lo.x) / cell).rounded(.up)), 0), x1 = min(Int(((hi.x - g.lo.x) / cell).rounded(.down)), g.nx - 1)
                let z0 = max(Int(((lo.y - g.lo.y) / cell).rounded(.up)), 0), z1 = min(Int(((hi.y - g.lo.y) / cell).rounded(.down)), g.nz - 1)
                guard x0 <= x1, z0 <= z1 else { continue }
                for z in z0...z1 { for x in x0...x1 { open[z * g.nx + x] = false } }   // cell centers inside the padded box
            }
            var seen = [Bool](repeating: false, count: open.count), queue: [Int] = []
            for c in starts where open[c] && !seen[c] { seen[c] = true; queue.append(c) }
            var k = 0
            while k < queue.count {
                let c = queue[k], x = c % g.nx, z = c / g.nx
                k += 1
                for (dx, dz) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                    let nx = x + dx, nz = z + dz
                    guard nx >= 0, nz >= 0, nx < g.nx, nz < g.nz else { continue }
                    let m = nz * g.nx + nx
                    if open[m] && !seen[m] { seen[m] = true; queue.append(m) }
                }
            }
            var missed: Float = 0
            for i in items.indices where useDepth(i) > 0 && items[i].kind != .anchor || i == main {
                let atTable = hub[i].map { items[$0].kind == .table } == true   // a dining chair is reached from behind
                let p = s.pos[i] + f[i] * (atTable ? -1 : 1) * (items[i].half.y + FengShui.person + cell / 2)
                guard let c = Self.cellIndex(p, g) else { missed += 1; continue }
                let x = c % g.nx, z = c / g.nx
                var ok = false
                for dz in -1...1 { for dx in -1...1 where !ok {   // a step either way still counts
                    let nx = x + dx, nz = z + dz
                    if nx >= 0, nz >= 0, nx < g.nx, nz < g.nz, seen[nz * g.nx + nx] { ok = true }
                } }
                if !ok { missed += 1 }
            }
            return missed
        }

        // MARK: Moves

        /// Back against a wall, facing in. `t` = distance along the edge (nil = random).
        func snap(_ i: Int, to e: Int, at t: Float?, _ s: inout State, _ rng: inout SplitMix64) {
            let e = edges[e], h = items[i].half, m = min(h.x + FengShui.wall, e.len / 2)
            let along = simd_clamp(t ?? m + rng.unit() * max(e.len - 2 * m, 0), m, e.len - m)
            s.pos[i] = e.a + e.dir * along + e.n * (h.y + FengShui.wall + 0.005)
            s.yaw[i] = atan2(e.n.x, e.n.y)
        }
        func randomWall(_ rng: inout SplitMix64) -> Int {
            var r = rng.unit() * edges.reduce(0) { $0 + $1.len }
            for (k, e) in edges.enumerated() { r -= e.len; if r <= 0 { return k } }
            return edges.count - 1
        }
        func randomPoint(_ rng: inout SplitMix64) -> SIMD2<Float> {
            for _ in 0..<20 {
                let p = lo + (hi - lo) * SIMD2(rng.unit(), rng.unit())
                if FloorClamp.contains(p, outline) { return p }
            }
            return center
        }
        func replace(_ i: Int, _ s: inout State, _ rng: inout SplitMix64) {
            if items[i].kind == .screen, !consoles.isEmpty, rng.unit() < 0.5 {   // next to a console, backs aligned
                let c = consoles[Int(rng.unit() * Float(consoles.count)) % consoles.count], fc = Self.front(s.yaw[c])
                let side: Float = rng.unit() < 0.5 ? 1 : -1, rc = SIMD2(fc.y, -fc.x)
                s.pos[i] = s.pos[c] + rc * side * (items[c].half.x + items[i].half.x + 0.05) + fc * (items[i].half.y - items[c].half.y)
                s.yaw[i] = s.yaw[c]
            } else if items[i].kind.hugsWall, !edges.isEmpty { snap(i, to: randomWall(&rng), at: nil, &s, &rng) }
            else { s.pos[i] = randomPoint(&rng); s.yaw[i] = Float(Int(rng.unit() * 4)) * .pi / 2 }
        }
        func clamp(_ i: Int, _ s: inout State) {
            s.pos[i] = FloorClamp.clamp(footprint: s.pos[i], half: Self.aabb(items[i].half, s.yaw[i]), to: outline, wall: FengShui.wall)
        }

        func randomized(_ start: State, _ rng: inout SplitMix64) -> State {
            var s = start
            for i in movable { replace(i, &s, &rng); clamp(i, &s) }
            return s
        }

        func anneal(_ start: State, iterations: Int, _ rng: inout SplitMix64) -> (State, Float) {
            var cur = start, curP = terms(cur).total
            var best = cur, bestP = curP
            let t0: Float = 1.5, t1: Float = 0.003, steps = max(iterations, 1)
            for k in 0..<steps {
                if k & 255 == 0, Task.isCancelled { break }
                let temp = t0 * pow(t1 / t0, Float(k) / Float(steps))
                var c = cur
                let i = movable[Int(rng.unit() * Float(movable.count)) % movable.count]
                var touched = [i]
                let roll = rng.unit()
                switch roll {
                case ..<0.4:   // jitter, shrinking as it cools
                    let step = 0.05 + 0.6 * temp / t0
                    c.pos[i] += SIMD2(rng.unit() - 0.5, rng.unit() - 0.5) * 2 * step
                case ..<0.55 where !edges.isEmpty:   // nearest wall, keep the spot along it
                    let w = nearestWall(c.pos[i]), e = edges[w.e]
                    snap(i, to: w.e, at: simd_dot(c.pos[i] - e.a, e.dir), &c, &rng)
                case ..<0.7:   // quarter turn (sometimes half)
                    c.yaw[i] += (rng.unit() < 0.5 ? 1 : -1) * (rng.unit() < 0.8 ? .pi / 2 : .pi)
                    c.yaw[i] = atan2(sin(c.yaw[i]), cos(c.yaw[i]))
                case ..<0.85 where movable.count > 1:   // swap two of a kind (a chair taking the bookshelf's spot looks wrong)
                    let alike = movable.filter { $0 != i && items[$0].kind == items[i].kind }
                    guard !alike.isEmpty else { continue }
                    let j = alike[Int(rng.unit() * Float(alike.count)) % alike.count]
                    c.pos.swapAt(i, j); c.yaw.swapAt(i, j)
                    touched.append(j)
                default:
                    replace(i, &c, &rng)
                }
                for t in touched { clamp(t, &c) }
                let p = terms(c).total
                if p < curP || rng.unit() < exp((curP - p) / temp) {
                    cur = c; curP = p
                    if p < bestP { best = c; bestP = p }
                }
            }
            return (best, bestP)
        }

        // MARK: Note

        func note(_ b: Terms, _ a: Terms) -> String {
            let name = main.map { items[$0].label.lowercased() } ?? ""
            let command = !name.isEmpty && name.count <= 12 ? "Chi flowing · \(name) has the command seat" : "Chi flowing · command seat claimed"
            let gains: [(Float, String)] = [
                (b.overlap - a.overlap, "Untangled · nothing bumps anymore"),
                (b.inside - a.inside, "Back inside the walls · grounded"),
                (b.door - a.door, "Door swings free · chi welcome"),
                (b.clearance - a.clearance, "Every seat has legroom"),
                (b.circulation - a.circulation, "Clear walkways all around"),
                (b.view - a.view, "Clear view from the sofa"),
                (b.command - a.command, command),
                (b.chi - a.chi, "Clear chi path from the door"),
                (b.wall - a.wall, "Backs to walls · feeling supported"),
                (b.window - a.window, "Windows unblocked · light flows"),
                (b.facing - a.facing, "Everyone faces the good stuff"),
                (b.breathing - a.breathing, "Room to breathe"),
                (b.balance - a.balance, "Yin and yang, nicely balanced"),
                (b.rug - a.rug, "Rug grounds the circle"),
            ]
            return gains.max { $0.0 < $1.0 }.map(\.1) ?? "Chi flowing"
        }
    }

    /// Tiny seeded generator so each agent (and each test run) is reproducible.
    struct SplitMix64: RandomNumberGenerator, Sendable {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
        /// Uniform in [0, 1).
        mutating func unit() -> Float { Float(next() >> 40) / Float(1 << 24) }
    }
}
