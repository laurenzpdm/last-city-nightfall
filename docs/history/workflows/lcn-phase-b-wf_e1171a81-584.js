export const meta = {
  name: 'lcn-phase-b',
  description: 'Phase B: the seven missing sim systems + the legibility layer that makes the sim visible',
  phases: [
    { title: 'Build', detail: '12 part-owners: logistics, production, citizens, society, combat, threat, research, economy, overlays, HUD, build menu, render fixes' },
    { title: 'Integrate', detail: 'wire 11 systems together, make the gate green' },
    { title: 'Perf', detail: 'the tick budget is already 43% gone with 4 systems; now there are 11' },
    { title: 'Judge', detail: 'fresh critic + blind side-by-side against Factorio and Frostpunk' },
  ],
}

const ROOT = '/Users/maximilianthuemmler/Documents/last-city-nightfall'
const GODOT = '/Applications/Godot.app/Contents/MacOS/Godot'

const PRE = `You are building **Last City: Nightfall**, a Tower Defense x City Builder x Automation game
for STEAM in **Godot 4.7.1**, GDScript, 2D top-down. The bar is literally Factorio and Frostpunk.

REPO: ${ROOT}   GODOT: ${GODOT}

STEP 1 MANDATORY: read ${ROOT}/docs/ARCHITECTURE.md (it is law), then ${ROOT}/game/core/*.gd for the
contracts you code against (SimSystem, Sim, SimClock, Bus, Rng, Registry, Log, Harness), then skim
an existing high-quality part for house style: game/sim/heat/heat_flow.gd and game/sim/climate/.

WHAT ALREADY EXISTS AND WORKS (verified by an independent critic, not claimed by a builder):
- game/sim/grid — 256x256 chunked map, deposits, Dial's-algorithm flow-field pathfinding
- game/sim/climate — day/night arc, per-cell temperature, scheduled Great Frosts, era escalation
- game/sim/heat — a real max-min-fair flow solver with per-tile throughput limits, distance loss,
  repeaters, priority load shedding and PER-CONSUMER BOTTLENECK ATTRIBUTION. Rated deeper than
  Frostpunk's radius model. Read it before you design anything that touches heat.
- game/sim/build — placement, construction queue, blueprints (capture/rotate/mirror/book), undo
- game/view/render, game/view/camera — real rendering and camera
- tests/ — own framework, 100 tests / 4904 asserts, determinism replay verified byte-identical

ROUND 1 CRITIC SCORED THE BUILD 3.8/10. His exact biggest gap, which frames this whole phase:
  "Legibility, at a 2. The sim computes, per network, a bottlenecks array of {cell, kind, reason,
   load, capacity, consumers}, plus per-node dist/eta/served/bottleneck_kind, and ships all of it
   in state.json. Exactly none of it reaches a pixel. The most sophisticated thing in the codebase
   is invisible."

HARD RULES
- Write ONLY in the folders you own + your own tests/<part>/ + your own game/content/<category>/.
  Never touch another part's folder, game/core/, or project.godot. 11 other agents are working
  in this repo right now.
- Static typing on EVERY declaration and signature.
- game/sim/** is deterministic: no randf(), no Time.get_ticks_msec(), no frame delta, no input,
  no reaching into view/ or ui/. Randomness ONLY via Rng.stream("name"). Time ONLY via the tick int
  and SimClock.DT. ALWAYS .sort() dictionary keys before any iteration that affects state.
- Log.info/warn/error, never print().
- **PERFORMANCE IS A HARD CONSTRAINT.** The tick budget is 50 ms and four systems already eat 43%
  of it. You are adding the fifth through eleventh. Profile your own step(), keep it under 2 ms at
  realistic scale, and say what it actually measures. Cache, dirty-flag, and avoid per-tick
  allocation. A system that is elegant and slow will be cut.
- Other systems may be absent while parallel work lands: always Sim.get_system(&"x") defensively
  and degrade gracefully.

VERIFY YOUR OWN WORK. A claim is worth nothing, a run is worth everything:
  cd ${ROOT} && ${GODOT} --headless --path . -- --harness --scenario=first_night --ticks=6000 --out=artifacts/\${PART}
Read the log and state.json. ZERO errors you caused. Then run \`bash tools/check.sh\` and leave it GREEN.

WHEN DONE append one JSON line to ${ROOT}/progress/events.jsonl (append with >>, never overwrite).

Write real, deep, shippable systems. No stubs, no TODO placeholders, no "in a full implementation".`

const SCHEMA = {
  type: 'object',
  properties: {
    part: { type: 'string' },
    what_works: { type: 'string' },
    verified_by: { type: 'string', description: 'The exact command run and what its output showed' },
    perf_ms_per_tick: { type: 'string' },
    contracts_exposed: { type: 'array', items: { type: 'string' } },
    known_gaps: { type: 'array', items: { type: 'string' } },
  },
  required: ['part', 'what_works', 'verified_by', 'known_gaps'],
}

const PARTS = [
  { key: 'P19', label: 'P19 legibility overlays', prompt: `${PRE}

YOUR PART: **[P19] READABILITY OVERLAYS** — you own \`game/ui/overlays/\`, \`tests/overlays/\`.
**YOU ARE THE HIGHEST-PRIORITY AGENT IN THIS ENTIRE PHASE.** The critic's single biggest gap is
yours to close. Factorio is beloved because you can SEE the state of your factory. Right now this
game computes brilliant heat analysis and shows the player a number.

Read game/sim/heat/heat_flow.gd and heat_system.gd FIRST and find every piece of analysis already
computed: network_stats(), bottleneck_of(), per-node dist/eta/served/bottleneck_kind, brownouts,
starved counts, buffer levels. All of it exists. Your job is to make it visible and beautiful.

Build a proper overlay/lens system, toggled by number keys and by a holdable ALT key:
1. **Heat network lens** — every network gets a distinct hue; pipes tint by their network; flow
   direction animates along pipes; line thickness or intensity reads throughput. A player must see
   at a glance that these two halves of their base are NOT connected.
2. **Bottleneck lens** — the choking tile pulses; starved consumers are ringed; a leader line
   connects a dying building to the exact cell that is strangling it. This is the money feature:
   the sim already knows the answer, so show it.
3. **Warmth/thermal lens** — a smooth heat gradient over terrain (blue to orange), the survival
   isotherm drawn as a contour so the player sees exactly where their city can live.
4. **Freeze/health lens** — frozen and freezing buildings, time-to-freeze, damage.
5. **Logistics lens** (coordinate with [P03], degrade gracefully if absent) — belt saturation and
   starved/backed-up machines, Factorio-style.
6. **Coverage lens** — turret range, worker walking distance, unpowered structures.
Plus an **always-on legibility layer** that does not need a key: subtle state icons on buildings
(no heat, no worker, no input, output full, frozen), pulsing only when something is wrong so the
base is calm when healthy and screams when it is not.

Non-negotiables: overlays render legibly at every zoom level; they never obscure the thing being
diagnosed; they respect Settings.accessibility (colorblind_mode, high_contrast_overlays,
reduce_motion) with genuinely distinguishable palettes, not just hue shifts; and they read the sim
without ever mutating it. Rendering must be cheap: batch into few draw calls, do not spawn a node
per tile.

VERIFY VISUALLY — mandatory. Add shots to a scenario and run:
  timeout 200 ${GODOT} --path . --resolution 1920x1080 -- --harness --visual --scenario=first_night --out=artifacts/P19
then READ the PNGs with your Read tool and judge them honestly. Iterate until a stranger could
diagnose a heat problem from the image alone.` },

  { key: 'P03', label: 'P03 logistics/belts', prompt: `${PRE}

YOUR PART: **[P03] Logistics** — you own \`game/sim/logistics/\`, \`game/content/logistics/\`,
\`tests/logistics/\`. This is the Factorio half of the game's soul.

- \`LogisticsSystem extends SimSystem\` (order 30, system_name &"logistics") at
  game/sim/logistics/logistics_system.gd.
- **Belts** that are fast and correct: items on a belt must be a compact lane representation
  (position-along-lane, not a node per item) so 10,000 items cost nothing. Two lanes per belt,
  proper compression when backed up, correct merging at junctions, and belt tiers with different
  throughput. Model this on Factorio's transport-line design and be honest about throughput math.
- **Undergroundthings**: underground belt pairs with a max span, so players can cross their own
  lines. This is essential for real factory building.
- **Splitters** with the behaviour players expect: even split, priority input/output, and filters.
- **Inserters/arms**: swing from source to target, respect stack size, and have a real rate that
  makes tier choice matter.
- **Storage**: chests/yards with capacity, plus a logistics request layer where a building can pull
  what it needs.
- Everything reads/writes through clean APIs so [P04] production can consume and produce items, and
  [P02] heat can eventually be fed coal (heat currently runs in a "fuel autarky" fallback because
  logistics does not exist — read heat_system.gd around _fuel_autarky and WIRE FUEL DELIVERY UP so
  generators genuinely need coal delivered. That transforms heat from a static number into a
  supply-chain problem, which is the entire point of the game).
- Item definitions as .tres in game/content/logistics/ (coal, iron ore, iron plate, steel, scrap,
  copper, circuits, ammunition, insulation, machine parts).
- Expose \`throughput_of(cell)\`, \`saturation_of(cell) -> float\`, \`is_starved(building_id)\` so
  [P19]'s logistics lens can visualise your state. Coordinate: expose these even if unused today.
- serialize()/metrics(): items_on_belts, throughput, starved_machines, backed_up_belts.
Tests: throughput math, compression, splitter fairness, underground span limits, determinism.` },

  { key: 'P04', label: 'P04 production/recipes', prompt: `${PRE}

YOUR PART: **[P04] Production & Recipes** — you own \`game/sim/production/\`,
\`game/content/recipes/\`, \`tests/production/\`.

- \`ProductionSystem extends SimSystem\` (order 40, system_name &"production").
- \`RecipeDef extends Resource\` (class_name RecipeDef) in game/sim/production/recipe_def.gd:
  inputs, outputs, time_ticks, machine_tags, heat_cost, unlock_id, category. Design it so [P10]
  research can gate recipes and [P18] can build a browsable recipe tree from it.
- Machines that consume inputs, take time, produce outputs, stall visibly when starved or blocked
  (emit Bus.machine_stalled with a reason StringName — [P19] will render it), and consume heat while
  running. A cold machine works slower or not at all: tie production to the warmth field from
  HeatSystem.warmth_at(). That single coupling is what fuses the city builder to the factory.
- Real production chains with genuine ratios, at least three tiers deep, designed so that hitting
  a clean ratio feels satisfying: ore -> plate -> part -> component -> ammunition/insulation.
  The player should be able to compute ratios and be rewarded for it. Write the ratios down in a
  comment so a balance agent can tune them later.
- Byproducts and a heat-recovery loop (smelters emit waste heat that can be captured) so that
  clever layouts pay off.
- Write a REAL recipe set as .tres in game/content/recipes/, and building defs for the machines you
  need go in a request to [P11]'s schema — you may ADD .tres building files to
  game/content/buildings/ for your own machines (that folder is shared additively; only add files
  whose names start with your machine names, never edit someone else's file).
- serialize()/metrics(): active_machines, stalled, items_per_minute per output, chain depth.
Tests: recipe resolution, stall reasons, ratio math, warmth coupling, determinism.` },

  { key: 'P05', label: 'P05 citizens', prompt: `${PRE}

YOUR PART: **[P05] Citizens** — you own \`game/sim/citizens/\`, \`tests/citizens/\`.
Frostpunk's power comes from the fact that the numbers are people. Make them people.

- \`CitizenSystem extends SimSystem\` (order 50, system_name &"citizens").
- A population of individuals (not an abstract number) but stored efficiently in parallel arrays so
  1000+ citizens cost almost nothing per tick. Each has: name, age bracket, health, warmth,
  hunger, fatigue, morale, job, home, and a state machine (sleeping, walking, working, sick,
  injured, dead).
- Needs that interact with the rest of the sim for real: warmth read from HeatSystem.warmth_at()
  at their current cell (cold citizens get sick, sick citizens stop working, that is the Frostpunk
  death spiral), food consumed from stock, rest gated by housing and by shift laws.
- Jobs: buildings declare workers_required; you assign citizens, they walk there using the grid
  flow-field, and their presence gates that building's output. Unstaffed buildings must visibly
  underperform — expose \`staffing_of(building_id) -> float\`.
- Shifts and a day rhythm tied to ClimateSystem's phase_of_day: the city should visibly fill and
  empty. This is what makes a city feel alive rather than like a spreadsheet.
- Sickness, injury, medical care, and death with a cause. Emit Bus.citizen_died with the cause so
  [P06] society and [P22] narrative can react. Deaths must feel like events, not decrements.
- Individual citizens must be inspectable: expose \`citizen_info(id) -> Dictionary\` rich enough
  that a UI can show "Mara Kessler, 34, tinsmith, cold and hungry, walking to Workshop 2". A player
  clicking one person and seeing a life is worth more than ten systems.
- serialize()/metrics(): population, sick, dead_total, avg_warmth, avg_morale, employed, homeless.
Tests: need decay math, job assignment determinism, death spiral, staffing effects, 1000-citizen perf.` },

  { key: 'P06', label: 'P06 society/hope/laws', prompt: `${PRE}

YOUR PART: **[P06] Society: Hope, Discontent and Law** — you own \`game/sim/society/\`,
\`game/content/laws/\`, \`tests/society/\`. This is THE Frostpunk signature system. Get it right and
the game has a conscience; get it wrong and it is a factory sim with snow.

- \`SocietySystem extends SimSystem\` (order 60, system_name &"society").
- **Hope** and **Discontent** as two opposed meters that move for legible, traceable reasons.
  Every change must carry a reason string so a UI can show "Discontent +4: three died in the cold
  last night". Never let a meter move mysteriously. Expose \`hope_reasons() -> Array[Dictionary]\`.
- Consequences with teeth: at maximum discontent the player is exiled and the run ends; at zero
  hope the city gives up. Both must be telegraphed with escalating warnings, never a sudden loss.
- **The Book of Laws**: a signable law tree where each law is a real moral choice with real
  mechanical consequences and no clean answer. Child labour, corpse disposal, extended shifts,
  rationing, sawdust in the food, a fighting pit, faith or order as a discipline path. Each law
  should trade a resource problem for a human cost, and laws should foreclose other laws so the
  player's book becomes a record of who they turned out to be. Sign-time cooldowns so laws are
  scarce and considered.
- Write REAL law content as .tres in game/content/laws/ — at least 24 laws across two branching
  paths, each with authored prose that is bleak and specific, never generic. Prose quality matters
  as much as the mechanic; this is the writing players quote.
- Factions/groups forming around grievances, with demands and deadlines.
- serialize()/metrics(): hope, discontent, laws_signed, active_grievances.
Tests: meter math, reason traceability, law prerequisite/exclusion graph correctness, determinism.` },

  { key: 'P07', label: 'P07 combat/turrets', prompt: `${PRE}

YOUR PART: **[P07] Combat** — you own \`game/sim/combat/\`, \`game/content/enemies/\`,
\`tests/combat/\`. This is the tower-defense third of the game and it currently does not exist.

- \`CombatSystem extends SimSystem\` (order 80, system_name &"combat").
- Enemies as data-driven defs (.tres in game/content/enemies/): health, armour, speed, damage,
  behaviour, size, and what they target. Design at least 8 distinct threats that demand different
  answers, not stat-scaled copies: a swarm that punishes single-target turrets, an armoured breaker
  that punishes low-damage spam, something that specifically eats heat (drains pipes) and so
  attacks the network rather than the walls, a burrower that ignores walls, a screamer that raises
  discontent, and a night-boss.
- Enemy movement using the grid flow-field (Sim.get_system(&"grid")), with real behaviour: they
  path to the warm centre, break walls when blocked, and prefer weak points. Must handle 500+
  enemies inside the tick budget: no per-enemy A*, use the shared field.
- **Turrets that burn heat to fire.** This is the fusion of the three genres: a turret with no heat
  is a decoration, so defending badly browns out your city and heating badly disarms your walls.
  Targeting with real selection policy (closest/strongest/first), turn rate, range, reload, ammo
  drawn from [P03]/[P04] where available (degrade to infinite ammo if absent, and say so in the log).
- Projectiles and damage: ballistics with travel time, flamethrowers with cone and heat cost, area
  damage, armour interaction. Emit Bus.turret_fired / structure_damaged / enemy_killed with
  positions so [P14] VFX can render it later.
- Walls, gates, repair, and structural damage that meaningfully changes the map (a broken wall
  re-routes the flow field).
- serialize()/metrics(): enemies_alive, kills, damage_taken, turret_uptime, heat_spent_on_defence.
Tests: targeting policy, damage/armour math, 500-enemy perf, wall-break repathing, determinism.` },

  { key: 'P08', label: 'P08 threat director', prompt: `${PRE}

YOUR PART: **[P08] Threat Director** — you own \`game/sim/threat/\`, \`tests/threat/\`.
You are the game's dramaturge. Frostpunk's storms and Factorio's evolution are both here.

- \`ThreatSystem extends SimSystem\` (order 70, system_name &"threat").
- A **wave director** that composes each night's attack rather than picking from a list: a budget
  that grows on a designed curve, spent on enemy compositions from game/content/enemies/, with
  approach vectors chosen against the player's actual defences (read the grid's chokepoints, and
  probe weak sides) so that turtling one side is punished. Never unfair, always legible in hindsight.
- **Telegraphing is mandatory and is the whole feeling of the game**: the player must know roughly
  what is coming and from where, with enough time to act and never enough resources to fully
  prepare. Emit Bus.wave_incoming early with direction and estimated strength, escalating.
- **Pressure curve across a campaign**: quiet early nights that teach, a first real assault, a
  false lull, escalation, and named set-piece nights that coincide with [P09]'s Great Frosts so the
  worst attack lands on the coldest night. Read ClimateSystem's storm schedule and deliberately
  synchronise the peaks. That intersection is the best moment the game can produce.
- **Adaptive pressure, honestly bounded**: measure how comfortably the player cleared the last
  waves and adjust within a declared band, so that a strong player is stretched and a struggling
  player is not annihilated. Write the band into a comment and expose it in metrics; hidden rubber
  banding that players can feel is worse than none.
- An in-fiction reason the threat exists that ties to heat (they are drawn to warmth) so that the
  player's own success is what summons them. Expose \`threat_level() -> float\` and
  \`next_wave_preview() -> Dictionary\` for the HUD.
- serialize()/metrics(): wave, threat_level, budget, waves_cleared, pressure_band.
Tests: budget curve determinism, composition legality, adaptation bounds, storm synchronisation.` },

  { key: 'P10', label: 'P10 research', prompt: `${PRE}

YOUR PART: **[P10] Research & Progression** — you own \`game/sim/research/\`,
\`game/content/research/\`, \`tests/research/\`.

- \`ResearchSystem extends SimSystem\` (order 90, system_name &"research").
- A tech tree that is a real graph with prerequisites, costs paid in items produced by [P04], and
  time. Emit Bus.research_started/completed/unlocked. Unlocks gate building defs (BuildingDef has
  unlock_id), recipes and laws.
- **Pacing is the actual deliverable.** Design the tree so that each unlock answers a problem the
  player is feeling RIGHT NOW: insulation arrives the night heat loss first hurts, the better
  turret arrives when the armoured breaker first appears, underground belts arrive when the base
  first tangles. Write the intended beat for each node in its .tres description. A tech tree that
  is a shopping list is a failure; one that reads as a conversation with the player's problems is
  the goal.
- At least 40 real research nodes across branches: heat engineering, logistics, metallurgy,
  defence, survival/medicine, and a dark "desperate measures" branch that ties into [P06]'s laws.
- Expose \`is_unlocked(id) -> bool\`, \`available() -> Array\`, \`progress_of(id) -> float\` and a
  \`tree_layout()\` helper rich enough that [P18] can draw the tree without re-deriving the graph.
- serialize()/metrics(): researched_count, active, progress, unlocks_pending.
Tests: prerequisite graph correctness (no cycles, all reachable), cost deduction, unlock gating.` },

  { key: 'P17', label: 'P17 HUD', prompt: `${PRE}

YOUR PART: **[P17] HUD** — you own \`game/ui/hud/\`, \`tests/hud/\`.
Today the entire interface is game/play/play_hud.gd: 114 lines, four Labels and a ColorRect. You
replace it with a real one. (game/play/ is the integrator's placeholder; do not edit it, build
yours properly in game/ui/hud/ and the integrator will switch over.)

- A HUD that is calm when the city is healthy and urgent when it is not. Frostpunk's HUD is a ring
  of dread; Factorio's is almost invisible until something is wrong. Take the best of both.
- Core readouts, all read live from the sim: the day/phase clock with **time until nightfall** as
  the single most prominent number, temperature, heat supply/demand/deficit/buffer, population with
  sick and dead, hope and discontent, resource stocks with rate-of-change arrows (a stock falling
  is the information, not the stock).
- **Alerts that are actionable, not noise**: severity-ranked, grouped, deduplicated, each clickable
  to focus the camera on the actual problem via Bus.camera_focus_requested. Never show
  "Network 5 short 0 heat/s" — round sensibly and write plain sentences a human would say.
- A **next-wave indicator** reading [P08]'s next_wave_preview(): direction, strength, time.
- A selection panel: click any building or citizen and see what it is doing, what it needs, and
  why it is not working — including [P02]'s bottleneck reason and [P05]'s citizen_info.
- Diegetic weight: this is a besieged city, the UI should feel like scratched metal and lamplight,
  not a web dashboard. Use [P13]'s palette (game/view/render/palette.gd) so it belongs to the world.
- Scales correctly with Settings ui_scale and font_scale; keyboard navigable; every number has a
  tooltip explaining what it means and what changes it.
VERIFY VISUALLY: run the visual harness, read your own PNGs, iterate until it looks shippable.` },

  { key: 'P18', label: 'P18 build menu', prompt: `${PRE}

YOUR PART: **[P18] Build Menu, Tooltips & Browsers** — you own \`game/ui/build_menu/\`,
\`tests/build_menu/\`.

- A build palette that scales to 60+ buildings: categorised, searchable by typing, keyboard-driven,
  with recently-used and favourites. Factorio's quickbar is the model: fast hands beat pretty menus.
- **Tooltips that answer the real question.** Not "Coal Generator: produces heat". Show inputs,
  outputs, rates, heat cost, workers needed, footprint, what it unlocks, and CONTEXTUAL warnings
  ("you have no coal delivery to this area", "this will exceed your pipe capacity"). Read the live
  sim to compute those warnings. This is where a player learns the game without a tutorial.
- A **recipe browser** built from [P04]'s RecipeDef graph: what makes this, what is it used for,
  click through the chain in both directions. Factorio players live in this screen.
- A **tech tree screen** built from [P10]'s tree_layout(): readable graph, current progress, what
  each node unlocks and why it matters now.
- A **blueprint library UI** on top of [P11]'s blueprint book: preview thumbnails, rename, delete,
  place. The system is already built and completely invisible.
- A **law screen** for [P06]'s Book of Laws that presents each choice with its authored prose,
  its cost, and what it forecloses. This screen should feel heavy.
- Every panel: openable by hotkey, closable by Escape, remembers state, never blocks the game.
Use [P13]'s palette so it belongs to the world. VERIFY VISUALLY with the visual harness and read
your own PNGs.` },

  { key: 'P13b', label: 'P13 render fixes', prompt: `${PRE}

YOUR PART: **[P13] Rendering, second pass** — you own \`game/view/render/\`, \`tests/render/\`.
You are fixing named, verified defects found by a critic who looked at the actual frames. Read
artifacts/critic_vis/shots/*.png yourself with your Read tool BEFORE you start, and again after.

CONFIRMED DEFECTS, in priority order:
1. **Terrain reads as a broken texture atlas.** The snow is a visible grid of repeating tiles with
   hard chunk seams across the whole screen (worst in midday.png). Fix with proper tile variation,
   multi-octave noise breakup, and seam-free chunk sampling. This single defect is what makes the
   game look amateur.
2. **The snow/thawed boundary is a giant staircase of axis-aligned rectangles** at every zoom.
   It needs blending, a transition band, drift edges, something organic. Snow does not have corners.
3. **Deep night is unreadable and the game is named after it.** 208 buildings existed and the frame
   showed a dark void with two blown-out white blobs. Two problems: (a) the radiator lights are
   pure white, which reads as a rendering bug rather than warmth — they must be warm amber and
   falloff-shaped; (b) there is no ambient legibility floor, so unlit buildings vanish entirely.
   Give the player moonlight/snow-bounce so the city is always readable in silhouette, and reserve
   full darkness for beyond the city. Compare against Frostpunk's night: it is dark but you can
   always read your city.
4. **The day/night grade is a flat global multiply**, so dusk tints snow 40 tiles from any light.
   It must read as light falling on things, not as a colour filter over the frame.
5. **Building variety is about six sprites repeated**, and two structurally identical hearths appear
   at different scales in one frame. Silhouettes must be distinct enough to identify a building by
   shape alone at far zoom.
6. **Performance**: entity drawing costs 36 ms of CPU for 206 buildings, a 27 fps ceiling before the
   sim even runs, projecting to ~300 ms/frame at the 1717-building stress city. Batch aggressively
   (MultiMesh / a single canvas item per layer), cull properly, and LOD distant detail away. Measure
   before and after and report both numbers.
Also add: snow accumulation that builds during snowfall, soot near industry, and heat shimmer.
VERIFY: run the visual harness at several times of day, READ every PNG, and be honest about whether
it now looks like a game someone would buy.` },

  { key: 'P12', label: 'P12 economy/balance', prompt: `${PRE}

YOUR PART: **[P12] Economy & Balance** — you own \`game/sim/economy/\`, \`game/content/economy/\`,
\`tests/economy/\`, and the scenario tuning files in \`tests/scenarios/\` (you may EDIT the scenario
JSONs — coordinate by only fixing what is broken, and fix a lot, because they are badly broken).

Verified problems you must fix:
- tests/scenarios/first_night.json is ~70% no-op: it references building kinds that do not exist
  ('hearth' vs the real id 'the_hearth', 'radiator' vs 'warmth_radiator', worker_hut, scrap_yard,
  stone_quarry, belt, flame_turret). Read game/content/buildings/*.tres for the REAL ids and make
  every scenario actually build what it claims.
- stress_1000.json says "over a thousand buildings and a thousand hostiles" and actually produces
  350 buildings, zero hostiles, and 37 disconnected single-node heat networks. Make it real: it is
  the only thing the perf gate measures.
- economy_60min.json simulates a dead city: heat supply is 0.00 for 55 of its 60 minutes and
  deficit == demand on every row. It should model a city that actually grows.
- grid op 'reveal' is called by three scenarios and does not exist.
Then build the actual part:
- A central, documented balance table (game/content/economy/) holding the numbers that matter:
  resource yields, building costs, heat production/consumption, research costs, population growth,
  threat budget. Other systems should read from here rather than hardcoding, where practical.
- **Run the numbers, do not guess them.** Use the headless harness to run long scenarios and read
  metrics.csv, then tune toward a designed difficulty curve: the first night should be survivable
  by an attentive beginner, day 3 should hurt, the first Great Frost should nearly break them.
  Write the intended experience per day into a document and show, with measured data from actual
  runs, that the current numbers produce it.
- Build an analysis script in tools/ that reads a metrics.csv and reports the curve (heat margin
  over time, population trend, resource bottleneck by phase) so future balance work is measurement
  driven, not vibes driven.` },
]

phase('Build')
const built = await parallel(PARTS.map(p => () => agent(p.prompt, { label: p.label, phase: 'Build', schema: SCHEMA })))
const ok = built.filter(Boolean)
log(`Phase B build: ${ok.length}/${PARTS.length} parts returned`)

phase('Integrate')
const integration = await agent(`${PRE}

YOU ARE THE INTEGRATOR. You alone may write anywhere, including game/core/ and project.godot.
Twelve agents just landed logistics, production, citizens, society, combat, threat, research,
economy, overlays, HUD, build menu and render fixes in parallel. Their claims:
${ok.map(r => `- ${r.part}: ${r.what_works}\n  gaps: ${(r.known_gaps || []).join('; ') || 'none'}`).join('\n')}

Verify everything yourself. Builders are unreliable narrators about their own work.

MANDATE:
1. \`bash tools/check.sh\` GREEN, and it must still be capable of going red.
2. **Make the eleven systems actually interlock.** The point of this phase is that heat needs coal
   that logistics delivers, machines need warmth and workers, turrets burn heat, citizens die of
   cold and that moves hope, threat synchronises with the Great Frost. Hunt for systems that were
   written defensively against each other's absence and are now silently degrading instead of
   connecting — e.g. HeatSystem's _fuel_autarky fallback must switch OFF now that logistics exists.
   Find every such fallback and close it.
3. **Switch the UI over**: game/play/ was my placeholder shell. If [P17]'s HUD and [P18]'s build
   menu are real, wire them into boot.gd and delete game/play/ (update ARCHITECTURE.md accordingly).
4. Make the game genuinely PLAYABLE start to finish for one full day/night cycle with combat.
5. Visual proof run; read the PNGs yourself; fix what is broken.
6. Commit.
Report honestly, including what is still hollow.`,
  { label: 'integrator-B', phase: 'Integrate', effort: 'high', schema: {
      type: 'object',
      properties: {
        check_green: { type: 'boolean' },
        systems_live: { type: 'number' },
        interlocks_closed: { type: 'array', items: { type: 'string' } },
        fallbacks_still_open: { type: 'array', items: { type: 'string' } },
        playable_full_cycle: { type: 'boolean' },
        what_a_player_now_sees: { type: 'string' },
        still_hollow: { type: 'array', items: { type: 'string' } },
      },
      required: ['check_green', 'systems_live', 'playable_full_cycle', 'what_a_player_now_sees', 'still_hollow'],
    } })

phase('Perf')
const perf = await agent(`${PRE}

YOU ARE THE PERFORMANCE ENGINEER and you may edit hot paths anywhere in the repo.

Measured facts from before this phase, when only FOUR systems existed:
- stress_1000: 45.9 ticks/s against a declared target of 400. Floor was set to 35 so the gate
  reports green while running at 11% of target. That floor is a lie the team told itself.
- 43% of the 50 ms tick budget consumed by four systems. There are now eleven.
- Entity drawing: 36 ms CPU for 206 buildings, projecting to ~300 ms/frame at 1717 buildings.
- A single flow-field repair costs 27 ms, and repairs fire on every building placement, so dragging
  a line of pipes is a guaranteed hitch.
- game/core/sim.gd has NO per-system timing at all, so nobody can attribute cost.

DO THIS:
1. **Add per-system tick instrumentation first** (in game/core/sim.gd) so every claim afterwards is
   measured, not guessed. Report a real profile table: ms per system at realistic scale.
2. Fix the biggest offenders by measurement, not by intuition. Known suspects worth checking:
   heat_flow.gd:401-485 sorts keys inside the round loop when the sort order cannot change between
   rounds; heat_flow.gd:510 bypasses the routing cache whenever deficit is nonzero, which is most
   of every night; flow-field repair cost; entity draw batching.
3. Raise the perf floor to something honest and make the gate fail below it. A gate tuned to pass
   is worse than no gate.
4. Re-measure after each change and report before/after numbers. Do not break determinism: run the
   determinism check after every optimisation, and say explicitly that you did.
Target: 60+ ticks/s at the real stress scenario with all eleven systems, and 60 fps rendering at a
1000-building city. If you cannot reach it, report exactly how far you got and what remains.`,
  { label: 'perf-engineer', phase: 'Perf', effort: 'high', schema: {
      type: 'object',
      properties: {
        profile_before: { type: 'string' },
        profile_after: { type: 'string' },
        ticks_per_second_before: { type: 'number' },
        ticks_per_second_after: { type: 'number' },
        fps_before: { type: 'string' },
        fps_after: { type: 'string' },
        optimisations: { type: 'array', items: { type: 'string' } },
        determinism_still_holds: { type: 'boolean' },
        remaining_bottlenecks: { type: 'array', items: { type: 'string' } },
      },
      required: ['ticks_per_second_before', 'ticks_per_second_after', 'optimisations', 'determinism_still_holds', 'remaining_bottlenecks'],
    } })

phase('Judge')
const JUDGE_CTX = `Project: "Last City: Nightfall" at ${ROOT} — Tower Defense x City Builder x Automation,
Godot 4.7, targeting Steam. Eleven simulation systems, a legibility overlay layer, HUD, build menu.

**YOU MUST NOT READ ANY BUILDER, INTEGRATOR OR PERF SUMMARY.** Ignore progress/events.jsonl and git
commit messages entirely. Judge ONLY what you can make the actual build do with your own hands.

Run it yourself:
  cd ${ROOT} && bash tools/check.sh
  timeout 400 ${GODOT} --headless --path . -- --harness --scenario=first_night --ticks=24000 --out=artifacts/j_sim
  timeout 250 ${GODOT} --path . --resolution 1920x1080 -- --harness --visual --scenario=first_night --out=artifacts/j_vis
Read log.txt, state.json, metrics.csv. READ EVERY PNG in the shots folder with your Read tool.
You may also launch the game interactively and drive it if that helps you judge.`

const [critic, blind] = await parallel([
  () => agent(`You are a RUTHLESS game critic with FRESH EYES and zero investment in this codebase. You have
shipped and reviewed games at the level of Factorio and Frostpunk. You are not here to encourage.

${JUDGE_CTX}

The previous round scored 3.8/10 with this biggest gap: "Legibility, at a 2. The sim computes rich
bottleneck analysis and none of it reaches a pixel." Check specifically whether that is now fixed,
and do not accept a partial fix as a fix.

SCORE 0-10 where **7 = a competent indie game**, **9 = genuinely comparable to Factorio/Frostpunk**,
**10 = better than them at that thing**. Be stingy and justify every score with evidence you gathered.
Dimensions: simulation_depth, legibility, visual_quality, feel, pressure_and_pacing, cohesion, rigor.

Then name the ONE thing that most urgently must change next. Exactly one.`,
    { label: 'critic-round2', phase: 'Judge', effort: 'high', schema: {
        type: 'object',
        properties: {
          scores: { type: 'object', additionalProperties: { type: 'number' } },
          overall: { type: 'number' },
          legibility_gap_fixed: { type: 'boolean' },
          what_is_real: { type: 'string' },
          what_is_fake: { type: 'array', items: { type: 'string' } },
          visual_verdict: { type: 'string' },
          biggest_gap: { type: 'string' },
          evidence: { type: 'array', items: { type: 'string' } },
        },
        required: ['scores', 'overall', 'legibility_gap_fixed', 'what_is_fake', 'visual_verdict', 'biggest_gap', 'evidence'],
      } }),

  () => agent(`You are running a BLIND SIDE-BY-SIDE COMPARISON. You have deep firsthand knowledge of Factorio
and Frostpunk: their systems, their UI, their pacing, how they actually look and feel in motion.

${JUDGE_CTX}

Your job is NOT to be kind. For each dimension below, compare this build directly against the
relevant reference game and declare a WINNER: "ours", "factorio", "frostpunk", or "tie".
Judge our side ONLY from what you personally observed running the build and reading its frames.
Judge their side from your knowledge of the actual shipped games.

Dimensions to compare:
1. automation_readability     — vs Factorio (belts, flow, bottleneck diagnosis, alt-mode)
2. factory_depth              — vs Factorio (production chains, ratios, logistics)
3. base_building_feel         — vs Factorio (placement, blueprints, drag-build, undo)
4. city_under_pressure        — vs Frostpunk (dread, the clock, the cold closing in)
5. moral_weight               — vs Frostpunk (laws, consequences, writing)
6. visual_atmosphere          — vs Frostpunk (light, snow, darkness, mood)
7. ui_craft                   — vs both
8. onboarding_and_teaching    — vs both
9. moment_to_moment_feel      — vs both

For every dimension where we LOSE, state concretely what the reference game does that we do not.
Be specific and technical, at the level of "Factorio's alt-mode draws the recipe icon on every
machine so a screenshot of a base is self-documenting; ours draws nothing on machines at all".

Then name the SINGLE BIGGEST GAP across all dimensions, the one that would most improve our
standing if fixed. Exactly one.`,
    { label: 'blind-comparison', phase: 'Judge', effort: 'high', schema: {
        type: 'object',
        properties: {
          comparisons: {
            type: 'array',
            items: {
              type: 'object',
              properties: {
                dimension: { type: 'string' },
                winner: { type: 'string' },
                margin: { type: 'string', description: 'narrow | clear | not close' },
                why: { type: 'string' },
                what_they_do_that_we_dont: { type: 'string' },
              },
              required: ['dimension', 'winner', 'why'],
            },
          },
          wins: { type: 'number' },
          losses: { type: 'number' },
          ties: { type: 'number' },
          single_biggest_gap: { type: 'string' },
          would_a_factorio_player_keep_playing: { type: 'string' },
        },
        required: ['comparisons', 'wins', 'losses', 'ties', 'single_biggest_gap'],
      } }),
])

return { built: ok, integration, perf, critic, blind }
