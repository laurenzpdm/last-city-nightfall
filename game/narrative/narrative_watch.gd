class_name LcnWorldWatch
extends RefCounted
## THE RULE: A CARD THAT STOPS THE WORLD MAY NOT BE ON SCREEN WHILE THE WORLD
## NEEDS WATCHING. [P22]
##
## Three rounds running, a story card sat over the middle of the screen at the
## exact moment the player needed to look at the middle of the screen. Each time
## it was MOVED — a slot, a solver, a stage director — and each time the next
## beat put it back over something else, because moving a rectangle is not a
## rule about when a rectangle may exist. `artifacts/CRIT/shots/assault.png` is
## the third one: "A Demand With a Date On It", 660 x 460 dead centre, over a
## city with ten hostiles inside the perimeter and the ATTENTION stack four rows
## deep behind it.
##
## So this file is the rule, in one place, with one answer:
##
##     WHEN THE THREAT DIRECTOR HAS A NIGHT IN PROGRESS, OR THERE IS ANYTHING
##     ALIVE AND HOSTILE INSIDE THE CITY, NOTHING THAT STOPS THE WORLD IS ON
##     SCREEN. IT WAITS. IT COMES BACK WHEN THE NIGHT IS OVER.
##
## It is not a suppression flag and it does not answer, discard or expire
## anything: [P22]'s deadline keeps running in the sim, where it belongs, and the
## card is up again the frame the last hostile goes down. What the player gets
## instead is one line in the flavour feed — low, left, out of the stage — saying
## a decision is waiting and how long it has. See `narrative_card.gd`.
##
## ── WHY THE SIM AND NOT THE HUD ──────────────────────────────────────────────
##
## [P17]'s probe already fuses this ([`_resolve_state`] switches the whole
## composition to NIGHT on it) and reading the probe would have been one line.
## It is deliberately not done that way: the probe is an interface instrument, it
## polls at 10 Hz, and the one thing this rule may never be is a frame late at
## the start of a fight. Every source below is a public accessor on a sim system,
## asked through `Sim.get_system` — which returns null for a part that is not in
## the build, so a build with no threat director gets `NONE` and behaves exactly
## as it did before this file existed.
##
## ── THE ORDER THE SOURCES ARE ASKED IN, AND WHY ──────────────────────────────
##
## The same order `LcnHarness._live_enemies()` uses, on purpose: the gate that
## decides an `assault` beat has something in the frame and the rule that decides
## a card may not be in that frame must not be able to disagree. [P07] owns the
## bodies when it is resolving; [P08] owns them when it is running the night
## itself, and says so in `current_wave_report().resolver`.
##
##   BREACH     [P08] `current_wave_report().breached` — they are inside. This is
##              the loudest state the game has and it outranks everything.
##   ASSAULT    anything alive and hostile: [P07]'s `live_enemy_count()`, else
##              [P08]'s `metrics().live`.
##   SET PIECE  [P08] `next_wave_preview().set_piece` while the wave is ACTIVE —
##              the director itself calling this night a set piece.
##   INBOUND    the last `LEAD_SECONDS` of the countdown. A modal that appears
##              twenty seconds before the wall is hit is the same defect one beat
##              earlier, and this is the window [P17] already treats as an
##              assault for the purpose of the composition.

## What the world is doing. `NONE` is the only value that lets a modal stand.
enum Watch { NONE, INBOUND, ASSAULT, SET_PIECE, BREACH }

## Names, for logs, tests and the one line the player sees.
const WATCH_NAMES: Array[String] = ["none", "inbound", "assault", "set_piece", "breach"]

## How long before a wave lands the stage is already the player's. Matches the
## 45 s [P17]'s `_resolve_state` uses to swing the whole composition to NIGHT, so
## the card standing down and the HUD leaning forward happen on the same second
## rather than eleven seconds apart.
const LEAD_SECONDS: float = 45.0


## The one question. Returns a `Watch`. Never throws, never assumes a part is in
## the build, and does not cache — it is three dictionary reads and it has to be
## right on the frame it is asked, not on the next poll.
static func watch() -> int:
	if not Sim.alive:
		return Watch.NONE
	var threat: SimSystem = Sim.get_system(&"threat")
	var combat: SimSystem = Sim.get_system(&"combat")

	var report: Dictionary = {}
	if threat != null and threat.has_method(&"current_wave_report"):
		report = threat.call(&"current_wave_report") as Dictionary
	if bool(report.get("breached", false)):
		return Watch.BREACH

	var live: int = 0
	if combat != null and combat.has_method(&"live_enemy_count"):
		live = int(combat.call(&"live_enemy_count"))
	if live <= 0 and threat != null and threat.has_method(&"metrics"):
		live = int((threat.call(&"metrics") as Dictionary).get("live", 0))
	if live <= 0 and not report.is_empty():
		live = int(report.get("live", 0))

	var preview: Dictionary = {}
	if threat != null and threat.has_method(&"next_wave_preview"):
		preview = threat.call(&"next_wave_preview") as Dictionary
	var active: bool = bool(preview.get("active", false)) or not report.is_empty()

	if active and bool(preview.get("set_piece", false)):
		return Watch.SET_PIECE
	if live > 0:
		return Watch.ASSAULT
	# An ACTIVE wave with nothing on the map yet is still a night in progress —
	# the first pack is walking in. `active` alone would also be true for the
	# handful of ticks between the last kill and the director resolving the
	# night, which is exactly when the card is allowed back, so this is the one
	# place the two are deliberately not the same test.
	if active:
		return Watch.ASSAULT
	var until: float = float(preview.get("seconds_until", -1.0))
	if bool(preview.get("known", false)) and until >= 0.0 and until <= LEAD_SECONDS:
		return Watch.INBOUND
	return Watch.NONE


## True when nothing that stops the world may be on screen.
static func needs_watching() -> bool:
	return watch() != Watch.NONE


static func name_of(w: int) -> String:
	return WATCH_NAMES[w] if w >= 0 and w < WATCH_NAMES.size() else "?"


## The half-sentence the player is shown in place of the card. Written here
## rather than in the presenter because it is the RULE explaining itself, and a
## player who loses a modal without being told why has been given a bug.
static func because(w: int) -> String:
	match w:
		Watch.BREACH:
			return "they are inside the perimeter"
		Watch.SET_PIECE:
			return "tonight is a set piece"
		Watch.ASSAULT:
			return "the city is under attack"
		Watch.INBOUND:
			return "the wave is nearly here"
		_:
			return ""
