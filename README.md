# Last City: Nightfall

A Tower Defense × City Builder × Automation game for Steam. Godot 4.7, GDScript, 2D top-down.

A dying city on a frozen plain. **Heat is your power grid, your morale system and your
ammunition at the same time.** Generators make it, pipes carry it, citizens die without it,
turrets burn it to fire, and every night something comes out of the dark drawn by the warmth.
You automate because you cannot click fast enough to survive.

## Status

Early and honest: **~117k lines, 11 simulation systems, currently scored 4.2/10 by its own
adversarial critics** against a stated bar of Factorio and Frostpunk. It is not a finished game.

## How it is built

Written almost entirely by AI agents working in parallel, under three rules that make that
possible:

1. **Absolute folder ownership.** Content registers by directory scan, never by editing a
   shared list, so there is nothing to merge-conflict over.
2. **Determinism.** The simulation runs at a fixed 20 Hz with seeded named RNG streams and no
   wall clock. Replays are byte-identical, verified across separate processes.
3. **Critics judge the running build, never a summary.** Every reviewer gets fresh context and
   is forbidden from reading builder reports. They run the harness and look at the actual frames.

Rule 3 exists because of a real incident: twelve builders honestly reported success, the test
gate said green, 768 tests passed, and the entire user interface was an orphan node no human
could open. Only an agent who tried to open a menu found it.

## Running it

```bash
godot --path .                                    # play
bash tools/check.sh                               # the gate
godot --headless --path . -- --harness --scenario=first_night --ticks=12000 --out=artifacts/a
godot --path . --resolution 1920x1080 -- --harness --visual --scenario=first_night --out=artifacts/vis
```

See [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) for the contract and
[docs/HANDOFF.md](docs/HANDOFF.md) for current state, known defects and what comes next.
