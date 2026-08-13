export const meta = {
  name: 'lcn-phase-a-resume',
  description: 'Resume Phase A at the Integrate + Critic stages (builders already landed on disk)',
  phases: [
    { title: 'Audit', detail: 'independently audit what the 7 builders actually left on disk' },
    { title: 'Integrate', detail: 'make it green, playable and visually real' },
    { title: 'Critic', detail: 'fresh harsh critic judges the running build only' },
  ],
}

const ROOT = '/Users/maximilianthuemmler/Documents/last-city-nightfall'
const GODOT = '/Applications/Godot.app/Contents/MacOS/Godot'

const CTX = `Project: **Last City: Nightfall**, a Tower Defense x City Builder x Automation game for
STEAM, built in **Godot 4.7.1**, GDScript, 2D top-down. The bar is Factorio and Frostpunk.

REPO: ${ROOT}   GODOT: ${GODOT}
Read ${ROOT}/docs/ARCHITECTURE.md first. It is the binding contract.

CONTEXT ON STATE: seven agents built the foundation in parallel. Their final written reports were
LOST when the host process died, but all their code is on disk and committed (git log: "Phase A
build stage"). So there are no summaries to trust — only the code and what it actually does when
run. That is the correct situation to be in.

Present and ticking: game/sim/grid, game/sim/climate, game/sim/heat, game/sim/build,
game/view/render, game/view/camera, tests/ (own framework + scenarios).
Deliberately NOT built yet (these are the next wave, do not build them): logistics, production,
citizens, society, threat, combat, research.

VERIFIED BASELINE (I ran this myself just now, it is true):
  ${GODOT} --headless --path . -- --harness --scenario=smoke --out=artifacts/x   ->  exit 0
  256x256 map generated in 204ms, 55113 walkable cells, 5 chokepoints, 21 building defs loaded,
  heat reports climate=true build=true grid=true, 4 systems ticking.`

phase('Audit')
const AUDIT_SCHEMA = {
  type: 'object',
  properties: {
    area: { type: 'string' },
    real_depth: { type: 'string', description: 'What is genuinely implemented, with file:line evidence' },
    hollow: { type: 'array', items: { type: 'string' }, description: 'What looks implemented but is a stub or a lie' },
    broken: { type: 'array', items: { type: 'string' }, description: 'Actual defects found by running or reading' },
    contract_violations: { type: 'array', items: { type: 'string' }, description: 'Determinism / typing / ownership / logging rule breaks' },
    integration_gaps: { type: 'array', items: { type: 'string' }, description: 'APIs that do not line up between parts' },
    score_0_10: { type: 'number' },
  },
  required: ['area', 'real_depth', 'hollow', 'broken', 'contract_violations', 'score_0_10'],
}

const AUDITS = [
  { key: 'sim', label: 'audit:sim-depth', focus: `the SIMULATION: game/sim/grid, game/sim/climate, game/sim/heat, game/sim/build.
Read the code properly. Is the heat network a real flow solve with pressure, loss and brownout
cascade, or a fake? Is the grid flow-field real and does it scale? Is the climate curve real?
Is the blueprint system real (capture, stamp, rotate, mirror, book) or a shell? Check determinism
rule breaks (randf, Time.get_ticks_msec, unsorted Dictionary iteration affecting state) with grep.` },
  { key: 'view', label: 'audit:view-visual', focus: `the PRESENTATION: game/view/render and game/view/camera.
Critically: does the game actually RENDER anything? Run the visual harness yourself and LOOK:
  ${GODOT} --path . --resolution 1920x1080 -- --harness --visual --scenario=smoke --out=artifacts/audit_vis
NOTE: the harness does not auto-quit in visual mode, so run it with a timeout, e.g. prefix with
\`timeout 90\`, then read the PNGs in artifacts/audit_vis/shots/ with your Read tool.
If no PNG is produced, that is the single most important finding — say so loudly and diagnose why.
Judge the shaders, palette, lighting and sprite factory as a player would judge a Steam page.` },
  { key: 'rig', label: 'audit:test-rig', focus: `the TEST RIG and its honesty: tests/, tools/.
Run \`bash tools/check.sh\` and report the REAL result. Run the test suite directly. Do the tests
actually assert meaningful behaviour, or are they tautologies that pass no matter what? Does the
determinism checker really detect a divergence (try breaking something temporarily and confirm it
catches it, then restore). Does the perf gate produce real numbers? A test rig that always says
green is worse than no test rig.` },
]

const audits = await parallel(AUDITS.map(a => () => agent(`${CTX}

YOU ARE AN INDEPENDENT AUDITOR with fresh eyes. You did not write any of this code and you owe it
no loyalty. Your job is to find out what is REAL and what is theatre.

AUDIT SCOPE: ${a.focus}

Method: read the actual code, run the actual build, check the actual outputs. Cite file:line or
quote real command output for every claim you make. Do not write or modify game code — you are
auditing, not fixing (you may create temporary files under /tmp and must revert any experiment).
Score 0-10 where 7 = competent indie, 9 = Factorio/Frostpunk tier, 10 = better. Be stingy.`,
  { label: a.label, phase: 'Audit', effort: 'high', schema: AUDIT_SCHEMA })))

const A = audits.filter(Boolean)
log(`Audits complete: ${A.map(x => `${x.area}=${x.score_0_10}`).join(', ')}`)

phase('Integrate')
const integration = await agent(`${CTX}

YOU ARE THE INTEGRATOR and you have write access to the WHOLE repo, including game/core/ and
project.godot. You are the only agent with that.

Three independent auditors just examined the build. Their findings:
${A.map(x => `
### ${x.area} (scored ${x.score_0_10}/10)
REAL: ${x.real_depth}
HOLLOW: ${(x.hollow || []).join(' | ') || 'none'}
BROKEN: ${(x.broken || []).join(' | ') || 'none'}
CONTRACT VIOLATIONS: ${(x.contract_violations || []).join(' | ') || 'none'}
INTEGRATION GAPS: ${(x.integration_gaps || []).join(' | ') || 'none'}`).join('\n')}

Verify their claims against the code yourself before acting — auditors are also fallible.

YOUR MANDATE, in priority order:
1. **Make the game visually real and playable.** This is the top priority. When a human runs the
   game they must see: a generated frozen map, buildings they can place, warm light pooling around
   heat sources, snow, and a day that visibly turns to night. Create/repair the main game scene
   that assembles world + renderer + camera + a minimal placement interaction, and make
   project.godot point at it. Right now boot.tscn is a bare Node — that is not a game.
2. **Fix every contract violation and integration gap** the auditors found that you confirm.
   Where two parts disagree on an API, choose the better design and fix the caller.
3. **Make \`bash tools/check.sh\` genuinely GREEN**, and make sure it would go RED if something
   actually broke. A gate that cannot fail is worthless.
4. **Fix the harness visual-mode hang**: game/core/harness.gd never quits in visual mode, so
   automated screenshot runs hang forever. Add a clean shutdown after the last shot (keep a flag
   like --stay-open for a human who wants to keep playing). Every later critic depends on this.
5. Produce a real visual proof run and LOOK at it yourself with your Read tool:
   \`timeout 120 ${GODOT} --path . --resolution 1920x1080 -- --harness --visual --scenario=first_night --out=artifacts/integrate\`
   Iterate until the frames show an actual game, not a black screen.
6. Commit (git -c user.email=claude@local -c user.name=claude).
7. Append a progress line to ${ROOT}/progress/events.jsonl (append only, >>).

Report only what you verified by running. Be honest about what is still hollow.`,
  { label: 'integrator', phase: 'Integrate', effort: 'high', schema: {
      type: 'object',
      properties: {
        check_green: { type: 'boolean' },
        gate_can_actually_fail: { type: 'boolean' },
        renders_real_frames: { type: 'boolean' },
        shots: { type: 'array', items: { type: 'string' } },
        fixes_applied: { type: 'array', items: { type: 'string' } },
        what_a_player_now_sees: { type: 'string' },
        still_hollow: { type: 'array', items: { type: 'string' } },
      },
      required: ['check_green', 'renders_real_frames', 'what_a_player_now_sees', 'still_hollow', 'fixes_applied'],
    } })

phase('Critic')
const critic = await agent(`You are a RUTHLESS game critic with FRESH EYES and zero investment in this codebase. You have
shipped and reviewed games at the level of Factorio and Frostpunk. You are not here to encourage.

Project: "Last City: Nightfall" at ${ROOT} — Tower Defense x City Builder x Automation, Godot 4.7,
targeting Steam. It is at the end of its FOUNDATION phase: grid, climate, heat, build/blueprints,
rendering, camera and a test rig exist. Logistics, production, citizens, society, threat, combat
and research deliberately do not exist yet.

**YOU MUST NOT READ ANY BUILDER OR INTEGRATOR SUMMARY.** Ignore progress/events.jsonl claims and
git commit messages. Judge only what you can make the actual build do with your own hands.

DO THIS, in order:
1. \`cd ${ROOT} && bash tools/check.sh\` — read the real output. Does it pass? Could it fail?
2. \`timeout 300 ${GODOT} --headless --path . -- --harness --scenario=first_night --ticks=12000 --out=artifacts/critic_a\`
   Read log.txt (errors? suspicious silence?), state.json (rich world state or empty scaffolding?),
   metrics.csv (do the numbers MOVE and mean something, or are they flat?).
3. \`timeout 150 ${GODOT} --path . --resolution 1920x1080 -- --harness --visual --scenario=first_night --out=artifacts/critic_vis\`
   Read EVERY PNG in artifacts/critic_vis/shots/ with your Read tool. Judge them the way a player
   judges a Steam store page in three seconds. If there are no PNGs, that is a damning finding.
4. Read the code of heat, grid, build and climate and decide whether the depth is real or a stub
   in a costume. Grep for determinism violations yourself.

SCORE 0-10 where **7 = a competent indie game**, **9 = genuinely comparable to Factorio/Frostpunk**,
**10 = better than them at that thing**. Be stingy. An honest working foundation is a 3-4, not a 7.
Dimensions: foundation_solidity, simulation_depth, visual_quality, legibility, feel, rigor.

Then name the ONE thing that most urgently must change next. Exactly one. Specific and technical
enough that a builder can act on it in the next hour.`,
  { label: 'critic-foundation', phase: 'Critic', effort: 'high', schema: {
      type: 'object',
      properties: {
        check_actually_green: { type: 'boolean' },
        game_actually_runs: { type: 'boolean' },
        saw_real_frames: { type: 'boolean' },
        scores: { type: 'object', additionalProperties: { type: 'number' } },
        overall: { type: 'number' },
        what_is_real: { type: 'string' },
        what_is_fake: { type: 'array', items: { type: 'string' } },
        visual_verdict: { type: 'string' },
        biggest_gap: { type: 'string' },
        evidence: { type: 'array', items: { type: 'string' } },
      },
      required: ['check_actually_green', 'game_actually_runs', 'saw_real_frames', 'scores', 'overall', 'biggest_gap', 'what_is_fake', 'visual_verdict'],
    } })

return { audits: A, integration, critic }
