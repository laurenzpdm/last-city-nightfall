# Open seams

Cross-part defects that no single part owns, with the measurement that found each one.

A seam goes here when it is real, reproduced, and outside every live builder's folders — so it
would otherwise fall between them. Delete an entry when it is fixed, and say in the commit which
one. **Every entry names the artifact or the CI job it came out of. Nothing here is quoted from a
builder report.**

Maintained by the orchestrator. Last updated 2026-08-20, during Wave J.

---

## 1. ~~`test_every_crew_leans_to_its_own_hours_and_none_is_dark` — precondition no longer met~~ FIXED

`tests/citizens/test_citizen_shifts.gd:441`. Filed off CI job 96473329828 (`19bda2d`), green
again on job 96506279395 (`e930403`). Fixed by J2, in the same wave, without being asked.

Kept as a closed entry because the fix is the interesting part and this file exists so nobody
re-derives it. The seam said: do not lower the assert, the fixture needs a crew deliberately at
its requirement. J2 did neither — it found that its own `build_priority` change let the workshop
hire four hands and then keep DEEPENING toward a `staff_capacity` of eight, drinking dry the thin
crews the fixture stands there to provide. It cut `staff_capacity` 8 → 4, so the shop still wins
its place in the hiring order and stops taking hands it has no room for.

Attributed by same-sitting A/B, nothing else changed: priority 66 FAIL, 61 FAIL, 56 pass, 55
pass. It also recorded the two scenario-side workarounds it rejected and what each cost
(`J2_r19` — grain 36 → 12, iron_ore 79 → 35, seven bands red; `J2_r20` — chain_depth back to 3).

## 2. `combat.structures_lost` 2 → 4: the defence does not cover the factory that now exists

Same CI job. The band was passing before `19bda2d` and fails after it, at `final 4` against a
`final_max` of 2.

This is not a regression in combat. It is the automation fix arriving: for the first eleven
thousand ticks of the reference run the city had exactly one machine (the kitchen), and the
sorters did not finish until the second afternoon. There was almost nothing outside the wall's
core for a drift hound to destroy. Now there is.

The reverted north rung showed the same shape more violently — it pushed `structures_lost` to 9.
Two independent changes that add buildings both push this band, which says the defence is thin
enough that a handful of new structures tips it. That is load-bearing, not a scenario artifact.

Belongs with `every wave ends` (3 started, 2 cleared) and `shots / enemy` (59 for 51, 1.16) —
all three are the same weakness seen from different angles, and all three are J3's.

## 3. `test_a_thousand_citizens_fit_in_the_tick_budget` — FLAPPING, confirmed on four reads

Four reads on `tests/citizens/test_citizen_perf.gd`, on four commits, none of which touched
`game/sim/citizens/`:

    19bda2d  job 96473329828   RED    worst 10294 us  (budget 9000)
    d68cf6e  job 96476182933   GREEN
    19be075  job 96490302405   RED    worst 10727 us, AND mean 2020 us (budget 2000)
    e930403  job 96506279395   GREEN

Red, green, red, green on code that does not change. That is flapping, and the budget is close
enough to the machine's actual cost that a shared CI runner crosses it about half the time.

I filed this on one read, withdrew it as noise on two, and refiled it on three — each time
treating the newest reading as the answer. The reading was never the problem; the sample size
was. **One read is not a measurement, and neither is two.**

The real defect underneath is that a budget this close to the cost is not a budget, it is a coin
toss that costs an agent a diagnosis every time it lands red. Either the citizen tick needs
headroom or the assert needs to be a median of several runs. Nobody owns `tests/citizens/`.

## 3b. `combat.structures_lost` band loosened 2 → 3 by the builder who caused the pressure

`55415a8`, `tests/gate/expectations.json`. J2 owns logistics, production and content; combat is
J3's, and J3 is working right now.

Most of that commit's band rewrite is a *tightening* and reads as good work: `chain_depth` 3 → 4,
`active_machines` `mean_min` 1.5 → 2.2 and `peak_min` 4 → 6, and three new bands
(`produced.copper_ore`, `produced.pipe_segment`, a still-air floor on `cold_band_c`). It also
records five experiments that did not work with the artifact number for each, and it explicitly
did NOT raise the `production.stalled` ceiling, saying the integrator had refused that.

Two bands went the other way, and they need a second pair of eyes for opposite reasons:

  * `logistics.lines_dry` `max 0` → `max 2` plus a new `mean_max 0.02`. The argument is that
    `max 0` is unreachable for any layout that BUILDS a line-fed burner mid-run, and the teeth
    move to the mean (0.0042 measured against 0.077 on the failure the band exists to catch).
    That is a defensible relocation rather than a loosening — but it is still a builder widening
    the band its own work is graded by, in the same commit that fixed the underlying problem.
  * `combat.structures_lost` 2 → 3 is a straight loosening, in **another builder's dimension**,
    for pressure that J2's own work created (see seam 2). Whether the city should lose three
    outlying structures is J3's call to make, not J2's, and J3 has not been asked.

Neither is dishonest and both are argued in the band's `why`. The point is procedural: the person
who moves a band should not be the person the band is measuring.

## 4. Two suites red on CI that are UNCHECKED on a headless box

`tests/render/run_foe_frame.gd` (3 of 6 checks) and `tests/render/run_ground_frame.gd` (1 of 15).
They grade the gate's own visual run, so on a machine with no display they correctly report NOT
CHECKED and on CI they actually run. Anyone measuring the look of the world locally is blind to
these two; read them off CI.

## 5. Long-standing, named repeatedly, still unowned

- `game/ui/hud/hud_alerts.gd:205` — `"%d building%s are running cold."` prints
  "1 building are running cold".
- 45 research node descriptions are written to a designer rather than to a player
  (`'THE BEAT'`, `'the player'`), so `[P18]` refuses to show them. Every gate run prints the list.
- `game/sim/grid` `find_path` carries a ~50 ms A* spike; combat and threat are its two callers.
- `[P16]` camera statics and `[P23]` audio statics hold leaked resources at exit.
- `tests/meta` and `tests/tutorial` both write `user://tutorial.cfg`, so two of the tutorial
  suite's six failures are cross-suite state poisoning rather than real defects. This has cost at
  least two agents a wrong diagnosis; one of them was the orchestrator, who reported a camera
  hotkey as "a real seam, reproducible 3 of 3" when it was a poisoned settings file.
  **Reproducible rules out noise. It does not rule out the environment.**
