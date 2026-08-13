class_name SocietyVerdict
extends RefCounted
## How a run ends, and the four warnings you get before it does.
##
## Two ways out, and neither of them is allowed to arrive without notice.
##
##   EXILE. Discontent climbs. At fifty the murmuring starts, at seventy you get
##   told, at eighty six you get told in the street, and at a hundred the crowd
##   gives you twelve hours to fix it. Get discontent back under eighty inside
##   that window and they go home. Do not, and they put you out on the ice.
##
##   DESPAIR. Hope falls. At thirty two people stop finishing sentences, at
##   twenty they stop starting them, at nine the shifts stop turning up, and at
##   zero the city holds a vigil that lasts twelve hours. Get hope back over
##   fourteen and the vigil breaks up. Do not, and the fires go out one at a
##   time and nobody relights them.
##
## Rungs re arm. Climbing back down past a warning and up through it again gives
## the warning again, because a player who fixed it once and broke it twice has
## earned being told twice.

const REARM_MARGIN: float = 6.0

## 0 none, 1 murmur, 2 warning, 3 final, 4 ultimatum or vigil.
var unrest_stage: int = 0
var despair_stage: int = 0

var ultimatum_until: int = -1
var vigil_until: int = -1

var ended: bool = false
var end_reason: String = ""
var end_tick: int = -1


func reset() -> void:
	unrest_stage = 0
	despair_stage = 0
	ultimatum_until = -1
	vigil_until = -1
	ended = false
	end_reason = ""
	end_tick = -1


func ultimatum_active() -> bool:
	return ultimatum_until >= 0


func vigil_active() -> bool:
	return vigil_until >= 0


func hours_left(tick: int, hour_ticks: int) -> float:
	if hour_ticks <= 0:
		return 0.0
	var until: int = -1
	if ultimatum_until >= 0:
		until = ultimatum_until
	if vigil_until >= 0:
		until = vigil_until if until < 0 else mini(until, vigil_until)
	if until < 0:
		return 0.0
	return maxf(0.0, float(until - tick) / float(hour_ticks))


## One step. Returns the events that fired, in order. Once `ended` is true this
## does nothing at all: the run is over and society stops shouting.
func step(hope: float, discontent: float, tick: int, hour_ticks: int,
		context: Dictionary) -> Array[Dictionary]:
	if ended:
		return []
	var events: Array[Dictionary] = []
	events.append_array(_unrest(discontent, tick, hour_ticks, context))
	if ended:
		return events
	events.append_array(_despair(hope, tick, hour_ticks, context))
	return events


# --- discontent --------------------------------------------------------------

func _unrest(d: float, tick: int, hour_ticks: int, ctx: Dictionary) -> Array[Dictionary]:
	var events: Array[Dictionary] = []
	var stage: int = _stage_up(d)

	if ultimatum_until >= 0:
		if d < SocietyDefs.UNREST_RELIEF:
			ultimatum_until = -1
			unrest_stage = 2
			events.append({
				"kind": &"ultimatum_lifted", "meter": "discontent", "stage": 2,
				"text": "The crowd outside the hall thinned and then it was gone. "
					+ "Somebody had put a stove in the square and there was nowhere left to stand and be angry.",
			})
			return events
		if tick >= ultimatum_until:
			ended = true
			end_reason = SocietyDefs.REASON_EXILE
			end_tick = tick
			events.append({
				"kind": &"game_over", "meter": "discontent", "reason": SocietyDefs.REASON_EXILE,
				"text": "They came at the end of the twelfth hour and they were not loud about it. "
					+ "You were given a coat, a lamp and four days of rations, and the gate was "
					+ "closed behind you while you were still deciding which way to walk. "
					+ "%s" % _who_hated_you(ctx),
			})
			return events
		return events

	if stage <= unrest_stage:
		if d < _rearm_line(unrest_stage):
			unrest_stage = maxi(0, unrest_stage - 1)
		return events

	unrest_stage = stage
	match stage:
		1:
			events.append({
				"kind": &"unrest", "meter": "discontent", "stage": 1,
				"text": "Talk stops when you walk past a work gang and starts again "
					+ "behind you. %s" % _worst_grievance_line(ctx),
			})
		2:
			events.append({
				"kind": &"unrest", "meter": "discontent", "stage": 2,
				"text": "A delegation came to the hall. They were polite and they had "
					+ "written it down. %s" % _worst_grievance_line(ctx),
			})
		3:
			events.append({
				"kind": &"unrest", "meter": "discontent", "stage": 3,
				"text": "There is a crowd in the square now and it does not disperse "
					+ "when it gets dark. This is the last warning you are going to get. "
					+ "%s" % _worst_grievance_line(ctx),
			})
		4:
			ultimatum_until = tick + int(round(SocietyDefs.UNREST_ULTIMATUM_HOURS * float(hour_ticks)))
			events.append({
				"kind": &"ultimatum", "meter": "discontent", "stage": 4,
				"hours": SocietyDefs.UNREST_ULTIMATUM_HOURS,
				"until_tick": ultimatum_until,
				"text": "They have given you until this time tomorrow. Nobody is "
					+ "shouting. Somebody has already opened the outer gate and left it open. "
					+ "%s" % _worst_grievance_line(ctx),
			})
	return events


func _stage_up(d: float) -> int:
	if d >= SocietyDefs.UNREST_ULTIMATUM:
		return 4
	if d >= SocietyDefs.UNREST_FINAL:
		return 3
	if d >= SocietyDefs.UNREST_WARNING:
		return 2
	if d >= SocietyDefs.UNREST_MURMUR:
		return 1
	return 0


func _rearm_line(stage: int) -> float:
	match stage:
		1: return SocietyDefs.UNREST_MURMUR - REARM_MARGIN
		2: return SocietyDefs.UNREST_WARNING - REARM_MARGIN
		3: return SocietyDefs.UNREST_FINAL - REARM_MARGIN
	return SocietyDefs.UNREST_ULTIMATUM


# --- hope --------------------------------------------------------------------

func _despair(h: float, tick: int, hour_ticks: int, ctx: Dictionary) -> Array[Dictionary]:
	var events: Array[Dictionary] = []
	var stage: int = _stage_down(h)

	if vigil_until >= 0:
		if h > SocietyDefs.DESPAIR_RELIEF:
			vigil_until = -1
			despair_stage = 2
			events.append({
				"kind": &"ultimatum_lifted", "meter": "hope", "stage": 2,
				"text": "Someone started the morning bell without being told to, "
					+ "and by the second ring there were people at the kitchens.",
			})
			return events
		if tick >= vigil_until:
			ended = true
			end_reason = SocietyDefs.REASON_DESPAIR
			end_tick = tick
			events.append({
				"kind": &"game_over", "meter": "hope", "reason": SocietyDefs.REASON_DESPAIR,
				"text": "The vigil did not end. It simply got quieter, and then the "
					+ "second shift did not come out, and then the first. The generator "
					+ "ran until its bunker was empty because there was nobody left who "
					+ "thought it was worth filling.",
			})
			return events
		return events

	if stage <= despair_stage:
		if h > _rearm_line_hope(despair_stage):
			despair_stage = maxi(0, despair_stage - 1)
		return events

	despair_stage = stage
	match stage:
		1:
			events.append({
				"kind": &"despair", "meter": "hope", "stage": 1,
				"text": "People have stopped asking how long this goes on for. "
					+ "That is not the same thing as being reassured.",
			})
		2:
			events.append({
				"kind": &"despair", "meter": "hope", "stage": 2,
				"text": "Two families took their bunks apart for firewood and nobody "
					+ "reported it, because everyone understood.",
			})
		3:
			events.append({
				"kind": &"despair", "meter": "hope", "stage": 3,
				"text": "The night shift was eleven people short and none of them "
					+ "were sick. They just did not come. This is the last warning.",
			})
		4:
			vigil_until = tick + int(round(SocietyDefs.DESPAIR_VIGIL_HOURS * float(hour_ticks)))
			events.append({
				"kind": &"ultimatum", "meter": "hope", "stage": 4,
				"hours": SocietyDefs.DESPAIR_VIGIL_HOURS,
				"until_tick": vigil_until,
				"text": "They are sitting in the square around the generator, all of "
					+ "them, and they are not doing anything. Give them one reason "
					+ "before the day is out.",
			})
	return events


func _stage_down(h: float) -> int:
	if h <= SocietyDefs.DESPAIR_VIGIL:
		return 4
	if h <= SocietyDefs.DESPAIR_FINAL:
		return 3
	if h <= SocietyDefs.DESPAIR_WARNING:
		return 2
	if h <= SocietyDefs.DESPAIR_MURMUR:
		return 1
	return 0


func _rearm_line_hope(stage: int) -> float:
	match stage:
		1: return SocietyDefs.DESPAIR_MURMUR + REARM_MARGIN
		2: return SocietyDefs.DESPAIR_WARNING + REARM_MARGIN
		3: return SocietyDefs.DESPAIR_FINAL + REARM_MARGIN
	return SocietyDefs.DESPAIR_VIGIL


# --- prose helpers -----------------------------------------------------------

func _worst_grievance_line(ctx: Dictionary) -> String:
	var line: String = String(ctx.get("worst_grievance", ""))
	return "It is about the same thing it has been about all week." if line == "" else line


func _who_hated_you(ctx: Dictionary) -> String:
	var who: String = String(ctx.get("angriest_faction", ""))
	if who == "":
		return "Nobody spoke for you."
	return "%s did not speak for you, and nobody else volunteered." % who


func serialize(tick: int, hour_ticks: int) -> Dictionary:
	return {
		"unrest_stage": unrest_stage,
		"despair_stage": despair_stage,
		"ultimatum_until": ultimatum_until,
		"vigil_until": vigil_until,
		"hours_left": snappedf(hours_left(tick, hour_ticks), 0.01),
		"ended": ended,
		"end_reason": end_reason,
		"end_tick": end_tick,
	}


func deserialize(data: Dictionary) -> void:
	unrest_stage = int(data.get("unrest_stage", 0))
	despair_stage = int(data.get("despair_stage", 0))
	ultimatum_until = int(data.get("ultimatum_until", -1))
	vigil_until = int(data.get("vigil_until", -1))
	ended = bool(data.get("ended", false))
	end_reason = String(data.get("end_reason", ""))
	end_tick = int(data.get("end_tick", -1))
