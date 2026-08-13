export const meta = {
  name: 'lcn-phase-a-foundation',
  description: 'Last City: Nightfall — build the playable foundation vertical slice in Godot 4.7',
  phases: [
    { title: 'Build', detail: '7 parallel part-owners build grid, climate, heat, build-system, render, camera, test-rig' },
    { title: 'Integrate', detail: 'make it actually run, look right, and stay green' },
    { title: 'Critic', detail: 'harsh critic judges the real running build, not a summary' },
  ],
}

const ROOT = '/Users/maximilianthuemmler/Documents/last-city-nightfall'
const GODOT = '/Applications/Godot.app/Contents/MacOS/Godot'

const PRE = `You are building **Last City: Nightfall**, a Tower Defense x City Builder x Automation game
for STEAM, in **Godot 4.7.1**, GDScript, 2D top-down. The bar is literally Factorio and Frostpunk.
Nothing less ships. Dark, tense, beautiful.

REPO: ${ROOT}   GODOT BINARY: ${GODOT}

STEP 1, MANDATORY: read ${ROOT}/docs/ARCHITECTURE.md end to end. It is law. Then read
${ROOT}/game/core/*.gd so you know the exact contracts you are coding against
(SimSystem, Sim, SimClock, Bus, Rng, Registry, Log, Harness).

HARD RULES
- Write ONLY inside the folders you own (listed in your task) + your own tests/<part>/ folder
  + your own game/content/<category>/ files. Touching another part's folder breaks the build
  for 20 other agents. Never edit game/core/** or project.godot.
- Static typing on EVERY declaration and signature. \`var x: int = 0\`, \`func f(a: Vector2i) -> void:\`
- game/sim/** is deterministic: no randf(), no Time.get_ticks_msec(), no frame delta, no input,
  no node lookups into view/ or ui/. Randomness ONLY via Rng.stream("name"). Time ONLY via the
  tick int and SimClock.DT. Sort dictionary keys before iterating if order affects state.
- Logging via Log.info/warn/error, never print().
- WORLD CONSTANTS: tile size 32px, square grid, chunk 32x32 tiles, sim tick 20Hz.

VERIFY YOUR OWN WORK — a claim is worth nothing, a run is worth everything:
  cd ${ROOT} && ${GODOT} --headless --path . -- --harness --scenario=smoke --out=artifacts/\${YOURPART}
Read artifacts/\${YOURPART}/log.txt and state.json. ZERO script errors, ZERO warnings you caused.
Iterate until it is genuinely clean. Do not report done on a build you have not run.

WHEN DONE: append one line of JSON to ${ROOT}/progress/events.jsonl:
  {"t":"<iso8601>","level":"info","msg":"<part id>: <one concrete sentence about what now works>"}
(use \`date -u +%Y-%m-%dT%H:%M:%S\` for the timestamp; append with >> , never overwrite the file)

Write real, deep, shippable systems. No stubs, no TODO placeholders, no "in a full implementation
this would". If you write a placeholder you have failed the task.`

const SCHEMA = {
  type: 'object',
  properties: {
    part: { type: 'string' },
    files_written: { type: 'array', items: { type: 'string' } },
    what_works: { type: 'string', description: 'Concrete behavior now present, verified by an actual run' },
    verified_command: { type: 'string' },
    verified_output_summary: { type: 'string' },
    contracts_exposed: { type: 'array', items: { type: 'string' }, description: 'class_name / API other parts may use' },
    known_gaps: { type: 'array', items: { type: 'string' } },
  },
  required: ['part', 'files_written', 'what_works', 'verified_command'],
}

const PARTS = [
  {
    key: 'P01-grid',
    label: 'P01 grid+world',
    prompt: `${PRE}

YOUR PART: **[P01] Grid & World** — you own \`game/sim/grid/\`, \`game/content/biomes/\`, \`tests/grid/\`.

Build the substrate the entire game stands on:
- \`GridSystem extends SimSystem\` (order 20, system_name &"grid") at game/sim/grid/grid_system.gd.
- Chunked tile storage (32x32 chunks) that stays fast at 500x500 tiles. Flat PackedInt32Array /
  PackedByteArray per chunk, not per-tile objects. Tile fields: terrain, elevation, resource kind,
  resource amount, occupancy (building id), passability, snow depth.
- \`class_name Grid\` static helpers: cell<->world conversion (32px tiles), neighbours (4 and 8),
  ring/spiral iteration, line-of-sight, area queries, flood fill.
- Deterministic procedural map generation via Rng.stream("mapgen"): a frozen basin with a warm
  geothermal core at the centre (the reason a city exists here at all), ore/coal/scrap deposits
  in believable clusters that get richer the further out you push — that outward pressure IS the
  game's tension, so make the gradient real and tunable. Wrecks and ruins as scavengeable starting
  resources. Ridges and chasms that shape natural defensive chokepoints, because tower defense
  needs terrain that means something.
- Pathfinding surface for enemies + citizens: a flow-field / integration-field implementation
  (not per-unit A*) that scales to 1000+ agents, with a dirty-region rebuild when buildings change.
  Expose \`flow_direction(cell) -> Vector2i\` and \`request_rebuild(region)\`. This is performance
  critical: make it genuinely good, and measure it.
- Occupancy API other parts call: \`is_free(cell,size)\`, \`occupy(cell,size,id)\`, \`release(id)\`,
  \`building_at(cell) -> int\`.
- serialize()/deserialize() for the whole grid, and metrics(): tiles_dirty, path_rebuild_ms, chunks.
Write tests in tests/grid/ covering determinism (same seed -> identical map hash), flow-field
correctness around obstacles, and occupancy edge cases.`,
  },
  {
    key: 'P09-climate',
    label: 'P09 climate+nightfall',
    prompt: `${PRE}

YOUR PART: **[P09] Climate & Nightfall** — you own \`game/sim/climate/\`, \`tests/climate/\`.
This is the game's heartbeat and its dread pump. Everything else is paced by you.

- \`ClimateSystem extends SimSystem\` (order 10, system_name &"climate") at game/sim/climate/climate_system.gd.
- Day/night cycle. A day is a real arc, not a light switch: dawn, morning, afternoon, dusk,
  night, deep night. Expose \`phase_of_day() -> StringName\`, \`day_progress() -> float\` (0..1),
  \`day() -> int\`, \`is_night() -> bool\`, and \`seconds_until_night() -> float\` (the HUD's most
  important number). Emit Bus.day_started / Bus.night_started.
- Temperature model with real spatial meaning: a global ambient that plunges at night and worsens
  over the campaign, PLUS local temperature that heat sources raise (the heat part [P02] will read
  your ambient and write local warmth — expose \`ambient_temperature() -> float\` and a settable
  \`local_offset\` grid hook, coordinate through Sim.get_system(&"heat") defensively since that part
  may not exist yet).
- Weather: clear, snowfall, whiteout blizzard, and the campaign-defining **Great Frost** storms
  that arrive on a schedule the player can see coming and dread. Storms must be TELEGRAPHED —
  the player gets warning, time to prepare, and then it hurts. Emit Bus.alert_raised for warnings.
- A difficulty/pressure curve over the campaign: each day colder than the last, with named
  escalation beats. Make the curve data-driven and tunable in one obvious place.
- serialize()/metrics(): day, phase, ambient_temp, storm_intensity, seconds_to_night.
Tests in tests/climate/: cycle length exactness, storm scheduling determinism, temperature curve.`,
  },
  {
    key: 'P02-heat',
    label: 'P02 heat+power',
    prompt: `${PRE}

YOUR PART: **[P02] Heat & Power Network** — you own \`game/sim/heat/\`, \`tests/heat/\`.
THIS IS THE SIGNATURE SYSTEM OF THE GAME. Heat is power, warmth, morale and ammunition at once.
If this system is not deep, elegant and legible, the game has no spine.

- \`HeatSystem extends SimSystem\` (order 20 — run AFTER climate; use order 25, system_name &"heat")
  at game/sim/heat/heat_system.gd.
- A real network graph: generators produce heat, pipes/conduits carry it, buildings consume it,
  buffers store it. Solve distribution per tick as a proper flow problem, not a hand-wave.
  Connected components get recomputed incrementally when the grid changes, not from scratch.
- Pressure/throughput: a pipe has capacity. Overdrawing a line browns out everything downstream —
  and the player must be able to SEE which line and why. Distance causes loss. Insulation upgrades
  reduce loss. This creates real engineering decisions about topology.
- Radiant heat: a heated building warms its surroundings with falloff, writing into a spatial
  warmth field that citizens ([P05]) and buildings read. Overlapping sources add. This is what
  makes a city plan look like a city plan.
- Brownout / blackout cascade: when supply < demand, shed load by priority, emit Bus.heat_shortfall
  and Bus.building_froze, and let it cascade in a way that is dramatic but always traceable to a
  cause the player can find.
- Generator variety hooks: read building definitions from Registry ("buildings" category) rather
  than hardcoding, so [P04]/content agents can add generators without touching your code.
- Expose for other parts: \`warmth_at(cell) -> float\`, \`network_of(building_id) -> int\`,
  \`network_stats(nid) -> Dictionary\` (supply, demand, buffer, deficit, loss).
- serialize()/metrics(): total_supply, total_demand, deficit, networks, frozen_buildings, avg_warmth.
Tests in tests/heat/: flow conservation, brownout priority order, falloff correctness, incremental
rebuild equals full rebuild, determinism.
Coordinate defensively: Sim.get_system(&"grid") and (&"climate") may be null during parallel dev.`,
  },
  {
    key: 'P11-build',
    label: 'P11 build+blueprints',
    prompt: `${PRE}

YOUR PART: **[P11] Build & Construction** — you own \`game/sim/build/\`, \`game/content/buildings/\`,
\`tests/build/\`. You also define the BuildingDef resource every other part reads.

- \`BuildingDef extends Resource\` with \`class_name BuildingDef\` in game/sim/build/building_def.gd.
  Fields other parts need: id, display_name, description, category, size (Vector2i), cost
  (Dictionary of item->amount), build_time_ticks, heat_produced, heat_consumed, heat_buffer,
  workers_required, hp, footprint rules, placement rules (needs_ore / needs_flat / must_connect),
  unlock_id, and a free-form \`tags: Array[StringName]\`. Design this schema carefully — 20 other
  agents will extend it, so make it expressive and document each field in one line.
- \`BuildSystem extends SimSystem\` (order 15, system_name &"build") handling commands submitted via
  Sim.submit_command({"system":&"build", ...}): place, remove, cancel, rotate, place_blueprint,
  and a construction queue where buildings take real time and real materials to finish. Emit
  Bus.building_placed / removed / state_changed / placement_rejected (with a REASON STRING the
  UI can show — never a silent failure).
- Ghost/validity checking that other layers can query without mutating: \`can_place(kind, cell, rot)
  -> Dictionary {ok: bool, reason: String}\`.
- **Blueprints**: capture a rectangular region into a reusable stamp, save/load it, stamp it down
  as ghosts that construction fulfils over time. Factorio's blueprint system is a huge part of why
  that game is loved — treat this as a first-class feature, including copy, paste, mirror, rotate.
- Undo/redo stack for construction actions.
- Write REAL starting content in game/content/buildings/ as .tres files (Registry scans it):
  at minimum a geothermal tap, a coal generator, a heat pipe, a warmth radiator, a scrap collector,
  an ore drill, a smelter, a workshop, a housing block, a granary, a wall, and a basic turret mount.
  Give them costs and numbers that make a coherent opening 20 minutes.
- serialize()/metrics(): buildings_total, under_construction, queued.
Tests in tests/build/: placement validity, cost deduction, blueprint round-trip, undo correctness.`,
  },
  {
    key: 'P13-render',
    label: 'P13 render+art direction',
    prompt: `${PRE}

YOUR PART: **[P13] Rendering & Art Direction** — you own \`game/view/render/\`, \`tests/render/\`.
The game must be genuinely beautiful. This is the part that decides whether a critic says
"gorgeous" or "programmer art". Frostpunk's look: cold blue-grey dark, warm orange pools of
light, snow, long shadows, heavy atmosphere.

- \`WorldRenderer\` node at game/view/render/world_renderer.gd + world_renderer.tscn — reads the
  sim (Sim.get_system(&"grid") etc.), never writes it. Interpolate positions with SimClock.alpha
  so movement is smooth at 60fps despite the 20Hz sim.
- Tile rendering that is FAST at 500x500: use TileMapLayer or a custom MultiMesh/canvas-item batch.
  Never one Node2D per tile. Prove it: run at scale and log the frame cost.
- **Lighting is the whole art direction.** CanvasModulate for the night tint that shifts across
  the day cycle, Light2D pools around heat sources, warm rim light on buildings near heat, deep
  cold shadow away from it. The player should be able to feel the temperature by looking.
- A day/night colour grade driven by ClimateSystem phase (read defensively, it may be null):
  dawn steel-blue, noon pale bleached, dusk amber, night near-black with orange islands.
- Post-processing pass: subtle bloom on warm sources, vignette, film grain, chromatic cold shift
  at low temperature. All toggleable via Settings.graphics. Use a CanvasLayer with a shader —
  the project uses the GL Compatibility renderer, so keep shaders compatible with it and VERIFY
  they compile by running the game.
- Procedurally generate the placeholder art YOURSELF as crisp vector-ish sprites drawn in code or
  committed SVG/PNG — no flat coloured rectangles. Buildings need silhouette readability: a player
  must identify a building by shape alone at zoomed-out scale. Define and document the palette in
  one file (cold #0b1220 → #1d2c44, warm #ff8a3d → #ffd9a0, snow #e8eef7) and make every other
  view part able to import it.
- Snow accumulation shading, footprint/soot darkening near industry, ice cracking on cold tiles.
VERIFY VISUALLY, this is mandatory for your part: run
  cd ${ROOT} && ${GODOT} --path . --resolution 1920x1080 -- --harness --visual --scenario=smoke --out=artifacts/P13
then READ the PNG files in artifacts/P13/shots/ with your Read tool and look at them honestly.
If it does not look like a game someone would pay for, iterate. Add shots to the smoke scenario
if you need them (tests/scenarios/ is shared — only append your own shot entries).`,
  },
  {
    key: 'P16-camera',
    label: 'P16 camera+input',
    prompt: `${PRE}

YOUR PART: **[P16] Camera & Input** — you own \`game/view/camera/\`, \`tests/camera/\`.
Feel is decided here. A city builder with bad camera feel is dead on arrival; Factorio's camera
is invisible because it is perfect.

- \`GameCamera\` (Camera2D subclass) at game/view/camera/game_camera.gd + .tscn.
- Smooth pan: WASD/arrows with acceleration and deceleration, middle-mouse drag, optional edge
  scroll (Settings.gameplay.edge_scroll). Speed scales with zoom level so it always feels equal.
- **Zoom toward the cursor**, not the screen centre — this is the single most important camera
  detail in a builder. Smooth exponential interpolation, clamped range, and at far zoom the game
  must stay readable (coordinate with [P19] overlays later; expose \`zoom_level() -> float\` and
  emit a signal when crossing readability thresholds).
- Momentum/inertia on release, but killable instantly on a new input. No floatiness.
- Camera shake API for [P15] to call: \`shake(strength, duration, frequency)\` with trauma-based
  decay, respecting Settings.graphics.screen_shake and accessibility.reduce_motion.
- Focus/pan-to API: \`focus_on(pos, immediate)\` wired to Bus.camera_focus_requested (alerts jump
  the camera to the problem).
- A complete input action map defined IN CODE at runtime (you may not edit project.godot):
  build, cancel, rotate, copy, paste, blueprint, pause, speed 1/2/3, overlays 1-5, quick-save.
  Provide a rebindable InputMap layer and persist through Settings.
- Selection: click, box-select drag, hover highlight. Expose hovered cell + selected entities via
  a clean API for [P17]/[P18] to consume. Never mutate sim directly — go through Sim.submit_command.
Tests in tests/camera/: zoom-to-cursor math, clamping, shake decay, rebinding round-trip.`,
  },
  {
    key: 'P00-testrig',
    label: 'P00 test rig',
    prompt: `${PRE}

YOUR PART: **[P00] Test Rig & Scenarios** — you own \`tests/run_tests.gd\`, \`tests/framework/\`,
\`tests/scenarios/\`, and \`tools/\` (except do not break the existing run_sim.sh/run_visual.sh
contracts — extend them).

Everyone else's work gets judged by this rig, so it has to be excellent and fast.

- A minimal, dependency-free test framework in tests/framework/ (do NOT install GUT or gdUnit4 —
  keep the repo self-contained): \`class_name TestCase\` with assert_eq/assert_true/assert_near/
  assert_throws/assert_deterministic, plus setup/teardown, and clear failure output showing
  expected vs actual with file:line.
- \`tests/run_tests.gd\` runnable as \`${GODOT} --headless --path . --script tests/run_tests.gd\`
  that discovers every \`tests/**/test_*.gd\`, runs them, prints a per-suite summary, prints
  "TESTS FAILED" and exits nonzero on any failure, "TESTS PASSED" on green. It must tolerate
  parts that do not exist yet (skip, don't crash) — 20 agents are building in parallel.
- Scenario library in tests/scenarios/ as JSON (schema is in game/core/harness.gd — read it):
  \`smoke\` (exists, keep it), \`first_night\` (build a small base, survive night one),
  \`economy_60min\` (long headless run for balance data), \`stress_1000\` (perf: many entities),
  \`determinism\` (same seed twice must match byte for byte).
  Scenarios reference build commands via Sim.submit_command payloads — read [P11]'s building_def
  and build_system to get the command shape right, and if it is not written yet, define the shape
  you need in the scenario and note it in your report so [P11] conforms.
- A **determinism replay checker** in tools/: run a scenario twice, hash state.json, diff and
  report the first divergent key path. This is the tripwire that protects the whole project.
- A **performance gate** in tools/: run stress_1000 headless, assert ticks/second above a floor,
  write artifacts/perf.json. Fail loudly on regression.
- Upgrade tools/check.sh into the single green gate: parse + tests + determinism + perf, with
  crisp output and a correct exit code.
Make \`tools/check.sh\` actually pass on the current repo before you report done.`,
  },
]

phase('Build')
const built = await parallel(PARTS.map(p => () =>
  agent(p.prompt, { label: p.label, phase: 'Build', schema: SCHEMA })))

const ok = built.filter(Boolean)
log(`Phase A build: ${ok.length}/${PARTS.length} parts returned`)

phase('Integrate')
const integration = await agent(`${PRE}

YOU ARE THE INTEGRATOR. Seven agents just built the foundation of Last City: Nightfall in parallel:
${ok.map(r => `- ${r.part}: ${r.what_works}\n  gaps: ${(r.known_gaps || []).join('; ') || 'none reported'}`).join('\n')}

Do NOT trust any of that. Verify everything against the actual repo and actual runs.

You have write access to the WHOLE repo including game/core/ and project.godot — you are the only
agent who does. Your job:
1. Run \`cd ${ROOT} && bash tools/check.sh\` and make it GREEN. Fix every script error, every parse
   error, every broken contract between parts. If two parts disagree on an API, pick the better one
   and fix the caller.
2. Wire the vertical slice together so the game ACTUALLY RUNS AND IS PLAYABLE:
   boot -> world generated -> renderer showing the map -> camera controllable -> a building can be
   placed -> heat flows from it -> warmth is visible -> the day/night cycle runs and night falls.
   Create the main game scene that assembles renderer + camera + world if it does not exist, and
   point project.godot at the right main scene.
3. Run the visual harness and LOOK at the output with your Read tool:
   \`${GODOT} --path . --resolution 1920x1080 -- --harness --visual --scenario=first_night --out=artifacts/integrate\`
   Fix what is visually broken or missing. Take shots at dawn, midday, dusk, night.
4. Make sure \`tools/run_sim.sh --scenario=first_night --ticks=12000\` completes with zero errors
   in log.txt and produces meaningful metrics.csv rows (not empty, not all zeros).
5. Commit with git (user.email=claude@local, user.name=claude).
Report honestly what is genuinely working versus what is still hollow.`,
  { label: 'integrator', phase: 'Integrate', schema: {
      type: 'object',
      properties: {
        check_green: { type: 'boolean' },
        playable: { type: 'boolean' },
        what_actually_runs: { type: 'string' },
        shots_written: { type: 'array', items: { type: 'string' } },
        broken_or_hollow: { type: 'array', items: { type: 'string' } },
        fixes_applied: { type: 'array', items: { type: 'string' } },
      },
      required: ['check_green', 'playable', 'what_actually_runs', 'broken_or_hollow'],
    } })

phase('Critic')
const critic = await agent(`You are a RUTHLESS game critic with FRESH EYES and ZERO investment in this codebase.
You have shipped and reviewed games at the level of Factorio and Frostpunk. You are not here to be
encouraging. You are here to find out whether this thing is real.

The project is at ${ROOT} — "Last City: Nightfall", a Tower Defense x City Builder x Automation
game in Godot 4.7 targeting Steam.

**YOU MUST NOT READ ANY AGENT'S SUMMARY OR REPORT.** Ignore progress/events.jsonl claims. Judge
only what you can make the actual build do. Builders lie to themselves constantly.

DO THIS:
1. \`cd ${ROOT} && bash tools/check.sh\` — does the gate actually pass? Read the real output.
2. Run the sim for real and read the artifacts:
   \`${GODOT} --headless --path . -- --harness --scenario=first_night --ticks=12000 --out=artifacts/critic_a\`
   Read artifacts/critic_a/log.txt (errors? warnings? silence where there should be events?),
   state.json (is the world state actually rich, or empty scaffolding?), metrics.csv (do the
   numbers MOVE and mean something, or are they flat zeros?).
3. Run the VISUAL harness and LOOK at the frames with your Read tool:
   \`${GODOT} --path . --resolution 1920x1080 -- --harness --visual --scenario=first_night --out=artifacts/critic_vis\`
   Read every PNG in artifacts/critic_vis/shots/. Judge them as a player seeing a Steam page.
4. Read the code of the systems that matter (heat, grid, build, climate) and judge whether the
   depth is real or whether it is a stub wearing a costume.

SCORE 0-10 on each, where **7 = a competent indie game**, **9 = genuinely comparable to
Factorio/Frostpunk**, **10 = better than them at that specific thing**. Be stingy. A foundation
vertical slice that works honestly deserves about a 3-4, not a 7.
- foundation_solidity, simulation_depth, visual_quality, legibility, feel, determinism_and_rigor

Then name the ONE thing that most urgently has to change. Not five things. One.
Be specific and technical enough that a builder can act on it immediately.`,
  { label: 'critic-foundation', phase: 'Critic', effort: 'high', schema: {
      type: 'object',
      properties: {
        check_actually_green: { type: 'boolean' },
        game_actually_runs: { type: 'boolean' },
        scores: { type: 'object', additionalProperties: { type: 'number' } },
        overall: { type: 'number' },
        what_is_real: { type: 'string' },
        what_is_fake: { type: 'array', items: { type: 'string' }, description: 'Things that look implemented but are hollow' },
        visual_verdict: { type: 'string', description: 'Honest judgement of the actual screenshots' },
        biggest_gap: { type: 'string' },
        evidence: { type: 'array', items: { type: 'string' }, description: 'Concrete file:line or log/metric quotes backing the verdict' },
      },
      required: ['check_actually_green', 'game_actually_runs', 'scores', 'overall', 'biggest_gap', 'what_is_fake'],
    } })

return { built: ok, integration, critic }
