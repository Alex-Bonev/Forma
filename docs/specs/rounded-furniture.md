# Spec: Consistent rounded furniture style

Status: **in progress** (delegated agent, worktree). Owner: A (Alex).

## Problem

There are three visual styles in one room:
- low-poly Kenney models (toilet, trash can, appliances…)
- photoreal Poly Haven models (sofa, chairs, tables…)
- the procedural rounded wall basin

Alex wants everything soft and rounded.

## Decision

- **Procedural rounded models** for every category that is still low-poly: built from RealityKit primitives with generous corner radii, in the style of `RoomBuilder.wallBasin` and `demoChair`.
- **Poly Haven models stay** for the categories they cover, because they are already smooth. "Realistic Models" off falls back to the rounded procedural set where one exists, otherwise to Kenney.

## Interface

New file `RoomVibe/Features/Designer/ProceduralFurniture.swift`:

```swift
@MainActor enum ProceduralFurniture {
    /// Fills `size` (x width, y height, z depth), centered on the origin, front +Z, back -Z.
    static func model(for key: String, size: SIMD3<Float>) -> Entity?
    static let keys: [String]
}
```

Keys: toilet, bathtub, sink, washerDryer, refrigerator, stove, oven, dishwasher, television, trashcan, box, bed, stairs, fireplace, lamp, rug, plant, bench, desk, tv_console.

## Integration (A, after merge)

- `RoomBuilder.furnish` and `CatalogItem.entity()`: prefer the Poly Haven model when Realistic Models is on and one exists; otherwise prefer `ProceduralFurniture.model`; otherwise the Kenney template.
- Procedural models are built at the exact target size, so they need no stretching and no 180° turn.

## Acceptance

- Every key renders recognizably in a Simulator gallery screenshot, rounded, facing +Z.
- UI tests still pass.
