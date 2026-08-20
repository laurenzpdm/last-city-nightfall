# Open seams

Cross-part defects that no single part owns, with the measurement that found each one.

A seam goes here when it is real, reproduced, and outside every live builder's folders — so it
would otherwise fall between them. Delete an entry when it is fixed, and say in the commit which
one. **Every entry names the artifact or the CI job it came out of. Nothing here is quoted from a
builder report.**

Maintained by the orchestrator. Last updated 2026-08-20, during Wave J.

---

## 1. `test_every_crew_leans_to_its_own_hours_and_none_is_dark` — precondition no longer met

`tests/citizens/test_citizen_shifts.gd:441`. CI job 96473329828, commit `19bda2d`.

    assert_gt — precondition: at least one crew of two or more has NO surplus to
    split (found 0) — an overstaffed city covers both rotations under the old rule
    too, so without one of these the last assertion measures nothing
      expected: > 0
      actual:   0

**This is a good change breaking a good test, and both halves of that matter.**

The test counts `tight` — crews where `crew <= need`, i.e. with no surplus to split — because
only those tell the new shift rule apart from the old one. An overstaffed city covers both
rotations under either rule, so a fixture full of deep crews would go green against the very
roster this suite exists to forbid. The author made it a hard assert rather than a skip
specifically so it could not vanish quietly. That was right.

What changed underneath it: `19bda2d` raised `workshop` `build_priority` 55 → 66, so the shop
now hires before the scrap collector that fills its input bin and gets all four of the hands it
needs. Every crew in the reference city now has surplus. `tight` is 0 — not because the rule
broke, but because the fixture can no longer pose the question.

Do **not** fix this by lowering the assert or turning it into a skip. The fixture needs a crew
that is deliberately at exactly its requirement, so the question stays askable no matter how
well the city is staffed. Nobody in Wave J owns `tests/citizens/`.

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

## 3. `test_a_thousand_citizens_fit_in_the_tick_budget` — FLAPPING, and I called it noise too early

Three reads on `tests/citizens/test_citizen_perf.gd`, on three commits, none of which touched
`game/sim/citizens/`:

    19bda2d  job 96473329828   RED    worst 10294 us  (budget 9000)
    d68cf6e  job 96476182933   GREEN
    19be075  job 96490302405   RED    worst 10727 us, AND mean 2020 us (budget 2000)

I filed this on one read, then withdrew it as noise on two. Both calls were premature in the
same direction — I treated the second reading as settling a question that needed a third. Two of
three red is the FLAPPING signature the gate itself uses, and the third read added a *second*
failing assert (the mean, 1% over its budget), which pure runner noise does not usually do.

So: real enough to keep, not established enough to act on. What would settle it is three reads on
one commit rather than one read on three, which is what the gate's own FLAPPING detection does
for standalone suites and does not do for tests inside `run_tests.gd`. Nobody owns
`tests/citizens/`.

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
