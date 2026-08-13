# [P19] Readability overlays

The legibility layer. Six world-space lenses plus an always-on status layer that
turn the simulation's own analysis into something a player can see.

## For other parts

```gdscript
var root: LcnOverlayRoot = LcnOverlayRoot.instance()
if root != null:
    root.set_mode(LcnOverlayDefs.Mode.BOTTLENECK)   # e.g. from a tutorial step
    print(root.hotkey_for(LcnOverlayDefs.Mode.THERMAL))
    print(root.stats())                              # for a critic or a perf gate
Bus.overlay_mode_changed                              # emitted on every change
```

The root installs itself from `game/content/overlays/overlay_bootstrap.tres`
(Registry scans it at boot). It is skipped entirely on headless runs and with
`--no-view` / `--no-overlays`.

## The lenses

| key | lens | what it answers |
|---|---|---|
| F1 | heat network | which grid is which, where heat is going, how hard |
| F2 | bottlenecks | which tile is strangling which building |
| F3 | warmth | where the city can physically live |
| 4  | freeze & damage | how cold each building is and how long it has |
| 5  | logistics | belts, fuel bunkers, stalled machines |
| 6  | coverage | turret reach, crew, structures on no grid |

`ALT` held is the detail key; `ALT+1..6` also selects a lens. A bare number key
is claimed only when `InputMap` says no other part wants it, so [P16]'s sim
speed keys survive.

## Structure

```
overlay_defs.gd        enums, bit flags, labels — the shared vocabulary
overlay_palette.gd     colour + dash + glyph per channel, per vision mode
overlay_geometry.gd    contours, dashes, leaders, rings, hatch — pure maths
overlay_probe.gd       duck-typed reads of the systems that may not exist yet
overlay_snapshot.gd    the flat, read-only picture of the sim (sampled at 4 Hz)
overlay_layer.gd       base class: frame context, batched lines, labels, plates
*_lens.gd              one file per lens, all drawing only from the snapshot
status_icons.gd        the always-on layer and its editorial policy
overlay_legend.gd      the on-screen key, in screen space
overlay_root.gd        modes, hotkeys, the two canvas layers, the harness script
```

## Rules this part holds itself to

* **it never writes to the simulation.** `tests/overlays/test_overlay_snapshot.gd`
  serialises the world, samples a hundred times, and diffs the JSON.
* **it is cheap.** Sampling is 4 Hz and touches each heat node once; drawing is
  flat Packed arrays batched into a handful of draw calls. Both are measured and
  logged under the `overlay` tag.
* **it never hides what it is diagnosing.** Fills are clamped below 62% alpha,
  marks are rings and brackets, badges float above a building rather than on it.
* **colour is never the only channel.** Every network carries a dash pattern and
  a legend glyph; every severity carries a shape.
