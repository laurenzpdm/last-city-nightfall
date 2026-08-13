export const meta = {
  name: 'lcn-phase-c',
  description: 'Phase C: make everything reachable, give the gate teeth, then VFX/feel/audio/narrative/stats',
  phases: [
    { title: 'Repair', detail: 'boot seam, gate blindness, logistics reachability, lying UI, combat stall' },
    { title: 'Present', detail: 'VFX, feel, audio, narrative, production graphs' },
    { title: 'Integrate', detail: 'one coherent build' },
    { title: 'Playthrough', detail: 'a fresh agent plays the whole game and smooths it' },
    { title: 'Judge', detail: 'critic + blind side-by-side vs Factorio and Frostpunk' },
  ],
}

const ROOT = '/Users/maximilianthuemmler/Documents/last-city-nightfall'
const GODOT = '/Applications/Godot.app/Contents/MacOS/Godot'

const PRE = `You are building **Last City: Nightfall**, a Tower Defense x City Builder x Automation game
for STEAM in **Godot 4.7.1**, GDScript, 2D top-down. The bar is Factorio and Frostpunk.

REPO: ${ROOT}   GODOT: ${GODOT}
STEP 1 MANDATORY: read ${ROOT}/docs/ARCHITECTURE.md, then game/core/*.gd.

STATE OF THE BUILD: eleven simulation systems, an overlay lens layer, a HUD, a build menu,
86k+ lines, 768 tests. Performance was just taken from 36 to 122 ticks/s with determinism intact,
and the renderer holds 60 fps at a 1700-building city in 8 draw calls.

**A FRESH CRITIC JUST SCORED IT 4.2/10 AND FOUND SOMETHING THAT INVALIDATES MOST OF IT.**
I reproduced his finding myself, by hand, so treat it as fact and not as opinion:

    ERROR: Parent node is busy setting up children, \`add_child()\` failed.
    [INFO][boot] view installed: renderer + camera + HUD + build menu + play shell
    ERROR: String formatting error   (x8 in a 30-second run, x68 in a full visual run)
    ... and tools/check.sh still reports CHECK GREEN.

His verdict, verbatim:
"Nothing you built is reachable, and the gate cannot see it. The build menu is never in the scene
tree. So the palette, tech tree, law panel, recipe browser and blueprint library do not exist in
the running game, the society system issues ultimatums demanding a law the player has no UI to
sign, and the entire logistics pillar has no command path from a human at all. Meanwhile 768 tests,
a determinism replay and a perf gate all report green, because Log.errors counts only the project's
own logger and every engine-level error is invisible. Until a human can open a menu, the eleven
systems underneath are a simulation, not a game."

Other confirmed findings you should assume are true:
- logistics.belt_lines = 0 and items_moved = 0 across all 24000 ticks of first_night. Belts are not
  BuildingDefs so they never appear in the build catalogue. The automation pillar is unreachable.
- Wave 2 never ends: enemy #5000018 born at tick 17036 is still alive at tick 24000 at full HP.
  43 shots fired and 19 kills across three whole days.
- The ATTENTION panel claims "Timber runs out in 20 seconds" while the checkpoints show timber going
  715 -> 495 -> stable. The alerts are lying to the player.
- Overlay world labels are drawn on CanvasLayer 70 and the HUD sits at 65, so world badges are
  painted straight across the clock panel in three of seven screenshots.

HARD RULES
- Write ONLY in the folders you own + your own tests/<part>/. Never touch another part's folder.
  Only the agent explicitly given game/core/ and boot may edit those. 9 other agents are working now.
- Static typing everywhere. game/sim/** stays deterministic (Rng.stream only, no wall clock, no
  frame delta, sort keys before state-affecting iteration). Log.info/warn/error, never print().
- The tick budget is 50 ms and heat already takes 86% of it. Keep your step() under 1 ms.

VERIFY YOUR OWN WORK BY RUNNING IT. Specifically, engine-level errors now count as failure:
  cd ${ROOT} && timeout 200 ${GODOT} --path . --resolution 1920x1080 -- --harness --visual --scenario=first_night --out=artifacts/\${PART} 2>&1 | grep -E "^ERROR|SCRIPT ERROR|add_child|formatting"
That grep MUST come back empty for anything you touched. Then \`bash tools/check.sh\`.
Append one JSON line to ${ROOT}/progress/events.jsonl when done (append with >>).`

const SCHEMA = {
  type: 'object',
  properties: {
    part: { type: 'string' },
    what_works: { type: 'string' },
    verified_by: { type: 'string' },
    engine_errors_remaining: { type: 'string' },
    known_gaps: { type: 'array', items: { type: 'string' } },
  },
  required: ['part', 'what_works', 'verified_by', 'known_gaps'],
}

const PARTS = [
  { key: 'C1', label: 'C1 boot seam + reachability', prompt: `${PRE}

YOUR PART: **[C1] THE BOOT SEAM — you are the most important agent in this phase.**
You own \`game/boot.gd\`, \`game/boot.tscn\`, \`game/core/\`, \`game/play/\`, and every
\`*_bootstrap.gd\` / bootstrap .tres across the project (you may edit those files in any folder,
but ONLY the bootstrap/install seam, nothing else in another part's folder).

THE JOB: make every single thing that was built actually reachable by a human playing the game.

1. Fix the add_child seam properly. \`tree.root.add_child()\` during boot's _ready is refused by
   Godot. Use \`add_child.call_deferred()\` or parent to Boot, and then WAIT for it to be in the
   tree before declaring success.
2. **Make silent failure impossible.** Every install() must return null unless
   \`node.is_inside_tree()\` is genuinely true afterwards, and boot must log an ERROR naming the
   subsystem that failed instead of printing a success line listing things that do not exist.
   The current log line "view installed: renderer + camera + HUD + build menu + play shell" was
   printed while the build menu was an orphan. That class of lie must become impossible.
3. Then AUDIT EVERY SUBSYSTEM FOR REACHABILITY and fix what you find. For each of: build palette,
   tech tree screen, law/Book of Laws screen, recipe browser, blueprint library, overlay lenses,
   stats screens, selection panel, alerts — verify by LAUNCHING THE GAME and driving it that a
   human can actually open it with a key and see it. Report the key for each.
4. Resolve the CanvasLayer ordering conflict: world-space overlays must not paint over the HUD.
   Establish and document a single layer allocation table in game/core/ that every UI part reads,
   so this cannot recur.
5. Society issues ultimatums demanding a law the player cannot sign. Make sure the law screen is
   reachable and wired to the actual signing command path.
6. Write a REACHABILITY TEST in tests/ that launches the real scene tree and asserts every
   subsystem is inside the tree and responds to its hotkey. This is the test that would have caught
   the bug that cost this project a whole phase.
Your definition of done: you personally launched the game, pressed the keys, and saw each screen.` },

  { key: 'C2', label: 'C2 gate teeth', prompt: `${PRE}

YOUR PART: **[C2] GIVE THE GATE TEETH** — you own \`tools/\`, \`tests/framework/\`, \`tests/gate/\`.

768 tests, a determinism replay and a perf gate all reported CHECK GREEN on a build where the main
menu did not exist and 68 engine errors printed per run. That is the deepest failure in this
project and it is yours to fix.

1. **Engine-level errors must fail the gate.** Godot prints \`ERROR:\` / \`SCRIPT ERROR:\` to stderr
   without touching our Log. Capture stderr in every harness and gate invocation, classify, and
   fail on it. Add an allowlist file with written justifications if some are genuinely benign, but
   default to failing.
2. **Orphan/reachability assertions**: the gate must fail if a subsystem that claims to install is
   not in the scene tree after boot. Coordinate with [C1] who is fixing the seam; you write the
   detector independently so it works even if he misses one.
3. **Emptiness assertions — the "0 belts" class.** A scenario that runs 24000 ticks while
   logistics.items_moved stays 0, or combat fires 43 shots in three days, is a failing scenario,
   not a passing one. Add per-scenario EXPECTATION blocks (min/max bands on named metrics) and fail
   when reality falls outside. Every shipped scenario gets meaningful expectations. This turns
   metrics.csv from decoration into a contract.
4. **Liveness assertions**: fail if an enemy exists for more than N ticks at full HP, if a wave
   never ends, if a resource alert contradicts the actual metric series. Generalise: the gate should
   catch "the UI says X while the data says not-X".
5. Re-verify that the determinism check and perf gate can still actually fail: break something on
   purpose in a scratch copy, confirm RED, restore. Report what you broke and what it caught.
   NOTE: a previous agent crashed Godot doing this and burned 10 minutes; do it in a COPY of the
   repo under /tmp, never in the live tree, and use a short scenario.
6. Make check.sh output a crisp, honest one-screen report. It should be impossible to read it and
   come away with a rosier impression than the truth.` },

  { key: 'C3', label: 'C3 logistics reachable', prompt: `${PRE}

YOUR PART: **[C3] MAKE THE AUTOMATION PILLAR REACHABLE** — you own \`game/sim/logistics/\`,
\`game/content/logistics/\`, and you may ADD belt/inserter/splitter .tres files to
\`game/content/buildings/\` (add only your own files, never edit someone else's).

Confirmed: logistics.belt_lines = 0 and items_moved = 0 across 24000 ticks. Belts are not
BuildingDefs, so BuildCatalog never lists them, so no human and no scenario can place one. The
Factorio half of this game is code that has never once run in anger.

1. Make every logistics piece a first-class placeable: belts, underground belts, splitters,
   inserters, and storage must appear in the build palette with proper costs, categories, icons and
   tooltips, and must be placeable by the same command path a player uses.
2. **Drag-to-build belts** the way Factorio does it: drag a path, get a line of belts with correct
   orientation at corners, auto-connecting to what it touches. This is the single most-used
   interaction in the genre and it must feel effortless.
3. Wire fuel delivery for real: heat generators must consume coal that belts and inserters actually
   deliver, so that a brownout can be caused by a logistics failure. Verify by running a scenario
   where cutting the belt causes the city to go cold, and show that in your report.
4. Fix or write scenarios that genuinely exercise it (coordinate with [C2] who is adding metric
   expectations — your scenarios must satisfy real bands, not zero).
5. Prove throughput matches the declared numbers: measure items/minute on a saturated line and
   compare against the spec in your item defs. Report both numbers.
Your definition of done: you launched the game, dragged out a belt line by hand, watched coal move
along it into a generator, and the city stayed warm because of it.` },

  { key: 'C4', label: 'C4 UI truth pass', prompt: `${PRE}

YOUR PART: **[C4] THE UI MUST STOP LYING** — you own \`game/ui/hud/\`, \`game/ui/build_menu/\`.

The interface currently tells the player things that are not true. Every one of these is confirmed:
1. **68 String formatting errors per visual run**, from vitals_widget.gd:78-81 where \`+ "..." % x\`
   binds % to the last operand. Find and fix every one of them, then grep the whole UI for the same
   pattern. Your run must produce ZERO engine errors.
2. **The depletion alerts are fabricating**: "Timber runs out in 20 seconds" printed in red while
   the checkpoints show timber going 715 -> 495 and then stable. Rewrite the projection to use a
   real measured rate over a real window, require a sustained negative trend before predicting, and
   never predict from a single sample. An alert that cries wolf trains the player to ignore the HUD,
   which is worse than having no HUD.
3. **Alert quality generally**: rank by severity, group duplicates, and write them as sentences a
   human would say. Round sensibly (never "short 0 heat/s"). Every alert must be clickable to focus
   the camera on the actual problem.
4. Take a hard look at every number the HUD shows and verify it against state.json from a real run.
   Anything that disagrees is a bug. Report the list you checked.
5. The build menu is currently an orphan node ([C1] is fixing the seam). Your job is to make sure
   that once it IS in the tree, it is genuinely good: fast keyboard-driven palette, real tooltips
   with contextual warnings, recipe browser, tech tree, law screen, blueprint library.
Verify visually: run the harness, READ your own PNGs, and confirm the HUD is legible and honest.` },

  { key: 'C5', label: 'C5 combat/threat repair', prompt: `${PRE}

YOUR PART: **[C5] COMBAT AND THREAT REPAIR** — you own \`game/sim/combat/\`, \`game/sim/threat/\`,
\`game/content/enemies/\`.

Confirmed defects:
1. **Wave 2 never ends.** Enemy #5000018 was born at tick 17036 and is still alive at tick 24000 at
   full HP 95.0. threat.state stays 'active', waves_started sticks at 2, wave 3 never arrives.
   Find the root cause (a stuck pathfinding state? an unreachable goal? a target that no longer
   exists?) and fix it properly. Add a watchdog that logs and resolves any enemy that has made no
   progress for N ticks, so this failure mode can never silently stall the campaign again.
2. **43 shots fired and 19 kills across three whole days** is not a tower defense game. Turrets are
   barely engaging. Diagnose why (no ammo? no heat? no targets in range? never staffed?) and make
   defence an actual pressure the player feels every night.
3. Combat's worst tick is 15.5 ms, the largest single spike in the build, and nobody has looked at
   it. Profile it (game/core/sim.gd now has per-system instrumentation, use it) and bring the peak
   down. Report before and after.
4. Make the night actually dangerous and legible: enemies must arrive from telegraphed directions,
   break through where you are weak, and be visibly fought off. A player must be able to tell a good
   night from a bad night without reading a number.
5. Verify by running a full campaign scenario and reporting: waves started, waves cleared, enemies
   spawned, enemies killed, damage taken, heat spent on defence, per day. The numbers must describe
   an escalating fight, not a stalled one.` },

  { key: 'P14', label: 'P14 VFX + weather', prompt: `${PRE}

YOUR PART: **[P14] VFX & Weather** — you own \`game/view/vfx/\`, \`tests/vfx/\`.
The world currently has no particles at all. Combat emits Bus.turret_fired / structure_damaged /
enemy_killed and nothing renders. Snowfall is a shader tint, not weather.

Build, all driven off Bus signals so you never touch the sim:
- Snow: real falling snow with wind, density driven by ClimateSystem's weather state, whiteout
  blizzards that genuinely reduce visibility during a Great Frost, and snow that settles.
- Fire and heat: embers rising from the hearth and every generator, heat shimmer over hot surfaces,
  smoke plumes that bend with wind and thicken with industry, sparks from working machines.
- Combat: muzzle flashes, tracers with travel time matching the sim's ballistics, impact sparks,
  flamethrower cones, explosions with debris, enemy death effects that differ per enemy type.
- Damage and decay: structural damage smoke, frost creeping visibly over freezing buildings,
  ice shatter when something breaks.
- Breath: citizens exhale visible steam in the cold. Small, and it is the kind of detail that makes
  a world feel inhabited.
PERFORMANCE IS THE CONSTRAINT: use GPUParticles2D with pooled emitters, hard caps, and aggressive
culling. The renderer currently holds 60 fps at 1700 buildings in 8 draw calls; do not squander it.
Measure your frame cost and report it. Respect Settings.graphics (snow_density) and
accessibility.reduce_motion.
VERIFY VISUALLY: run the visual harness, READ your PNGs, iterate until the world feels alive.` },

  { key: 'P15', label: 'P15 feel + juice', prompt: `${PRE}

YOUR PART: **[P15] Feel & Juice** — you own \`game/view/feel/\`, \`tests/feel/\`.
The critic scored feel **2/10**, the lowest score in the build. That is your mandate.

Feel is not decoration, it is the difference between clicking a button and placing a building.
- Placement: a satisfying settle, a dust puff, a snap, a subtle screen response. Construction should
  visibly progress and completion should land with weight.
- Destruction and damage: shake scaled to significance (use GameCamera.shake, respecting
  Settings.graphics.screen_shake and accessibility.reduce_motion), hit-stop on heavy impacts.
- Hover and selection: everything the cursor touches must respond within one frame. Buildings lift
  slightly, outlines appear, tooltips fade in with proper easing curves, never linearly.
- UI motion: panels that open with intent, numbers that count up rather than snapping, alerts that
  arrive with urgency proportional to severity.
- The night transition: dusk falling should be an EVENT the player feels, not a lerp. Coordinate
  with [P13]'s grade and [P23]'s audio through Bus signals.
- Idle life: buildings animate at rest, pipes pulse subtly with flow, the hearth breathes.
Every effect needs a real easing curve and a considered duration. Build a small tweening/easing
helper library so other parts can be consistent, and document the timing vocabulary (how long a
"snappy" response is versus a "heavy" one) so the whole game feels like one hand made it.
Measure your frame cost. VERIFY VISUALLY and be honest about whether the game now feels alive.` },

  { key: 'P23', label: 'P23 audio', prompt: `${PRE}

YOUR PART: **[P23] Audio** — you own \`game/audio/\`, \`game/content/audio/\`, \`tests/audio/\`.
The game is completely silent. Silence is why it feels like a simulation rather than a place.

You have no sound library, so SYNTHESISE your audio procedurally in code (AudioStreamGenerator or
generated AudioStreamWAV buffers written at build time) and commit the generator. Aim for a
coherent, bleak, industrial palette rather than realistic samples: this constraint can become the
art direction if you treat it seriously.
- Ambience that tracks state: wind that rises with the storm and howls in a whiteout, the low hum
  of a working city, the sound draining away as night falls and things freeze.
- The hearth: a deep, warm, ever-present fire bed that is the emotional anchor of the whole mix.
  A player should notice immediately when it weakens.
- Machines: each machine type a distinct rhythmic loop, pitched and gated by whether it is actually
  running, so the player can HEAR that their factory has stalled. This is a legibility feature.
- Combat: turret fire, impacts, enemy calls approaching out of the dark, the specific dread of
  something big.
- UI: restrained, tactile clicks and confirmations. Alerts with a severity-graded sting.
- Adaptive music: layered stems that respond to threat level, night, and hope, mixed by the sim
  state through Bus signals rather than triggered arbitrarily.
Build a proper mixer with buses (master/music/sfx/ambience) wired to Settings.audio, ducking under
alerts, distance attenuation, and voice limiting so a big fight cannot blow out the mix.
VERIFY: run the game, confirm no audio errors, and report the actual bus structure and voice counts.` },

  { key: 'P22', label: 'P22 narrative + events', prompt: `${PRE}

YOUR PART: **[P22] Narrative & Events** — you own \`game/narrative/\`, \`game/content/events/\`,
\`tests/narrative/\`.

Frostpunk is remembered for its writing. [P06] already shipped 32 laws with authored prose; your job
is everything around them.
- An event system that fires on real simulation state, never on a timer alone: a delegation arrives
  because discontent crossed a line, a scout returns because you researched the right thing, someone
  dies and their family asks for something. Events must be CAUSED, and the player must be able to
  tell what caused them.
- Dilemmas with two bad options and a visible cost on both sides. No obviously correct choice, ever.
- A campaign spine: an opening that establishes why this city exists here, escalating beats tied to
  [P09]'s Great Frosts and [P08]'s set-piece nights, and an ending that reckons with what the player
  did to survive. Frostpunk's "but at what cost" epilogue is the reference.
- Small flavour: named citizens whose deaths are reported by name, log entries, overheard lines,
  scavenger reports from the dark. Write at least 120 distinct pieces of flavour text.
- Write ALL of it in ENGLISH, bleak, specific, concrete. Never generic fantasy-grimdark. The test of
  a line is whether it could only be about THIS city on THIS night.
Content goes in game/content/events/ as .tres so Registry picks it up. Expose a clean API so [P17]'s
HUD and [P18]'s panels can present events without knowing your internals.` },

  { key: 'P20', label: 'P20 stats + graphs', prompt: `${PRE}

YOUR PART: **[P20] Statistics & Production Graphs** — you own \`game/ui/stats/\`, \`tests/stats/\`.

Factorio's production statistics screen is one of the most beloved UIs in the genre and we have
nothing like it. This is a dimension the blind comparison will judge us on directly.
- Time-series recording of every meaningful quantity: items produced and consumed per type, heat
  supply/demand/deficit, population, deaths, hope, discontent, kills, damage, research progress.
  Record efficiently in ring buffers at several resolutions (last minute / hour / whole run) so
  memory stays bounded and the sim cost stays near zero.
- A production graph screen: per-item production versus consumption over selectable windows, sortable,
  with the ability to see at a glance which item is the current bottleneck of the whole factory.
- A heat/power graph showing supply, demand and deficit over the day, with the nights shaded, so a
  player can see the shape of their survival.
- A society graph: population, deaths, hope and discontent over the campaign, annotated with the
  laws they signed and the events that happened, so the run reads as a story afterwards.
- An after-action summary at the end of each night: what was produced, what was lost, what nearly
  failed. This is the screen that makes a player say "one more day".
Read from the sim without perturbing it, and keep the recording cost under 0.2 ms/tick (measure it).
VERIFY VISUALLY: read your own PNGs and iterate until the graphs are genuinely readable and pretty.` },
]

phase('Repair')
const built = await parallel(PARTS.map(p => () => agent(p.prompt, { label: p.label, phase: p.key.startsWith('C') ? 'Repair' : 'Present', schema: SCHEMA })))
const ok = built.filter(Boolean)
log(`Phase C build: ${ok.length}/${PARTS.length} returned`)

phase('Integrate')
const integration = await agent(`${PRE}

YOU ARE THE INTEGRATOR. You alone may write anywhere. Ten agents just landed. Their claims:
${ok.map(r => `- ${r.part}: ${r.what_works}\n  gaps: ${(r.known_gaps || []).join('; ') || 'none'}`).join('\n')}

Verify everything yourself; builders are unreliable narrators about their own work.

MANDATE:
1. \`bash tools/check.sh\` GREEN **and it must now fail on engine errors**. Prove it can fail.
2. **ZERO engine errors in a full visual run.** This is the acceptance criterion for the whole
   phase. Run it and grep, and do not stop until the grep is empty.
3. Every subsystem reachable by a human: launch the game, press every key, open every screen.
   Report the actual key map you verified.
4. Resolve conflicts between the ten parts (CanvasLayer ordering, hotkey collisions, competing
   installers, audio/VFX/feel all reacting to the same Bus signals and stepping on each other).
5. Commit.
Report honestly what is still hollow.`,
  { label: 'integrator-C', phase: 'Integrate', effort: 'high', schema: {
      type: 'object',
      properties: {
        check_green: { type: 'boolean' },
        gate_fails_on_engine_errors: { type: 'boolean' },
        engine_errors_in_visual_run: { type: 'number' },
        reachable_screens: { type: 'array', items: { type: 'string' } },
        unreachable: { type: 'array', items: { type: 'string' } },
        still_hollow: { type: 'array', items: { type: 'string' } },
      },
      required: ['check_green', 'engine_errors_in_visual_run', 'reachable_screens', 'still_hollow'],
    } })

phase('Playthrough')
const playthrough = await agent(`You are a FRESH agent with no history on this project. Your job is to PLAY THE WHOLE GAME and then
smooth it into one coherent thing. You have full write access to the repo.

Project: "Last City: Nightfall" at ${ROOT}, Godot 4.7, targeting Steam. Read docs/ARCHITECTURE.md.

**PLAY IT FIRST, PROPERLY, BEFORE YOU CHANGE ANYTHING.** Launch the real game and drive it:
  ${GODOT} --path . --resolution 1920x1080
Use the harness with --stay-open if that helps, and use scripted scenarios to reach later states
quickly. Take screenshots as you go and READ them. Actually try to survive: build heat, lay belts,
staff buildings, research, sign laws, defend a night. Then keep going into later days.

Write down, as a player would: where you were confused, where you were bored, where something
looked wrong, where two systems disagreed with each other, where the game failed to tell you
something you needed, where the tone broke. Ten sessions' worth of small friction is what separates
a competent game from a great one.

THEN FIX THE SEAMS. You are explicitly authorised to make small changes anywhere to make the whole
thing cohere: consistent terminology across UI and narrative, consistent colour meaning, consistent
key bindings, consistent number formatting and units, consistent tone of voice, sensible defaults,
removing contradictions between systems, tightening the opening minutes.
Do NOT build new systems. Your job is coherence, not features.

Report: what the experience is actually like, the friction list you found, what you fixed, and the
three things that would most improve the game next.`,
  { label: 'playthrough-smoother', phase: 'Playthrough', effort: 'high', schema: {
      type: 'object',
      properties: {
        what_playing_it_is_like: { type: 'string' },
        friction_found: { type: 'array', items: { type: 'string' } },
        fixed: { type: 'array', items: { type: 'string' } },
        still_incoherent: { type: 'array', items: { type: 'string' } },
        top_three_next: { type: 'array', items: { type: 'string' } },
      },
      required: ['what_playing_it_is_like', 'friction_found', 'fixed', 'top_three_next'],
    } })

phase('Judge')
const JUDGE_CTX = `Project: "Last City: Nightfall" at ${ROOT} — Tower Defense x City Builder x Automation,
Godot 4.7, Steam target.

**YOU MUST NOT READ ANY BUILDER, INTEGRATOR OR PLAYTHROUGH SUMMARY.** Ignore progress/events.jsonl
and git commit messages entirely. Judge ONLY what you make the actual build do with your own hands.

  cd ${ROOT} && bash tools/check.sh
  timeout 400 ${GODOT} --headless --path . -- --harness --scenario=first_night --ticks=24000 --out=artifacts/j3_sim
  timeout 300 ${GODOT} --path . --resolution 1920x1080 -- --harness --visual --scenario=first_night --out=artifacts/j3_vis
Read log.txt, state.json, metrics.csv. READ EVERY PNG with your Read tool. Grep the run for
engine-level errors (^ERROR, SCRIPT ERROR) — a build that prints errors is not a shipping build.
Launch the game interactively and drive it if that helps you judge.`

const [critic, blind] = await parallel([
  () => agent(`You are a RUTHLESS game critic with FRESH EYES and zero investment in this codebase. You have
shipped and reviewed games at the level of Factorio and Frostpunk. You are not here to encourage.

${JUDGE_CTX}

Previous rounds scored 3.8 then 4.2 out of 10. The last critic's biggest gap was:
"Nothing you built is reachable, and the gate cannot see it. Until a human can open a menu, the
eleven systems underneath are a simulation, not a game."
Verify specifically whether that is now genuinely fixed. Open the menus yourself. Do not accept a
partial fix.

SCORE 0-10 where **7 = a competent indie game**, **9 = genuinely comparable to Factorio/Frostpunk**,
**10 = better than them at that thing**. Be stingy; justify every score with evidence you gathered.
Dimensions: simulation_depth, legibility, visual_quality, feel, pressure_and_pacing, cohesion, rigor.
Then name the ONE thing that most urgently must change next. Exactly one.`,
    { label: 'critic-round3', phase: 'Judge', effort: 'high', schema: {
        type: 'object',
        properties: {
          scores: { type: 'object', additionalProperties: { type: 'number' } },
          overall: { type: 'number' },
          reachability_fixed: { type: 'boolean' },
          engine_errors_seen: { type: 'number' },
          what_is_real: { type: 'string' },
          what_is_fake: { type: 'array', items: { type: 'string' } },
          visual_verdict: { type: 'string' },
          biggest_gap: { type: 'string' },
          evidence: { type: 'array', items: { type: 'string' } },
        },
        required: ['scores', 'overall', 'reachability_fixed', 'what_is_fake', 'visual_verdict', 'biggest_gap'],
      } }),

  () => agent(`You are running a BLIND SIDE-BY-SIDE COMPARISON. You have deep firsthand knowledge of Factorio and
Frostpunk: their systems, their UI, their pacing, how they look and feel in motion.

${JUDGE_CTX}

For each dimension below, compare this build directly against the reference game and declare a
winner. Judge OUR side ONLY from what you personally observed running the build and reading its
frames. Judge THEIR side from your knowledge of the actual shipped games. Do not be kind.

Dimensions:
1. automation_readability (vs Factorio)   2. factory_depth (vs Factorio)
3. base_building_feel (vs Factorio)       4. city_under_pressure (vs Frostpunk)
5. moral_weight (vs Frostpunk)            6. visual_atmosphere (vs Frostpunk)
7. ui_craft (vs both)                     8. onboarding_and_teaching (vs both)
9. moment_to_moment_feel (vs both)        10. audio (vs both)

OUTPUT FORMAT — the "comparisons" field is an ARRAY OF PLAIN STRINGS, one per dimension, each
formatted exactly like this, using " :: " as the separator:
  "automation_readability :: winner=factorio :: margin=not close :: Factorio's alt-mode draws the recipe icon on every machine so a screenshot of a base is self-documenting; ours draws nothing on machines at all"
winner must be one of: ours, factorio, frostpunk, tie.
margin must be one of: narrow, clear, not close.

Then give wins/losses/ties as counts, and name the SINGLE BIGGEST GAP across all dimensions: the one
fix that would most improve our standing. Exactly one.`,
    { label: 'blind-comparison', phase: 'Judge', effort: 'high', schema: {
        type: 'object',
        properties: {
          comparisons: { type: 'array', items: { type: 'string' } },
          wins: { type: 'number' },
          losses: { type: 'number' },
          ties: { type: 'number' },
          single_biggest_gap: { type: 'string' },
          would_a_factorio_player_keep_playing: { type: 'string' },
          would_a_frostpunk_player_feel_the_dread: { type: 'string' },
        },
        required: ['comparisons', 'wins', 'losses', 'ties', 'single_biggest_gap'],
      } }),
])

return { built: ok, integration, playthrough, critic, blind }
