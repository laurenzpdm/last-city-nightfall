extends Node
## One-directional signal bus: simulation announces, view and UI listen.
## Nothing in game/sim/** may connect to a view signal. Nothing in view/ or ui/
## may mutate sim state in a handler — request it through Sim.submit_command().

# --- world / lifecycle ---
signal world_created(seed_value: int)
signal world_ready()
signal tick_advanced(tick: int)
signal day_started(day: int)
signal night_started(day: int)
signal game_over(reason: String)

# --- construction ---
signal building_placed(id: int, kind: StringName, cell: Vector2i)
signal building_removed(id: int, cell: Vector2i)
signal building_state_changed(id: int, state: int)
signal placement_rejected(cell: Vector2i, reason: String)

# --- heat / power ---
signal network_changed(network_id: int)
signal heat_shortfall(network_id: int, deficit: float)
signal building_froze(id: int)

# --- logistics / production ---
signal item_produced(kind: StringName, amount: int)
signal machine_stalled(id: int, reason: StringName)

# --- citizens / society ---
signal citizen_died(id: int, cause: StringName)
signal hope_changed(value: float, delta: float)
signal discontent_changed(value: float, delta: float)
signal law_enacted(id: StringName)

# --- threat / combat ---
signal wave_incoming(wave: int, seconds_until: float)
signal wave_started(wave: int, strength: float)
signal wave_cleared(wave: int)
signal enemy_spawned(id: int, kind: StringName, pos: Vector2)
signal enemy_killed(id: int, pos: Vector2)
signal turret_fired(id: int, from: Vector2, to: Vector2)
signal structure_damaged(id: int, amount: float, pos: Vector2)

# --- research ---
signal research_started(id: StringName)
signal research_completed(id: StringName)
signal unlocked(id: StringName)

# --- narrative / ui ---
signal narrative_event(id: StringName, payload: Dictionary)
signal alert_raised(severity: int, key: StringName, text: String, pos: Vector2)
signal toast(text: String)

# --- view-only chatter (view ↔ ui, never sim) ---
signal camera_focus_requested(pos: Vector2)
signal overlay_mode_changed(mode: StringName)
signal build_selection_changed(kind: StringName)
signal ui_scale_changed(scale: float)
