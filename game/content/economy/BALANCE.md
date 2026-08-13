# Balance — the intended experience, and the measurements that prove it

**[P12] Economy & Balance.** This is the design document for every number that
decides whether the city lives. It is written to be argued with: each claim is
followed by the run that produced it, and every run is reproducible from this
repository in one command.

    python3 tools/gen_scenarios.py
    tools/run_sim.sh --scenario=economy_60min --out=artifacts/balance
    tools/analyze_balance.py artifacts/balance --strict

---

## 0. Where the numbers live

| What | Where | Owner |
|---|---|---|
| Material prices, starting stock, deposit yields, population, research and defence envelopes, audit bands | `game/content/economy/balance_table.tres` → `game/sim/economy/balance_table.gd` | [P12] |
| The intended experience, day by day, as measurable bands | `game/content/economy/difficulty_curve.tres` → `game/sim/economy/difficulty_curve.gd` | [P12] |
| Building costs, heat figures, footprints | `game/content/buildings/*.tres` | [P11] + content |
| Day length, temperature, the Great Frost calendar | `game/content/biomes/*.tres` | [P09] |
| Wave budgets, set pieces, adaptation | `ThreatProfile` | [P08] |
| The heat solver itself | `game/sim/heat/` | [P02] |

**[P12] does not copy any of the other four.** Copies rot. What it holds instead
is the *fence* around them — bands a definition has to sit inside — plus the
cross-system questions nobody else can answer alone: can a city that followed
the intended build order afford night twelve, and is the tech tree priced in
materials this economy has heard of. `Balance.audit()`, `Balance.audit_research()`
and `Balance.audit_threat()` measure exactly that, and `tests/economy/` fails the
build on any of them.

`Balance.threat_budget()` **delegates** to [P08]'s live director when it is
present. One source of truth at runtime; the table is the documented fallback.

---

## 1. The common currency: material points

Everything in the game is bought with a bag of items. To compare a wall against
a smelter you need one axis. `material_value` is it — abstract labour points per
unit, raw ground materials at ~1, a smelted plate at what it cost to smelt, a
fabricated part carrying its whole chain.

| item | points | | item | points |
|---|---|---|---|---|
| stone, timber, grain | 1.0 | | copper_coil | 7.0 |
| scrap | 1.2 | | gear | 8.0 |
| coal | 1.5 | | pipe_segment | 9.0 |
| insulation_wool, ration | 3.0 | | steel_plate | 10.0 |
| iron_plate | 4.0 | | ammo_shell | 12.0 |
| insulation | 6.0 | | circuit | 20.0 |

Measured against the shipped content, that gives:

| building | points | per cell | per heat/s |
|---|---|---|---|
| heat_pipe | 8 | 8.0 | 7.5 carried per point |
| wall | 6 | 6.0 | — |
| warmth_radiator | 100 | 25.0 | 8.3 drawn |
| coal_generator | 134 | 22.3 | **4.5 produced** |
| housing_block | 176 | 11.0 | 19.6 drawn, 0.75 heat/resident |
| heat_accumulator | 204 | 51.0 | 4.4 stored per point |
| workshop | 248 | 20.7 | 24.8 drawn |
| geothermal_tap | 330 | 36.7 | **6.0 produced**, no fuel |
| recuperator | 340 | 85.0 | 22.7 recovered |
| the_hearth | 780 | 31.2 | **6.5 produced** |

Read the three bold rows together and the energy economy is legible in one line:
**coal is the cheap answer and geothermal is the free-forever one**, at a 33%
premium up front. That is the intended shape and the audit band
(`producer_points_per_heat = 2.5 .. 11.0`) is the fence around it.

### The audit has teeth, and here is the proof

An audit nobody has watched fail checks nothing. `tests/economy/test_building_audit.gd`
feeds the audit six deliberately broken definitions and requires each to be
caught: a 5×5 that costs two stone, a building that costs nothing, a tier-1
generator with a misplaced decimal point (300 heat/s), a cost priced in an
invented item, housing that shelters forty people on nine heat a second, and a
one-plate pipe carrying five thousand. It also asserts the *control*: the
shipped coal generator produces **no** findings.

The audit is scoped by what a building is **for**, not by which fields are
non-zero. A smelter vents 4 heat/s while drawing 14 and is judged as a consumer,
not as a power plant. An accumulator conducts 40 and stores 900 and is judged on
its storage. A watchtower draws 1.0 and is not a heat customer in any meaningful
sense, so cost-per-heat is not applied to it. Turrets are deliberately **not**
audited on heat: a turret's cost buys damage, and that band belongs to [P07] once
weapons exist. A fence painted on the ground is worse than no fence.

---

## 2. The intended experience, day by day

The dark half of a day (dusk → night → deep night) is when the game is played,
so that is what is measured. Four numbers per night:

* **margin** — mean heat supply ÷ demand
* **trough** — the single worst sample of the night; this is what decides
  whether a night is *frightening*, where the margin only decides whether it is
  *survivable*
* **frozen** — worst share of the heat grid frozen at once
* **buffer floor** — lowest stored heat against the most the grid ever banked:
  "how much of your savings did the night take"

| day | label | intent | margin | trough | frozen ≤ |
|---|---|---|---|---|---|
| 1 | First Night | Survivable by an attentive beginner. The night bites, the buffer covers it, nobody dies. | 0.88–1.45 | 0.62–1.10 | 4% |
| 2 | The Squeeze | The first real squeeze. Industry browns out before the homes do, and the player feels the shed order. | 0.80–1.30 | 0.52–1.02 | 7% |
| 3 | **First Frost** | On the calendar from minute one, and it should still nearly take the city. | 0.62–1.05 | 0.30–0.86 | 16% |
| 4 | Colder Ground | The morning after. Colder baseline, a grid that has to be rebuilt wider before dusk. | 0.72–1.25 | 0.42–1.00 | 14% |
| 5 | Consolidation | The player who banked storage on day 4 has a quiet night; the one who did not, does not. | 0.74–1.30 | 0.46–1.05 | 13% |
| 6 | Outgrown | Demand outgrows a hearth-only city for good. | 0.68–1.20 | 0.40–0.98 | 16% |
| 7 | **Second Frost** | A city with no thermal storage and no second generator ring does not see day 8. | 0.52–1.00 | 0.22–0.80 | 26% |

Days 3 and 7 are storm nights because [P09]'s fixed calendar puts Great Frosts
there (`frost_day = [3, 7, 12, 18, 25, 33]`).
`tests/economy/test_difficulty_curve.gd` cross-checks the curve against that
calendar, so the two cannot drift apart and leave bands describing nights that
never happen.

The curve deliberately stops at day 7. Past the last designed day
`targets_for()` returns nothing rather than an extrapolation nobody wrote down.

---

## 3. Measured: does the build produce that experience?

`economy_60min` is the instrument — seven and a half campaign days of a city
that grows by one district every morning, all on one heat network. The run below
is `artifacts/p12_econ7`, seed 11, 72 000 ticks, 360 samples.

    tools/analyze_balance.py artifacts/p12_econ7 --strict

```
THE CURVE  — measured over dusk/night/deep-night of each day
  day  label            margin   trough   frozen  buf-floor  storm   coldest  verdict
    1  First Night      0.942    0.679     0.0%     0.431   0.00    -31.8  pass
    2  The Squeeze      0.967    0.887     0.0%     0.329   0.00    -28.4  pass
    3  First Frost      0.849    0.732     0.0%     0.424   0.50    -38.1  pass
    4  Colder Ground    0.844    0.834     0.6%     0.357   0.00    -32.7  pass
    5  Consolidation    0.921    0.814     1.2%     0.469   0.00    -37.5  pass
    6  Outgrown         0.912    0.782     3.0%     0.136   0.00    -40.0  pass
    7  Second Frost     0.538    0.363    11.1%     0.000   0.66    -54.0  pass

THE GRID  — at the final tick
  1 network(s); 100.0% of every heat entity is in the largest one

VERDICT
  ✓ every graded day inside its designed band
```

Reading it as a player experience:

* **Day 1** ends the night at 0.68 of demand at its worst and burns 57% of what
  the grid had banked, with nothing frozen. That is precisely "the night bites,
  the buffer covers it, nobody dies" — and a player who skipped the one
  generator the plan builds on day 1 does not have that 0.43 of buffer left.
* **Day 3, the First Frost**, drops ambient to −38.1 °C at 0.50 storm intensity
  and takes the night to 0.73. The city holds, and it holds *because* the
  accumulator went up that morning.
* **Days 4 to 6** run the long squeeze: margins 0.84, 0.92, 0.91 with troughs in
  the 0.78–0.83 band and the buffer floor falling from 0.36 to 0.14 as the plain
  cools from −32.7 °C to −40.0 °C. Nothing dramatic happens on any of them and
  that is the point — this is the stretch where a player spends on homes and
  tells themselves the margin is fine.
* **Day 7, the Second Frost**, is the near-death: −54.0 °C, trough 0.36, 11% of
  the grid frozen at once, and the buffer floor at **0.000** — every joule the
  city ever banked, gone. Anything less than the three generators built that
  morning loses the outer rungs.

The whole run stays on **one** heat network, 100% of heat entities in it, and
logs **zero** errors at 419 ticks/second.

### Where the tuning actually went

Three iterations, each one a run:

| run | change | day 1 margin/trough | day 6 | day 7 |
|---|---|---|---|---|
| `p12_econ1` | two generators a day from day 1 | 1.214 / 0.996 | 0.63 | 0.39 |
| `p12_econ6` | back-loaded to 1,1,2,2,2,2,2 | 0.942 / 0.679 | 1.04 / 0.93 | 0.55 / 0.32 |
| `p12_econ7` | days 4–5 spend on homes, day 6 corrects with three burners | 0.942 / 0.679 | 0.91 / 0.78 | 0.54 / 0.36 |

The first version was a play-through of a *good* player, not of the design
target. Back-loading the generator schedule to **1, 1, 2, 1, 1, 3, 3** models the
person the design is written for: they get one burner up before the first dusk,
are frightened by it, and buy the second the next morning. That single change
moved day 1 from 1.214/0.996 to 0.942/0.679.

The second pass fixed days 4 and 5, which were reading `soft` at troughs of 1.16
and 1.14 — nights that never dipped. Moving one generator out of each and into
day 6 turned them into the long, unglamorous squeeze the design asks for, and it
is what makes the Second Frost land three days later.

Nothing was fixed by editing a band.

---

### The reference run, with the guns live

`first_night` is the other measured run (`artifacts/p12_fn2`, seed 7, 11 000
ticks) and it keeps everything `economy_60min` pins: real waves, real hauling,
real fuel. Its day 1 grades **soft**:

```
  day  label            margin   trough   frozen  buf-floor  storm   coldest
    1  First Night      1.034    0.793     3.6%     0.041   0.00    -28.6
      buffer  ~  0.041 is outside 0.050..1.000 (soft)

  dawn        margin 1.145   in deficit  50.5% of samples
  afternoon   margin 1.179   in deficit   0.0% of samples
  night       margin 1.088   in deficit  26.0% of samples
  deep_night  margin 0.858   in deficit 100.0% of samples   300 brownouts
```

That phase table is the shape the whole game is built around and it is worth
reading on its own: **the afternoon is free, and every single sample of deep
night is in deficit.** The player spends the light half building the thing that
will not quite carry them through the dark half.

Day 1 misses its buffer floor by 0.009 — the city ends the night with 4% of what
it banked rather than 5%. That is a genuine near-miss reported as one, not a
failure, and it is on the right side: the reference run should end the first
night with almost nothing left.

---

## 4. The law nobody had written down

**A heat producer must stand inside a radiator's field or the Hearth's, or it
freezes on the third night and never thaws.**

This came out of a run, not out of a spreadsheet. Working from [P02]'s thermal
model:

    a coal generator holds itself at  outside + 1.6 × (30 × 0.15) × (1 + 0.35 × 1.5)
                                    = outside + 11.0 °C
    it freezes at −10 °C
    ⇒ it needs ground warmer than about −21 °C
    its own radiance is worth ~10.5 °C
    ⇒ it dies once the plain passes about −32 °C — which is day three

`artifacts/p12_econ3` is the run that made it visible: **thirteen of fourteen
coal generators frozen at the final tick**, all of them fuelled, all of them
connected, supply pinned at the Hearth's 120 while demand reached 600. The
scenario was placing generators in their own row, four tiles from the nearest
radiator.

The consequences, all landed:

* districts in `economy_60min` are now **radiator-first**, generators flush
  against it, so the second generator's centre sits 5.5 tiles from the
  radiator's — inside its 6.5 radius;
* `tests/economy/test_scenario_wiring.gd::test_every_producer_stands_where_it_can_survive_the_night`
  refuses any balance scenario that breaks the law;
* it is the single most important thing to teach in [P21]'s tutorial and to show
  in [P19]'s overlays, because a player cannot see it and will lose a base to it.

---

## 5. The other law: two machines side by side are not connected

`HeatGraph` links two buildings when their footprints touch orthogonally **and
at least one of them conducts**. A generator that touches only a housing block
is a private one-node network: it produces into nothing, freezes, and the run
still exits 0.

That is what the previous `economy_60min` was doing — **sixteen** generators on
sixteen private islands, heat supply reading 120.00 (the Hearth, alone) for an
hour of simulated time, with a green exit code. `stress_1000` had a milder
version of the same thing: two isolated generators and three pipe stubs.

Three separate things now make that impossible to ship again:

1. `tools/gen_scenarios.py` rebuilds the component graph over every layout it
   emits and **refuses to write** a scenario whose heat entities are not one
   grid (`Layout.audit_heat`);
2. `tests/economy/test_scenario_wiring.gd` re-derives the same graph from the
   shipped JSON, against the live registry, at gate time;
3. `tools/analyze_balance.py` checks the *runtime* network count against
   `expects.max_heat_networks`, which is the half the static checks cannot see —
   the map is generated at runtime and terrain can refuse a pipe. That check is
   what caught the last surviving orphan in this part: a single pipe at
   (145, 144), stranded because the rung crossed rock.

---

## 6. What this instrument deliberately holds still

An instrument measures one variable. `economy_60min` measures the **heat**
economy, so two confounders are pinned, each with an op the owning system
provides for exactly this purpose:

* **`threat: peace`.** [P08]'s director is live and it works. Without peace the
  city loses 143 structures by day 8 (`artifacts/p12_econ2`) and the "heat
  margin" is really a graph of how fast a wave director eats a base with no
  turrets on it. Combat balance is measured in `first_night`, which keeps its
  walls and its guns.
* **`heat: fuel_all coal`, every 60 s.** [P03] hauls coal to burners using
  citizens. An unfuelled Hearth is a reading of the hauling chain, not of the
  grid.

Both are stated in the scenario file and both are visible in the report's
command list. Neither is a fudge factor on the physics.

---

## 7. Open findings — measured, not fixed

These are real and they are *not* mine to fix. They are recorded here because a
balance owner who finds them and says nothing is worse than one who never looked.

1. **The food chain does not feed the city.** In every run of `economy_60min`,
   `citizens.food_days` reaches 0.00 during day 3 and the whole population dies
   on day 4 — with 6 000 grain and 6 000 ration added to the city stock at the
   start of *every* day and `build.materials` visibly rising to confirm the
   items landed. Either the stock those items land in is not the stock
   `CitizenSystem` reads (`CitizenDefs.FOOD_ITEMS = [ration, grain]`), or the
   larder is not being served from it. **This is the highest-value seam in the
   build right now**: it makes every long run a graph of a graveyard after day
   four. Owners: [P05] citizens, [P03] logistics.
2. **The freeze spiral has no floor.** A frozen generator produces nothing, and
   producing nothing is what keeps it frozen — `_thermal()` warms a node from
   `delivered + output × 0.15`, and a producer delivers to itself only while it
   runs. Once the ambient passes the point where its own radiance cannot hold
   it, the only way back is external warmth. That is a *good* mechanic and it is
   the sharpest thing in the heat model, but nothing in the game currently tells
   the player it exists. Owners: [P19] overlays, [P21] tutorial.
3. **`stress_1000` has no hostiles.** The description used to claim "a thousand
   hostiles" and produced zero. It no longer claims them. The scenario contract
   in `tests/p00/test_scenarios.gd` forbids addressing a system this build does
   not have, and when the scenario was regenerated [P07]/[P08] had only just
   landed. The combat half of the stress test is owed, not forgotten, and the
   description says so.
4. **The turrets in `first_night` are ornaments, and it costs the Hearth.**
   The log says it plainly:
   `mount 'turret_mount' asks for weapon 'burner_cannon', which does not exist`.
   With nothing firing, a drift_hound walks the perimeter and at tick 10 531
   `The Hearth #1 destroyed by drift_hound`. Because the Hearth's 5×5 footprint
   is what joins the four pipe arms, losing it splits the city into four
   networks and drops the largest component to 41% of the grid. The scenario's
   grid claim now covers day 1 only, and says why. Owner: [P07] weapons content.
5. **`stress_1000` is at 36 ticks/second against a floor of 35.** It measured 45
   before [P05]/[P03]/[P04]/[P07]/[P08] landed. The floor is not mine to move
   and the workload is real (1 483 heat entities, 98.9% of them in one
   component, which is the expensive case on purpose), but the perf gate has
   roughly one tick/second of headroom left.

---

## 8. How to do balance work here

1. Change a number in `game/content/economy/balance_table.tres`, or a build
   order in `tools/gen_scenarios.py`.
2. `python3 tools/gen_scenarios.py` — it refuses to emit a layout whose heat
   grid is in pieces.
3. `tools/run_sim.sh --scenario=economy_60min --out=artifacts/<name>`
4. `tools/analyze_balance.py artifacts/<name> --strict`
5. If a band moved, say **in this file** why the design changed — not just that
   the number did. A band edited to match a run is not balance, it is
   bookkeeping.

`tools/analyze_balance.py a b --diff` prints two runs side by side, which is the
fastest way to see what one change actually did.
