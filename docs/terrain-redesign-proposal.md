# Terrain system redesign proposal

Status: **Implemented** (approved; see [Terrain](terrain.md)). Choices made: one tile size for the whole grid; one grid per terrain, with tiles allowed to be spaced apart; a removed tile leaves a hole; chunks have level of detail.

## Goals

- Default terrain workflow is manual, not endless procedural generation.
- Developers place large, initially flat square terrain sections in the editor, similar to Unity Terrain.
- Adjacent sections snap together automatically, share compatible dimensions/resolution, and render with seamless edges.
- Sculpting and painting brushes operate continuously across section boundaries without cracks, discontinuities, or material seams.
- Terrain sections can be added, selected, moved where appropriate, and removed through an editor workflow. Support save/load, undo/redo, and reliable recovery of edits.
- Keep Tallow's voxel capabilities (including caves, overhangs, and destruction) rather than restricting terrain to heightmaps.
- World generation is game-specific: each game supplies its own procedural terrain implementation. Tallow supplies terrain storage, editing, meshing, streaming, and generator interfaces, but does not impose one world shape.
- Endless generation remains available as an explicitly configured opt-in system, not the default.

## Proposed architecture

1. **Terrain world/data:** a shared terrain container with a tile grid, stable tile IDs, voxel density/material data, serialized edits, and shared boundary sampling.
2. **Terrain editor:** create adjacent flat tiles; select/remove tiles; sculpt/paint seamlessly across edges; provide undo/redo and clear controls.
3. **Generator interface:** optional game-owned density/biome generation, applicable to selected tiles, streaming regions, or endless worlds. No forced default noise generator.
4. **Streaming:** independent of generation. Stream hand-authored and/or generated terrain based on each game's requirements.

## Proposed modes

- **Manual (default):** explicitly placed, flat tiles, sculpted by hand.
- **Procedural:** game-defined generation applied to chosen areas.
- **Streaming:** load/unload existing authored or generated tiles.
- **Endless:** optional game-controlled expansion using its generator.

## Current engine considerations

At the time of discussion, `VoxelTerrain` already defaulted to `TerrainMode.Fixed`, with a flat 4×4-chunk area; `Endless` was optional and `SetGenerator(...)` existed. The missing workflow was Unity-like adjacent tile authoring and seamless shared boundaries. The existing fixed terrain density intentionally fades out at the edge, so placing independent terrains side-by-side alone is insufficient.

## Acceptance criteria for a future implementation

- Creating a new terrain produces one flat manually placed tile, not an expanding generated world.
- Adding neighboring tiles in all four directions aligns them precisely and does not duplicate occupied tiles.
- Height sculpting and material painting across tile boundaries are visually and numerically continuous.
- Editing, saving, reloading, and undo/redo preserve shared edges and paint layers.
- Different games can plug in different generators; no generator is required for manually authored terrain.
- Existing scenes and optional endless worlds remain compatible or have an explicit migration path.
- Automated tests cover tile placement, edge continuity, brush overlap, persistence, and backward compatibility.

This document records the design intent the implementation follows.
