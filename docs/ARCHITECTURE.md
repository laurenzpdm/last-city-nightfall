# Last City: Nightfall — Architecture Contract

**This file is law.** Every agent reads it before writing a line. Violating the ownership
rules breaks the build for everyone else.

Engine: **Godot 4.7.1**, GDScript with **static typing everywhere**, 2D top-down.
Target: **Steam** (Windows / macOS / Linux desktop). Mouse+keyboard first, gamepad later.

---

## 0. The pitch (what we are actually building)

A dying city on a frozen plain. You keep it warm, you keep it fed, you keep it building —
and every night something comes out of the dark to take it apart. Heat is your power grid,
your defense grid and your morale system at the same time. You automate because you cannot
click fast enough to survive, not because a tutorial told you to.

Three genres, one resource: **heat**.
- **City builder** — heat keeps citizens alive, sets morale, gates district growth.
- **Automation** — heat is produced, piped, buffered, transformed into ammo and parts.
- **Tower defense** — turrets burn heat to fire. Night drains it. Overextend and you go dark.

Design north stars, in priority order:
1. **Legible.** A player must be able to look at a base and *read* it. Every failure is
   the player's fault and visibly so. (Factorio's contract with the player.)
2. **Pressured.** The clock always moves toward night. Every choice costs something real.
   (Frostpunk's contract.)
3. **Beautiful.** Cold blue dark, warm orange light, snow, embers, long shadows.
4. **Deterministic.** Same seed + same inputs = same run. Non-negotiable (see §3).

---

## 1. Directory ownership — hard rule

An agent writes **only** inside the folders it owns, plus its own tests. It never edits
another part's folder, and never edits `game/core/` or `project.godot`.

```
game/
  boot.gd/.tscn    INTEGRATOR ONLY. The single entry point: creates the world,
                   installs the renderer, the camera and the play shell.
  core/            INTEGRATOR ONLY. Autoloads + contracts. Do not touch.
  play/            INTEGRATOR ONLY. The session shell: build mode, the ghost, the
                   minimum HUD. Placeholder for [P17]/[P18]; delete on their arrival.
  sim/             Deterministic simulation. No rendering, no input, no UI.
    grid/          [P01] tiles, terrain, chunks, pathfinding surface
    heat/          [P02] heat + power network graph, pipes, falloff
    logistics/     [P03] belts, arms, buffers, item movement
    production/    [P04] machines, recipes, crafting graph
    citizens/      [P05] population, jobs, needs, shifts
    society/       [P06] hope, discontent, laws, factions
    combat/        [P07] turrets, projectiles, damage, enemies-in-world
    threat/        [P08] wave director, spawn curves, adaptive pressure
    climate/       [P09] day/night, temperature, storms, seasons
    research/      [P10] tech tree, unlocks, progression gates
    build/         [P11] placement, ghosts, blueprints, undo
    economy/       [P12] balance curves + tuning tables (data only)
  content/         Data-driven .tres. Each part writes ONLY its own subfolder.
    buildings/ recipes/ enemies/ laws/ research/ events/ biomes/
  view/            Reads sim, never writes sim.
    render/        [P13] art direction, lighting, shaders, post
    vfx/           [P14] particles, weather, embers, explosions
    feel/          [P15] juice, shake, easing, micro-anim
    camera/        [P16] camera, input mapping, controls
  ui/
    hud/           [P17] resource bars, alerts, time, notifications
    build_menu/    [P18] build UI, tooltips, item info, recipe browser
    overlays/      [P19] READABILITY LENSES — the automation-legibility layer
    stats/         [P20] production graphs, flow analysis, history
    tutorial/      [P21] onboarding, teaching, first 20 minutes
  narrative/       [P22] events, dilemmas, story beats, flavor text
  audio/           [P23] adaptive music, ambience, SFX, mix
  meta/            [P24] save/load, settings, accessibility, Steam
tools/             Harness, CLI, screenshot rig. INTEGRATOR + tooling agent.
tests/             tests/<part>/ — each part owns its own folder.
                   A suite entry point is `test_*.gd`, `run_*.gd` or a `.tscn`;
                   anything else in tests/ is invisible to the gate. See §6.
progress/          Live progress page. Written by the orchestrator only.
artifacts/         Run outputs: screenshots, metrics, state dumps. Generated.
```

**Registration is by directory scan, never by editing a shared list.** To add a building,
drop a `.tres` in `game/content/buildings/`. `Registry` finds it. There is no
`all_buildings.gd` to conflict over. Same for recipes, enemies, laws, research, events.

---

## 2. Autoloads (in `game/core/`, integrator-owned)

| Autoload | Purpose |
|---|---|
| `Log` | Structured logging, level-filtered, harness-capturable |
| `Rng` | **The only** source of randomness. `Rng.stream("threat").randf()` |
| `Registry` | Scans `game/content/**`, exposes typed lookups by id |
| `SimClock` | Fixed-step tick driver. Owns tick order. |
| `Sim` | Root of the simulation world. Holds all sim systems. |
| `Bus` | Signal bus. Sim → View communication. One direction. |
| `Settings` | User config, graphics, accessibility, keybinds |
| `Harness` | Automated-run driver. Inert unless `--harness` is passed. |

---

## 3. Determinism — the rule that makes everything else testable

The simulation runs at a **fixed 20 Hz tick** (`SimClock.TICK_HZ = 20`), independent of
frame rate. Rendering interpolates between ticks; it never drives state.

Forbidden in `game/sim/**`:
- `randf()`, `randi()`, `randomize()`, `Time.get_ticks_msec()`, `delta`
- reading input, touching nodes in `view/` or `ui/`
- `await` on anything frame-based
- iterating an unordered `Dictionary` in a way that affects state (sort keys first)

Required instead:
- `Rng.stream(name)` — named, seeded, independent streams
- `SimClock.tick` (int) for time
- `SimClock.DT` (= 0.05) for per-tick integration

Why: the harness replays a scenario headlessly and gets byte-identical results, so a critic
can be handed the *actual behavior* of the build instead of a builder's summary, and so
balance regressions show up as a diff instead of a vibe.

Every sim system extends `SimSystem` and declares a tick order priority. Lower runs first.

```
10 climate → 20 heat → 30 logistics → 40 production → 50 citizens
→ 60 society → 70 threat → 80 combat → 90 research → 99 metrics
```

---

## 4. The harness — how work gets judged

Never judge from a builder's summary. Judge from a run.

```bash
# Deterministic headless run: sim only, no renderer. Fast. For balance/regression/perf.
tools/run_sim.sh --scenario=first_night --ticks=12000 --seed=7 --out=artifacts/run_a

# Visual run: real window, real rendering, auto-driven, saves PNGs at scripted beats.
tools/run_visual.sh --scenario=first_night --shots=opening,build,dusk,assault,dawn
```

Outputs land in `artifacts/<run>/`:
- `state.json` — full sim state at end + at each checkpoint
- `metrics.csv` — per-tick series (heat, pop, hope, threat, throughput, fps)
- `shots/*.png` — actual frames from the actual build
- `log.txt` — structured log

A critic is given the **artifacts folder and the running game**, never a written summary.

---

## 5. Code conventions

- `snake_case` files and functions, `PascalCase` classes, `SCREAMING_CASE` consts.
- **Static typing on every declaration and signature.** `var x: int = 0`, `func f(a: Vector2i) -> void:`
- `class_name` on anything another part legitimately needs to reference.
- Tabs for indent (Godot standard).
- Prefer `Resource` data + plain `RefCounted` logic over deep node trees. Shallow scenes.
- No node lookups by path across parts. Communicate through `Bus` signals or `Sim` accessors.
- Every public function that another part calls gets a one-line doc comment. No essays.
- Comments explain *why*, never *what*.

## 6. Definition of done for a part

1. It runs in the actual build without errors in the log. A `Log.error` inside
   `game/sim/**` fails the harness run — `expects.max_errors` is enforced.
2. It has tests in `tests/<part>/` that pass headlessly.
3. It is visible/legible to the player, or it is explicitly internal.
4. `tools/check.sh` is green (parse + tests + determinism replay + perf).
5. A fresh critic looking at a real run cannot name an obvious hole in it.

### 6.1 The test naming contract

`tests/framework/test_runner.gd` discovers a suite entry point by NAME. There is
exactly one rule and it is enforced, not implied:

| pattern | how it runs |
|---|---|
| `tests/**/test_*.gd` extending `TestCase` | in-process, by the shared runner |
| `tests/**/*.tscn` | as a SCENE, in its own Godot process |
| `tests/**/run_*.gd` extending `SceneTree` | with `--script`, in its own process |

A `.tscn` always wins over the `.gd` it instantiates. A `Node`-based suite run
with `--script` compiles **before the autoloads exist**, prints nothing and exits
0 — a silent false green, which is exactly how 371 build assertions were reported
passing while never executing. Every standalone suite must print one of
`TESTS PASSED` / `TESTS FAILED`; `tools/check.sh` fails a suite that prints
neither.

### 6.2 The scenario contract

`tests/scenarios/*.json` are generated by `tools/gen_scenarios.py`, which knows
every footprint and refuses to emit a placement that would be refused at runtime.
Two rules have teeth in `tests/p00/test_scenarios.gd`:

* every `system` a scenario addresses must exist **in this build**, and
* every building `kind` a scenario places must exist in the registry.

A scenario that talks to a system nobody has written is not a plan; it is a run
that silently does nothing and still exits 0.
