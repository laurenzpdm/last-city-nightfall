# [P15] Feel & Juice — the timing vocabulary

**The whole game must feel like one hand made it.** That is only possible if every
part reaches for the same seven durations and the same curve library instead of
inventing a 0.25 each. This file is the vocabulary. `timing.gd` is the vocabulary
as code, `ease.gd` is the curve library, and `tween_kit.gd` is the shortest path
from "I want this to move" to "it moves the way the rest of the game moves".

Nothing in this game moves linearly. A linear tween starts at full speed and
stops at full speed, and the eye reads that as a slide rather than as a thing
with mass. If you find yourself writing `Tween.TRANS_LINEAR`, you want
`LcnEase.Kind.CUBIC_OUT`.

---

## The ladder

| rung | seconds | curve | what it is for |
|---|---|---|---|
| `FLICK` | 0.06 | `QUART_OUT` | the cursor is acknowledged: hover tint, key-down, a cell outline |
| `SNAP` | 0.12 | `EXPO_OUT` | a decision lands: a button, snap-to-grid, a tab change |
| `QUICK` | 0.20 | `CUBIC_OUT` | a small thing appears: a tooltip, a toast, a badge, an icon swap |
| `SETTLE` | 0.32 | `SETTLE` | a physical thing arrives: a building lands, a panel opens |
| `HEAVY` | 0.55 | `CUBIC_IN_OUT` | something large and consequential: a demolition, a law signed |
| `SWELL` | 0.90 | `QUART_OUT` | a value travels: a number counts up, a bar fills, a meter moves |
| `EVENT` | 2.60 | `SINE_IN_OUT` | the world turns: nightfall, a wave arriving, the hearth dying |

**The rule behind the ladder.** Anything the PLAYER caused must be visibly under
way within `FLICK` and finished by `SETTLE`, or the game feels like it is
thinking. Anything the WORLD caused may take up to `EVENT`, because the player
needs time to notice it and time to feel it.

Staggering a group (a row of icons, a pipe run): `LcnTiming.stagger(i)` — 22 ms
apart, capped at eight, so a whole group plus its own `SETTLE` still lands inside
`SWELL`. A stagger the player has to wait out has stopped being a flourish.

---

## The two families of curve

`LcnEase` holds two kinds of function and mixing them up is the usual mistake.

**Transitions** (`LINEAR` … `SMOOTHSTEP`) go from 0 to 1. They interpolate.
Several overshoot on the way, which is the point: an overshoot is what makes a
thing look like it *arrived* somewhere rather than *stopped* somewhere.

- `BACK_OUT` — overshoot and return. The single most useful curve in the file.
- `SETTLE` — most of the travel in the first third, one small bounce, then dead
  still. The placement curve.
- `ANTICIPATE` — pulls back before it goes. "This is about to happen."
- `SPRING` (`LcnEase.spring`) — for things that get interrupted constantly.

**Envelopes** (`IMPACT`, `PULSE`, `SPIKE`) describe strength over a lifetime and
do not end where they started. `IMPACT` is 1 → 0 (full on the first frame it
exists, which is what makes a flash a flash). `PULSE` is 0 → 1 → 0. `SPIKE` is a
fast attack and a long tail.

---

## The two clocks

| clock | source | freezes on pause | used by |
|---|---|---|---|
| **world** | `SimClock.seconds()` | yes | dust, sparks, rings, debris, tracers, the city breathing |
| **interface** | unscaled frame delta | no | hover, selection, tooltips, panels, counting numbers |

A world effect belongs to a simulated event, so it holds its breath when the
player pauses and runs triple at 3× — and, the reason this matters for the gate,
a harness run that advances 1400 ticks between two rendered frames ages it
correctly instead of playing seventy seconds of dust in a single frame.

Interface response must keep working while the game is paused, or the cursor
feels dead exactly when the player is thinking hardest.

---

## Accessibility is part of the vocabulary, not a switch bolted on

- `LcnTiming.decorative(s)` → **0** under `accessibility.reduce_motion`. Use it
  for anything that is only there to look good: overshoot, dust, a screen sweep.
- `LcnTiming.meaningful(s)` → **at most `SNAP`** under reduce motion. Use it for
  motion that carries the causal link between a click and its result. A panel
  still has to be *seen* to open.
- `LcnTiming.shake_scale()` folds `graphics.screen_shake` and `reduce_motion`
  together, so there are two independent ways to switch the camera off.
- `LcnTiming.hit_stop_enabled()` is separate from shake on purpose: some players
  are fine with a camera that shakes and hate one that stutters.

Under reduce motion the idle-life layer keeps the warmth and drops the movement,
because the light is information and the breathing is decoration.

---

## What is where

| file | class | what it owns |
|---|---|---|
| `ease.gd` | `LcnEase` | the curve library, pure math |
| `timing.gd` | `LcnTiming` | the ladder, the two clocks, the accessibility scaling |
| `tween_kit.gd` | `LcnTweenKit` | `pop` `fade_in` `fade_out` `slide_in` `count` `deny` `flash_modulate` |
| `impulse.gd` | `LcnImpulse` | a scalar that gets kicked and recovers; survives interruption |
| `number_ticker.gd` | `LcnNumberTicker` | a number that travels instead of snapping |
| `fx_pool.gd` | `LcnFxPool` | fixed-size, allocation-free effect storage |
| `world_fx.gd` | `LcnFeelWorldFx` | dust, rings, sparks, flashes, embers, debris, frost, tracers, stamps |
| `hover_fx.gd` | `LcnFeelHoverFx` | the hover lift, the brackets, the selection |
| `idle_life.gd` | `LcnFeelIdleLife` | the city breathing, pipes pulsing |
| `screen_fx.gd` | `LcnFeelScreenFx` | washes, edge pressure, the nightfall sweep |
| `feel_root.gd` | `LcnFeel` | the coordinator: Bus → feel, camera impulses, hit-stop |
| `feel_bootstrap.gd` | `LcnFeelBootstrap` | self-installer, via `game/content/feel/` |

## Where it draws

```
z -18   idle life        additive, between [P13]'s glow (-20) and the sprites (0)
z   5   world FX         above the sprites, below the placement ghost (60)
z   6   hover FX         above everything in the world: never occlude the cursor's target
L  61   screen FX        above the grade (60), below the lenses (62) and the HUD (65)
```

Layer 61 is the argument, not an accident. A full-frame response that sits
*under* [P13]'s post stack gets graded away at exactly the hour it matters, and
one that sits *over* [P17]'s HUD washes out the clock while the player is trying
to read it. 61 is the only slot where a wash reads at full strength and still
cannot cover a readable number — and a [P19] lens still beats it, because a
diagnosis beats a decoration. See `game/core/ui_layers.gd`.

---

## Using it from another part

```gdscript
var feel: LcnFeel = LcnFeel.instance()          # null when the view is not built
if feel != null:
    feel.shake(0.4, LcnTiming.SETTLE)           # an impact you own
    feel.world.dust(world_pos)                  # a puff you own
    feel.screen.wash(LcnPalette.DANGER, 0.3)    # a frame you own
    feel.beat.connect(_on_feel_beat)            # named beats, for audio and grade
    feel.focus_structure(id)                    # point the hover treatment at one thing
```

`focus_structure(id)` is there for [P21]'s tutorial: it aims the lift, the rim
and the brackets at a named structure regardless of where the cursor is, so the
game can say *this one* in its own visual language instead of inventing a second
highlight. `focus_structure(-1)` hands control back to the mouse.

`feel.beat(name, strength, at)` fires on: `place` `complete` `demolish` `freeze`
`deny` `hit` `kill` `select` `alert` `nightfall` `dawn` `assault` `relief` `law`
`research` `game_over`. It is a **view** signal and lives on this node rather
than on `Bus`, because `Bus` is core-owned and strictly simulation → view, while
a nightfall cue is something [P23]'s audio and [P13]'s grade both want to hang
off the same instant.

`feel.nightfall_progress()` (0..1 during the sweep) and `feel.night_pressure()`
(continuous darkness) are there so nobody has to keep a second copy of the
world's mood.

---

## The budget

The whole layer is allowed **1 ms of frame time** and is measured every 240
frames into the log (`feel: frame … | fx … | idle … | hover … | screen …`).
Three rules keep it there and all three are enforced by
`tests/feel/feel_perf.tscn`:

1. the effect pool is **fixed at construction** and never grows — a full pool
   overwrites its oldest row, so a thousand simultaneous deaths cost exactly what
   ten do;
2. nothing lives longer than `LcnTiming.MAX_EFFECT_LIFE` (3.2 s);
3. the idle-life anchor list is rebuilt twice a second, culled to the view and
   capped at 96, so the 1700-building stress city draws the same anchors as a
   90-building opening.

There is a second budget that is easier to forget: **every `Bus` handler in
`feel_root.gd` runs inside a simulation tick**, because that is where the signal
is emitted. The tick budget is 50 ms and heat already has 86% of it, so a handler
here is a bounds check and a few float writes. Anything that needs the world is
resolved once on `world_ready` and cached; turret tracers are rate-limited to one
per 60 ms and placements to six per tick, because a scenario can place a
forty-tile pipe run in a single tick and forty stamps is not forty times the feel.
