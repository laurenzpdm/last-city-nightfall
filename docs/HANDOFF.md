# Last City: Nightfall — Cloud Handoff

Everything an agent needs to pick this up cold, in the cloud or on a fresh machine.
Written 2026-08-13, after Phase C was interrupted. **Every number below was verified by
running the build, not taken from an agent's report.** That distinction is the method of
this whole project: see §7.

---

## 1. What this is

A Tower Defense × City Builder × Automation game for **Steam**, built in **Godot 4.7.1**,
GDScript, 2D top-down. The stated bar is Factorio and Frostpunk.

A dying city on a frozen plain. Heat is the power grid, the morale system and the ammunition
at the same time. Generators make it, pipes carry it, citizens die without it, turrets burn it
to fire, and every night something comes out of the dark drawn by the warmth. You automate
because you cannot click fast enough to survive.

**Read `docs/ARCHITECTURE.md` first. It is the binding contract** for folder ownership,
determinism rules and code conventions. It is what lets a dozen agents work in one repo
without destroying each other.

## 2. Verified state, 2026-08-13

| | |
|---|---|
| Lines of GDScript | ~117,000 across ~366 files |
| Commits | 134+ |
| Simulation systems live | 11 |
| Sim tick | 20 Hz fixed, deterministic, byte-identical replays verified |
| Performance | 122 ticks/s; 60 fps at a 1700-building city, 8 draw calls |
| Repo | `github.com/laurenzpdm/last-city-nightfall` |

**Critic scores so far** (fresh context each time, judging the running build only, never a
builder's summary):

| Round | Score | The one gap the critic named |
|---|---|---|
| 1 | 3.8 / 10 | Legibility: rich sim analysis, zero pixels |
| 2 | 4.2 / 10 | Nothing is reachable, and the gate cannot see it |
| 3 | not reached | Phase C was interrupted before the judges ran |

## 3. What exists and works

**Simulation** (`game/sim/`, all 11 systems tick):
- `heat/` — **the best thing in the repo.** A real max-min-fair flow solver: level-synchronous
  multi-source BFS routing, progressive filling across three constraint families (per-tile
  throughput, per-source availability, per-consumer demand), successive-shortest-path
  augmentation on saturation, priority load shedding, repeater tiles that reset transmission
  efficiency, and **per-consumer bottleneck attribution with reason codes**. A round-1 critic
  read it line by line, measured conservation (`supply − [delivered+loss+charge] = 0.00000`)
  and distance loss against the formula, and called it a deeper heat model than Frostpunk's,
  which is fundamentally a radius-overlap check. Do not casually refactor this.
- `grid/` — 256×256 chunked map, deposits, Dial's-algorithm flow-field pathfinding
- `climate/` — day/night arc, per-cell temperature, scheduled Great Frosts, era escalation
- `build/` — placement, construction queue, blueprints (capture/rotate/mirror/book), undo
- `logistics/`, `production/`, `citizens/`, `society/`, `combat/`, `threat/`, `research/`

**Presentation**: `view/render` (real lighting, day/night grade, procedural sprites),
`view/camera`, `view/vfx` (weather, industry, combat, decay, breath), `view/feel`,
`ui/hud`, `ui/build_menu`, `ui/overlays` (six diagnostic lenses), `ui/stats`,
`audio` (10 buses, 47 procedurally synthesised streams), `narrative`.

**Rigour**: own test framework, ~768 tests, determinism replay, per-system tick profiling
(`Sim.profile_report()`), a reachability suite, `tools/lint_sim.sh` for determinism violations.

## 4. Known defects, all reproduced by hand

**A. Three reachability-suite failures.** Run
`godot --path . tests/boot/run_reachability.tscn -- --force-ui`:
```
FAIL 2 is still fast-forward with a full quickbar (speed=1.0)
FAIL 3 is still very fast (speed=1.0)
FAIL clicking the hearth fills the selection panel (id=-1)
TESTS FAILED — 88 checks, 3 failures
```
Number keys 2 and 3 are claimed by both sim-speed and the build quickbar. Clicking a building
does not populate the selection panel.

**B. The reachability suite exits 0 while printing TESTS FAILED.** This is the round-2 disease
returning in a new place: a gate that cannot go red. **Fix the exit code before anything else**,
or CI will certify broken builds again.

**C. Engine-level leaks on every single run:**
```
WARNING: 740 ObjectDB instances were leaked at exit
ERROR: 258 resources still in use at exit
```
An `ERROR:` line prints on every run and nothing fails. C2's mandate was to make engine-level
errors fail the gate; that work was interrupted. This is unfinished.

**D. The renderer invents a city when none exists.** With no structures it draws "337
placeholder structures" as a preview settlement, then drops them when real construction
appears. Useful for isolated render tests, dangerous everywhere else: a screenshot can show a
city that does not exist in the simulation. At minimum it must be impossible in harness runs.

**E. Round-2 findings that Phase C was mid-way through fixing.** Re-verify each, do not assume:
belts never placed in any scenario (`logistics.items_moved = 0` across 24000 ticks); wave 2
never ending (one enemy alive 6960 ticks at full HP); the HUD fabricating depletion warnings;
68 `String formatting error` lines per visual run; world overlay labels painting over the HUD.

## 5. Phase C: what landed, what did not

Ten builders launched at 20:58, interrupted at 21:58. The workflow journal recorded only 3
returns, **but far more landed on disk than that suggests** — measured directly:

| Agent | Folder | On disk | Status |
|---|---|---|---|
| C1 boot seam | `game/boot.gd`, `game/core/ui_layers.gd`, `tests/boot/` | 443 test lines + rewritten boot | **Done.** Install contract with `is_inside_tree()` verification, `install_report`, layer table, input router, `--ui-tour` |
| C2 gate teeth | `tools/`, `tests/framework/` | partial | **Unfinished.** Harness now counts orphan nodes and total `Log.errors`, but engine stderr still does not fail anything |
| C3 logistics reachable | `game/sim/logistics/` | partial | Re-verify: does a human get a placeable belt? |
| C4 UI truth | `game/ui/hud/`, `build_menu/` | partial | Re-verify the String-formatting errors and fake alerts |
| C5 combat repair | `game/sim/combat/`, `threat/` | partial | Re-verify the wave-2 stall |
| P14 VFX | `game/view/vfx/` | 2,814 lines | Installs and reports live |
| P15 feel | `game/view/feel/` | 2,866 lines | Re-verify |
| P23 audio | `game/audio/` | 4,422 lines | Installs, 10 buses, 47 streams |
| P22 narrative | `game/narrative/` | 4,600 lines | Installs, chapters firing |
| P20 stats | `game/ui/stats/` | 4,445 lines | Installs, 19 series across 3 tracks |

**Never run after the builders**: the integrator, the playthrough agent, the round-3 critic and
the blind side-by-side comparison against Factorio and Frostpunk. Those are the next stage.

## 6. How to run everything

```bash
# Play it
godot --path .

# Deterministic headless run: sim only, fast, for balance/regression/perf
godot --headless --path . -- --harness --scenario=first_night --ticks=12000 --out=artifacts/a

# Real frames from the real renderer (needs a display; on Linux use xvfb-run)
godot --path . --resolution 1920x1080 -- --harness --visual --scenario=first_night --out=artifacts/vis

# Every screen, photographed in turn
godot --path . -- --ui-tour

# Reachability: can a human actually open each screen?
godot --path . tests/boot/run_reachability.tscn -- --force-ui

# The whole gate
bash tools/check.sh
```
Outputs land in `artifacts/<run>/`: `state.json`, `metrics.csv`, `log.txt`, `shots/*.png`.

`tools/check.sh` and the run scripts honour a `GODOT` environment variable, so any machine
works: `export GODOT=/path/to/godot`.

## 7. The method — do not skip this

This project is built by many agents in parallel, and it only works because of three rules:

1. **Folder ownership is absolute.** An agent writes only in the folders it owns. Content
   registers by directory scan (drop a `.tres` in `game/content/buildings/`), never by editing
   a shared list, so there is nothing to merge-conflict over.
2. **Determinism is non-negotiable.** No `randf()`, no wall clock, no frame delta anywhere in
   `game/sim/**`. Randomness only through `Rng.stream("name")`. Sort dictionary keys before any
   iteration that affects state. This is what makes a replay byte-identical, which is what makes
   a critic able to judge behaviour instead of vibes.
3. **Critics judge the running build, never a summary.** Every review agent gets fresh context
   and is explicitly forbidden from reading builder reports, `progress/events.jsonl` or commit
   messages. They run the harness, read the artifacts, and look at the actual PNG frames.

Rule 3 is not ceremony. In round 2 all twelve builders honestly reported success, `check.sh`
said GREEN, 768 tests passed — and the entire user interface was an orphan node that no human
could open. Only an agent who tried to open a menu found it.

## 8. Cloud CI

`.github/workflows/gate.yml` runs on every push:
- **gate (macOS)** — installs Godot, imports, runs `tools/check.sh`, counts engine-level error
  lines separately, runs a 12000-tick deterministic simulation, uploads `gate.log` + artifacts.
- **screenshots (Linux, xvfb)** — renders `first_night` and uploads the real PNG frames as a
  build artifact, so a reviewer anywhere can look at what the build actually draws.

Standard GitHub-hosted runners, **macOS included, are free and unmetered for public
repositories** with no minute cap. That is why this repo is public. If it is ever made private,
macOS minutes bill at a 10× multiplier and the macOS job should be dropped.

## 9. What to do next, in order

1. **Fix the exit code of the reachability suite (defect B).** A gate that cannot fail is worse
   than no gate, and this project has now been bitten by that exact thing twice.
2. **Finish C2's mandate**: engine-level stderr errors must fail the gate. Then the leaks in
   defect C become visible pressure instead of scrollback.
3. **Fix defects A and D**, then re-verify the round-2 findings in E one at a time by running,
   not by reading code.
4. **Then run the stage Phase C never reached**: integrator → playthrough agent → round-3 critic
   → blind side-by-side comparison against Factorio and Frostpunk.
5. Still entirely unbuilt: **[P21] tutorial** and **[P24] meta** (save/load UI, settings screen,
   accessibility, Steam integration, achievements, controller). Neither has been started.

## 10. Standing instruction from Maximilian

> Stop after Phase C. Do not launch a further wave without asking him first. Report the result
> and wait.
