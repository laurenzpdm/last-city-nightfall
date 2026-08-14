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

**The gate's own verdict, measured 2026-08-14 on `main` before any change — `CHECK RED — 10
failing`, exit 1.** Read that before believing any other number on this page. `tools/check.sh`
was never green; the row above that says "768 tests pass" is true and irrelevant, which is the
whole lesson of round 2.

```
FAIL  tests                           1063 passed, 4 failed
FAIL  tests/feel/feel_gallery.tscn    24 checks, 1 failed
FAIL  tests/feel/feel_perf.tscn       6 checks, 2 failed
FAIL  perf gate                       stress_1000 at 43 ticks/s
FAIL  engine errors                   363 blocking
FAIL  engine errors: boot             Godot's own stderr during a real launch
FAIL  contract: first_night           26 pass, 4 FAIL
FAIL  contract: determinism           11 pass, 1 FAIL
FAIL  contract: first_night_endurance 14 pass, 1 FAIL
FAIL  engine errors: visual           the only pass that executes ui/ and view/
```
The perf number was measured on a loaded 4-core box under software GL (llvmpipe). It is not
comparable to the 122 ticks/s in the table above and must be re-measured on an idle machine
before anyone reads anything into it.

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

## 4. Known defects

> **2026-08-14: three of the five entries below were WRONG, and being wrong about a defect
> costs more than not knowing about it.** Everything in this section has now been re-measured
> by running the build. Where the old text said something false, the false claim is kept and
> struck through, because the *way* it was wrong is the useful part.

**A. Three reachability-suite failures.** ✅ **Fixed, both causes measured.**
```
FAIL 2 is still fast-forward with a full quickbar (speed=1.0)
FAIL 3 is still very fast (speed=1.0)
FAIL clicking the hearth fills the selection panel (id=-1)
```
~~"Number keys 2 and 3 are claimed by both sim-speed and the build quickbar."~~ Not the
quickbar — `LcnInputRouter` already settled that collision. The real cause: **[P19] decided
which bare numbers were free by probing `InputMap`**, which is only populated once [P16]'s
camera installs the action map. With a display, [P19] installs *before* boot builds the camera,
so it probed an empty map, concluded 1/2/3 were free, took them as lens keys and swallowed them
with `set_input_as_handled()`. Now `LcnLayers.key_is_reserved()` is asked first, so the
reservation cannot depend on who booted first. The tell is in the log:
`[overlay] ready — … keys F1 F2 F3 4 5 6` (was `1 2 3 4 5 6`).

~~"Clicking a building does not populate the selection panel."~~ It does. Every link works
when called directly: `provider.entity_at_world` → 1, `press`/`release` → `has_selection=true`,
`describe_building(1)` → a full dictionary, `hud.select(1)` → 1. The click never *arrived*:
[P22]'s event card sits over the middle of the world and its body `RichTextLabel` held the GUI
hover at screen centre. Godot defaults `RichTextLabel` to `MOUSE_FILTER_STOP` (unlike `Label`,
which defaults to `IGNORE`), so prose was eating the mouse. The suite now dismisses what a
player would dismiss and **names the Control covering the click** instead of blaming [P17].

**B. ~~The reachability suite exits 0 while printing TESTS FAILED.~~** ✅ **Fixed — but the
claim was wrong, and the truth was worse.** It never printed `TESTS FAILED` and exited 0. It
printed **`TESTS PASSED`**:

| invocation | verdict | exit |
|---|---|---|
| `--headless`, no `--force-ui` — **what `tools/check.sh` ran** | `TESTS PASSED — 86 checks, 0 failures` | **0** |
| `--headless --force-ui` | `TESTS FAILED — 88 checks, 2 failures` | 2 |
| xvfb, a real display | `TESTS FAILED — 88 checks, 3 failures` | 3 |

The exit code was honest all along; the **verdict** was the lie. Every part that installs itself
from `game/content/**/*_bootstrap.tres` asks `LcnLayers.view_wanted()` while `Registry` is still
scanning — *before* `boot._ready`. With a display, or with `--force-ui`, [P19]/[P15]/[P20]/[P22]
come up first and boot adopts them; without either they decline and boot installs them itself,
in a different order. Only the second order was gated, and in it two of the three real failures
**cannot occur**. Note a display implies the *first* order — so the gated configuration was the
one no player ever gets.

The suite now refuses to run without `--force-ui` or a display; counts what it cannot ask as
`UNCHECKED` and returns `TESTS PASSED, PARTIAL` / exit 126; and `check.sh` reads each suite's own
`## REQUIRES:` line to supply the switches. `gate.yml` gates on the process exit code and
requires a verdict, so a suite that dies before printing one is no longer green.

**C. ~~Engine-level errors do not fail the gate — C2's mandate is unfinished.~~** ✅ **The
mechanism was already finished and already working.** `tools/scan_errors.py` reads every stage's
stderr and `check.sh` records it. Measured on `main` before any change: **`CHECK RED — 10
failing`, exit 1**, including `engine errors — 363 blocking`. What was unfinished was not the
gate but the *fixing*:

- **336 of the 363 came from one line.** [P06] numbers its demands (`{"id": 1}`); [P17] built an
  alert key with `String(1)`. Godot 4 has `String` constructors for `String`, `StringName` and
  `NodePath` and **nothing else**, and the alert panel refreshes several times a second for as
  long as a demand is open. → `str()`.
- **`HeatNetwork.clear_routing()` aborted on every call.** `topo.scratch` has not existed since
  residual routes became a memoised ring. A GDScript runtime error *aborts the function*, so
  `route_dirty = true` on the last line never ran — and the two callers are `rebuild_networks()`
  and **save loading**, precisely the two moments routing must be rebuilt from nothing.
- ALSA has no sound card on a build machine and printed an engine error before a line of this
  project ran. Visual runs now use the Dummy audio driver; `tests/audio/` keeps the real one.

The 740 leaked objects / 258 resources are real and still there. They are `tracked` in
`tools/error_allowlist.txt` with an owner and an expiry (2026-10-01), printed with a count in
every gate report, and reported by the engine *after* the last artifact is written — so they
cannot alter a metric, a replay or a screenshot.

**D. The renderer invents a city when none exists.** ✅ **Fixed.** The [P13] preview settlement
is refused in any `--harness` run, guarded *inside* `ensure_preview_settlement()` so a later
caller cannot reach it (`--no-preview-city` forces it off anywhere). Verified: a visual harness
run now logs `world ready: 0 structures (real)` where it logged `337 structures (PLACEHOLDERS)`,
and a real 76-building city still renders.

**E. Round-2 findings, each re-verified by running.**

| finding | status |
|---|---|
| belts never placed, `logistics.items_moved = 0` | **CONFIRMED, still broken.** `first_night`, 11000 ticks: `items_moved` final 0, `belt_lines` peak 0, `logistics.lines` len 0, and 13 build commands refused. The automation pillar does nothing in the run a critic is handed. |
| wave 2 never ending | **Changed shape.** A watchdog now force-resolves a stuck wave (`wave 1 has been live for 401 ticks … resolving it by`). What remains is an accounting bug: `threat.waves_cleared` disagrees with `Bus.wave_cleared` by exactly one in both `determinism` and `first_night_endurance`. |
| HUD fabricating depletion warnings | **Already fixed in code, tests were stale.** `LcnHudTrend` grew projection gates (12 samples, 20 s span) so one purchase cannot become a countdown; two tests still fed 8 and 10 samples and asserted the old over-eager behaviour. Tests corrected, plus a new one covering the refusal. |
| 68 `String formatting error` per visual run | **Gone as a class.** A visual harness run is now `0 blocking` engine errors. |
| world overlay labels over the HUD | **Symptom gone, source still disagrees.** `LcnLayers.enforce()` corrects [P19] on every launch and logs it: `P19 overlays put overlay_world on layer 70; the table says 62 — corrected`. |

## 5. Phase C: what landed, what did not

Ten builders launched at 20:58, interrupted at 21:58. The workflow journal recorded only 3
returns, **but far more landed on disk than that suggests** — measured directly:

| Agent | Folder | On disk | Status |
|---|---|---|---|
| C1 boot seam | `game/boot.gd`, `game/core/ui_layers.gd`, `tests/boot/` | 443 test lines + rewritten boot | **Done.** Install contract with `is_inside_tree()` verification, `install_report`, layer table, input router, `--ui-tour` |
| C2 gate teeth | `tools/`, `tests/framework/` | ~~partial~~ done | ~~**Unfinished.** engine stderr still does not fail anything~~ **Wrong — it does.** `tools/scan_errors.py` reads every stage's stderr and `check.sh` gates on it; it is why `main` is `CHECK RED`. See §4C |
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
# --force-ui (or a real display) is MANDATORY — without it the suite refuses to
# run rather than certify an install order no player ever gets. See §4B.
godot --path . tests/boot/run_reachability.tscn -- --force-ui

# The whole gate
bash tools/check.sh
```

On a headless Linux box, anything that draws needs xvfb:
```bash
export GODOT=/path/to/godot
xvfb-run -a -s "-screen 0 1920x1080x24" bash tools/check.sh
xvfb-run -a -s "-screen 0 1920x1080x24" \
    "$GODOT" --path . tests/boot/run_reachability.tscn -- --force-ui
```
The reachability suite has three outcomes, not two: `TESTS PASSED` (exit 0),
`TESTS FAILED` (exit = failure count), and **`TESTS PASSED, PARTIAL` (exit 126)** — it ran, it
found nothing wrong, and it could not ask everything it exists to ask. Headless, the click test
is `UNCHECKED` because there is no GUI hit-testing to click through. PARTIAL is not a pass:
`check.sh` records it as a skip and downgrades its verdict to `CHECK GREEN, PARTIAL`.
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

Defects A, B, C and D are done (§4). What is left, in the order it is worth doing:

1. **The automation pillar does not run.** `first_night` moves zero items over 11000 ticks and
   refuses 13 build commands. This is the largest gap between what the game claims and what a
   run contains, and no amount of gate work substitutes for it.
2. **`threat.waves_cleared` vs `Bus.wave_cleared`** disagree by one, failing two gate contracts.
   Find out which is right and whether the watchdog force-resolving waves is masking a third
   defect underneath.
3. **Legibility:** the `workshop` archetype carries **13** shipped buildings against a limit of
   3 — every splitter and every underground draws the same silhouette. The first north star in
   `ARCHITECTURE.md` is "a player must be able to look at a base and *read* it".
4. **[P15]'s cull rejects everything:** `441 structures offered, 0 survived the view cull`, so
   the city never breathes. Re-measure `_draw` on an idle machine before trusting the perf half.
5. **Re-measure perf cleanly.** Every perf number currently on this page is contaminated.
6. **Then the stage Phase C never reached**: integrator → playthrough agent → round-3 critic →
   blind side-by-side comparison against Factorio and Frostpunk.
7. Still entirely unbuilt: **[P21] tutorial** and **[P24] meta** (save/load UI, settings screen,
   accessibility, Steam integration, achievements, controller). Neither has been started.

### 9.1 A method note, earned the hard way

Three of the five defects in §4 were **described wrongly** in this file, and two of those three
described work as unfinished that was already done. The pattern in all three: the symptom was
observed correctly and the cause was guessed, then written down in the same voice as the
measurement. If you take one habit from this round, take this one — **write the command and its
output next to the claim**, and when you cannot, say "guess". A wrong cause in a handoff is more
expensive than a blank space, because the next agent starts by trying to fix the wrong thing.

## 10. Standing instruction from Maximilian

> Stop after Phase C. Do not launch a further wave without asking him first. Report the result
> and wait.
