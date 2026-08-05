extends Node3D

## Game shell: builds the scene, drives the simulator, and turns input into cue
## strikes. Everything visible is constructed in code -- there are no art assets
## to load, and keeping the scene file empty means the table geometry can never
## drift out of sync with the collision geometry it is drawn from.

## CPU is a turn the player is not taking: the computer is looking at the table,
## lining the cue up, or about to stroke it. Deliberately its own state rather
## than a flag on AIM, so every piece of input handling has one thing to check.
enum { AIM, CHARGING, SHOOTING, PLACING, OVER, CPU }

## The simulator is stepped in fixed slices so a shot plays out identically at
## 60 or 240 fps. Frame delta only decides how many slices we run.
const SIM_STEP := 1.0 / 240.0
## A shot that has not settled in this much table time is abandoned as a foul,
## so a ball wedged somewhere can never hang the game.
const SHOT_TIMEOUT := 60.0
## Wall-clock ceiling on a shot, as a backstop to SHOT_TIMEOUT above.
##
## SHOT_TIMEOUT is measured on the table clock, which is the right measure for a
## shot that is genuinely still running -- but useless for the failure it most
## needs to catch. Two balls resting on the exact distance at which they are
## detected as touching grind out events microseconds apart: the table clock
## crawls, so it never reaches SHOT_TIMEOUT, and the turn hangs for good. Real
## time keeps running whatever the simulation thinks, so this always fires.
const SHOT_REAL_TIMEOUT_MS := 20000
const MAX_SLICES_PER_FRAME := 720
## Wall-clock ceiling on simulating a shot within one frame. The slice count
## alone does not bound the work: a slice's cost depends on how many events are
## in it, and that is unbounded on a degenerate table.
const FRAME_SIM_BUDGET_MS := 10.0

## Pixels of mouse draw-back for a full-power stroke.
const DRAW_BACK_FULL := 260.0
const FINE_AIM_RATE := 0.30        # rad/s (Q/E), also scaled by Shift
## Aim resolution is quoted as how far the *contact point* moves per pixel, not
## as an angle. An angle that feels fine potting a ball at 30 cm is hopelessly
## coarse at two metres, which is exactly where the precision is needed.
const AIM_POINT_PER_PIXEL := 0.00055
## Hold Shift for precision: one pixel then turns the cue about 0.02 degrees,
## which is what it takes to pick a specific contact point on a ball a metre away.
## Without it the smallest possible nudge is a quarter of a ball at that range.
const AIM_PRECISION := 0.12
## Metres of table travel per pixel when positioning a ball with the cursor
## captured.
const PLACE_SENSITIVITY := 0.0016
const SPIN_RATE := 1.30            # units of ball radius per second
## Pause at the edge of the legal tip area before the miscue band opens up.
const TIP_DETENT_TIME := 0.45
const ELEV_RATE := 0.65            # rad/s
const ELEV_MAX := deg_to_rad(60.0)

enum { CAM_AIM, CAM_ORBIT, CAM_TOP }

## How long the CPU is left to look at the table before it strokes, and how much
## of each frame it may spend planning. The pause is not padding: a computer that
## answers instantly reads as a script rather than an opponent, and the planner
## genuinely needs a couple of hundred milliseconds at the higher levels.
const CPU_LOOK_TIME := 0.75
const CPU_BUDGET_MS := 7.0
## How fast the cue swings round onto the shot the CPU has chosen.
const CPU_AIM_RATE := 4.0

var sim: PoolSim
var table: PoolTable
## Untyped on purpose: RulesUKPool, RulesSnooker and RulesKiller share the
## interface Main uses (reset / begin_shot / end_shot / player / ball_in_hand /
## game_over / winner / in_hand_in_d / the message signal) but are otherwise
## different games.
var rules
## The table being played on: POOL or SNOOKER. Killer uses the pool table, so
## every geometry and view decision keyed off this stays correct for it.
var game_mode: int = PoolPhys.POOL
## The game being played, which is what picks the rules engine.
var game_kind: int = PoolPhys.GAME_EIGHT_BALL
## Seats at the table. Two for everything except killer.
var player_count := 2
var audio: PoolAudio
var hud: HUD
var view: TableView
var room: RoomView
var menu: MainMenu
var ai: AIPlayer
var net: NetGame

## Seeds every rack. Sent with the match over a network so both machines shuffle
## the triangle the same way; a pool rack is randomised, and two tables that do
## not start identical never become identical.
var _match_seed := 0
var _rack_index := 0
## What the host will start once everybody has joined, and where it is listening.
var _pending_config := {}
var _host_port := NetGame.DEFAULT_PORT
## An input that arrived before this machine was ready to apply it -- almost
## always because its own copy of the previous shot was still rolling when the
## next player, whose copy had already stopped, took their turn.
##
## Held rather than dropped. The sender has already played it and will never send
## it again, so discarding one input desynchronises the frame permanently; the
## receiver only has to wait a moment for its own table to catch up.
var _pending_strokes: Array = []
## How many strokes have been played in this frame. Sent with every stroke and
## checked on arrival: in a game where both machines simulate from the same
## inputs, applying those inputs in a different order is the one thing that can
## silently produce two different tables. A stroke whose number is not the one
## due next is held, not applied.
var shot_index := 0
## Whether the cue ball has been put down for this turn. `rules.ball_in_hand`
## cannot answer that: it says the turn *began* in hand and stays true until the
## rules move on, so it is still set the moment after the ball is placed.
var _placed_this_turn := false
var _pending_place := Vector2.ZERO
var _pending_place_seat := -1

## Who is playing. `cpu[i]` is true when player i is the computer.
var cpu := [false, false]
var cpu_level: int = AIPlayer.MEDIUM
## Set false by the test harnesses, which drive the game directly and have no
## way to click through a menu.
var start_in_menu := true
var menu_open := false

var state := PLACING
var aim_dir := Vector3(0, 0, -1)
var power := 0.0
var spin := Vector2.ZERO           # (side, vertical) tip offset in units of R
var elevation := 0.0
var slow_motion := false
var show_guide := true

var _views: Array[MeshInstance3D] = []
var _rng := RandomNumberGenerator.new()
var _accum := 0.0
## Accumulated draw-back, in pixels, while the cue is being pulled.
var _draw_back := 0.0
## How long an arrow has been held against the miscue limit.
var _tip_detent := 0.0

# Cue stick.
var cue_node: Node3D
var _pullback := 0.08
var _strike_anim := 0.0

# Aim guide. The triangles are gathered here first and committed in one go --
# see _commit_guide for why.
var guide: MeshInstance3D
var guide_mesh: ImmediateMesh
var guide_mat: StandardMaterial3D
var _guide_pts := PackedVector3Array()
var _guide_cols := PackedColorArray()

# Camera.
var cam_rig: Node3D
var cam: Camera3D
## Plain int, not the enum type: it is cycled with modulo, and GDScript rightly
## objects to assigning a bare integer where an enum value is expected.
var cam_mode: int = CAM_AIM
var _orbit_yaw := 0.0
var _orbit_pitch := -0.62
var _orbit_dist := 2.6
var _aim_dist := 0.90
var _cur_pivot := Vector3.ZERO
var _cur_yaw := 0.0
var _cur_pitch := -0.30
var _cur_dist := 2.6
var _dragging := false
## The striker's aim, when the striker is on another machine. Zero means nobody
## has sent one, which is also what a fresh turn resets it to -- a cue left
## pointing where the *last* player aimed is worse than one pointing nowhere.
var _remote_aim := Vector3.ZERO
var _remote_draw := 0.0
var _aim_send_wait := 0.0
var _aim_sent_yaw := INF
var _aim_sent_draw := -1.0
## Twenty a second. The cue is swung onto whatever arrives rather than snapped,
## so this is about how quickly a change of mind shows up elsewhere, not about
## how smooth it looks.
const AIM_SEND_PERIOD := 0.05
## Which way a rightward flick of the mouse turns the aim, held through the band
## where the answer is ambiguous -- see _aim_screen_sign.
var _aim_sign := 1.0

## True until the first stroke of a rack has been played, which is what tells the
## CPU to break rather than to go looking for a pot in a solid triangle.
var _opening_shot := true
## Who breaks each rack, from the menu.
var _breaker := 0
## CPU turn: seconds left of looking at the table, and where its cue is swinging
## to. The aim is eased onto the chosen line rather than snapped, so the shot is
## readable before it is played.
var _cpu_wait := 0.0
var _cpu_aim := Vector3.ZERO
var _cpu_ready := false
## Reported once per run, so a physics failure does not become a wall of errors
## that pushes the useful part of the log out of the window.
var _reported_bad_ball := false
## Wall-clock time the current shot was struck, for SHOT_REAL_TIMEOUT_MS.
var _shot_started_ms := 0

var _place_preview := Vector3.ZERO
## Where the ball being placed is heading, in table coordinates. Tracked directly
## because with the pointer captured there is no cursor position to project.
var _place_target := Vector2.ZERO
## Traced shot prediction, recomputed only when the shot inputs change.
var _predict := {}
var _predict_dirty := true
var _predict_hop := 0.0
var _predict_at := 0.0
## Cursor captured: aiming can then sweep the whole way round without running out
## of screen. ESC hands the cursor back.
var pointer_locked := true
## How long mouse movement stays ignored after the window is focused again.
##
## A captured pointer that has been away and come back reports where it has been:
## the first motion event after tabbing in carries the whole excursion in one
## `relative`, which snapped the aim right round before anyone had touched the
## mouse. Long enough to swallow that, short enough that a deliberate movement on
## the way in is not lost.
const FOCUS_GRACE := 0.15
var _focus_grace := 0.0
## Single motion events larger than this are not a hand movement -- they are the
## window manager handing back a pointer, or a jump between screens.
const MOUSE_JUMP_MAX := 250.0


## Tabbing out of a game that has captured the pointer has to give it back, or
## the cursor is trapped in a window that is no longer in front. Godot does that
## for the *window*, but the mode is ours to restore, and restoring it a frame
## before the pointer has settled is what made coming back feel like the aim had
## been shoved.
func _notification(what: int) -> void:
	match what:
		NOTIFICATION_APPLICATION_FOCUS_OUT, NOTIFICATION_WM_WINDOW_FOCUS_OUT:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		NOTIFICATION_APPLICATION_FOCUS_IN, NOTIFICATION_WM_WINDOW_FOCUS_IN:
			_focus_grace = FOCUS_GRACE
			_apply_pointer_lock()


func _ready() -> void:
	_rng.randomize()
	_build_environment()
	_build_camera()
	_build_cue()
	_build_guide()

	audio = PoolAudio.new()
	audio.name = "Audio"
	add_child(audio)

	var layer := CanvasLayer.new()
	add_child(layer)
	hud = HUD.new()
	hud.name = "HUD"
	layer.add_child(hud)

	ai = AIPlayer.new(cpu_level)

	net = NetGame.new()
	net.name = "Net"
	add_child(net)
	net.match_started.connect(_on_net_match)
	net.stroke_received.connect(_on_net_stroke)
	net.aim_received.connect(_on_net_aim)
	net.placement_received.connect(_on_net_placement)
	net.net_message.connect(func(t: String) -> void: hud.show_message(t, "info"))
	net.disconnected.connect(_on_net_disconnected)
	net.peers_changed.connect(_on_net_peers_changed)
	# The router answers a second or two after hosting starts, so the lobby line
	# is rewritten when it does rather than being decided once and left stale.
	net.upnp_changed.connect(func(_state: int, _addr: String) -> void: _update_lobby())

	# A table is racked either way, so the menu opens over a real game rather
	# than a black screen.
	_new_game(PoolPhys.GAME_EIGHT_BALL)

	if start_in_menu:
		_open_menu(false)
	else:
		_apply_pointer_lock()


## Build (or rebuild) everything that depends on which game is being played.
## PoolPhys.configure() reshapes the ball size, table dimensions and pocket cut,
## so the table geometry and its view both have to be made again from scratch.
func _new_game(p_game: int) -> void:
	game_kind = p_game
	game_mode = PoolPhys.table_for(p_game)
	PoolPhys.configure(game_mode)

	table = PoolTable.new()
	sim = PoolSim.new(table)

	# The cue is sized from the spec too, so it has to be rebuilt with the table.
	if cue_node != null:
		cue_node.queue_free()
		cue_node = null
		_build_cue()
	if view != null:
		view.queue_free()
	view = TableView.new()
	view.name = "Table"
	add_child(view)
	view.build(table)

	# The room is sized from the table, so it is rebuilt with it.
	if room != null:
		room.queue_free()
	room = RoomView.new()
	room.name = "Room"
	add_child(room)
	room.build(table)

	# Written out rather than as a ternary: the branches are different types.
	if p_game == PoolPhys.GAME_SNOOKER:
		rules = RulesSnooker.new()
	elif p_game == PoolPhys.GAME_KILLER:
		rules = RulesKiller.new()
	else:
		rules = RulesUKPool.new()
	rules.message.connect(_on_rules_message)

	for v in _views:
		v.queue_free()
	_views.clear()

	_rack()
	hud.snooker = p_game == PoolPhys.GAME_SNOOKER
	hud.killer = p_game == PoolPhys.GAME_KILLER
	hud.players = player_count
	hud.show_message(PoolPhys.GAME_NAMES[p_game], "info")


## Start the match the menu asked for.
func start_match(config: Dictionary) -> void:
	var game := int(config.get("game", PoolPhys.GAME_EIGHT_BALL))
	# Killer is the only game that seats more than two, and the seat count has to
	# be settled before `cpu` and the breaker are read against it.
	player_count = 2
	if game == PoolPhys.GAME_KILLER:
		player_count = clampi(int(config.get("players", 4)),
			RulesKiller.MIN_PLAYERS, RulesKiller.MAX_PLAYERS)
	cpu = (config.get("cpu", []) as Array).duplicate()
	while cpu.size() < player_count:
		cpu.append(false)
	cpu.resize(player_count)
	cpu_level = int(config.get("level", AIPlayer.MEDIUM))
	ai.set_level(cpu_level)
	# A networked match carries its seed so both machines rack alike; a local one
	# takes a fresh one so successive frames are not the same frame.
	_match_seed = int(config.get("seed", randi()))
	_rack_index = 0
	shot_index = 0
	_pending_strokes.clear()
	_pending_place_seat = -1
	_breaker = clampi(int(config.get("breaker", 0)), 0, player_count - 1)
	_close_menu()
	_new_game(game)


# ---------------------------------------------------------------------------
# networked play
# ---------------------------------------------------------------------------

## Host a frame. The config is the menu's, plus the seed both machines rack from.
func host_match(config: Dictionary, port: int) -> bool:
	var seats := int(config.get("players", 2))
	_host_port = port
	if not net.host(port, seats):
		hud.show_message(net.last_error, "bad")
		return false
	hud.show_message("hosting -- waiting for players", "info")
	_pending_config = config.duplicate()
	return true


func join_match(address: String, port: int) -> bool:
	if not net.join(address, port):
		hud.show_message(net.last_error, "bad")
		return false
	return true


## Host only: everyone who is coming has arrived, so deal the frame out.
func begin_hosted_match() -> void:
	if not net.is_host():
		return
	var config := _pending_config.duplicate()
	config["seed"] = randi()
	# Seats nobody joined are played by the computer, which the host runs.
	var seat_cpu := []
	for i in range(net.seat_peer.size()):
		seat_cpu.append(net.seat_peer[i] == 0)
	config["cpu"] = seat_cpu
	config["players"] = net.seat_peer.size()
	net.start_match(config)


func _on_net_match(config: Dictionary) -> void:
	_match_seed = int(config.get("seed", 0))
	_rack_index = 0
	# `start_match` closes the menu, which is what takes every peer -- host and
	# joiners alike -- out of the lobby and on to the table together.
	start_match(config)


func _on_net_stroke(seat: int, stroke: Dictionary) -> void:
	if rules.game_over:
		return
	# Queued, not held in a single slot: a peer that falls two strokes behind --
	# which a slow frame is enough to cause -- would otherwise have the second
	# overwrite the first, and the frame would stall on a stroke that never
	# arrives again.
	_pending_strokes.append({"seat": seat, "stroke": stroke})
	_drain_pending()


func _on_net_placement(seat: int, x: float, z: float) -> void:
	if rules.game_over:
		return
	_pending_place_seat = seat
	_pending_place = Vector2(x, z)
	_drain_pending()


## Apply whatever has been waiting.
##
## Two conditions decide whether a stroke can be played, and only two: that it is
## the next stroke of the frame, and that this machine has finished simulating
## the last one. Everything else -- whose turn the local rules think it is, what
## the local state machine is showing -- is derived from those, and gating on
## derived state is what stalled a peer that was merely a frame behind. Retried
## every frame, so a stroke that cannot be played yet simply waits.
func _drain_pending() -> void:
	if rules.game_over:
		_pending_strokes.clear()
		_pending_place_seat = -1
		return

	# Advisory only, since the stroke carries the cue-ball position it was struck
	# from. This exists to show the other player moving the ball about, and
	# losing it costs nothing.
	if _pending_place_seat >= 0 and sim.is_shot_over() \
			and rules.player == _pending_place_seat and rules.ball_in_hand:
		_place_target = _pending_place
		_pending_place_seat = -1
		_apply_placement()
		_finish_placement()

	if state == SHOOTING or not sim.is_shot_over():
		return

	# Strokes already played are duplicates and are thrown away; the rest wait
	# their turn in the frame.
	while not _pending_strokes.is_empty():
		var next := -1
		for i in range(_pending_strokes.size()):
			var n: int = int(_pending_strokes[i]["stroke"].get("n", shot_index))
			if n < shot_index:
				_pending_strokes.remove_at(i)
				next = -2
				break
			if n == shot_index:
				next = i
				break
		if next == -2:
			continue                      # dropped a duplicate; look again
		if next < 0:
			return                        # nothing due yet
		var entry: Dictionary = _pending_strokes[next]
		_pending_strokes.remove_at(next)
		_apply_stroke(entry["stroke"])
		return                            # one shot at a time


## The menu asked to open a table others can join. The menu stays up: the frame
## is not dealt until the host presses "start frame", so people have time to
## arrive.
func _on_menu_host(config: Dictionary, port: int) -> void:
	if host_match(config, port):
		_update_lobby()


func _on_menu_join(address: String, port: int) -> void:
	if join_match(address, port):
		if menu != null:
			menu.set_lobby("connecting to %s ..." % address, false)


## Keep the menu's lobby line honest about who is actually here.
func _update_lobby() -> void:
	if menu == null or not net.is_active():
		return
	if net.is_host():
		var seats := net.seat_peer.size()
		var here := net.humans_connected()
		var waiting := seats - here
		menu.set_lobby("hosting on port %d -- %d of %d seats taken%s\n%s"
			% [_host_port, here, seats,
			", %d will be CPU" % waiting if waiting > 0 else "",
			_upnp_line()], true)
	else:
		menu.set_lobby("connected -- waiting for the host to start", false)


## What to tell the host about reaching them from outside the LAN.
##
## The address is the only thing a player actually has to act on, so it is the
## thing the line leads with. When the router will not play along, the line says
## what to forward rather than just that something failed -- that is the whole
## of the manual fix, and it is short.
func _upnp_line() -> String:
	# The address on this network comes first and is always shown, whatever the
	# router has to say. Anyone in the same building has to use it: sending a
	# packet to this table's *external* address means leaving the network and
	# coming back in, which plenty of routers refuse to do -- so a host that
	# advertised only the forwarded address was joinable from the internet and not
	# from the next room.
	var lan := NetGame.local_address()
	var here := "on this network: %s:%d" % [lan, _host_port] if lan != "" \
		else "on this network: this machine's address, port %d" % _host_port
	match net.upnp_status:
		NetGame.UPNP_SEARCHING:
			return "%s\nchecking whether the router will open the port ..." % here
		NetGame.UPNP_MAPPED:
			return "%s\nfrom anywhere else: %s:%d" % [here, net.external_address, _host_port]
		NetGame.UPNP_REFUSED:
			return "%s\n%s -- to play further afield, forward UDP %d to this machine." \
				% [here, net.upnp_error, _host_port]
	return here


func _on_net_peers_changed() -> void:
	_update_lobby()


func _on_net_disconnected() -> void:
	# The frame stays on screen and stays playable locally; there is nothing to
	# be gained by tearing the table down because a connection went.
	hud.show_message("disconnected -- playing on locally", "bad")


func _apply_pointer_lock() -> void:
	if menu_open:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		return
	Input.mouse_mode = Input.MOUSE_MODE_CAPTURED if pointer_locked \
		else Input.MOUSE_MODE_VISIBLE


func _enter_placing() -> void:
	state = PLACING
	# A cue ball that has just been potted is somewhere down a pocket, which is
	# no place to start measuring from and nothing to aim at. Put it on the table
	# now rather than leaving that to the first frame of mouse movement: until it
	# is back there is no legal shot to play, and on a network there is no sane
	# position to send.
	if sim.cue != null and sim.cue.is_active():
		_place_target = Vector2(sim.cue.pos.x, sim.cue.pos.z)
	else:
		_place_target = Vector2(0.0, PoolPhys.baulk_z())
	_apply_placement()


## Hand the table to whoever is next to play.
func _begin_turn() -> void:
	_placed_this_turn = false
	_remote_aim = Vector3.ZERO
	_remote_draw = 0.0
	_aim_sent_yaw = INF
	_aim_sent_draw = -1.0
	power = 0.0
	spin = Vector2.ZERO
	elevation = 0.0
	_tip_detent = 0.0
	_predict_dirty = true
	if rules.game_over:
		state = OVER
		return
	# Only the machine that owns this seat drives it. On everyone else's screen
	# the turn is something to watch: no planner, no ball to place, and every
	# input already gated by `_is_local_turn`. Without this the client would run
	# its own copy of the host's computer player and stroke the ball with it.
	if not net.controls(rules.player):
		state = AIM
	elif cpu[rules.player]:
		_begin_cpu_turn()
	elif rules.ball_in_hand:
		_enter_placing()
	else:
		state = AIM


func _is_cpu_turn() -> bool:
	if rules.game_over:
		return false
	if not cpu[rules.player]:
		return false
	# Networked: the computer is run by whoever owns that seat, which is the
	# host. Every machine watches the result, but only one decides it.
	return net.controls(rules.player)


## Is the seat now at the table one this machine plays? Always true offline.
func _is_local_turn() -> bool:
	if rules.game_over:
		return false
	return net.controls(rules.player)


# ---------------------------------------------------------------------------
# menu
# ---------------------------------------------------------------------------

func _open_menu(resumable: bool) -> void:
	if menu == null:
		var layer := CanvasLayer.new()
		layer.layer = 2
		add_child(layer)
		menu = MainMenu.new()
		menu.name = "Menu"
		layer.add_child(menu)
		menu.start_requested.connect(start_match)
		menu.host_requested.connect(_on_menu_host)
		menu.join_requested.connect(_on_menu_join)
		menu.begin_requested.connect(begin_hosted_match)
		menu.resume_requested.connect(_close_menu)
	menu.set_resumable(resumable)
	menu.visible = true
	menu_open = true
	_apply_pointer_lock()


func _close_menu() -> void:
	if menu != null:
		menu.visible = false
	menu_open = false
	_apply_pointer_lock()


# ---------------------------------------------------------------------------
# construction
# ---------------------------------------------------------------------------

func _build_environment() -> void:
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.022, 0.024, 0.030)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.36, 0.40, 0.48)
	env.ambient_light_energy = 0.13
	env.tonemap_mode = Environment.TONE_MAPPER_ACES
	env.tonemap_white = 1.8
	env.ssao_enabled = true
	# A 35 cm sampling radius is enormous next to a 5.7 cm ball: it produced broad,
	# weak shading instead of the tight dark contact patch that tells you a ball is
	# touching the cloth, which is what made them look like they were hovering.
	env.ssao_radius = 0.07
	env.ssao_intensity = 3.0
	env.ssao_power = 2.0
	env.ssao_detail = 1.0
	env.glow_enabled = true
	env.glow_intensity = 0.16
	env.glow_bloom = 0.05
	env.glow_hdr_threshold = 1.1
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)

	# The pendant lamps over the table belong to the room, and are built with it:
	# how many there are and how far apart they hang depends on which table is
	# under them.

	# Weak fill so the room and the table sides are not solid black.
	var fill := DirectionalLight3D.new()
	fill.rotation = Vector3(deg_to_rad(-58.0), deg_to_rad(38.0), 0.0)
	fill.light_energy = 0.16
	fill.light_color = Color(0.72, 0.80, 1.0)
	fill.shadow_enabled = false
	add_child(fill)


func _build_camera() -> void:
	cam_rig = Node3D.new()
	cam_rig.name = "CameraRig"
	add_child(cam_rig)
	cam = Camera3D.new()
	cam.fov = 55.0
	cam.near = 0.02
	cam.far = 60.0
	cam.position = Vector3(0.0, 0.0, _cur_dist)
	cam_rig.add_child(cam)


func _build_cue() -> void:
	cue_node = Node3D.new()
	cue_node.name = "Cue"
	add_child(cue_node)

	var shaft_mat := StandardMaterial3D.new()
	shaft_mat.albedo_color = Color(0.62, 0.44, 0.26)
	shaft_mat.roughness = 0.24
	var butt_mat := StandardMaterial3D.new()
	butt_mat.albedo_color = Color(0.16, 0.07, 0.05)
	butt_mat.roughness = 0.28
	var tip_mat := StandardMaterial3D.new()
	tip_mat.albedo_color = Color(0.30, 0.44, 0.60)
	tip_mat.roughness = 0.75

	# A cue is modelled as three tapered sections laid along local +Z, tip at
	# the origin, so positioning is just "put the tip where it strikes".
	# Radii come from the game's cue spec, so a snooker cue really is the thinner
	# stick -- and thinner is not just a look: less wood out at the end means less
	# end mass, which is why its squirt is lower too.
	var tip_r := PoolPhys.CUE_TIP_R
	var butt_r := PoolPhys.CUE_BUTT_R
	var mid_r: float = lerpf(tip_r, butt_r, 0.35)
	var half: float = PoolPhys.CUE_LENGTH * 0.5
	_add_cue_section(tip_mat, tip_r * 0.95, tip_r, 0.012, 0.0)
	_add_cue_section(shaft_mat, tip_r, mid_r, half - 0.012, 0.012)
	_add_cue_section(butt_mat, mid_r, butt_r, half, half)


func _add_cue_section(mat: Material, r_tip: float, r_butt: float, length: float,
		offset: float) -> void:
	var mi := MeshInstance3D.new()
	var c := CylinderMesh.new()
	c.top_radius = r_tip
	c.bottom_radius = r_butt
	c.height = length
	c.radial_segments = 14
	mi.mesh = c
	mi.material_override = mat
	# Rotate the cylinder's +Y onto local -Z, then push it back along +Z so the
	# thin end sits at the section's start.
	mi.rotation = Vector3(-PI * 0.5, 0.0, 0.0)
	mi.position = Vector3(0.0, 0.0, offset + length * 0.5)
	cue_node.add_child(mi)


func _build_guide() -> void:
	guide_mesh = ImmediateMesh.new()
	guide_mat = StandardMaterial3D.new()
	guide_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	guide_mat.vertex_color_use_as_albedo = true
	guide_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	guide_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	guide = MeshInstance3D.new()
	guide.name = "AimGuide"
	guide.mesh = guide_mesh
	guide.material_override = guide_mat
	add_child(guide)


# ---------------------------------------------------------------------------
# racking
# ---------------------------------------------------------------------------

## Set the balls up for a fresh rack. `reset_rules` is false for the one case
## that re-racks in the middle of a game -- the black going down on the break --
## where the rules engine has already worked out whose break it is now.
func _rack(reset_rules := true) -> void:
	for v in _views:
		v.queue_free()
	_views.clear()
	sim.balls.clear()
	sim.falling.clear()
	sim.cue = null
	sim.shot_log.clear()
	sim.sound_queue.clear()

	# Every rack is drawn from the match seed and the rack's number, so a re-rack
	# is as reproducible as the first one and needs nothing sent for it.
	_rng.seed = _match_seed + _rack_index * 7919
	_rack_index += 1

	var mesh := BallAssets.make_mesh()
	var cue_ball := PoolBall.new(0, 0)
	cue_ball.place(Vector3(0.0, 0.0, PoolPhys.HEAD_STRING_Z + (
		-0.10 if game_mode == PoolPhys.SNOOKER else 0.28)))
	sim.add_ball(cue_ball)
	_add_ball_view(mesh, 0)

	if game_mode == PoolPhys.SNOOKER:
		_rack_snooker(mesh)
	else:
		_rack_pool(mesh)

	if reset_rules:
		if game_kind == PoolPhys.GAME_KILLER:
			rules.reset(player_count)
		else:
			rules.reset()
		rules.player = _breaker
	_opening_shot = true
	aim_dir = Vector3(0, 0, -1)
	hud.winner = -1
	_sync_views()
	_begin_turn()


func _rack_pool(mesh: Mesh) -> void:
	var pos := PoolTable.rack_positions(_rng)
	var nums := PoolTable.rack_numbers(_rng)
	for i in range(15):
		var b := PoolBall.new(i + 1, nums[i])
		b.place(Vector3(pos[i].x, 0.0, pos[i].y))
		b.orient = _random_orientation()
		sim.add_ball(b)
		_add_ball_view(mesh, nums[i])


## Fifteen reds in the triangle behind the pink, then the six colours on spots.
func _rack_snooker(mesh: Mesh) -> void:
	var reds := PoolTable.snooker_red_positions()
	var id := 1
	for p in reds:
		var b := PoolBall.new(id, 1)
		b.place(Vector3(p.x + _rng.randf_range(-0.00015, 0.00015), 0.0,
			p.y + _rng.randf_range(-0.00015, 0.00015)))
		b.orient = _random_orientation()
		sim.add_ball(b)
		_add_ball_view(mesh, 1)
		id += 1
	for value in range(2, 8):
		var spot := PoolPhys.snooker_spot(value)
		var b := PoolBall.new(id, value)
		b.place(Vector3(spot.x, 0.0, spot.y))
		b.orient = _random_orientation()
		sim.add_ball(b)
		_add_ball_view(mesh, value)
		id += 1


func _random_orientation() -> Quaternion:
	return Quaternion(Vector3(_rng.randf_range(-1, 1), _rng.randf_range(-1, 1),
		_rng.randf_range(-1, 1)).normalized(), _rng.randf_range(0.0, TAU))


func _add_ball_view(mesh: Mesh, number: int) -> void:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = BallAssets.make_material(number)
	mi.name = "Ball%d" % number
	add_child(mi)
	_views.append(mi)


## Return balls to the table. Pool re-spots at the foot spot; snooker puts each
## colour back on its own spot, or the highest free spot if that one is taken.
func _respot(numbers: Array) -> void:
	# Snooker spots the highest value first, so that a colour waiting its turn in
	# the pocket does not have its own spot taken by a lower one.
	var order: Array = RulesSnooker.respot_order(numbers) \
		if game_mode == PoolPhys.SNOOKER else numbers
	for n in order:
		for b in sim.balls:
			if b.number != n or b.is_active():
				continue
			b.pocket_id = -1
			# Snooker's placement is shared with the CPU planner, which has to
			# reproduce it exactly to know where a respotted colour will land.
			var spot := RulesSnooker.respot_position(sim, n, b) \
				if game_mode == PoolPhys.SNOOKER \
				else sim.free_spot(Vector2(0.0, PoolPhys.FOOT_SPOT_Z), b)
			sim.return_to_table(b, Vector3(spot.x, 0.0, spot.y))
			break


# ---------------------------------------------------------------------------
# frame
# ---------------------------------------------------------------------------

func _process(delta: float) -> void:
	if _focus_grace > 0.0:
		_focus_grace -= delta
	if menu_open:
		# The table stays alive behind the panel, turning slowly, so the menu
		# opens onto the game rather than onto a screenshot of it.
		_orbit_yaw = wrapf(_orbit_yaw + delta * 0.10, -PI, PI)
		cam_mode = CAM_ORBIT
		sim.advance_drops(delta)
		_sync_views()
		_update_camera(delta)
		return

	# A held input can only be applied once this machine's own table has caught
	# up, so it is retried every frame rather than only on arrival.
	if net.is_active():
		_drain_pending()

	match state:
		AIM, CHARGING:
			# Only the machine playing this seat may move the cue; everyone else
			# is watching and their keys do nothing but the camera.
			if _is_local_turn():
				_update_aim_keys(delta)
		SHOOTING:
			_step_sim(delta)
		PLACING:
			if _is_local_turn():
				_update_placing()
		CPU:
			_update_cpu(delta)

	# Only outside a shot, where drops are the tail of something already judged
	# and nothing depends on exactly when they land. During the shot they are
	# stepped in `_step_sim`.
	if state != SHOOTING:
		sim.advance_drops(delta * (0.22 if slow_motion else 1.0))
	_sync_net_aim(delta)
	_animate_cue(delta)
	_sync_views()
	_update_guide()
	_update_camera(delta)
	_sync_hud()
	audio.flush(sim)


## Table time always runs at 1:1 with wall time (or at the slow-motion rate).
##
## An earlier version sped the clock up as the balls wound down, to save the
## player from watching a long slow roll. It has been removed: it is immediately
## visible as the ball apparently accelerating, which is exactly the thing this
## game must not do. Roll-out length is a physics question and is settled by
## MU_ROLL, not by cheating the clock.
func _step_sim(delta: float) -> void:
	_accum += delta * (0.22 if slow_motion else 1.0)
	var slices := 0
	# A frame is allowed only so long. A ball rattling in a pocket jaw can
	# generate events by the thousand per simulated second, and without a clock
	# here the slice loop simply does not come back: the window stops responding,
	# and an application that has stopped responding is one the system is
	# entitled to kill without saying anything. Running the shot slower than real
	# time for a moment is a far better failure than not running at all.
	var deadline := Time.get_ticks_usec() + int(FRAME_SIM_BUDGET_MS * 1000.0)
	while _accum >= SIM_STEP and slices < MAX_SLICES_PER_FRAME:
		sim.advance(SIM_STEP)
		# Stepped with the shot, in table time, not with the frame. A ball
		# falling into a pocket is part of the shot -- the rules wait for it,
		# and it can still bounce back out -- so integrating it by however long
		# the last frame happened to take makes the outcome depend on frame
		# rate. Two machines playing the same stroke then disagree about where
		# it finished.
		sim.advance_drops(SIM_STEP)
		_accum -= SIM_STEP
		slices += 1
		if sim.settled():
			_accum = 0.0
			break
		if Time.get_ticks_usec() > deadline:
			# Drop the backlog rather than owing table time we can never repay,
			# which would put the shot further behind on every frame.
			_accum = minf(_accum, SIM_STEP * 2.0)
			break
	# `is_shot_over`, not `settled`: a ball still falling through a pocket leaves
	# the table settled but the shot unfinished, and that is a state the timeout
	# has to be able to break out of too.
	var stalled: bool = Time.get_ticks_msec() - _shot_started_ms > SHOT_REAL_TIMEOUT_MS
	if (sim.shot_time > SHOT_TIMEOUT or stalled) and not sim.is_shot_over():
		sim.force_stop()
		hud.show_message("Shot timed out", "bad")
	if sim.is_shot_over():
		_predict_dirty = true
		_finish_shot()


func _finish_shot() -> void:
	var report: Dictionary = rules.end_shot(sim)
	_respot(report["respot"])
	_opening_shot = false

	if rules.game_over:
		state = OVER
		hud.winner = rules.winner
		var why: String = report["reason"]
		hud.show_message("Player %d wins%s" % [rules.winner + 1,
			("  (%s)" % why) if why != "" else ""],
			"good")
		return

	# The black on the break: the triangle goes back and it is broken again.
	if report.get("rerack", false):
		_rack(false)
		return

	_begin_turn()
	if game_kind == PoolPhys.GAME_EIGHT_BALL and not cpu[rules.player] \
			and rules.on_black(sim):
		hud.show_message("Player %d on the black" % (rules.player + 1), "info")


func _update_aim_keys(delta: float) -> void:
	var turn := 0.0
	if Input.is_key_pressed(KEY_Q):
		turn += 1.0
	if Input.is_key_pressed(KEY_E):
		turn -= 1.0
	if turn != 0.0:
		var rate := FINE_AIM_RATE
		if Input.is_key_pressed(KEY_SHIFT):
			rate *= AIM_PRECISION
		aim_dir = aim_dir.rotated(Vector3.UP, turn * rate * delta)
		_predict_dirty = true

	var d := Vector2.ZERO
	if Input.is_key_pressed(KEY_LEFT):
		d.x -= 1.0
	if Input.is_key_pressed(KEY_RIGHT):
		d.x += 1.0
	if Input.is_key_pressed(KEY_UP):
		d.y += 1.0
	if Input.is_key_pressed(KEY_DOWN):
		d.y -= 1.0
	if d != Vector2.ZERO:
		_predict_dirty = true
		var next := spin + d * SPIN_RATE * delta
		var legal := PoolPhys.MAX_TIP_OFFSET
		# Detent at the miscue limit. Holding an arrow used to run the tip straight
		# out to MISCUE_LIMIT, which is the worst place it can possibly be -- a
		# stroke there delivers a fraction of its power. Reaching for maximum draw
		# should land on maximum *legal* draw; going past it has to be deliberate.
		if next.length() > legal:
			if spin.length() <= legal + 1.0e-6 and _tip_detent < TIP_DETENT_TIME:
				_tip_detent += delta
				next = next.normalized() * legal
			elif next.length() > PoolPhys.MISCUE_LIMIT:
				next = next.normalized() * PoolPhys.MISCUE_LIMIT
		else:
			_tip_detent = 0.0
		spin = next
	else:
		_tip_detent = 0.0

	var e := 0.0
	if Input.is_key_pressed(KEY_W):
		e += 1.0
	if Input.is_key_pressed(KEY_S):
		e -= 1.0
	if e != 0.0:
		elevation = clampf(elevation + e * ELEV_RATE * delta, 0.0, ELEV_MAX)
		_predict_dirty = true


# ---------------------------------------------------------------------------
# the computer's turn
# ---------------------------------------------------------------------------

## Put the cue ball down if the CPU has it in hand, then set it thinking. The
## placement is decided in one go -- it is a geometry search, not a simulation --
## while the stroke itself is planned across frames by `_update_cpu`.
func _begin_cpu_turn() -> void:
	state = CPU
	_cpu_wait = CPU_LOOK_TIME
	_cpu_ready = false
	ai.set_level(cpu_level)

	if rules.ball_in_hand:
		_place_target = ai.plan_placement(sim, rules, game_kind,
			rules.in_hand_in_d(), _is_break_shot())
		_apply_placement()
	ai.begin(sim, rules, game_kind, _is_break_shot())
	_cpu_aim = aim_dir


## True for the first stroke of a rack, which both games open with a break.
func _is_break_shot() -> bool:
	if game_mode == PoolPhys.SNOOKER:
		return _opening_shot
	return not rules.broken


func _update_cpu(delta: float) -> void:
	_cpu_wait = maxf(_cpu_wait - delta, 0.0)
	if not _cpu_ready:
		if not ai.think(CPU_BUDGET_MS):
			return
		_cpu_ready = true
		_cpu_aim = ai.shot.aim
		spin = ai.shot.spin
		power = _power_for_speed(ai.shot.speed)
		_predict_dirty = true

	# Swing the cue round onto the line rather than snapping to it, so the shot
	# can be read before it is played.
	# Rotating about UP by +a advances the rig yaw by +a, which is the same
	# relationship the camera is built on.
	var delta_angle := wrapf(_yaw_for(_cpu_aim) - _yaw_for(aim_dir), -PI, PI)
	var step: float = clampf(CPU_AIM_RATE * delta, 0.0, absf(delta_angle))
	if absf(delta_angle) > 1.0e-4:
		aim_dir = aim_dir.rotated(Vector3.UP, signf(delta_angle) * step).normalized()
		_predict_dirty = true
	if absf(delta_angle) > 0.01 or _cpu_wait > 0.0:
		return

	aim_dir = _cpu_aim
	_shoot(ai.shot.speed)


func _update_placing() -> void:
	if not pointer_locked:
		# Cursor visible: point at the spot you want.
		var p := _mouse_on_cloth()
		if p == Vector3.INF:
			return
		_place_target = Vector2(p.x, p.z)
	_apply_placement()


## Move the cue ball to `_place_target`, pulled inside whatever zone the rules
## allow and off any ball it would be sitting on. Separate from the mouse
## handling above because the CPU sets the target outright, and must not have it
## overwritten by wherever the pointer happens to be lying.
func _apply_placement() -> void:
	var target := _place_target
	if rules.in_hand_in_d():
		# In hand means in the D: on or behind the baulk line, inside the arc.
		# Both games break from there; in snooker every ball in hand is there.
		var c := Vector2(0.0, PoolPhys.baulk_z())
		target.y = maxf(target.y, c.y)
		var rel := target - c
		var lim := PoolPhys.d_radius() - PoolPhys.BALL_R
		if rel.length() > lim:
			target = c + rel.normalized() * lim
	target.x = clampf(target.x, -PoolPhys.HALF_W, PoolPhys.HALF_W)
	target.y = clampf(target.y, -PoolPhys.HALF_L, PoolPhys.HALF_L)
	_place_target = target

	var spot := sim.free_spot(target, sim.cue)
	_place_preview = Vector3(spot.x, PoolPhys.BALL_R, spot.y)
	sim.return_to_table(sim.cue, _place_preview)
	_predict_dirty = true


## The player has settled on where the cue ball goes. Where it ends up is an
## input exactly as the stroke is, so it travels the same way.
func _commit_placement() -> void:
	if net.is_active():
		net.send_placement(rules.player, _place_target.x, _place_target.y)
	_finish_placement()


func _finish_placement() -> void:
	_placed_this_turn = true
	state = AIM
	hud.clear_message()


func _clear_of_balls(p: Vector2, moving: PoolBall) -> bool:
	for b in sim.balls:
		if b == moving or not b.is_active():
			continue
		if p.distance_to(Vector2(b.pos.x, b.pos.z)) < PoolPhys.BALL_D + 0.0005:
			return false
	return true


# ---------------------------------------------------------------------------
# visuals
# ---------------------------------------------------------------------------

## Potted balls are genuinely falling through the pocket, so there is nothing to
## fake here: draw every ball at its simulated position. Balls that came to rest
## at the bottom of a pocket stay drawn -- you can look down the hole and see
## them. Only balls that left the table entirely are hidden.
func _sync_views() -> void:
	for i in range(sim.balls.size()):
		var b := sim.balls[i]
		var v := _views[i]
		if b.state == PoolBall.OFF_TABLE:
			v.visible = false
			continue
		# A ball whose position has stopped being a number is a physics failure,
		# and pushing it into a node transform turns that into a renderer failure
		# -- which is far harder to trace back. Park it instead, and say so once.
		if not _finite(b.pos):
			if not _reported_bad_ball:
				_reported_bad_ball = true
				push_error("Ball %d has a non-finite position (%v); parking it."
					% [b.number, b.pos])
				hud.show_message("Physics glitch on ball %d -- see the log"
					% b.number, "bad")
			b.state = PoolBall.OFF_TABLE
			b.vel = Vector3.ZERO
			b.avel = Vector3.ZERO
			v.visible = false
			continue
		v.visible = true
		v.position = b.pos
		# The orientation goes into the same transform, and a NaN quaternion is
		# just as fatal there as a NaN position -- but it costs nothing to draw
		# the ball unrotated, so this one is repaired rather than parked.
		if _finite_quat(b.orient):
			v.quaternion = b.orient
		else:
			b.orient = Quaternion.IDENTITY
			b.avel = Vector3.ZERO
			v.quaternion = b.orient
			if not _reported_bad_ball:
				_reported_bad_ball = true
				push_error("Ball %d has a non-finite orientation; resetting it."
					% b.number)


## Aim, sent and received.
##
## While this machine is lining a shot up -- by hand or with its computer player
## -- the direction of the cue and how far it is drawn back go out at a fixed
## rate; while somebody else is, the cue on this screen follows theirs. Without
## it a watching player sees a cue lying wherever their own last shot left it,
## which reads as the striker aiming at nothing at all, and the computer's turn
## in particular looks broken.
##
## Nothing about the shot depends on any of this arriving. The stroke itself is
## still sent once, reliably, and every machine plays it out from the table it
## already agrees on -- these are only the cue moving about beforehand.
func _sync_net_aim(delta: float) -> void:
	if not net.is_active():
		return
	if _is_local_turn():
		_remote_aim = Vector3.ZERO
		# Only while a shot is being lined up. Once it has been played the stroke
		# itself carries the aim, and a packet sent during the shot would be the
		# one thing this design does not have: a mid-shot packet.
		if state != AIM and state != CHARGING and state != CPU and state != PLACING:
			return
		_aim_send_wait -= delta
		if _aim_send_wait > 0.0:
			return
		var yaw := _yaw_for(aim_dir)
		var draw: float = power if state == CHARGING else 0.0
		# A cue standing still is worth no packets at all.
		if absf(wrapf(yaw - _aim_sent_yaw, -PI, PI)) < 0.0015 \
				and absf(draw - _aim_sent_draw) < 0.01:
			return
		_aim_send_wait = AIM_SEND_PERIOD
		_aim_sent_yaw = yaw
		_aim_sent_draw = draw
		net.send_aim(rules.player, yaw, draw)
		return
	if _remote_aim == Vector3.ZERO or state != AIM:
		return
	# Swung round rather than snapped: these arrive twenty times a second, and a
	# cue that steps between them looks like a cue being dragged.
	var k := 1.0 - exp(-16.0 * delta)
	var turn := wrapf(_yaw_for(_remote_aim) - _yaw_for(aim_dir), -PI, PI)
	if absf(turn) > 1.0e-5:
		aim_dir = aim_dir.rotated(Vector3.UP, turn * k).normalized()
		_predict_dirty = true
	power = lerpf(power, _remote_draw, k)


## Somebody else is aiming. Kept as a direction rather than applied on the spot,
## so the cue is swung onto it in `_sync_net_aim` at the frame rate rather than
## at whatever rate the packets happen to land.
func _on_net_aim(seat: int, yaw: float, draw: float) -> void:
	if seat != rules.player or _is_local_turn():
		return
	_remote_aim = Vector3(-sin(yaw), 0.0, -cos(yaw))
	_remote_draw = clampf(draw, 0.0, 1.0)


func _animate_cue(delta: float) -> void:
	# The cue is drawn for the computer too: watching it settle onto its line and
	# draw back is how you can tell what it has decided to do.
	var visible_now := state == AIM or state == CHARGING or state == CPU
	cue_node.visible = visible_now or _strike_anim > 0.0
	if not cue_node.visible:
		return

	if _strike_anim > 0.0:
		_strike_anim = maxf(_strike_anim - delta, 0.0)
		_pullback = lerpf(-0.012, _pullback, _strike_anim / 0.09)
	else:
		var want := 0.055 + 0.30 * power
		_pullback = lerpf(_pullback, want, 1.0 - exp(-18.0 * delta))

	var frame := _cue_frame()
	var tip: Vector3 = frame["tip"]
	var axis: Vector3 = frame["axis"]
	cue_node.position = tip - axis * _pullback
	cue_node.look_at(cue_node.position + axis, Vector3.UP)


## The smallest butt elevation this shot can be played at: clear of the rail
## behind it, and over any ball sitting in the way of the shaft. A level cue
## drives straight through the cushion whenever the cue ball is near one, and
## straight through a ball parked behind it -- neither of which a player can do,
## so the game raises the butt for them. The geometry lives in the simulation
## because the CPU has to play its candidates at the angle they will be struck at.
func _forced_elevation() -> float:
	return sim.clearance_elevation(aim_dir)


## Elevation actually used, for both the drawing and the strike -- they must
## agree, because tilting the cue really does change the shot.
func _elev() -> float:
	return maxf(elevation, _forced_elevation())


## Where the tip touches the ball and which way the cue travels, using the same
## construction as PoolSim.cue_strike so the picture matches the physics.
func _cue_frame() -> Dictionary:
	var rad := PoolPhys.BALL_R
	var off := spin
	if off.length() > PoolPhys.MISCUE_LIMIT:
		off = off.normalized() * PoolPhys.MISCUE_LIMIT
	var dir := Vector3(aim_dir.x, 0.0, aim_dir.z).normalized()
	var right := dir.cross(Vector3.UP).normalized()
	var elev := _elev()
	var axis := (dir * cos(elev) - Vector3.UP * sin(elev)).normalized()
	var p_axis := right.cross(axis).normalized()
	var back := sqrt(maxf(rad * rad - (off.x * rad) ** 2 - (off.y * rad) ** 2, 0.0))
	var rc := right * (off.x * rad) + p_axis * (off.y * rad) - axis * back
	return {"tip": sim.cue.pos + rc, "axis": axis}


## Cue speed for the current power setting. Shared by the strike and the guide so
## the prediction is of the shot you are about to play, not a different one.
func _shot_speed() -> float:
	var reach: float = lerpf(1.0, 0.55, clampf(_elev() / ELEV_MAX, 0.0, 1.0))
	return lerpf(PoolPhys.CUE_SPEED_MIN, PoolPhys.CUE_SPEED_MAX * reach, power * power)


## The inverse, for the CPU: it decides on a stroke speed, and the power meter
## has to show the stroke it is about to play.
func _power_for_speed(speed: float) -> float:
	var reach: float = lerpf(1.0, 0.55, clampf(_elev() / ELEV_MAX, 0.0, 1.0))
	var span: float = maxf(PoolPhys.CUE_SPEED_MAX * reach - PoolPhys.CUE_SPEED_MIN, 1.0e-4)
	return clampf(sqrt(clampf((speed - PoolPhys.CUE_SPEED_MIN) / span, 0.0, 1.0)), 0.0, 1.0)


## Throttled: re-tracing the shot is the most expensive thing the game does per
## frame, and a guide that updates 45 times a second is indistinguishable from one
## that updates 120 times a second while you sweep the cue.
const PREDICT_MIN_INTERVAL := 1.0 / 45.0


func _refresh_prediction() -> void:
	if not _predict_dirty:
		return
	var now := Time.get_ticks_msec() * 0.001
	if now - _predict_at < PREDICT_MIN_INTERVAL:
		return
	_predict_at = now
	_predict_dirty = false
	_predict = sim.predict_cue_path(aim_dir, _shot_speed(), spin.x, spin.y, _elev(),
		PoolSim.PREDICT_SECONDS, elevation)
	# How high the cue ball actually gets, taken from the trace rather than
	# guessed, so the HUD can say whether this stroke will clear anything.
	var hop := 0.0
	for p: Vector3 in _predict.get("path", PackedVector3Array()):
		hop = maxf(hop, p.y - PoolPhys.BALL_R)
	_predict_hop = hop


## Lengths of the two lines drawn out of a contact -- where the object ball
## leaves, and where the cue ball goes on to -- as multiples of the table's
## length. Both are aiming aids for the *next* ball as much as this one, so they
## want to reach a useful part of the table rather than stop just past the
## contact. Given in tables so a snooker player gets the same reach across a bed
## twice the size.
const GUIDE_OBJECT_LINE := 0.45
const GUIDE_CUE_LINE := 0.30


## The guide is a trace of the actual simulated shot, not a straight line along
## the cue. With side spin the two are different: squirt throws the launch a few
## degrees off the cue's line and swerve bends the path afterwards, so a straight
## line promises contacts that never happen.
func _update_guide() -> void:
	guide_mesh.clear_surfaces()
	if not show_guide or (state != AIM and state != CHARGING) or sim.cue == null:
		return
	_refresh_prediction()
	var path: PackedVector3Array = _predict.get("path", PackedVector3Array())
	if path.size() < 2:
		return

	var y := 0.0018
	_guide_pts.clear()
	_guide_cols.clear()

	# The cue ball's real path: curve, arc and all. Drawn at the height the ball
	# will actually be, with a dimmer shadow on the cloth underneath, so a jump or
	# a scoop reads as leaving the table instead of looking like a plain roll.
	var airborne_at := PoolPhys.BALL_R + 0.002
	for i in range(path.size() - 1):
		var p0 := path[i]
		var p1 := path[i + 1]
		_ribbon(Vector3(p0.x, y, p0.z), Vector3(p1.x, y, p1.z), 0.0030,
			Color(1, 1, 1, 0.20))
		if p0.y > airborne_at or p1.y > airborne_at:
			_ribbon(Vector3(p0.x, p0.y, p0.z), Vector3(p1.x, p1.y, p1.z), 0.0050,
				Color(0.45, 0.90, 1.00, 0.85))
		else:
			_ribbon(Vector3(p0.x, y, p0.z), Vector3(p1.x, y, p1.z), 0.0035,
				Color(1, 1, 1, 0.42))

	# Mark the apex so the height is readable at a glance.
	if _predict_hop > 0.004:
		var apex := path[0]
		for p: Vector3 in path:
			if p.y > apex.y:
				apex = p
		_ring(Vector3(apex.x, y, apex.z), PoolPhys.BALL_R * 0.7, 0.0030,
			Color(0.45, 0.90, 1.00, 0.55))
		_ribbon(Vector3(apex.x, y, apex.z), apex, 0.0025, Color(0.45, 0.90, 1.00, 0.45))

	var hit_number: int = _predict.get("hit_number", -1)
	if hit_number >= 0:
		var contact: Vector3 = _predict["contact"]
		contact.y = y
		_ring(contact, PoolPhys.BALL_R, 0.0035, Color(1, 1, 1, 0.62))
		# Where each ball actually leaves the collision, throw included.
		var obj_dir: Vector3 = _predict["object_dir"]
		if obj_dir.length() > 0.01:
			var oa: Vector3 = _predict["object_at"]
			var obc := Vector3(oa.x, y, oa.z)
			_ribbon(obc, obc + Vector3(obj_dir.x, 0.0, obj_dir.z).normalized()
				* (PoolPhys.PLAY_L * GUIDE_OBJECT_LINE),
				0.0050, Color(1.0, 0.80, 0.22, 0.66))
		var cue_after: Vector3 = _predict["cue_dir_after"]
		if cue_after.length() > 0.01:
			_ribbon(contact, contact
				+ Vector3(cue_after.x, 0.0, cue_after.z).normalized()
				* (PoolPhys.PLAY_L * GUIDE_CUE_LINE),
				0.0040, Color(0.35, 0.85, 1.0, 0.50))

	_commit_guide()


## Hand the collected triangles to the mesh, but only if there are any.
##
## The geometry is gathered into arrays first rather than pushed straight at the
## ImmediateMesh, for one reason: every ribbon on a shot can legitimately be
## skipped -- a path whose points all land on the same spot has no direction to
## give a quad a width -- and a surface committed with zero vertices is not a
## surface. Building it up first means the decision to commit is made once, when
## it is known whether there is anything to draw.
func _commit_guide() -> void:
	if _guide_pts.is_empty():
		return
	guide_mesh.surface_begin(Mesh.PRIMITIVE_TRIANGLES, guide_mat)
	for i in range(_guide_pts.size()):
		guide_mesh.surface_set_color(_guide_cols[i])
		guide_mesh.surface_add_vertex(_guide_pts[i])
	guide_mesh.surface_end()


## Flat quad of width `w` lying on the cloth from a to b.
##
## Anything that is not a finite number is dropped on the floor here. A NaN that
## reaches a vertex buffer is not a visual glitch: it poisons the mesh's bounding
## box, and the GPU fault that follows takes the whole process with it, with no
## Godot error and no crash report to show for it. The guide traces a live
## simulation every frame, so this is the one place in the game where a bad
## number could get that far.
func _ribbon(a: Vector3, b: Vector3, w: float, col: Color) -> void:
	if not (_finite(a) and _finite(b)):
		return
	var d := Vector3(b.x - a.x, 0.0, b.z - a.z)
	if d.length() < 1.0e-6:
		return
	var side := Vector3(-d.z, 0.0, d.x).normalized() * (w * 0.5)
	var quad := [a - side, a + side, b + side, b - side]
	for idx: int in [0, 1, 2, 0, 2, 3]:
		_guide_cols.append(col)
		_guide_pts.append(quad[idx])


static func _finite(v: Vector3) -> bool:
	return is_finite(v.x) and is_finite(v.y) and is_finite(v.z)


## A quaternion is only safe to hand to a transform if it is finite *and* a unit:
## Godot builds the basis straight from it, so a degenerate one is as bad as a
## non-finite one.
static func _finite_quat(q: Quaternion) -> bool:
	if not (is_finite(q.x) and is_finite(q.y) and is_finite(q.z)
			and is_finite(q.w)):
		return false
	return absf(q.length_squared() - 1.0) < 0.01


func _ring(center: Vector3, r: float, w: float, col: Color) -> void:
	var steps := 36
	for i in range(steps):
		var a0 := TAU * float(i) / float(steps)
		var a1 := TAU * float(i + 1) / float(steps)
		_ribbon(center + Vector3(cos(a0), 0.0, sin(a0)) * r,
			center + Vector3(cos(a1), 0.0, sin(a1)) * r, w, col)


func _update_camera(delta: float) -> void:
	var pivot := Vector3.ZERO
	var yaw := _cur_yaw
	var pitch := _cur_pitch
	var dist := _cur_dist

	if state == SHOOTING or state == OVER:
		# Broadcast view: pull back to take in the whole table, keeping the
		# heading the player was aiming from so the cut is not disorienting.
		pivot = Vector3(0.0, 0.0, 0.0)
		yaw = _yaw_for(aim_dir)
		pitch = -0.66
		dist = 2.65 * _table_scale()
	elif state == PLACING:
		# Deliberately does NOT follow the cue ball: the ball tracks the mouse
		# here, so a camera that chased it would drag the pick ray with it and
		# the ball would run away across the table.
		pivot = Vector3.ZERO
		yaw = _cur_yaw
		pitch = -0.80
		dist = 2.55 * _table_scale()
	else:
		match cam_mode:
			CAM_AIM:
				pivot = sim.cue.pos + Vector3(0.0, 0.05, 0.0)
				yaw = _yaw_for(aim_dir)
				pitch = -0.34
				dist = _aim_dist
			CAM_ORBIT:
				pivot = Vector3.ZERO
				yaw = _orbit_yaw
				pitch = _orbit_pitch
				dist = _orbit_dist * _table_scale()
				# Held inside the room: pulled back past the walls you would be
				# looking at their backfaces, which are not drawn.
				if room != null:
					dist = minf(dist, room.max_camera_distance(pitch))
			CAM_TOP:
				# Fixed yaw: letting the top-down view spin with the aim is
				# disorienting, and the cue and guide already show the heading.
				pivot = Vector3.ZERO
				yaw = 0.0
				pitch = -PI * 0.5 + 0.02
				dist = 2.95 * _table_scale()

	var k := 1.0 - exp(-9.0 * delta)
	_cur_pivot = _cur_pivot.lerp(pivot, k)
	_cur_yaw = _cur_yaw + wrapf(yaw - _cur_yaw, -PI, PI) * k
	_cur_pitch = lerpf(_cur_pitch, pitch, k)
	_cur_dist = lerpf(_cur_dist, dist, k)

	cam_rig.position = _cur_pivot
	cam_rig.rotation = Vector3(_cur_pitch, _cur_yaw, 0.0)
	cam.position = Vector3(0.0, 0.0, _cur_dist)

	# Hide the pendants once the camera is level with or above them, otherwise
	# they sit directly between an overhead view and the table.
	if room != null:
		var lamps_visible := cam.global_position.y < RoomView.LAMP_Y - 0.04
		for m in room.lamp_meshes:
			m.visible = lamps_visible


## Camera distances are quoted for a 9-foot table and scaled from there, so the
## 12-foot snooker table frames the same way instead of overflowing the view.
func _table_scale() -> float:
	return PoolPhys.PLAY_L / 2.54


## Distance to whatever the cue ball is going to hit, used to keep the aim
## resolution constant in table-space rather than in degrees.
func _aim_distance() -> float:
	if _predict.get("hit_number", -1) >= 0:
		var c: Vector3 = _predict["contact"]
		return Vector2(c.x - sim.cue.pos.x, c.z - sim.cue.pos.z).length()
	var path: PackedVector3Array = _predict.get("path", PackedVector3Array())
	if path.size() >= 2:
		var e := path[path.size() - 1]
		return Vector2(e.x - sim.cue.pos.x, e.z - sim.cue.pos.z).length()
	return 1.2


## Rig yaw that points the camera's forward (-Z) along `dir`.
func _yaw_for(dir: Vector3) -> float:
	return atan2(-dir.x, -dir.z)


## Who the HUD should say is at the table.
##
## Named from the same seat the status panel names, so the two never disagree
## about who is playing -- including in killer, where there are up to eight of
## them and "the other player" means nothing.
func _watching_name() -> String:
	if rules.game_over or state == OVER:
		return ""
	var p: int = rules.player
	if p < cpu.size() and cpu[p]:
		return "CPU %s" % ai.level_name()
	return "Player %d" % (p + 1)


func _sync_hud() -> void:
	hud.power = power
	hud.charging = state == CHARGING
	hud.cpu = cpu
	hud.cpu_name = ai.level_name()
	hud.thinking = state == CPU and not _cpu_ready
	hud.watching = _watching_name()
	# The notice stays up only while this machine has nothing to do about it: the
	# computer thinking, or somebody at the other end of a connection playing.
	hud.waiting = _is_cpu_turn() or not _is_local_turn()
	hud.spin = spin
	hud.elevation = _elev()
	hud.elevation_forced = _forced_elevation() > elevation + 1.0e-4
	hud.pointer_locked = pointer_locked
	hud.hop = _predict_hop
	hud.ball_diameter = PoolPhys.BALL_D
	hud.turn = rules.player
	if game_kind == PoolPhys.GAME_SNOOKER:
		hud.score = rules.score
		hud.break_score = rules.break_score
		hud.required = rules.required_name(sim)
	elif game_kind == PoolPhys.GAME_KILLER:
		hud.lives = rules.lives
	else:
		hud.groups = rules.groups
		hud.table_open = rules.table_open
		hud.visits = rules.visits_left
	hud.ball_in_hand = rules.ball_in_hand
	hud.in_d = rules.in_hand_in_d()
	hud.placing = state == PLACING
	hud.hide_controls = state == SHOOTING or state == CPU
	hud.slow_motion = slow_motion
	var down: Array[int] = []
	for b in sim.balls:
		if not b.is_active() and b.number != 0:
			down.append(b.number)
	down.sort()
	hud.potted = down


func _on_rules_message(text: String, kind: String) -> void:
	hud.show_message(text, kind)


# ---------------------------------------------------------------------------
# input
# ---------------------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if menu_open:
		# The menu's own buttons see mouse input first, through the GUI. All that
		# is left to do here is the two keys it wants that are not on a button.
		if event is InputEventKey and event.pressed and not event.echo:
			if menu.handle_key((event as InputEventKey).keycode):
				get_viewport().set_input_as_handled()
		return
	if event is InputEventMouseButton:
		_handle_mouse_button(event)
	elif event is InputEventMouseMotion:
		_handle_mouse_motion(event)
	elif event is InputEventKey and event.pressed and not event.echo:
		_handle_key(event)


func _handle_mouse_button(e: InputEventMouseButton) -> void:
	if e.button_index == MOUSE_BUTTON_RIGHT:
		_dragging = e.pressed
		if e.pressed:
			cam_mode = CAM_ORBIT
	elif e.button_index == MOUSE_BUTTON_WHEEL_UP:
		_zoom(-0.12)
	elif e.button_index == MOUSE_BUTTON_WHEEL_DOWN:
		_zoom(0.12)
	elif e.button_index == MOUSE_BUTTON_LEFT:
		# Not our seat: watching, not playing.
		if _is_cpu_turn() or not _is_local_turn():
			return
		if e.pressed:
			if state == PLACING:
				_commit_placement()
			elif state == AIM:
				# Draw the cue back to set the power, exactly as the cue is drawn
				# back on the table, and let go to play the stroke.
				state = CHARGING
				power = 0.0
				_draw_back = 0.0
				_predict_dirty = true
		elif state == CHARGING:
			if power > 0.02:
				_shoot()
			else:
				state = AIM      # a click with no draw is not a stroke


func _zoom(amount: float) -> void:
	if cam_mode == CAM_AIM:
		_aim_dist = clampf(_aim_dist * (1.0 + amount), 0.35, 2.4)
	else:
		_orbit_dist = clampf(_orbit_dist * (1.0 + amount), 0.8, 6.0)


## Aiming turns the cue by *relative* mouse movement rather than pointing at an
## absolute spot on the cloth.
##
## Pointing at a spot seems more natural and was the first thing tried, but it
## spins out of control: in the behind-the-ball view the camera yaw is slaved to
## the aim, so moving the mouse rotates the aim, which rotates the camera, which
## moves where the same mouse position lands on the cloth, which rotates the aim
## again. Relative motion never reads the camera back, so there is no loop.
func _handle_mouse_motion(e: InputEventMouseMotion) -> void:
	# Just tabbed back in, or the pointer has been handed across in one jump:
	# either way this is not somebody moving the mouse.
	if _focus_grace > 0.0 or e.relative.length() > MOUSE_JUMP_MAX:
		return
	if _dragging:
		_orbit_yaw = wrapf(_orbit_yaw - e.relative.x * 0.006, -PI, PI)
		_orbit_pitch = clampf(_orbit_pitch - e.relative.y * 0.005,
			-PI * 0.5 + 0.02, -0.03)
		return
	# Watching -- the computer, or another player over the network -- and the
	# mouse only moves the camera.
	if _is_cpu_turn() or not _is_local_turn():
		return
	if state == CHARGING:
		# Pulling the mouse back (down the screen) draws the cue back. Only the
		# vertical component is spent here: the horizontal one falls through to the
		# aiming code below, so the line can still be adjusted mid-draw, which is
		# what a player does on the table rather than starting the stroke again.
		_draw_back = clampf(_draw_back + e.relative.y, 0.0, DRAW_BACK_FULL)
		power = _draw_back / DRAW_BACK_FULL
		_predict_dirty = true
	if state == PLACING:
		if pointer_locked:
			# Move the ball in the plane of the table as seen by the camera, so
			# dragging right moves it right on screen whatever the view angle.
			# Not named `basis`: Node3D already has a `basis` property.
			var cam_basis := cam.global_transform.basis
			var right := Vector3(cam_basis.x.x, 0.0, cam_basis.x.z).normalized()
			var into := Vector3(-cam_basis.z.x, 0.0, -cam_basis.z.z).normalized()
			var d := right * e.relative.x - into * e.relative.y
			_place_target += Vector2(d.x, d.z) * PLACE_SENSITIVITY
		return
	if state != AIM and state != CHARGING:
		return
	if absf(e.relative.x) > 0.0:
		var sens := AIM_POINT_PER_PIXEL / maxf(_aim_distance(), 0.25)
		if Input.is_key_pressed(KEY_SHIFT):
			sens *= AIM_PRECISION
		aim_dir = aim_dir.rotated(Vector3.UP,
			-e.relative.x * sens * _aim_screen_sign()).normalized()
		_predict_dirty = true


## Which way round the aim turns for a rightward flick of the mouse.
##
## The aim turns about the table's own vertical, and from behind the ball that is
## the same thing as turning it on screen -- the camera is looking down the shot,
## so the far end of the line goes right when the mouse goes right. Press `C` and
## it is not: the orbit and overhead cameras stay where they are, so from the
## other side of the table, or with the cue pointing down the screen, the same
## flick swings the aim the other way. That is the reversed aim, and it is why the
## overhead view in particular felt backwards to play in.
##
## Turning the cue by a small angle moves the far end of the line along
## UP x aim. Project that onto the camera's own right axis and the sign says which
## way the screen is about to see it; ask for the sign that always sends it right.
func _aim_screen_sign() -> float:
	var s := Vector3.UP.cross(aim_dir).dot(cam.global_transform.basis.x)
	# Near zero the cue is pointing across the screen, where turning it barely
	# moves the far end sideways at all and the sign is genuinely ambiguous. Hold
	# the last answer through that band rather than flickering between them.
	if absf(s) > 0.15:
		_aim_sign = -1.0 if s > 0.0 else 1.0
	return _aim_sign


func _handle_key(e: InputEventKey) -> void:
	# The camera, the guide, slow motion, help and the menu stay live while
	# somebody else is at the table -- watching from wherever you like is not
	# playing for them. Everything that touches the cue does not.
	if _is_cpu_turn() or not _is_local_turn():
		match e.keycode:
			KEY_C, KEY_G, KEY_T, KEY_H, KEY_M, KEY_R, KEY_ESCAPE:
				pass
			_:
				return

	match e.keycode:
		KEY_SPACE:
			# Kept as a quick way to replay the same stroke; the cue is normally
			# drawn back with the mouse.
			if state == AIM and power > 0.02 and _is_local_turn():
				_shoot()
		KEY_C:
			cam_mode = (cam_mode + 1) % 3
		KEY_G:
			show_guide = not show_guide
		KEY_T:
			slow_motion = not slow_motion
		KEY_J:
			# Jump stance in one press: butt up, tip on centre. Reaching for a jump
			# by feel means finding both of those at once, and aiming low -- the
			# instinctive thing -- actively works against it.
			elevation = deg_to_rad(45.0)
			spin = Vector2(0.0, 0.10)
			_tip_detent = 0.0
			_predict_dirty = true
			hud.show_message("Jump stance: cue raised, tip on centre", "info")
		KEY_K:
			# Scoop stance: cue level, tip right under the ball. The companion to
			# the jump stance, and the only way to get the ball up without raising
			# the butt. Stops at the legal limit rather than running into the
			# miscue band, where the stroke would lose most of its power.
			elevation = 0.0
			spin = Vector2(0.0, -PoolPhys.MAX_TIP_OFFSET)
			_tip_detent = 0.0
			_predict_dirty = true
			# A rail or a ball close behind forces the butt up to keep the shaft
			# clear, which tilts the tip down and works directly against getting
			# under the ball. Worth saying so rather than letting the stroke
			# quietly do nothing.
			var forced := _forced_elevation()
			if forced > deg_to_rad(2.5):
				hud.show_message("Scoop stance -- but what is behind the shot tilts the cue %d deg, which weakens it"
					% int(round(rad_to_deg(forced))), "bad")
			else:
				hud.show_message("Scoop stance: cue level, tip under the ball", "info")
		KEY_X:
			spin = Vector2.ZERO
			_tip_detent = 0.0
			elevation = 0.0
		KEY_H:
			hud.show_help = not hud.show_help
		KEY_R:
			# Re-racking is a local reset, and there is no way to agree one
			# mid-frame. Over a network the host ends the match instead.
			if not net.is_active():
				_rack()
			else:
				hud.show_message("cannot re-rack in a network game", "bad")
		KEY_M:
			_open_menu(true)
		KEY_B:
			# Deliberate ball-in-hand, for practice.
			if state == AIM:
				_enter_placing()
		KEY_ESCAPE:
			pointer_locked = not pointer_locked
			_apply_pointer_lock()


## Play the stroke. `speed_override` is how the CPU shoots: it works in cue
## speed directly, having simulated that exact stroke, so it must not be put
## through the power curve and back again.
func _shoot(speed_override := -1.0) -> void:
	if not _is_local_turn():
		return
	# _shot_speed() already accounts for the fact that you cannot make a full
	# stroke with the butt in the air, and the guide used the same number.
	var speed := _shot_speed() if speed_override < 0.0 else speed_override
	var stroke := {
		"ax": aim_dir.x, "az": aim_dir.z, "speed": speed,
		"side": spin.x, "vert": spin.y, "elev": _elev(), "jump": elevation,
		"n": shot_index,
		# Where the cue ball was struck from. Carrying it makes a stroke
		# self-contained: with ball in hand the placement is part of the shot
		# rather than a second message that has to arrive first, and there is no
		# ordering left to get wrong. On an ordinary shot both machines already
		# have the ball here, so setting it again changes nothing.
		"cx": sim.cue.pos.x, "cz": sim.cue.pos.z,
		# The miscue's scatter, decided here and sent, so a stroke that slips off
		# the ball slips the same way on every machine watching it.
		"seed": randi(),
	}
	if not net.is_active():
		_apply_stroke(stroke)
		return
	# Networked, the striker's own stroke goes through the same queue as everyone
	# else's rather than straight to the table. One path and one ordering rule for
	# every stroke on every machine: the alternative is a local shot that can be
	# applied out of step with the sequence it was just given.
	net.send_stroke(rules.player, stroke)
	_pending_strokes.append({"seat": rules.player, "stroke": stroke})
	_drain_pending()


## Play a stroke, wherever it was decided. This is the only path that strikes the
## cue ball, so a shot arriving over the network goes through exactly what a
## local one does.
func _apply_stroke(stroke: Dictionary) -> void:
	if sim.cue == null or not sim.cue.is_active():
		# Striking a ball that is not on the table does nothing, and silently
		# doing nothing is how two machines stop agreeing without either noticing.
		push_error("stroke applied with no cue ball on the table -- desynchronised")
		hud.show_message("network error: out of step with the other player", "bad")
		return
	shot_index += 1
	if stroke.has("cx"):
		sim.return_to_table(sim.cue, Vector3(stroke["cx"], 0.0, stroke["cz"]))
	rules.begin_shot(sim)
	# Seeding per shot rather than per match keeps a lost or reordered packet
	# from shifting every later shot's randomness.
	sim.rng.seed = int(stroke["seed"])
	aim_dir = Vector3(stroke["ax"], 0.0, stroke["az"]).normalized()
	spin = Vector2(stroke["side"], stroke["vert"])
	elevation = stroke["jump"]
	var speed: float = stroke["speed"]
	PoolSim.cue_strike(sim.cue, aim_dir, speed, stroke["side"], stroke["vert"],
		stroke["elev"], false, stroke["jump"], sim.rng)
	audio.play("cue", sim.cue.pos, speed, 6.0)
	_strike_anim = 0.09
	_accum = 0.0
	_predict_dirty = true
	_shot_started_ms = Time.get_ticks_msec()
	state = SHOOTING


# ---------------------------------------------------------------------------
# picking
# ---------------------------------------------------------------------------

## Where the mouse ray crosses the plane through the ball centres. Returns
## Vector3.INF when the ray runs away from the cloth.
func _mouse_on_cloth() -> Vector3:
	var mouse := get_viewport().get_mouse_position()
	var from := cam.project_ray_origin(mouse)
	var dir := cam.project_ray_normal(mouse)
	if absf(dir.y) < 1.0e-5:
		return Vector3.INF
	var t := (PoolPhys.BALL_R - from.y) / dir.y
	if t <= 0.0:
		return Vector3.INF
	return from + dir * t
