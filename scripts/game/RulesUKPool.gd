class_name RulesUKPool
extends RefCounted

## UK eight-ball pool -- "English pool", WEPF world rules -- for two players
## sharing the table.
##
## The rules engine never watches the simulation live. It snapshots the table
## before the shot, then reads PoolSim.shot_log afterwards -- an ordered record
## of every contact, cushion and pocket -- and rules on it. That separation is
## what makes fouls like "which ball did the cue ball touch first" or "did that
## one bounce back out of the pocket" straightforward instead of a pile of
## per-frame flags.
##
## What makes this the UK game rather than American eight-ball, roughly in the
## order it changes how you play:
##
##   * A foul hands the opponent **two visits**, not one, with the cue ball in
##   hand for the first of them. Missing is expensive, which is why the UK game
##   is so much more about safety than the American one.
##   * Potting an opponent's ball is a foul in itself.
##   * There is **no cushion requirement** after the contact. American eight-ball
##   wants a ball down or a ball to a rail; the UK game does not, which is what
##   makes the roll-up -- creep up behind your own ball and leave everything
##   exactly where it is -- a legal shot and a staple of it.
##   * The break is played from the D, not from behind a head string.
##   * The black on the break is a re-rack, not a spot-up.
##   * A ball knocked off the table goes back on the black spot, and the black
##   leaving the table loses the game outright.
##
## Simplified deliberately: there is no "free table" after a foul and no
## nomination, both of which need a player decision this game has no way to ask
## for.

enum { OPEN, REDS, YELLOWS, BLACK }

signal message(text: String, kind: String)

## Visits handed to the opponent by a foul. This is the "two shots" of pub pool.
const VISITS_AFTER_FOUL := 2

var player := 0                        # 0 or 1, whose turn it is
var groups := [OPEN, OPEN]
var table_open := true
var broken := false
var game_over := false
var winner := -1

var ball_in_hand := true               # true before the break, and after a foul

## Visits this player has left. One in the ordinary way of things: a shot that
## pots nothing ends the turn. Two after a foul -- the incoming player can
## afford to miss once, and does not lose the table for it.
var visits_left := 1

## Whether the striker was on the black when they played, captured in
## `begin_shot`. It has to be remembered rather than asked for again: by the time
## `end_shot` rules on the shot the table has already changed, and potting your
## last colour would otherwise put you on the black retrospectively -- for the
## very shot that potted it. You come to the black on the *next* visit to the
## table, not partway through the stroke that cleared your group.
var _was_on_black := false


static func group_of(number: int) -> int:
	if number == 8:
		return BLACK
	if number >= 1 and number <= 7:
		return REDS
	if number >= 9 and number <= 15:
		return YELLOWS
	return OPEN


static func group_name(g: int) -> String:
	match g:
		REDS: return "reds"
		YELLOWS: return "yellows"
		BLACK: return "the black"
		_: return "open"


func opponent() -> int:
	return 1 - player


func reset() -> void:
	player = 0
	groups = [OPEN, OPEN]
	table_open = true
	broken = false
	game_over = false
	winner = -1
	ball_in_hand = true
	visits_left = 1
	_was_on_black = false


## Every ball in hand in this game is in hand *in the D*.
##
## There are only two of them: the break, and the shot after the cue ball has
## been potted or knocked off the table. A foul that leaves the cue ball on the
## cloth is not one -- the incoming player plays it from where it lies. Ball in
## hand anywhere on the table is the American game, and blackball; it is not the
## UK rules this engine says it implements.
func in_hand_in_d() -> bool:
	return true


## How many of `g` are still on the table.
func remaining(sim: PoolSim, g: int) -> int:
	var n := 0
	for b in sim.balls:
		if b.is_active() and group_of(b.number) == g:
			n += 1
	return n


## True when this player has cleared their colour and the black is all that is
## left for them.
func on_black(sim: PoolSim) -> bool:
	return not table_open and groups[player] != OPEN \
		and remaining(sim, groups[player]) == 0


## Every ball the striker may legally hit first. The CPU player asks for this
## rather than working it out again from the group state.
func legal_targets(sim: PoolSim) -> Array[int]:
	var out: Array[int] = []
	for b in sim.balls:
		if b.is_active() and b.number != 0 and is_legal_first_hit(sim, b.number):
			out.append(b.number)
	return out


func is_legal_first_hit(sim: PoolSim, number: int) -> bool:
	return _legal_first_hit(number, on_black(sim))


## The same judgement with "on the black" supplied rather than read off the
## table, so a finished shot can be ruled on as the table stood when the striker
## played it.
func _legal_first_hit(number: int, shooting_black: bool) -> bool:
	if shooting_black:
		return number == 8
	if number == 8:
		return false                      # the black is never on until it is
	if table_open:
		return true
	return group_of(number) == groups[player]


func begin_shot(sim: PoolSim) -> void:
	_was_on_black = on_black(sim)
	sim.begin_shot()


## Rule on a completed shot. Returns a report the presentation layer can show;
## `respot` lists object balls that must be returned to the black spot.
func end_shot(sim: PoolSim) -> Dictionary:
	var potted: Array[int] = []
	var off_table: Array[int] = []
	var escaped: Array[int] = []
	var first_hit := -1
	var contacted := false
	var cue_potted := false
	## Object balls sent to a cushion, counted once each: a legal break needs two
	## of them, and one ball rattling four rails is not two balls.
	var to_cushion := {}
	var timed_out := false

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
				# It bounced back out, so it was never potted. The shot is a foul
				# either way, but the ball stays on the table where it landed.
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
		"game_over": false,
		"winner": -1,
	}

	if not broken:
		_judge_break(report, to_cushion.size())
	else:
		_judge_normal(report)

	# A ball driven off the table always comes back on the black spot, and always
	# costs a foul. The black is the exception: it is loss of game, and the black
	# rules have already dealt with it.
	for n in off_table:
		if n != 8:
			(report["respot"] as Array[int]).append(n)
	if not off_table.is_empty() and not report["foul"] and not report["game_over"]:
		report["foul"] = true
		report["reason"] = "ball driven off the table"
	if not escaped.is_empty() and not report["game_over"] and not report["foul"]:
		report["foul"] = true
		report["reason"] = "ball jumped back out of the pocket"
	if timed_out and not report["game_over"]:
		report["foul"] = true
		report["reason"] = "shot timed out"

	_apply(report)
	return report


# ---------------------------------------------------------------------------

## The break. WEPF asks for two object balls to a cushion or a ball potted;
## anything less is not a break, it is a nudge.
##
## Unlike `_judge_normal` this needs nothing from the table itself: on the break
## every ball is a legal target and nobody owns a colour yet, so the whole
## judgement comes out of what the shot log says happened.
func _judge_break(report: Dictionary, balls_to_cushion: int) -> void:
	broken = true
	var potted: Array[int] = report["potted"]
	var black_down: bool = potted.has(8) or (report["off_table"] as Array).has(8)

	if report["first_hit"] == -1:
		report["foul"] = true
		report["reason"] = "no contact with the rack"
	elif potted.is_empty() and balls_to_cushion < 2:
		report["foul"] = true
		report["reason"] = "illegal break: fewer than two balls to a cushion"

	if report["cue_potted"]:
		report["foul"] = true
		report["reason"] = "in-off on the break"

	# The black on the break is neither a win nor a loss: the balls go back in
	# the triangle and it is broken again. Whoever did not foul breaks.
	if black_down:
		report["rerack"] = true
		report["respot"] = [] as Array[int]
		emit_signal("message", "Black on the break -- re-rack", "info")
		return

	# The table stays open after the break whatever went down; the colours are
	# settled by the first ball legally potted on a later shot.
	if not report["foul"] and not potted.is_empty():
		report["turn_passes"] = false
		emit_signal("message", "%d down on the break" % potted.size(), "good")
	elif not report["foul"]:
		emit_signal("message", "Legal break", "info")


## Like `_judge_break`, this reads only the shot log and the state carried in
## from `begin_shot` -- never the table, which by now shows the shot's result
## rather than the position it was played from.
func _judge_normal(report: Dictionary) -> void:
	var potted: Array[int] = report["potted"]
	var my_group: int = groups[player]
	var shooting_black := _was_on_black
	var black_down: bool = potted.has(8) or (report["off_table"] as Array).has(8)

	# --- fouls ------------------------------------------------------------
	if report["first_hit"] == -1:
		report["foul"] = true
		report["reason"] = "no ball contacted"
	elif not _legal_first_hit(report["first_hit"], shooting_black):
		var hit_group := group_of(report["first_hit"])
		if shooting_black:
			report["reason"] = "must hit the black first"
		elif hit_group == BLACK:
			report["reason"] = "cannot hit the black yet"
		else:
			report["reason"] = "hit %s first" % group_name(hit_group)
		report["foul"] = true

	# There is deliberately no cushion requirement here. American eight-ball asks
	# for a ball down or any ball to a rail after the contact; the UK game does
	# not, and rolling up gently behind your own ball and leaving everything
	# exactly where it was is not merely legal, it is one of the shots the game is
	# built on. Calling it a foul handed the opponent two shots for playing the
	# right shot.

	if report["cue_potted"]:
		report["foul"] = true
		report["reason"] = "in-off"

	# Potting an opponent's ball is a foul in the UK game -- and the ball stays
	# down, so it costs twice. Not so while the table is open, where neither
	# colour belongs to anyone yet.
	if not table_open:
		for n in potted:
			var g := group_of(n)
			if g != BLACK and g != my_group:
				report["foul"] = true
				if report["reason"] == "":
					report["reason"] = "potted an opponent's ball"

	# --- the black --------------------------------------------------------
	if black_down:
		var lost: bool = not shooting_black or report["foul"] \
			or (report["off_table"] as Array).has(8)
		report["game_over"] = true
		report["winner"] = opponent() if lost else player
		if lost:
			if (report["off_table"] as Array).has(8):
				report["reason"] = "black knocked off the table"
			elif not shooting_black:
				report["reason"] = "black potted too early"
			elif report["cue_potted"]:
				report["reason"] = "in-off while potting the black"
			# Otherwise `reason` already says which foul lost it.
		return

	if report["foul"]:
		return

	# --- claiming a colour ------------------------------------------------
	# The first ball legally potted after the break settles the colours. If one
	# of each went down on the same shot the earlier one counts, which is what
	# the shot log's ordering gives us for free.
	if table_open and not potted.is_empty():
		var claim := group_of(potted[0])
		if claim == REDS or claim == YELLOWS:
			groups[player] = claim
			groups[opponent()] = YELLOWS if claim == REDS else REDS
			table_open = false
			my_group = claim
			emit_signal("message", "Player %d takes %s"
				% [player + 1, group_name(claim)], "info")

	# --- continue or hand over --------------------------------------------
	for n in potted:
		if group_of(n) == groups[player]:
			report["turn_passes"] = false


func _apply(report: Dictionary) -> void:
	if report["game_over"]:
		game_over = true
		winner = report["winner"]
		return

	if report["rerack"]:
		# Re-racked breaks are set up by the caller. The player who did not foul
		# breaks again.
		if report["foul"]:
			player = opponent()
		broken = false
		table_open = true
		groups = [OPEN, OPEN]
		ball_in_hand = true
		visits_left = 1
		return

	if report["foul"]:
		# WEPF: the foul is worth two visits, and that is *all* it is worth. The
		# incoming player plays the cue ball from where it stopped -- it is only in
		# hand when there is no cue ball on the table to play from, and then it
		# goes in the D exactly as at the break.
		#
		# Handing over the whole table instead made every foul enormously more
		# expensive than the rules make it, and took the safety battle -- which is
		# most of what this game is -- out of it: there is no point rolling up
		# behind a ball if the answer is to pick the cue ball up and put it
		# wherever it is wanted.
		ball_in_hand = report["cue_potted"]
		# Named, both of them. "Foul: hit yellow first" on its own is read by
		# whoever is looking at it as an accusation, and a player watching the
		# other one foul on yellows while yellows are theirs is being told, as far
		# as they can tell, that the game has lost track of the colours.
		var struck := player
		player = opponent()
		visits_left = VISITS_AFTER_FOUL
		emit_signal("message", "Player %d fouled: %s -- two shots to player %d"
			% [struck + 1, report["reason"], player + 1], "bad")
		return

	ball_in_hand = false
	if not report["turn_passes"]:
		return

	# Nothing of theirs went down, so that visit is spent. A second one, from an
	# earlier foul, keeps them at the table.
	visits_left -= 1
	if visits_left > 0:
		emit_signal("message", "One shot left", "info")
		return
	player = opponent()
	visits_left = 1
