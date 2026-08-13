# Resume here — state at end of day, 2026-08-13

> **STANDING INSTRUCTION FROM MAXIMILIAN (2026-08-13, 21:56):**
> **Stop after Phase C. Do NOT launch Phase D or any further wave without asking him first.**
> Report the Phase C result and wait.

The machine was shut down with Phase C mid-flight. Everything below is verified, not claimed.

## Where the project stands

- **110,609 lines** of GDScript across 344 files, 116 commits today, all committed.
- Godot **4.7.1**. Run the game: `/Applications/Godot.app/Contents/MacOS/Godot --path .`
- Read `docs/ARCHITECTURE.md` first. It is the binding contract for all parallel agent work.
- An autosave loop commits every 3 minutes. It does NOT survive a reboot: restart it with
  the command in "Restart background services" below.

## Scores so far (fresh critic, judging the running build, never a builder's summary)

| Round | Score | Biggest gap the critic named |
|---|---|---|
| 1 | 3.8 / 10 | Legibility: rich sim analysis, zero pixels |
| 2 | 4.2 / 10 | Nothing is reachable, and the gate cannot see it |
| 3 | not reached | Phase C died mid-flight |

Round 2's finding, reproduced by hand and still the governing problem:
the build menu is never in the scene tree (`add_child()` refused during boot's `_ready`),
`install()` swallows the failure, and boot logs success anyway. Meanwhile 768 tests report
CHECK GREEN because `Log.errors` only counts the project's own logger, so engine-level
`ERROR:` lines on stderr are invisible to the gate.

Verify it is still broken in one command:
```bash
timeout 90 /Applications/Godot.app/Contents/MacOS/Godot --path . --resolution 1280x720 \
  -- --harness --visual --scenario=smoke --out=artifacts/verify 2>&1 \
  | grep -E "busy setting up|String formatting|view installed"
```

## Phase C: what was in flight when the machine went down

10 builders launched, **0 returned**. Their partial work is on disk and committed, but none
of them finished, so treat every Phase C folder as half-built until re-verified.

| Agent | Owns | Mission |
|---|---|---|
| C1 boot seam | `game/boot.gd`, `game/core/`, all `*_bootstrap.gd` | Make every subsystem genuinely reachable; make silent install failure impossible |
| C2 gate teeth | `tools/`, `tests/framework/` | Fail the gate on engine errors; add per-scenario metric expectation bands; liveness assertions |
| C3 logistics reachable | `game/sim/logistics/` | Belts as placeable BuildingDefs, drag-to-build, real coal delivery to generators |
| C4 UI truth | `game/ui/hud/`, `game/ui/build_menu/` | Kill 68 String-formatting errors/run; stop the HUD fabricating depletion warnings |
| C5 combat repair | `game/sim/combat/`, `game/sim/threat/` | Wave 2 never ends; 43 shots in 3 days; 15.5 ms peak tick |
| P14 VFX | `game/view/vfx/` | Snow, embers, tracers, explosions, frost |
| P15 feel | `game/view/feel/` | Critic scored feel 2/10, the lowest in the build |
| P23 audio | `game/audio/` | Game is completely silent; synthesise procedurally |
| P22 narrative | `game/narrative/` | Events caused by sim state, dilemmas, 120+ flavour lines |
| P20 stats | `game/ui/stats/` | Factorio-style production graphs |

After them the workflow had queued: integrator, then a **playthrough agent** (fresh context,
plays the whole game and smooths the seams), then a **critic** and a **blind side-by-side
comparison** against Factorio and Frostpunk over 10 dimensions.

The workflow script is saved and can be relaunched or resumed:
`~/.claude/projects/-Users-maximilianthuemmler-Documents-last-city-nightfall/53281f38-c692-4ffe-9741-5ec974b64719/workflows/scripts/lcn-phase-c-wf_877b3554-175.js`
Nothing completed, so a resume would re-run everything. Prefer re-launching with prompts
updated to reflect whatever the partial work actually left behind.

## First three things to do next session

1. **Audit what Phase C actually left on disk.** Ten agents were interrupted mid-write. Run
   `bash tools/check.sh` and a visual run, and find out what is half-finished before building
   anything new.
2. **Close the reachability bug (C1) and the gate blindness (C2) before anything else.** Until
   a human can open a menu, the eleven simulation systems underneath are a simulation, not a game,
   and until the gate sees engine errors it will keep certifying broken builds as green.
3. Then re-run the judge stage: critic plus blind comparison.

## Verified wins worth protecting

- Heat solver: max-min-fair flow with per-tile throughput limits, distance loss, repeaters,
  priority load shedding and per-consumer bottleneck attribution. The critic called it deeper
  than Frostpunk's radius model. Conservation and loss verified numerically.
- Determinism: two separate processes produce byte-identical `state.json`. Verified independently.
- Performance: 36 to 122 ticks/s, 60 fps at a 1700-building city in 8 draw calls.

## Restart background services

```bash
cd ~/Documents/last-city-nightfall/progress && nohup python3 -m http.server 8731 >/dev/null 2>&1 &
cd ~/Documents/last-city-nightfall && nohup bash -c 'while true; do sleep 180; git add -A >/dev/null 2>&1 && git -c user.email=claude@local -c user.name=claude commit -qm "autosave $(date +%H:%M)" >/dev/null 2>&1; done # lcn-autosave' >/dev/null 2>&1 &
```
Live progress page: http://localhost:8731

## Unrelated work finished today

The X (Twitter) ranking work is complete and persisted at
`~/.claude/skills/x-algorithm-posting/SKILL.md`. It is calibrated against the real weights in
`github.com/xai-org/x-algorithm` (`home-mixer/params/param.rs`) and documents five widely
repeated blog claims that the source code contradicts. Nothing about it needs redoing.

## Housekeeping

- Disk was at 100% with ~3.5 GB free. Worth clearing space before Steam exports.
- `~/Documents/llm-wiki` is referenced by the global CLAUDE.md but does not exist on this machine.
