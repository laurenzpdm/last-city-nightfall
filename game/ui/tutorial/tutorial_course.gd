class_name LcnTutorialCourse
extends RefCounted
## [P21] The lesson queue, and the rules that move it.
##
## There are exactly three ways the current lesson can change, and none of them
## is a clock:
##
##   1. THE WORLD ANSWERED IT.  `done_when` holds, so the lesson retires and the
##      queue moves to the next one the player has not been taught.
##   2. THE WORLD ANSWERED IT ALREADY.  A lesson whose condition is true the
##      moment it comes up is never shown. A player who piped their turret
##      before being told to is not told to.
##   3. THE WORLD OVERTOOK IT.  `urgent_when` holds on a later lesson, so it
##      jumps the queue — the first wave does not wait for the food chain, and a
##      guide still talking about grain while something is on the field is the
##      exact failure this part exists to avoid. When the urgent lesson retires,
##      the queue resumes underneath it.
##
## `advance()` returns true when the visible lesson changed, so the panel
## repaints on a change instead of every frame.

const CATEGORY: String = "tutorial"

var lessons: Array[LcnTutorialLesson] = []
var memory: LcnTutorialMemory = null

## Index into `lessons`, or -1 when the course is over.
var current: int = -1
## Where the queue was before an urgent lesson jumped in front of it.
var _resume_to: int = -1
## Lessons retired this session, in the order they were retired. For the log.
var retired: Array[StringName] = []


func _init(mem: LcnTutorialMemory = null) -> void:
	memory = mem if mem != null else LcnTutorialMemory.new()


## Loads every .tres in game/content/tutorial/, sorted by order then id, and
## drops any that do not validate — a broken lesson is named in the log and
## skipped rather than shown to a player as a blank card.
func load_lessons() -> void:
	lessons.clear()
	for res: Resource in Registry.all(CATEGORY):
		var lesson := res as LcnTutorialLesson
		if lesson == null:
			continue
		var problems: PackedStringArray = lesson.validate()
		if not problems.is_empty():
			Log.error("tutorial", "lesson '%s' is not usable: %s" % [
				String(lesson.id), "; ".join(problems)])
			continue
		lessons.append(lesson)
	lessons.sort_custom(func(a: LcnTutorialLesson, b: LcnTutorialLesson) -> bool:
		if a.order != b.order:
			return a.order < b.order
		return String(a.id) < String(b.id))


func size() -> int:
	return lessons.size()


func lesson_at(i: int) -> LcnTutorialLesson:
	if i < 0 or i >= lessons.size():
		return null
	return lessons[i]


func current_lesson() -> LcnTutorialLesson:
	return lesson_at(current)


func current_id() -> StringName:
	var l: LcnTutorialLesson = current_lesson()
	return l.id if l != null else &""


## 1-based position of the current lesson for the "2 of 6" line. 0 when over.
func position() -> int:
	return current + 1 if current >= 0 else 0


func finished() -> bool:
	return current < 0


## Picks the opening lesson for a fresh session. Never shows one the player has
## already been taught, and never shows one this city has already answered.
func begin(facts: LcnTutorialFacts) -> void:
	current = _next_open(-1, facts)
	_resume_to = -1


## The whole state machine. Returns true when the visible lesson changed.
func advance(facts: LcnTutorialFacts) -> bool:
	var before: int = current
	var urgent: int = _latest_urgent(facts)
	# Only ever jump FORWARD. The wave clock and the bodies on the field are
	# urgent at the same time; jumping to the LATEST of them and never back is
	# what stops two urgent lessons trading the panel four times a second.
	if urgent > current:
		if _resume_to < 0:
			_resume_to = current
		current = urgent
		return current != before
	var lesson: LcnTutorialLesson = current_lesson()
	if lesson == null:
		return false
	if not lesson.is_done(facts):
		return false
	_retire(lesson)
	if _resume_to >= 0:
		var resume: int = _resume_to
		_resume_to = -1
		current = _next_open(resume - 1, facts)
	else:
		current = _next_open(current, facts)
	return current != before


## Marks the current lesson taught and moves on without waiting for the world.
## Used by the closing card's Close button, which no condition can retire.
func dismiss_current(facts: LcnTutorialFacts) -> void:
	var lesson: LcnTutorialLesson = current_lesson()
	if lesson == null:
		return
	_retire(lesson)
	current = _next_open(current, facts)


func _retire(lesson: LcnTutorialLesson) -> void:
	retired.append(lesson.id)
	memory.remember(lesson.id)
	Log.info("tutorial", "lesson '%s' retired — the city answered it" % String(lesson.id))


## The next lesson after `from` that the player has not been taught and that the
## world has not already answered. -1 when the course is over.
func _next_open(from: int, facts: LcnTutorialFacts) -> int:
	for i: int in range(maxi(0, from + 1), lessons.size()):
		var lesson: LcnTutorialLesson = lessons[i]
		if memory.was_taught(lesson.id):
			continue
		if lesson.is_done(facts):
			# Already true, so there is nothing to teach. Remember it anyway:
			# the player demonstrably does not need this lesson.
			_retire(lesson)
			continue
		return i
	return -1


## The furthest-along lesson whose subject is happening RIGHT NOW. Furthest, not
## first: when the wave clock has run out AND something is already on the field,
## the thing to be talking about is the fight, not the countdown to it.
func _latest_urgent(facts: LcnTutorialFacts) -> int:
	var found: int = -1
	for i: int in lessons.size():
		var lesson: LcnTutorialLesson = lessons[i]
		if memory.was_taught(lesson.id) or lesson.is_done(facts):
			continue
		if lesson.is_urgent(facts):
			found = i
	return found
