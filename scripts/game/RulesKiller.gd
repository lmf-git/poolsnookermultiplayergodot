class_name RulesKiller
extends RefCounted

## Killer -- the pub knockout game, played on the UK pool table.
##
## Everyone plays in turn and gets exactly one shot each visit. Pot a ball and
## you keep your lives; fail to pot and you lose one. Lose them all and you are
## out. The frame ends when one player is left standing.
##
## There are no colours and no groups: every object ball on the table is a legal
## target for everybody, all the time. That makes the rules engine much smaller
## than the other two -- there is no state to track about who owns what, only how
## many lives everyone has and whose turn it is.
##
## Like the other engines this never watches the simulation live. It snapshots
## what it needs in `begin_shot`, then reads `PoolSim.shot_log` afterwards.
##
## Fouling costs a life, the same as missing. That is the consistent reading of
## "pot a ball or it costs you": going in-off has not potted anything worth
## having, and it saves inventing a separate punishment for a game whose only
## currency is lives.
##
## The break is the one exception to all of it. There is nothing to pot from a
## full pack that is worth calling a miss, so the breaker only has to play a
## proper break -- two object balls to a cushion, or a ball down -- and a nudge
## or a foul is what costs them. This also applies to the re-rack after the
## table has been cleared, which is a break like any other.

signal message(text: String, kind: String)

## Lives each player starts with. Three is the pub game as usually played, with
## the lives chalked on the board next to your name.
const LIVES := 3

## A break has to send this many object balls to a cushion to count as a break
## rather than a nudge -- unless it pots something, which settles it either way.
const BREAK_CUSHIONS := 2

const MIN_PLAYERS := 2
const MAX_PLAYERS := 8

var players := 2
## Lives remaining per player. Zero means eliminated.
var lives: Array[int] = []
var player := 0
var game_over := false
var winner := -1

var ball_in_hand := true               # true before the break, and after an in-off
var broken := false

## Whether the striker was still in when they played. Captured in `begin_shot`
## for the same reason the pool engine captures the black: by the time a shot is
## judged the state it was played under may already have moved on.
var _was_alive := true
## Whether the shot being judged was a break. Snapshotted alongside `_was_alive`
## because `_apply` clears `broken` for a re-rack, and by then the shot that
## cleared the table is still being reported on.
var _was_break := true


func reset(p_players := 2) -> void:
	players = clampi(p_players, MIN_PLAYERS, MAX_PLAYERS)
	lives.clear()
	for _i in range(players):
		lives.append(LIVES)
	player = 0
	game_over = false
	winner = -1
	ball_in_hand = true
	broken = false
	_was_alive = true
	_was_break = true


func is_alive(p: int) -> bool:
	return p >= 0 and p < lives.size() and lives[p] > 0


func alive_count() -> int:
	var n := 0
	for l in lives:
		if l > 0:
			n += 1
	return n


## The next player still in, going round the table from `from`. Returns `from`
## itself when nobody else is left.
func next_alive(from: int) -> int:
	for step in range(1, players + 1):
		var p := (from + step) % players
		if is_alive(p):
			return p
	return from


## Killer is played from the D on the break and after an in-off; there is no
## other kind of ball in hand.
func in_hand_in_d() -> bool:
	return true


## Object balls still on the table.
func remaining(sim: PoolSim) -> int:
	var n := 0
	for b in sim.balls:
		if b.is_active() and b.number != 0:
			n += 1
	return n


## Every ball is on, for everybody, always.
func is_legal_first_hit(_sim: PoolSim, number: int) -> bool:
	return number != 0


func legal_targets(sim: PoolSim) -> Array[int]:
	var out: Array[int] = []
	for b in sim.balls:
		if b.is_active() and b.number != 0:
			out.append(b.number)
	return out


func begin_shot(sim: PoolSim) -> void:
	_was_alive = is_alive(player)
	_was_break = not broken
	sim.begin_shot()


func end_shot(sim: PoolSim) -> Dictionary:
	var potted: Array[int] = []
	var off_table: Array[int] = []
	var escaped: Array[int] = []
	var first_hit := -1
	var contacted := false
	var cue_potted := false
	var timed_out := false
	## Object balls sent to a cushion, counted once each: only the break asks for
	## them, and one ball rattling four rails is not two balls.
	var to_cushion := {}

	for e in sim.shot_log:
		match e["type"]:
			"timeout":
				timed_out = true
			"ball":
				if not contacted and (e["a"] == 0 or e["b"] == 0):
					first_hit = e["b"] if e["a"] == 0 else e["a"]
					contacted = true
			"cushion":
				if e["a"] != 0:
					to_cushion[e["a"]] = true
			"pocket":
				var n: int = e["a"]
				if n == 0:
					cue_potted = true
				else:
					potted.append(n)
			"off_table":
				var n2: int = e["a"]
				if n2 == 0:
					cue_potted = true
				else:
					off_table.append(n2)
			"escaped_pocket":
				# It came back out, so it was never potted -- which off the break is
				# the difference between keeping a life and losing one.
				var n3: int = e["a"]
				escaped.append(n3)
				if n3 == 0:
					cue_potted = false
				else:
					potted.erase(n3)

	var report := {
		"potted": potted,
		"off_table": off_table,
		"escaped": escaped,
		"first_hit": first_hit,
		"cue_potted": cue_potted,
		"foul": false,
		"reason": "",
		"respot": [] as Array[int],
		"turn_passes": true,
		"rerack": false,
		"break_shot": _was_break,
		"lost_life": -1,
		"eliminated": -1,
		"game_over": false,
		"winner": -1,
	}

	_judge(sim, report, timed_out, to_cushion.size())

	# A ball driven off the table goes back on the black spot, exactly as in the
	# eight-ball game -- there is no black here for it to clash with.
	for n in off_table:
		(report["respot"] as Array[int]).append(n)

	_apply(report)
	return report


# ---------------------------------------------------------------------------

func _judge(sim: PoolSim, report: Dictionary, timed_out: bool,
		balls_to_cushion: int) -> void:
	var potted: Array[int] = report["potted"]

	if report["first_hit"] == -1:
		report["foul"] = true
		report["reason"] = "no ball contacted" if not _was_break \
			else "no contact with the rack"
	elif report["cue_potted"]:
		report["foul"] = true
		report["reason"] = "in-off"
	elif not (report["off_table"] as Array).is_empty():
		report["foul"] = true
		report["reason"] = "ball driven off the table"
	# A ball that rattles back out was never potted. Off the break that is only a
	# better reason than "failed to pot" for a life the striker was losing
	# anyway; on the break, where no pot is asked for, it is what a full pack
	# does and costs nothing.
	elif not _was_break and not (report["escaped"] as Array).is_empty() \
			and potted.is_empty():
		report["foul"] = true
		report["reason"] = "ball jumped back out of the pocket"
	elif timed_out:
		report["foul"] = true
		report["reason"] = "shot timed out"
	# There is no cushion requirement on a normal shot, for the same reason as
	# the pool rules: it is not a rule of the UK game and this is the UK table.
	# It would make no difference to the outcome in any case -- a killer shot
	# that pots nothing costs a life whether it reached a rail or not. The break
	# is where it does matter, because there the pot is not required: without it
	# the breaker could tap the pack and hand the next player a full rack.
	elif _was_break and potted.is_empty() and balls_to_cushion < BREAK_CUSHIONS:
		report["foul"] = true
		report["reason"] = "illegal break: fewer than two balls to a cushion"

	# The whole game, in one line: a foul or an empty pocket costs the striker a
	# life. The break is the exception -- nothing is expected off a full pack, so
	# a fair break that pots nothing costs nothing.
	if report["foul"] or (potted.is_empty() and not _was_break):
		if report["reason"] == "":
			report["reason"] = "failed to pot"
		report["lost_life"] = player
		return

	# Survived the visit. Killer gives one shot a visit whatever happens, so the
	# table passes regardless.
	report["turn_passes"] = true
	if _was_break and potted.is_empty():
		emit_signal("message", "Legal break", "info")
	if remaining(sim) == 0:
		report["rerack"] = true


func _apply(report: Dictionary) -> void:
	broken = true
	ball_in_hand = report["cue_potted"]

	var hit: int = report["lost_life"]
	if hit >= 0 and _was_alive:
		lives[hit] -= 1
		if lives[hit] > 0:
			emit_signal("message", "Player %d: %s -- %d %s left"
				% [hit + 1, report["reason"], lives[hit],
				"life" if lives[hit] == 1 else "lives"], "bad")
		else:
			# Out of lives, and so out of the frame.
			report["eliminated"] = hit
			emit_signal("message", "Player %d out -- %s"
				% [hit + 1, report["reason"]], "bad")

	if alive_count() <= 1:
		report["game_over"] = true
		game_over = true
		for p in range(players):
			if is_alive(p):
				winner = p
				break
		report["winner"] = winner
		return

	if report["rerack"]:
		# The table is clear with players still in, so it is racked again. One
		# shot a visit applies to the break like any other shot, so the rack is
		# broken by whoever is next -- not by the player who cleared it.
		broken = false
		ball_in_hand = true

	player = next_alive(player)
