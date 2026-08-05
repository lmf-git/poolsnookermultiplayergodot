class_name RulesSnooker
extends RefCounted

## Snooker for two players.
##
## Like the pool engine, this never watches the simulation live: it reads
## PoolSim.shot_log after the shot and rules on it.
##
## Ball `number` doubles as the ball's value, which is all the scoring needs:
## 1 red, 2 yellow, 3 green, 4 brown, 5 blue, 6 pink, 7 black.

signal message(text: String, kind: String)

const RED := 1
const MIN_FOUL := 4

var player := 0
var score := [0, 0]
var break_score := 0

## While reds remain, the striker alternates red / colour. `on_red` says which is
## required next. Once the reds are gone the colours must go in ascending order,
## tracked by `colour_order`.
##
## Between the two -- reds gone but `reds_done` still false -- is the one stroke
## at a colour of choice that belongs to the player who potted the last red. It
## is theirs only while they stay at the table; see `_hand_over`.
var on_red := true
var colour_order := 2
var reds_done := false

var game_over := false
var winner := -1
var ball_in_hand := true          # in-hand means "play from the D"
var free_ball := false


func reset() -> void:
	player = 0
	score = [0, 0]
	break_score = 0
	on_red = true
	colour_order = 2
	reds_done = false
	game_over = false
	winner = -1
	ball_in_hand = true
	free_ball = false


func opponent() -> int:
	return 1 - player


## In snooker, in hand always means from the D -- there is no other kind.
func in_hand_in_d() -> bool:
	return true


func reds_left(sim: PoolSim) -> int:
	var n := 0
	for b in sim.balls:
		if b.is_active() and b.number == RED:
			n += 1
	return n


## What the striker has to hit first.
func required_name(sim: PoolSim) -> String:
	if not reds_done and reds_left(sim) > 0:
		return "red" if on_red else "a colour"
	if not on_red and not reds_done:
		return "a colour"
	return PoolPhys.snooker_name(colour_order)


func begin_shot(sim: PoolSim) -> void:
	sim.begin_shot()


## True when `value` is a legal first contact. Public because the CPU player asks
## rather than working the red/colour cycle out for itself.
func is_legal_target(sim: PoolSim, value: int) -> bool:
	if reds_left(sim) > 0 or not reds_done:
		if on_red:
			return value == RED
		return value >= 2
	return value == colour_order


## Every ball the striker may legally hit first, by value. Colours repeat only
## as distinct balls, so this is a set: on a colour, all six are legal targets.
func legal_targets(sim: PoolSim) -> Array[int]:
	var out: Array[int] = []
	for b in sim.balls:
		if b.is_active() and b.number != 0 and is_legal_target(sim, b.number):
			if not out.has(b.number):
				out.append(b.number)
	return out


func end_shot(sim: PoolSim) -> Dictionary:
	var potted: Array[int] = []
	var off_table: Array[int] = []
	var first_hit := -1
	var cue_potted := false
	var escaped: Array[int] = []

	var timed_out := false
	for e in sim.shot_log:
		if e["type"] == "timeout":
			timed_out = true
		match e["type"]:
			"ball":
				if first_hit < 0 and (e["a"] == 0 or e["b"] == 0):
					first_hit = e["b"] if e["a"] == 0 else e["a"]
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
					# Not a pot. Forcing a ball off the table is a foul, and
					# counting it as a pot credited the striker with the very
					# ball they had just lost.
					off_table.append(n2)
			"escaped_pocket":
				var n3: int = e["a"]
				escaped.append(n3)
				if n3 == 0:
					cue_potted = false
				else:
					potted.erase(n3)

	var report := {
		"potted": potted,
		"off_table": off_table,
		"first_hit": first_hit,
		"cue_potted": cue_potted,
		"foul": false,
		"reason": "",
		"points": 0,
		"penalty": 0,
		"respot": [] as Array[int],
		"turn_passes": true,
		"game_over": false,
		"winner": -1,
	}

	_judge(sim, report, escaped)
	if timed_out and not report["game_over"]:
		report["foul"] = true
		report["penalty"] = maxi(int(report["penalty"]), MIN_FOUL)
		report["reason"] = "shot timed out"
	_apply(sim, report)
	return report


func _judge(sim: PoolSim, report: Dictionary, escaped: Array[int]) -> void:
	var potted: Array[int] = report["potted"]
	var first_hit: int = report["first_hit"]
	var penalty := 0
	var reason := ""

	# --- fouls ------------------------------------------------------------
	if first_hit < 0:
		penalty = MIN_FOUL
		reason = "no ball hit"
	elif not is_legal_target(sim, first_hit):
		# The penalty is the value of the ball on, or of the ball hit, whichever
		# is greater, with a floor of four.
		penalty = maxi(MIN_FOUL, maxi(first_hit, required_value(sim)))
		reason = "hit %s first, %s was on" % [
			PoolPhys.snooker_name(first_hit), required_name(sim)]

	if report["cue_potted"]:
		penalty = maxi(penalty, maxi(MIN_FOUL, required_value(sim)))
		reason = "in-off" if reason == "" else reason

	if not escaped.is_empty():
		penalty = maxi(penalty, MIN_FOUL)
		reason = "ball jumped back out of the pocket"

	# A ball forced off the table: a foul worth the value of that ball or of the
	# ball on, whichever is greater.
	for v in report["off_table"] as Array[int]:
		penalty = maxi(penalty, maxi(MIN_FOUL, maxi(v, required_value(sim))))
		if reason == "":
			reason = "%s forced off the table" % PoolPhys.snooker_name(v)

	# Potting a ball that was not on is a foul worth that ball's value.
	for v in potted:
		if not _is_legal_pot(sim, v, potted):
			penalty = maxi(penalty, maxi(MIN_FOUL, v))
			if reason == "":
				reason = "potted %s when %s was on" % [
					PoolPhys.snooker_name(v), required_name(sim)]

	if penalty > 0:
		report["foul"] = true
		report["penalty"] = penalty
		report["reason"] = reason
		# Every colour potted in a foul shot goes back on its spot; reds stay down.
		# A ball knocked off the table is returned on the same terms -- the colour
		# comes back, a red is simply gone.
		for v in potted:
			if v != RED:
				(report["respot"] as Array[int]).append(v)
		for v in report["off_table"] as Array[int]:
			if v != RED:
				(report["respot"] as Array[int]).append(v)
		return

	# --- scoring ----------------------------------------------------------
	var gained := 0
	for v in potted:
		gained += v
	report["points"] = gained
	if gained > 0:
		report["turn_passes"] = false

	# Colours go back up while any red remains.
	for v in potted:
		if v != RED and (reds_left(sim) > 0 or not on_red):
			if not reds_done:
				(report["respot"] as Array[int]).append(v)

	_advance_state(sim, potted, report)


## Where a colour goes back on: its own spot if that is clear, otherwise the
## highest-value spot that is, otherwise as near its own spot as it will fit.
##
## Shared with the CPU planner rather than living in Main, because the planner
## has to put respotted colours back on the table it simulates. A colour that
## simply vanishes when potted leaves the planner judging its position against a
## table that is about to change -- most visibly when the ball reappears directly
## in front of the cue ball it was so pleased with.
static func respot_position(sim: PoolSim, value: int, moving: PoolBall) -> Vector2:
	var own := PoolPhys.snooker_spot(value)
	if sim.spot_clear(own, moving):
		return own

	# Its own spot is occupied, so it takes the highest-value spot that is free.
	for v: int in [7, 6, 5, 4, 3, 2]:
		var alt := PoolPhys.snooker_spot(v)
		if sim.spot_clear(alt, moving):
			return alt

	# Every spot is occupied. The ball then goes as near as possible to its own
	# spot on the line towards the top cushion, and only if there is no room
	# there, the same distance below it. Not "the nearest free point in any
	# direction", which is how a colour ends up sitting off to one side of its
	# spot where no player would think to look for it.
	for dir: float in [-1.0, 1.0]:
		for i in range(1, 200):
			var q := own + Vector2(0.0, dir * PoolPhys.BALL_R * 0.5 * float(i))
			if not sim.table.is_legal_center(q):
				break
			if sim.spot_clear(q, moving):
				return q
	return sim.free_spot(own, moving)


## The order a set of colours goes back in: highest value first, which is the
## order a referee spots them in and the only order that is well defined.
##
## It matters whenever a shot leaves more than one colour to come back. Each ball
## is spotted against the table as it stands, and a ball still in the pocket
## occupies nothing -- so putting the yellow back first lets it take the black
## spot while the black is waiting its turn in the pocket, and the black is then
## pushed off its own spot for no reason at all. Highest first, and every colour
## that can have its own spot gets it.
static func respot_order(values: Array) -> Array[int]:
	var out: Array[int] = []
	for v: int in values:
		out.append(v)
	out.sort()
	out.reverse()
	return out


func required_value(sim: PoolSim) -> int:
	if reds_left(sim) > 0 or not reds_done:
		return RED if on_red else 7
	return colour_order


func _is_legal_pot(sim: PoolSim, value: int, potted: Array[int]) -> bool:
	if reds_left(sim) > 0 or not reds_done:
		if on_red:
			# Any number of reds may go down together, but nothing else.
			return value == RED
		# One colour only.
		return value >= 2 and potted.size() == 1
	return value == colour_order


## Work out what is on for the next stroke.
func _advance_state(sim: PoolSim, potted: Array[int], report: Dictionary) -> void:
	if potted.is_empty():
		return

	if reds_done:
		# Clearing the colours in order.
		if potted.has(colour_order):
			colour_order += 1
			if colour_order > 7:
				report["game_over"] = true
				report["winner"] = 0 if score[0] > score[1] else 1
				if score[0] == score[1]:
					report["winner"] = -1     # tie; re-spot black in a real match
		return

	if on_red and potted.has(RED):
		on_red = false
		return
	if not on_red:
		on_red = true
		if reds_left(sim) == 0:
			# The colour just potted is spotted again before the next stroke, so
			# the sequence can still start on it.
			_start_colours(sim, report["respot"])


## Move to the closing sequence: colours only, lowest value first, and from here
## on a potted colour stays in the pocket.
func _start_colours(sim: PoolSim, coming_back: Array) -> void:
	reds_done = true
	on_red = false
	colour_order = lowest_colour(sim, coming_back)
	emit_signal("message", "Reds gone -- colours in order, %s on"
		% PoolPhys.snooker_name(colour_order), "info")


## Where the sequence starts: the lowest colour still in play. A ball in
## `coming_back` is in a pocket at this moment but is spotted before the next
## stroke, so it counts as being on the table.
##
## Public and static because the CPU has to answer the same question about the
## player it is handing the table to.
static func lowest_colour(sim: PoolSim, coming_back: Array = []) -> int:
	for v in range(2, 8):
		if coming_back.has(v):
			return v
		for b in sim.balls:
			if b.is_active() and b.number == v:
				return v
	return 7


## The table has passed to the other player. The free choice of colour belongs to
## whoever potted the last red, and only while they stay at the table: a player
## arriving to find no reds left has to start the sequence at the lowest colour,
## not pick the black. Missing the colour after the last red, or fouling on it,
## hands that choice back rather than passing it on.
func _hand_over(sim: PoolSim, report: Dictionary) -> void:
	if reds_done or reds_left(sim) > 0:
		return
	_start_colours(sim, report["respot"])


func _apply(sim: PoolSim, report: Dictionary) -> void:
	if report["foul"]:
		score[opponent()] += report["penalty"]
		break_score = 0
		# After a foul the reds/colour cycle restarts on red if any remain.
		if not reds_done:
			on_red = reds_left(sim) > 0 or on_red
		# Named, like the pool foul: whoever is reading it needs to know it was
		# not them, and the penalty goes to the player who is now at the table.
		var struck := player
		player = opponent()
		ball_in_hand = report["cue_potted"]
		emit_signal("message", "Player %d fouled, %d away to player %d: %s"
			% [struck + 1, report["penalty"], player + 1, report["reason"]], "bad")
		_hand_over(sim, report)
		return

	score[player] += report["points"]
	if report["points"] > 0:
		break_score += report["points"]
		emit_signal("message", "%d  (break %d)" % [report["points"], break_score],
			"good")

	if report["game_over"]:
		game_over = true
		winner = report["winner"]
		return

	ball_in_hand = false
	if report["turn_passes"]:
		break_score = 0
		player = opponent()
		if not reds_done:
			on_red = reds_left(sim) > 0
		_hand_over(sim, report)
