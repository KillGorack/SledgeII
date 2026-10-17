extends Node3D

@export var weapon_settings: Array[WeaponSettings] = []
@export var team: String = "team_red"

var current_weapon_index: int = 0
# Absolute timestamp (Time.get_ticks_msec(), same clock request_fire() below
# checks against), not a per-frame countdown - a countdown decremented by
# _physics_process's delta drifts against the server's wall-clock check by a
# few ms every tick (physics steps don't land at perfectly even wall-clock
# intervals), and that drift accumulates shot over shot until it crosses a
# whole cool_down and a shot lands a beat early or late - read as "cooldown's
# randomly off every few shots" before this was an absolute timestamp.
var _client_next_fire_time: float = 0.0
# Server-only: authoritative per-weapon cooldown, re-checked regardless of
# what the client claims - a modified client spamming request_fire still
# gets rejected here.
var _server_next_fire_time: Dictionary = {}
# Server-authoritative, per-weapon-index remaining ammo for physical
# (non-power) weapons - see request_fire() below for why this can't live on
# the shared WeaponSettings resource itself.
#
# Pushed to the owning client explicitly via _sync_ammo.rpc_id() below,
# NOT via a MultiplayerSynchronizer on this array - that was tried first and
# failed three different ways in a row (restricted visibility silently
# blocking every RPC on this node including request_fire itself; Array[int]
# specifically not replicating changes at all, a documented Godot bug,
# godot#74391; and finally a "Node not found" race on the synchronizer's own
# node path on spawn). A plain rpc_id() call is the same mechanism already
# proven reliable all over this project (request_fire, _play_launch_sound,
# apply_damage) - passing the array as an RPC argument sidesteps the whole
# automatic-property-replication machinery that kept breaking, rather than
# continuing to debug it. Pre-sized to weapon_settings.size() in _ready() so
# every valid index always has a real value, no .get()-with-fallback needed.
var _ammo_remaining: Array = []
# Owner-side counter tagging each fire request, so the server's spawn event
# (or rejection) can be matched back to the shot this client already
# predicted locally - see match.gd::predict_shot.
var _shot_seq: int = 0
# How far a client's claimed muzzle may sit from where the server thinks
# that barrel is before the server ignores the claim and uses its own. The
# server's view of a remote craft trails by roughly half an RTT plus the
# smoothing in movement.gd, and craft top out around 4 m/s - so this is
# generous for honest lag, while still keeping a shot from being fired from
# somewhere the craft plainly isn't.
const MUZZLE_TOLERANCE := 4.0

# The mines this craft can lay (Weapons/settings_mines/*.tres), filtered to the
# host's choices at spawn like weapon_settings. change_specials cycles
# current_mine_index. See Networking/mine_manager.gd.
@export var mine_settings: Array[MineSettings] = []
var current_mine_index: int = 0

@onready var barrel: Node3D = get_node("../Turret/Barrel")
@onready var power_node: Node3D = get_node("../power_node")
@onready var chat: Control = get_node("../Hud_InGame/Chat")


func current_mine() -> MineSettings:
	return mine_settings[current_mine_index] if current_mine_index >= 0 and current_mine_index < mine_settings.size() else null


func _ready() -> void:
	_ammo_remaining.resize(weapon_settings.size())
	for i in range(weapon_settings.size()):
		var settings := weapon_settings[i]
		_ammo_remaining[i] = settings.projectile_count_actual if settings else 0


func _physics_process(_delta: float) -> void:
	if not is_multiplayer_authority():
		return
	if weapon_settings.is_empty():
		return
	# Space/Enter are live keys while typing a chat message - see
	# chat_controller.gd::is_open, same reasoning as movement.gd.
	if chat.is_open:
		return
	# Mines are laid and blown by the server (mine_manager.gd); this is just
	# the request.
	if Input.is_action_just_pressed("change_specials", true) and not mine_settings.is_empty():
		current_mine_index = (current_mine_index + 1) % mine_settings.size()
	if Input.is_action_just_pressed("lay_mine") or Input.is_action_just_pressed("blow_mines"):
		var match_node = get_tree().get_first_node_in_group("match")
		if match_node and match_node.mines:
			if Input.is_action_just_pressed("lay_mine"):
				match_node.mines.request_lay_mine.rpc_id(1, current_mine_index)
			else:
				match_node.mines.request_blow_mines.rpc_id(1)
	# weapon_change is Tab and change_specials is Shift+Tab. Godot ignores held
	# modifiers by default, so Tab alone would also fire on Shift+Tab; exact_match
	# makes each action fire only for its own exact key combination.
	if Input.is_action_just_pressed("weapon_change", true):
		switch_weapon()
	var now = Time.get_ticks_msec() / 1000.0
	if Input.is_action_pressed("fire_weapon") and now >= _client_next_fire_time:
		var settings := weapon_settings[current_weapon_index]
		# Predicted locally off power_node's replicated current_power - same
		# "not trusted for correctness" caveat as the cooldown below, the
		# server re-checks for real in request_fire(). Skipping the RPC
		# entirely here (rather than sending it and doing nothing with the
		# rejection) is what lets is_on_cooldown() below show a steady "can't
		# fire" state instead of the trigger silently eating presses once
		# you're out - that silence was what read as "inconsistent" before
		# this existed.
		if settings.power_consumption > 0.0 and power_node.current_power < settings.power_consumption:
			return
		# Same idea for ammo - _ammo_remaining is the server's count, pushed
		# via _sync_ammo, so this only avoids predicting a shot the server is
		# certain to reject.
		if settings.projectile_count_capacity != 0 and _ammo_remaining[current_weapon_index] < settings.projectile_count:
			return
		# Client-side rate limiting only, for feel - keeps us from spamming
		# RPCs the server would reject anyway. Not trusted for correctness.
		_client_next_fire_time = now + settings.cool_down
		_shot_seq += 1
		var muzzle := _muzzle_transform(settings)
		# Client-side prediction: the shot leaves OUR barrel right now, from
		# where we actually see it, instead of a round trip later from where
		# the server thought we were. The host skips this - its own shots are
		# already the real, server-side ones with zero latency.
		if not multiplayer.is_server():
			var match_node = get_tree().get_first_node_in_group("match")
			if match_node:
				match_node.predict_shot(_shot_seq, settings.resource_path, team, muzzle)
		# Recoil belongs to whoever simulates this craft - that's us. The
		# server used to apply it to its own copy, which for any client-owned
		# craft is just a follower of the owner's transform, so client recoil
		# silently never happened.
		if settings.projectile_recoil > 0 and get_parent() is RigidBody3D:
			get_parent().apply_central_impulse(muzzle.basis.z.normalized() * settings.projectile_recoil)
		# "reverso" held at the moment of firing flips this shot's hit force
		# (push becomes pull) - the server decides what that means, see
		# collision_handler.gd::reverse_force.
		request_fire.rpc_id(1, current_weapon_index, _shot_seq, muzzle, Input.is_action_pressed("reverso"))


func _muzzle_transform(settings: WeaponSettings) -> Transform3D:
	var muzzle := barrel.global_transform
	muzzle.basis = muzzle.basis.orthonormalized()
	var forward := -muzzle.basis.z
	muzzle.origin += forward * settings.launch_offset
	return muzzle


# Client-feel only, same caveat as _client_next_fire_time itself: this is
# what actually gates the fire_weapon input above, so it's the right thing
# for a reticle to read - it already tracks whichever weapon is currently
# equipped, since cool_down is re-read from that weapon's settings every time
# a shot fires (see request below). Also true while there isn't enough power
# for the current weapon, for the same reason - the reticle shouldn't just go
# quiet. Ammo isn't factored in here (unlike power) - out of scope for this
# check, not because the client can't see it (see _ammo_remaining, now
# replicated for the HUD's own ammo readout).
func is_on_cooldown() -> bool:
	if Time.get_ticks_msec() / 1000.0 < _client_next_fire_time:
		return true
	if weapon_settings.is_empty():
		return false
	var settings := weapon_settings[current_weapon_index]
	return settings.power_consumption > 0.0 and power_node.current_power < settings.power_consumption


# Called by recon_station.gd (server-only, see its own comment) when the
# craft enters a recon station's Area3D - tops every weapon's ammo back up to
# its capacity. Power isn't touched here, same reason as ammo not being
# checked in is_on_cooldown(): the station already charges that continuously
# via power_node.gd just from being nearby.
#
# Returns whether any weapon's ammo actually went up, so recon_station.gd can
# gate its resupply sound on it - a weapon already sitting at capacity
# contributes nothing, and projectile_count_capacity == 0 ("unlimited", same
# convention as power_consumption == 0) is skipped entirely below, same as it
# always was, so power weapons never count toward this either.
func refill_ammo(station_color: int = ReconStation.StationColor.NONE) -> bool:
	var refilled: Array = _ammo_remaining.duplicate()
	var gained_ammo := false
	var station_is_mine: bool = station_color != ReconStation.StationColor.NONE and station_color == ReconStation.color_for_team(team)
	for i in range(weapon_settings.size()):
		var settings := weapon_settings[i]
		if settings and settings.projectile_count_capacity != 0:
			if settings.reload_on == WeaponSettings.ReloadOn.CAPTURED and not station_is_mine:
				continue
			if refilled[i] < settings.projectile_count_capacity:
				gained_ammo = true
			refilled[i] = settings.projectile_count_capacity
	_ammo_remaining = refilled
	_sync_ammo.rpc_id(get_multiplayer_authority(), _ammo_remaining)
	return gained_ammo


func switch_weapon() -> void:
	if weapon_settings.is_empty():
		return
	current_weapon_index = (current_weapon_index + 1) % weapon_settings.size()


@rpc("any_peer", "call_local", "reliable")
func request_fire(weapon_index: int, shot_seq: int, client_muzzle: Transform3D, reverse_force: bool = false) -> void:
	if not multiplayer.is_server():
		return
	# any_peer, so without this any client could fire ANY craft's weapon by
	# calling this on someone else's weapon_node. Only the craft's owner may.
	var sender := multiplayer.get_remote_sender_id()
	if sender != get_multiplayer_authority():
		return
	if not _try_fire(weapon_index, shot_seq, client_muzzle, sender, reverse_force):
		# Tell the shooter to take back the shot it already predicted.
		if sender != 1:
			_fire_rejected.rpc_id(sender, shot_seq)


# Server-only. Returns false if the shot is rejected for any reason.
func _try_fire(weapon_index: int, shot_seq: int, client_muzzle: Transform3D, sender: int, reverse_force: bool = false) -> bool:
	if weapon_index < 0 or weapon_index >= weapon_settings.size():
		return false
	var settings := weapon_settings[weapon_index]
	if settings == null or settings.projectile_prefab == null:
		return false
	# The spawner still needs a plain res:// string, not the Resource itself -
	# see match.gd::_create_volley for why (replication can't safely decode
	# arbitrary Objects, so every peer loads its own copy from disk by path).
	# resource_path is populated automatically for any .tres dragged into the
	# weapon_settings slot below, so this is just reading it back off, not
	# reintroducing the string typing this change was meant to get rid of.
	var path := settings.resource_path
	if path.is_empty():
		push_warning("weapon_node: weapon_settings[%d] has no resource_path (not a saved .tres?)" % weapon_index)
		return false
	# Small tolerance: the client's own clock gates its cooldown, and the
	# requests arrive with network jitter, so a shot sent exactly on time can
	# land a few ms "early" here. Without slack that rejects a perfectly
	# legitimate shot the client already predicted and shows flying.
	var now = Time.get_ticks_msec() / 1000.0 + 0.05
	var next_allowed = _server_next_fire_time.get(weapon_index, 0.0)
	if now < next_allowed:
		return false
	# Checked (and spent) before the cooldown is committed below, so a shot
	# rejected for insufficient power doesn't also cost you the cooldown - as
	# far as the weapon's concerned, nothing happened.
	if settings.power_consumption > 0.0 and not power_node.try_spend(settings.power_consumption):
		return false
	# Physical weapons (missiles, shells) spend ammo instead of power -
	# capacity 0 means unlimited, same convention as the old game. This has to
	# be its own Array rather than decrementing settings.projectile_count_actual
	# directly: weapon_settings entries are the same shared .tres Resource
	# referenced by every craft using this weapon, so writing the live count
	# onto the resource itself would drain one shared ammo pool across every
	# player instead of a separate one per craft. projectile_count_actual is
	# only ever read at _ready(), as the starting amount.
	if settings.projectile_count_capacity != 0:
		var ammo_left: int = _ammo_remaining[weapon_index]
		if ammo_left < settings.projectile_count:
			return false
		# Reassigns the whole array rather than mutating this element in
		# place - see _ammo_remaining's own comment for why.
		var updated: Array = _ammo_remaining.duplicate()
		updated[weapon_index] = ammo_left - settings.projectile_count
		_ammo_remaining = updated
		_sync_ammo.rpc_id(get_multiplayer_authority(), _ammo_remaining)
	_server_next_fire_time[weapon_index] = now - 0.05 + settings.cool_down
	var match_node = get_tree().get_first_node_in_group("match")
	if match_node == null or not match_node.has_method("spawn_projectile"):
		return false
	var server_muzzle := _muzzle_transform(settings)
	# Fire from where the shooter actually saw their barrel (that's what they
	# aimed with, and what their predicted shot is already flying from) - as
	# long as it's plausibly where the craft is.
	var muzzle := server_muzzle
	if client_muzzle.origin.distance_to(server_muzzle.origin) <= MUZZLE_TOLERANCE:
		muzzle = Transform3D(client_muzzle.basis.orthonormalized(), client_muzzle.origin)
	# The shot really left the shooter's barrel half an RTT ago - advance the
	# server's copy to match (capped, so a terrible connection can't turn
	# this into teleporting shots). 0 for the host's own shots.
	var fast_forward := 0.0
	if sender != 1:
		fast_forward = minf(match_node.peer_one_way_latency(sender), match_node.PROJECTILE_MAX_FAST_FORWARD)
	match_node.spawn_projectile(path, team, muzzle, false, sender, shot_seq, fast_forward, reverse_force)
	return true


@rpc("any_peer", "call_remote", "reliable")
func _fire_rejected(shot_seq: int) -> void:
	if multiplayer.get_remote_sender_id() != 1:
		return
	var match_node = get_tree().get_first_node_in_group("match")
	if match_node:
		match_node.reject_predicted_shot(shot_seq)


@rpc("any_peer", "call_local", "reliable")
func _sync_ammo(ammo: Array) -> void:
	# Server -> owner only. Without this a client could rpc_id(1, ...) its own
	# numbers straight into the server's authoritative ammo table.
	if multiplayer.get_remote_sender_id() != 1:
		return
	_ammo_remaining = ammo
