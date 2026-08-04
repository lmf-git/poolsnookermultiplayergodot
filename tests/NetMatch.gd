extends Node

## Two peers playing one frame, in a single process.
##
##     /Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
##         res://tests/NetMatch.tscn -- [port] [game] [seats]
##
## Two peers in one process need two MultiplayerAPIs, and Godot keys those by
## subtree: `SceneTree.set_multiplayer(api, root)` gives everything under `root`
## its own peer. They talk over the loopback -- a real socket, a real handshake
## and real packets, not a stub.
##
## The two subtree roots are named identically inside their own halves, because
## an RPC is addressed by the node's path *relative to its multiplayer root*. Give
## the two sides different internal layouts and every call is delivered to a path
## the other end does not have.
##
## What is being checked is the claim the whole design rests on: that sending
## only the stroke is enough. If it is, both tables hold the same balls in the
## same places after every shot, and the two rules engines agree on whose turn it
## is and who is winning. If it is not -- if anything in the shot is drawn from
## an unseeded generator, or an input is decided locally instead of sent -- the
## tables drift apart and the position check below fails.

## Frames to allow a shot to finish in. Generous on purpose: two full games are
## running in this one process, each with a millisecond budget per frame, so a
## three second shot takes far more than three seconds of frames. Giving up early
## does not fail the test honestly -- it compares two tables mid-roll and reports
## a desync that is really just one peer being a few slices ahead.
const SETTLE_FRAMES := 8000

var _passed := 0
var _failed := 0

var host_main: Node
var join_main: Node
var _want_seats := 2
var _want_game := 0
var _waiting_on: Node
var _want_shot := 0


func check(what: String, ok: bool, detail := "") -> void:
	if ok:
		_passed += 1
		printerr("  PASS  %s%s" % [what, "   " + detail if detail != "" else ""])
	else:
		_failed += 1
		printerr("  FAIL  %s%s" % [what, "   " + detail if detail != "" else ""])


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var port: int = int(args[0]) if args.size() > 0 else 27100
	var game: int = int(args[1]) if args.size() > 1 else PoolPhys.GAME_EIGHT_BALL
	var seats: int = int(args[2]) if args.size() > 2 else 2

	host_main = await _spawn("host")
	join_main = await _spawn("join")

	printerr("\n--- %s, %d seats, port %d ---"
		% [PoolPhys.GAME_NAMES[game], seats, port])

	# Host, then join, then wait for the seating chart to reach both sides.
	var config := {
		"game": game, "players": seats, "level": AIPlayer.MEDIUM, "breaker": 0,
	}
	# Driven through the menu, not by calling into Main: the menu is the only way
	# a person can reach any of this, so it is the path worth testing.
	host_main._open_menu(false)
	join_main._open_menu(false)
	await get_tree().process_frame
	var hm: MainMenu = host_main.menu
	hm.game = game
	hm.net_mode = hm.NET_HOST
	hm.port = port
	if game == PoolPhys.GAME_KILLER:
		hm.seats = maxi(0, seats - 3)
		hm.killer_who = hm.KILLER_ALL_HUMAN
	hm._refresh()
	check("the host menu offers to host", hm._start.text == "HOST")
	hm._on_start()
	check("the host starts listening", host_main.net.is_host())

	var jm: MainMenu = join_main.menu
	jm.net_mode = jm.NET_JOIN
	jm.address = "127.0.0.1"
	jm.port = port
	jm._refresh()
	check("the joiner menu offers to join", jm._start.text == "JOIN")
	check("and hides the settings the host owns",
		not jm._players_label.get_parent().visible)
	jm._on_start()
	check("the client reaches it", join_main.net.is_active())
	_want_seats = seats
	await _until(_both_seated, 2000)
	check("both peers are seated", _both_seated(),
		"host sees %d, client has %d seats"
			% [host_main.net.humans_connected(), join_main.net.seat_peer.size()])

	check("the host is offered the start button", hm._begin.visible)
	check("and its lobby line says who is here", hm._lobby.text.contains("seats"),
		hm._lobby.text)
	hm._begin.pressed.emit()
	# The host leaves the lobby at once; the joiner leaves when the deal reaches
	# it, which is a round trip away.
	await _until(_menus_closed, 600)
	check("starting the frame closes the menu on both peers", _menus_closed())
	_want_game = game
	await _until(_client_dealt, 2000)
	var hn := []
	var jn := []
	for b in host_main.sim.balls:
		hn.append(b.number)
	for b in join_main.sim.balls:
		jn.append(b.number)
	check("the client is dealt the same game", join_main.game_kind == game)
	# Not compared here: whoever is breaking has already picked the cue ball up
	# to place it, so one table legitimately differs until that is committed.
	check("and the same rack order", hn == jn)

	# Seat one is the host, seat two the client: each machine plays its own.
	check("the host owns seat 1", host_main.net.controls(0))
	check("the client owns seat 2", join_main.net.controls(1))
	check("and neither owns the other's",
		not host_main.net.controls(1) and not join_main.net.controls(0))

	# Play a handful of shots from whichever side is up, and compare the tables
	# after every one.
	var shots := 0
	while shots < 6 and not host_main.rules.game_over:
		if not await _until(_in_step, 4000):
			check("peers came into step before shot %d" % (shots + 1), false,
				"turn %d/%d, strokes %d/%d"
					% [host_main.rules.player, join_main.rules.player,
					host_main.shot_index, join_main.shot_index])
			break
		var seat: int = host_main.rules.player
		var striker: Node = host_main if host_main.net.controls(seat) else join_main
		if not await _play_one(striker):
			break
		shots += 1
		var same := _same_table()
		check("tables agree after shot %d" % shots, same,
			"worst %.6f m" % _worst_gap())
		check("and so do the rules  (shot %d)" % shots,
			host_main.rules.player == join_main.rules.player
				and host_main.rules.game_over == join_main.rules.game_over,
			"turn %d vs %d" % [host_main.rules.player, join_main.rules.player])
		if not same:
			break

	check("shots actually got played", shots > 0, "%d played" % shots)
	if host_main.rules.game_over:
		printerr("   frame finished after %d shots" % shots)
	printerr("\n%d passed, %d failed" % [_passed, _failed])
	get_tree().quit(1 if _failed > 0 else 0)


# ---------------------------------------------------------------------------

## A Main under its own multiplayer root, which is what gives it its own peer.
## The child is always called "Main", so both sides address RPCs identically.
func _spawn(tag: String) -> Node:
	var root := Node.new()
	root.name = tag
	add_child(root)
	get_tree().set_multiplayer(SceneMultiplayer.new(), root.get_path())
	var m: Node = load("res://scenes/Main.tscn").instantiate()
	m.name = "Main"
	m.start_in_menu = false
	root.add_child(m)
	await get_tree().process_frame
	await get_tree().process_frame
	return m


## Take one shot on `striker`, then wait for both tables to come to rest.
## Both peers agree whose turn it is, have played the same number of strokes, and
## have stopped. A real player cannot click until their own client says it is
## their turn, so waiting for that here is not papering over anything -- shooting
## before it is what the game itself would not let you do.
func _in_step() -> bool:
	return host_main.rules.player == join_main.rules.player \
		and host_main.shot_index == join_main.shot_index \
		and host_main.sim.is_shot_over() and join_main.sim.is_shot_over() \
		and host_main.state != host_main.SHOOTING \
		and join_main.state != join_main.SHOOTING


func _play_one(striker: Node) -> bool:
	# Place the cue ball first if it is in hand, so the shot is legal.
	if striker.state == striker.PLACING:
		striker._commit_placement()
		await get_tree().process_frame
	if striker.state != striker.AIM:
		_waiting_on = striker
		await _until(_striker_ready, 2000)
	if striker.state != striker.AIM:
		return false
	# Aim down the table and hit it firmly: what matters is that a real stroke
	# happens, not that it is a good one.
	striker.aim_dir = Vector3(0.12, 0.0, -1.0).normalized()
	striker.spin = Vector2(0.1, -0.05)
	# Killer eliminates a player almost every visit, so a frame can be decided
	# before the six shots this asks for. That is the game ending, not a fault.
	if host_main.rules.game_over or join_main.rules.game_over:
		return false
	_want_shot = maxi(host_main.shot_index, join_main.shot_index) + 1
	var before: int = striker.shot_index
	striker._shoot(3.4)
	check("the striker actually played", striker.shot_index > before
		or not striker._pending_strokes.is_empty(),
		"seat %d, striker turn %d" % [striker.rules.player, striker.rules.player])
	var rested := await _until(_both_at_rest, SETTLE_FRAMES)
	check("both peers played the shot and stopped", rested,
		"strokes %d/%d, shot_time %.4f/%.4f"
			% [host_main.shot_index, join_main.shot_index,
			host_main.sim.shot_time, join_main.sim.shot_time])
	if not rested:
		for m in [host_main, join_main]:
			var q := []
			for e in m._pending_strokes:
				q.append("seat%d n=%s" % [e["seat"], str(e["stroke"].get("n"))])
			printerr("      %s: state=%d turn=%d over=%s n=%d in_hand=%s cue=%d queue=%s"
				% ["host  " if m == host_main else "client", m.state,
				m.rules.player, str(m.sim.is_shot_over()), m.shot_index,
				str(m.rules.ball_in_hand), m.sim.cue.state, str(q)])
	if not rested:
		return false
	_report_log_divergence()
	return true


## Where the two simulations first disagreed about what happened. The shot log is
## the ordered record of every contact, so the first entry that differs is the
## first moment the two tables stopped being the same table.
# Predicates, as methods rather than inline lambdas: a multi-line lambda with a
# trailing argument does not parse, and these read better anyway.

func _menus_closed() -> bool:
	return not host_main.menu_open and not join_main.menu_open


func _both_seated() -> bool:
	return host_main.net.humans_connected() >= 2 \
		and join_main.net.seat_peer.size() == _want_seats


## Waiting on the seed, not on the game kind: the client boots into an eight-ball
## rack of its own, so "is it showing eight-ball" is answered yes before the host
## has said anything at all. The seed is the thing only the host can supply.
func _client_dealt() -> bool:
	return join_main._match_seed == host_main._match_seed \
		and join_main.game_kind == _want_game \
		and join_main.sim.balls.size() > 1


func _striker_ready() -> bool:
	return _waiting_on != null and _waiting_on.state == _waiting_on.AIM


## Both peers have played the shot we are waiting for -- not merely "both are
## idle", which is also true of the moment before the second one has heard about
## it -- and both have come to rest.
func _both_at_rest() -> bool:
	return host_main.shot_index >= _want_shot and join_main.shot_index >= _want_shot \
		and host_main.sim.is_shot_over() and join_main.sim.is_shot_over() \
		and host_main.state != host_main.SHOOTING \
		and join_main.state != join_main.SHOOTING


## Where the two simulations disagreed, if they did.
func _report_log_divergence() -> void:
	var a: Array = host_main.sim.shot_log
	var b: Array = join_main.sim.shot_log
	check("both peers logged the same shot", a.size() == b.size()
		and host_main.sim.shot_time == join_main.sim.shot_time,
		"%d vs %d events, %.9f s vs %.9f s"
			% [a.size(), b.size(), host_main.sim.shot_time,
			join_main.sim.shot_time])
	if _same_table():
		return
	for m in [host_main, join_main]:
		printerr("      %s: state=%d turn=%d in_hand=%s cue_state=%d n=%d pend(place=%d stroke=%d)"
			% ["host  " if m == host_main else "client", m.state, m.rules.player,
			str(m.rules.ball_in_hand), m.sim.cue.state, m.shot_index,
			m._pending_place_seat, m._pending_stroke_seat])
	# Only on a failure is the detail worth printing, and then all of it.
	var n: int = mini(a.size(), b.size())
	for i in range(n):
		if str(a[i]) != str(b[i]):
			printerr("      first differing event %d:\n        host   %s\n        client %s"
				% [i, str(a[i]), str(b[i])])
			break
	for i in range(host_main.sim.balls.size()):
		var hb: PoolBall = host_main.sim.balls[i]
		var jb: PoolBall = join_main.sim.balls[i]
		if (hb.pos - jb.pos).length() > 1.0e-9 or hb.state != jb.state:
			printerr("      ball n=%d gap %.9f state %d/%d"
				% [hb.number, (hb.pos - jb.pos).length(), hb.state, jb.state])


## Every ball in the same place on both tables.
func _same_table() -> bool:
	return _worst_gap() < 1.0e-4


## Worst disagreement between the two tables.
##
## The cue ball is excluded while it is in hand, and that is not a loophole: it
## is genuinely not shared state yet. The player holding it has picked it up and
## is moving it about on their own screen; nobody else has a position for it
## until the stroke that uses it is sent, and the stroke carries it. Comparing it
## before then compares a decision one player has not finished making.
func _worst_gap() -> float:
	var a: Array = host_main.sim.balls
	var b: Array = join_main.sim.balls
	if a.size() != b.size():
		return INF
	var in_hand: bool = host_main.rules.ball_in_hand \
		or join_main.rules.ball_in_hand
	var worst := 0.0
	for i in range(a.size()):
		if in_hand and a[i].number == 0:
			continue
		if a[i].state != b[i].state:
			return INF
		worst = maxf(worst, (a[i].pos - b[i].pos).length())
	return worst


## Waits for `cond`, and says whether it actually came true. Callers must check:
## a timed-out wait leaves the world in whatever half-finished state it was in,
## and comparing that is worse than not comparing at all.
func _until(cond: Callable, frames: int) -> bool:
	for _i in range(frames):
		if cond.call():
			return true
		await get_tree().process_frame
	return cond.call()
