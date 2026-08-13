class_name CameraTuning
extends RefCounted
## Every number that decides how the camera feels, in one place.
##
## All pan speeds and accelerations are **screen** units (px/s, px/s²) and get divided
## by zoom before they touch world space. That is the whole trick behind "the camera
## feels the same at every zoom level": a key press always moves the world across the
## screen at the same rate, whether you are staring at one workshop or the whole plain.

const TILE_SIZE: int = 32
const CHUNK_TILES: int = 32

# --- zoom ---------------------------------------------------------------------
## Furthest out. 0.22 → a 32 px tile is ~7 px: districts read as blocks, not buildings.
var zoom_min: float = 0.22
## Closest in. 3.0 → a tile is 96 px: single-belt inspection.
var zoom_max: float = 3.0
var zoom_default: float = 1.0
## One wheel notch in log space. exp(0.18) ≈ 1.197× per notch.
var zoom_step: float = 0.18
## Half-life of the exponential approach to the target zoom. Short = crisp.
## Sized so a wheel notch is fully settled inside half a second — an exponential
## never arrives on its own, so the epsilon below has to be able to catch it.
var zoom_smooth_halflife: float = 0.05
## Below this distance in log space the zoom snaps and the anchor is released.
## 0.0015 in log space is 0.15% of the zoom level: invisible, and it guarantees
## the snap fires well before the 0.5 s settle deadline instead of just after it.
var zoom_snap_epsilon: float = 0.0015

# --- pan ----------------------------------------------------------------------
var pan_speed: float = 1450.0
var pan_accel: float = 11000.0
## Glide after releasing the pan keys. Short enough that it never feels floaty:
## full speed dies in ~0.28 s over ~120 px, which reads as weight, not drift.
var pan_release_halflife: float = 0.06
## Glide after throwing the map with a middle-mouse drag. Slightly longer: it is a throw.
var drag_release_halflife: float = 0.16
## Smoothing of the measured drag velocity, so one jittery mouse frame cannot fling the map.
var drag_velocity_halflife: float = 0.045
## Below this screen speed a glide is over. Prevents infinite creeping.
var glide_stop_speed: float = 45.0
var max_throw_speed: float = 3600.0

# --- edge scroll --------------------------------------------------------------
var edge_margin: float = 14.0
var edge_speed_scale: float = 0.85

# --- focus / pan-to -----------------------------------------------------------
var focus_min_duration: float = 0.18
var focus_max_duration: float = 0.80
## Bigger = slower focus for the same distance. Tuned against sqrt(screen distance).
var focus_distance_divisor: float = 45.0

# --- shake --------------------------------------------------------------------
var shake_max_offset_px: float = 26.0
var shake_max_roll: float = 0.02
var shake_default_frequency: float = 22.0
## trauma^exponent. 2 keeps small hits subtle and big hits violent.
var shake_exponent: float = 2.0

# --- readability thresholds ----------------------------------------------------
## Levels, matching GameCamera.DetailLevel: 0 close, 1 normal, 2 far, 3 strategic.
const DETAIL_CLOSE: int = 0
const DETAIL_NORMAL: int = 1
const DETAIL_FAR: int = 2
const DETAIL_STRATEGIC: int = 3

var detail_close: float = 1.0
var detail_normal: float = 0.55
var detail_far: float = 0.32
## Relative dead-band around a threshold so a hovering zoom cannot strobe the overlays.
var detail_hysteresis: float = 0.05

# --- selection ----------------------------------------------------------------
## Mouse travel above which a click becomes a box-select.
var drag_threshold_px: float = 5.0

# --- bounds -------------------------------------------------------------------
## Replaced by the real world extent as soon as the grid system reports one.
var default_bounds: Rect2 = Rect2(-8192.0, -8192.0, 16384.0, 16384.0)


## Boundary zoom between `level` and the next level out. Level 3 has no boundary below it.
func detail_threshold(level: int) -> float:
	match level:
		DETAIL_CLOSE: return detail_close
		DETAIL_NORMAL: return detail_normal
	return detail_far


## Readability band for a zoom, ignoring history. Use for initial state.
func detail_level_for(z: float) -> int:
	if z >= detail_close:
		return DETAIL_CLOSE
	if z >= detail_normal:
		return DETAIL_NORMAL
	if z >= detail_far:
		return DETAIL_FAR
	return DETAIL_STRATEGIC


## Next readability band given where we already are. A zoom parked exactly on a threshold
## must not flip back and forth, so a level is only left once the zoom clears the boundary
## by `detail_hysteresis`.
func detail_level_step(z: float, current: int) -> int:
	var level: int = clampi(current, DETAIL_CLOSE, DETAIL_STRATEGIC)
	while level < DETAIL_STRATEGIC and z < detail_threshold(level) * (1.0 - detail_hysteresis):
		level += 1
	while level > DETAIL_CLOSE and z > detail_threshold(level - 1) * (1.0 + detail_hysteresis):
		level -= 1
	return level


## Frame-rate independent exponential approach: after `halflife` seconds the gap halves.
static func approach(from: float, to: float, dt: float, halflife: float) -> float:
	if halflife <= 0.0:
		return to
	var k: float = pow(0.5, dt / halflife)
	return to + (from - to) * k


static func approach_vec(from: Vector2, to: Vector2, dt: float, halflife: float) -> Vector2:
	if halflife <= 0.0:
		return to
	var k: float = pow(0.5, dt / halflife)
	return to + (from - to) * k


## Ken Perlin's smootherstep. Zero first and second derivative at both ends, which is
## why a focus move starts and stops without a visible kick.
static func smootherstep(t: float) -> float:
	var x: float = clampf(t, 0.0, 1.0)
	return x * x * x * (x * (x * 6.0 - 15.0) + 10.0)
