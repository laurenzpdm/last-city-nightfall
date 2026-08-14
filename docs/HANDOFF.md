# Last City: Nightfall — Cloud Handoff

Everything an agent needs to pick this up cold. Written 2026-08-14, at the end of the run that
finished Phase C's gate work. **Every number below was produced by running the build in this
session, not copied from a report.** That distinction is the method of the whole project — §7.

The previous handoff described five defects. **Three of the five were wrong**, and one of the
three was wrong in the direction that matters: it made a broken gate sound better than it was.
Read §4 before you trust anything you have been told about this build.

---

## 1. What this is

A Tower Defense × City Builder × Automation game for **Steam**, built in **Godot 4.7.1**,
GDScript, 2D top-down. The stated bar is Factorio and Frostpunk.

A dying city on a frozen plain. Heat is the power grid, the morale system and the ammunition at
the same time. Generators make it, pipes carry it, citizens die without it, turrets burn it to
fire, and every night something comes out of the dark drawn by the warmth. You automate because
you cannot click fast enough to survive.

**Read `docs/ARCHITECTURE.md` first. It is the binding contract** for folder ownership,
determinism rules and code conventions. It is what lets a dozen agents work in one repo without
destroying each other.

## 2. Verified state, 2026-08-14

| | |
|---|---|
| Lines of GDScript | ~118,000 across ~373 files |
| Sim tick | 20 Hz fixed, deterministic — `tools/determinism.sh` says `IDENTICAL` |
| Tests | **1070 passing, 1 failing** (the one is perf — see §5) |
| Engine errors in the gate | **0 blocking** |
| Open work | `github.com/laurenzpdm/last-city-nightfall` PR **#1**, 15 commits, branch `claude/last-city-nightfall-defects-8rykuk` |

**CI on the head of PR #1:**

| job | verdict |
|---|---|
| `screenshots (Linux, xvfb)` | **green** — renders real frames, hard-gates the full reachability suite |
| `gate (macOS, headless)` | `CHECK RED — 5 failing`, of which **exactly one is a real defect** |

## 3. What changed in this run

`main` → PR #1, measured on the macOS runner both times:

| | `main` | now |
|---|---|---|
| `tools/check.sh` | `CHECK RED — 10 failing` | 5 failing, 1 real |
| blocking engine errors | **363** | **0** |
| tests | 1063 passed / 4 failed | **1070 / 1** |
| `contract: first_night` | 4 bands red | **1** band red |
| `screenshots (Linux)` | red | **green** |
| reachability suite | certified a broken build | 89 checks, 0 failures |

Fifteen commits. The ones worth knowing about:

- `70dfc68` the gate itself — see §4B
- `6aedf4d` `waves_cleared()` counted only wipes, so any night the city merely *held* fired the
  signal and left the counter at zero — silently skipping [P22]'s morning line and [P06]'s hope
  impulse for every night that was not a clean sweep
- `978cecc` `first_night` finally lays a belt: 20 belts, 2 inserters, 2 crates, ore drill → smelter
- `5804747` `items_moved` was a one-tick delta wearing a counter's name; the gate band read the
  final row, so it asked "did an item move on tick 11000 exactly?"
- `c4ee784` thirteen buildings shared one silhouette; split into seven archetypes
- `955fe68` the idle-animation cull rejected all 441 structures, and the sprite suite was reading
  its own cache — certifying sprites baked *before* the change under judgement
- `49e6b7e` a settings-screen key label was 23 of the gate's 24 remaining engine errors

## 4. Known defects — corrected

### A. Hotkeys 2/3, and the selection panel — **FIXED**, but the old diagnosis was wrong twice

The handoff said "number keys 2 and 3 are claimed by both sim-speed and the build quickbar".
They are not. `LcnInputRouter` already settles the quickbar case. The real cause: [P19] chose its
bare-number hotkeys by probing `InputMap`, which is only populated once [P16]'s camera installs
the action map. With a display attached [P19] installs *first*, probed an empty map, concluded
1/2/3 were free, and consumed them with `set_input_as_handled()`. `LcnLayers.key_is_reserved()`
is now asked first, so the answer no longer depends on who booted first.

"Clicking a building does not populate the selection panel" was also wrong. Every link works
when called directly — provider → 1, `press`/`release` → `has_selection=true`,
`describe_building` → a full dict, `hud.select` → 1. [P22]'s event card sits over the middle of
the world and its body `RichTextLabel` (Godot defaults `RichTextLabel` to `MOUSE_FILTER_STOP`,
unlike `Label`) held the GUI hover at screen centre. The suite was blaming [P17] for [P22].

### B. "The suite exits 0 while printing TESTS FAILED" — **FALSE, and the truth was worse**

It printed **`TESTS PASSED`**. Measured on 4.7.1:

| invocation | verdict | exit |
|---|---|---|
| `--headless`, no `--force-ui` — **what `check.sh` ran** | `TESTS PASSED — 86 checks, 0 failures` | **0** |
| `--headless --force-ui` | `TESTS FAILED — 88 checks, 2 failures` | 2 |
| xvfb, a real display | `TESTS FAILED — 88 checks, 3 failures` | 3 |

The exit code was honest. The *verdict* was the lie, in the one configuration the gate used.

**Why the same build passes and fails:** every part that installs itself from
`game/content/**/*_bootstrap.tres` asks `LcnLayers.view_wanted()` while `Registry` is still
scanning — *before* `boot._ready`. With a display, or with `--force-ui`, [P19]/[P15]/[P20]/[P22]
come up first and boot adopts them. Without either they decline and boot installs them itself, in
a different order, with a different owner for the number row. Only the second order was gated,
and in it two of the three failures **cannot occur**. A display implies the *first* order — so the
gated configuration was the one no player ever gets.

Fixed by: the suite refuses to run without `--force-ui` or a display; checks it cannot ask are
counted `UNCHECKED` and force `TESTS PASSED, PARTIAL` + exit 126; `check.sh` reads a suite's own
`## REQUIRES:` line; `gate.yml` gates on the process exit code and requires a verdict.

### C. "C2's mandate is unfinished — engine stderr fails nothing" — **FALSE**

Engine stderr already failed the gate. `tools/check.sh` on `main` was **`CHECK RED`, exit 1**,
with `engine errors — 363 blocking`. The mechanism was complete; nobody had fixed the errors.

**336 of the 363 came from one line.** [P06] numbers its demands (`{"id": 1}`); [P17] built an
alert key with `String(1)`. Godot 4 has `String` constructors for `String`, `StringName` and
`NodePath` and nothing else, and the alert panel refreshes several times a second for as long as
a demand is open.

That hunt also found a real correctness bug: `HeatNetwork.clear_routing()` referenced
`topo.scratch`, gone since residual routes became a memoised ring. A GDScript runtime error
*aborts the function*, so `route_dirty = true` on the last line never ran — and its two callers
are `rebuild_networks()` and **save loading**.

The 740 leaked objects / 258 resources are still there, still `tracked` in
`tools/error_allowlist.txt`, still printed with a count in every gate report. They are reported
by the engine after the last artifact is written and cannot alter a metric, a replay or a
screenshot. Nobody has done the teardown work.

### D. The renderer invents a city — **FIXED**

The [P13] preview settlement is refused in any `--harness` run, guarded *inside*
`ensure_preview_settlement` so a later caller cannot reach it. A review caught a hole in the
first fix: with no grid at all, `attach()` has already built a preview and generated its
structures *and its crowd*, so the refusal now empties both, and `_step_agents` checks
`preview_allowed()` too. Verified: `world ready: 0 structures (real)`, with a real 76-building
city still rendering.

### E. Round-2 findings — all five re-verified by running

1. **Belts never placed** — was true, now **fixed**. Not a logistics bug: `tests/logistics/`
   lays belts and passes its bands. Two independent causes. (a) `tools/gen_scenarios.py`'s `DEFS`
   table had no entry for `belt_mk1`, `crate`, `inserter_mk1`, `splitter_mk1`, `underground_mk1`
   or `long_arm_mk1` — the generator had **no vocabulary for a belt**, so no scenario it emitted
   could contain one. (b) `metrics()["items_moved"]` published a counter `LogiWorld.step()`
   zeroes every tick. `first_night` now runs ore drill → smelter on 20 belts.
2. **Wave 2 never ending** — the stall is gone; what remained was `threat.waves_cleared`
   disagreeing with `Bus.wave_cleared` by one. Fixed in `6aedf4d`.
3. **HUD fabricating depletion warnings** — already fixed in code. `LcnHudTrend` grew projection
   gates (12 samples, 20 s span) so one purchase cannot become a countdown. Two tests still fed
   8 and 10 samples and asserted the *old* over-eager behaviour; corrected, plus a new test for
   the refusal.
4. **68 String formatting errors per visual run** — gone as a class. A visual run is now 0
   blocking engine errors.
5. **World overlay labels over the HUD** — symptom was already handled by `LcnLayers.enforce()`;
   [P19] still *set* 70 and was corrected every launch, which is a disagreement surviving rather
   than a bug fixed. [P19] now reads the table.

## 5. What is still red, and what it means

`gate (macOS)` reports 5 failing. **One is a defect. Four are noise.**

### The last red band — and it is probably the BAND that is wrong, not the build

```
FAIL  build.rejected_total  final_max 0   final 13
```

**Do not "fix" this by chasing thirteen bad placements. They are deliberate.** Run it and look:

```bash
tools/run_sim.sh --scenario=first_night --ticks=11000 --out=artifacts/r
grep -c "refused" artifacts/r/log.txt          # -> 0.  Nothing is logged as a refusal.
python3 -c "import json;print(json.load(open('artifacts/r/state.json'))['final']['systems']['build']['stats'])"
                                               # -> {'rejected': 13, ...}
```

Thirteen rejections, zero refusal log lines, because they do not come from the command path.
They come from `_op_place_line`: `tools/gen_scenarios.py`'s `Layout.line()` draws a run
**through** whatever already stands, and says so in its own comment —

> `# A line runs THROUGH whatever is already there; build refuses the occupied`
> `# cells and lays the rest, which is what a player sees too.`

— and `BuildSystem._reject()` (`game/sim/build/build_system.gd:1202`) counts every one of those
skipped cells. So the scenario deliberately overdraws its heat trunks, build correctly declines
the cells that are taken, and the band then calls that a failure. `final_max 0` and a helper
whose documented job is to overdraw cannot both be right.

This also corrects the previous handoff, which said `gen_scenarios.py`'s "refuses to emit a
placement that would be refused at runtime" claim must be false. It is not: the generator refuses
to emit *colliding `place` commands* — `Layout.place()` asserts on overlap. `line()` is a
different, intentional path.

**The judgement call, which is a contract change and therefore Maximilian's:** the band was
presumably written to catch scenario-authoring mistakes, and that intent is good — a placement
that can never work should not sit silently in the reference run. But the threshold cannot be 0
while `line()` exists. Options, cheapest first:
1. band `rejected_total` to a small ceiling (13 today) so a *new* authoring mistake still trips it;
2. have `line()` skip occupied cells at generation time instead of relying on the runtime to
   decline them — changes what the scenario exercises, since a player really does drag through;
3. count line-skips separately from genuine command rejections in `BuildSystem`, and band only
   the latter. Cleanest, most work, and the only one that keeps the original intent intact.

### The four that flap

`test_a_shift_change_does_not_spike_the_frame`, `perf gate` (`stress_1000`), `feel_perf`
(`_draw`) and `audio_live` move run to run **with no code change**. Same test, same macOS
runner, six readings:

```
9410 · 9913 · 10442 · 11427 · 12177 · 16215 µs      floor: 9000
```

That is a 72 % spread on nominally identical hardware, and it is wider than the gap to the floor.
The gate currently has a noise floor broader than the defects it is meant to find — which is this
project's disease in a third costume: a gate that is red for reasons unrelated to the code gets
ignored exactly like one that is never red.

**Two decisions belong to Maximilian and must not be made by an agent**, because both change a
shipped contract rather than fix a bug:

1. **The perf statistic.** `worst-of-240-ticks` versus p95 or median. The best observation
   (9410 µs) is only 4.5 % over the floor, which suggests the true cost sits near 9400 and a
   modest optimisation plus a less noise-sensitive statistic would land it. Optimising against
   the 16215 µs worst case would need nearly a 2× speedup.
2. **`stress_1000`'s floor.** Declares `min_ticks_per_second: 100`; the runner measures 78–82.
   Note this is the *first time the perf gate has ever executed on CI* — it never got past the
   standalone stage before the bash 3.2 fix in `9d03ce0` — so there is **no evidence of a
   regression**, only a floor that was never validated on this hardware.
   `tools/perf_budget.json` has a `floor_multiplier` knob documented for exactly this, but
   applying it globally would also relax `determinism` (900) and `first_night` (600), which pass.

Maximilian's standing answer so far is **optimise, do not lower the floors**. The known hotspot:
`CitizenRouter` already dedups, caches and caps `REQUESTS_PER_TICK = 1`, so the spike is almost
certainly **one** A* search at its full `MAX_NODES = 1600` ceiling rather than a storm of them —
and the router's own comment notes a *failed* search pays the full budget, with `failed 50` in
the run. If that holds, the fix matching the existing design is a node budget per **tick** rather
than per **search**: a resumable A*. **Measure before changing**, and keep
`tools/determinism.sh` byte-identical.

## 6. How to run everything

**A fresh cloud container has no Godot.** Install it first, or nothing below works:

```bash
curl -fsSL -o /tmp/g.zip \
  https://github.com/godotengine/godot/releases/download/4.7.1-stable/Godot_v4.7.1-stable_linux.x86_64.zip
mkdir -p ~/godot && unzip -q -o /tmp/g.zip -d ~/godot
mv ~/godot/Godot_v4.7.1-stable_linux.x86_64 ~/godot/godot && chmod +x ~/godot/godot
export GODOT=$HOME/godot/godot
$GODOT --headless --path . --import        # once, before anything else
```

```bash
# Play it
$GODOT --path .

# Deterministic headless run: sim only, fast, for balance/regression/perf
tools/run_sim.sh --scenario=first_night --ticks=12000 --out=artifacts/a

# Real frames from the real renderer — needs a display
xvfb-run -a -s "-screen 0 1920x1080x24" tools/run_visual.sh --scenario=smoke --out=artifacts/vis

# Reachability: can a human actually open each screen?  --force-ui is REQUIRED
xvfb-run -a -s "-screen 0 1920x1080x24" \
  $GODOT --path . tests/boot/run_reachability.tscn -- --force-ui

# The whole gate
xvfb-run -a -s "-screen 0 1920x1080x24" bash tools/check.sh
```

**Practical notes that cost this session real time:**

- `tools/check.sh` takes **25–45 minutes**. A foreground shell call is capped at 10 minutes —
  run it in the background and poll the log.
- **Perf numbers are worthless while anything else is running.** The same test read 9913 and
  14617 µs on this box purely as a function of what else was on it. Check
  `ps -eo cmd | grep -c "[g]odot --"` is 0 before you measure, and re-check after.
- Local rendering is software GL (llvmpipe). `_draw` budgets fail here and pass on CI. Do not
  chase them locally.
- `python3 tools/gen_scenarios.py` is pure Python, runs in milliseconds, and asserts on
  collisions — it is a fast iteration loop for scenario work. Never hand-edit
  `tests/scenarios/*.json`; it is generated.

## 7. The method — do not skip this

This project is built by many agents in parallel, and it only works because of three rules:

1. **Folder ownership is absolute.** An agent writes only in the folders it owns. Content
   registers by directory scan, never by editing a shared list.
2. **Determinism is non-negotiable.** No `randf()`, no wall clock, no frame delta anywhere in
   `game/sim/**`. Randomness only through `Rng.stream("name")`. Sort dictionary keys before any
   iteration that affects state.
3. **Critics judge the running build, never a summary.** Every review agent gets fresh context
   and is forbidden from reading builder reports or commit messages.

Rule 3 is not ceremony. In round 2 all twelve builders honestly reported success, `check.sh` said
GREEN, 768 tests passed — and the entire user interface was an orphan node no human could open.

**This run added a fourth rule, learned the hard way: the gate lies too.** Three separate
instances, all found by running rather than reading:

- the sprite suite read its own `art_cache`, certifying sprites baked **before** the change under
  judgement;
- `feel_gallery` compared an anchor list nobody had rebuilt;
- `check.sh` reported `1 of 67 checks failed` as `67 checks failed`.

A test that cannot fail is worth less than no test, because it also occupies the slot where a
real one would go. When a suite passes, ask what it would take to make it fail — and if you
cannot answer, you have not verified anything. The strongest verification in this run reverted
the production file in a scratch copy and proved the new test went red against the old code.

## 8. Cloud CI

`.github/workflows/gate.yml` runs on every push and PR:

- **gate (macOS)** — installs Godot, imports, runs `tools/check.sh`, counts engine-level error
  lines separately, runs a 12000-tick deterministic simulation, uploads `gate.log` + artifacts.
- **screenshots (Linux, xvfb)** — renders `first_night`, uploads the real PNG frames, and runs
  the full reachability suite against a real framebuffer. This job is where the display-dependent
  checks are hard-gated; `TESTS PASSED, PARTIAL` fails it.

Both jobs now print **what is red** at the end of the job — failing stages, test names, engine
errors and contract bands — because finding out which of 1000 log lines mattered was costing a
full log download per iteration.

Standard GitHub-hosted runners, macOS included, are free and unmetered for public repositories.
That is why this repo is public.

## 9. What to do next, in order

**Read §5 first. Nothing in the gate is now known to be a defect in the game.** One band is
mis-specified and four stages are noise. That is a different problem from "the build is broken",
and it wants a different kind of work.

1. **`build.rejected_total`** — decide which of the three options in §5 to take. The evidence is
   already gathered; what is missing is a decision, not an investigation.
2. **The perf work.** Maximilian's standing answer is *optimise, do not lower the floors*, and
   that is the instruction to follow. One question he has NOT yet answered hangs off it: whether
   `worst-of-240-ticks` is the right statistic at all, given the spread in §5 is wider than the
   gap to the floor. Optimising is worth doing either way — a single A* at its full ceiling is a
   real hitch a player feels — so **start there and do not wait**; raise the statistic question
   again only if a genuine speedup still leaves the gate flapping.
3. **The teardown work behind defect C** — 740 leaked objects, 258 resources, allowlist entries
   expiring 2026-10-01.
4. **The stage Phase C never reached**: integrator → playthrough agent → round-3 critic → blind
   side-by-side comparison against Factorio and Frostpunk. **Not started — Maximilian asked to be
   consulted before this launches.**
5. Still entirely unbuilt: **[P21] tutorial** and **[P24] meta** (save/load UI, settings screen,
   accessibility, Steam integration, achievements, controller). Neither has been started.

Smaller things worth a look, all measured and none blocking:

- A dilemma card covers the hearth at launch until dismissed, and overlaps [P17]'s selection
  panel. Deliberate placement by [P22], but a critic will see it in the first screenshot.
- The build-menu hotkey rail collides with the STORES panel at 1920×1080.

## 10. Standing instruction from Maximilian

> Stop after Phase C. Do not launch a further wave without asking him first. Report the result
> and wait.

Phase C's gate work is finished. §9.4 is the next wave and **has not been started**.
