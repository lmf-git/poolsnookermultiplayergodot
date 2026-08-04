extends Node

## The UK eight-ball rules, checked directly.
##
##     /Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
##         res://tests/RulesTest.tscn
##
## The rules engine reads `PoolSim.shot_log` and nothing else, which means a shot
## can be described rather than played: each test below writes the log a real
## shot would have left and asks the engine to rule on it. That keeps these
## tests about the rules instead of about whether a particular stroke happened to
## go in.
##
## Every case here is one of the things that makes this UK pool rather than
## American eight-ball, plus the black, which decides frames.

var _passed := 0
var _failed := 0


func check(what: String, ok: bool, detail := "") -> void:
	if ok:
		_passed += 1
		print("  PASS  %s%s" % [what, "   " + detail if detail != "" else ""])
	else:
		_failed += 1
		print("  FAIL  %s%s" % [what, "   " + detail if detail != "" else ""])


func _ready() -> void:
	PoolPhys.configure(PoolPhys.POOL)
	test_break()
	test_black_on_the_break()
	test_claiming_a_colour()
	test_two_visits()
	test_opponents_ball_is_a_foul()
	test_the_black()
	test_coming_to_the_black()
	test_off_the_table()
	print("\n%d passed, %d failed" % [_passed, _failed])
	get_tree().quit(1 if _failed > 0 else 0)


# ---------------------------------------------------------------------------
# a table to rule on
# ---------------------------------------------------------------------------

## Cue ball plus seven reds (1-7), seven yellows (9-15) and the black.
func _table() -> PoolSim:
	var sim := PoolSim.new(PoolTable.new())
	var cue := PoolBall.new(0, 0)
	cue.place(Vector3(0.0, 0.0, PoolPhys.HEAD_STRING_Z))
	sim.add_ball(cue)
	var id := 1
	for n: int in [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15]:
		var b := PoolBall.new(id, n)
		# Spread out down the table; the positions only have to be legal and
		# distinct, since no shot is actually played.
		b.place(Vector3(-0.3 + 0.04 * float(id), 0.0, -0.6 + 0.05 * float(id)))
		sim.add_ball(b)
		id += 1
	return sim


func _find(sim: PoolSim, number: int) -> PoolBall:
	for b in sim.balls:
		if b.number == number:
			return b
	return null


## The cue ball strikes `number` first.
func _hit(sim: PoolSim, number: int) -> void:
	sim.shot_log.append({"type": "ball", "t": 0.1, "a": 0, "b": number,
		"speed": 1.0})


func _cushion(sim: PoolSim, number: int) -> void:
	sim.shot_log.append({"type": "cushion", "t": 0.2, "a": number, "speed": 1.0})


## `number` goes down, and leaves the table as a potted ball really would.
func _pot(sim: PoolSim, number: int) -> void:
	var b := _find(sim, number)
	if b != null:
		b.state = PoolBall.POCKETED
	sim.shot_log.append({"type": "pocket", "t": 0.3, "a": number, "pocket": 0})


func _off_table(sim: PoolSim, number: int) -> void:
	var b := _find(sim, number)
	if b != null:
		b.state = PoolBall.OFF_TABLE
	sim.shot_log.append({"type": "off_table", "t": 0.3, "a": number})


## Clear every ball of a group off the table, for setting up a player on the
## black.
func _clear_group(sim: PoolSim, group: int) -> void:
	for b in sim.balls:
		if b.number != 0 and RulesUKPool.group_of(b.number) == group:
			b.state = PoolBall.POCKETED


# ---------------------------------------------------------------------------

func test_break() -> void:
	print("\n--- the break ---")
	var rules := RulesUKPool.new()
	rules.reset()
	check("in hand before the break", rules.ball_in_hand)
	check("and it has to go in the D", rules.in_hand_in_d())

	var sim := _table()
	rules.begin_shot(sim)
	_hit(sim, 3)
	_cushion(sim, 3)
	var report := rules.end_shot(sim)
	check("one ball to a cushion is not a break", report["foul"],
		report["reason"])

	var rules2 := RulesUKPool.new()
	rules2.reset()
	var sim2 := _table()
	rules2.begin_shot(sim2)
	_hit(sim2, 3)
	_cushion(sim2, 3)
	_cushion(sim2, 11)
	var report2 := rules2.end_shot(sim2)
	check("two balls to a cushion is", not report2["foul"], report2["reason"])
	check("the table is still open after it", rules2.table_open)
	check("and in hand is now the whole table", not rules2.in_hand_in_d())


func test_black_on_the_break() -> void:
	print("\n--- the black on the break ---")
	var rules := RulesUKPool.new()
	rules.reset()
	var sim := _table()
	rules.begin_shot(sim)
	_hit(sim, 3)
	_cushion(sim, 3)
	_cushion(sim, 11)
	_pot(sim, 8)
	var report := rules.end_shot(sim)
	check("it is a re-rack, not a loss", report["rerack"] and not report["game_over"])
	check("the breaker breaks again", rules.player == 0)
	check("and it is a break again", not rules.broken and rules.in_hand_in_d())


func test_claiming_a_colour() -> void:
	print("\n--- claiming a colour ---")
	var rules := RulesUKPool.new()
	rules.reset()
	rules.broken = true
	var sim := _table()
	rules.begin_shot(sim)
	_hit(sim, 11)
	_pot(sim, 11)
	var report := rules.end_shot(sim)
	check("the first ball potted settles the colours", not rules.table_open)
	check("the striker takes it", rules.groups[0] == RulesUKPool.YELLOWS)
	check("the opponent gets the other", rules.groups[1] == RulesUKPool.REDS)
	check("and stays at the table", rules.player == 0 and not report["turn_passes"])


func test_two_visits() -> void:
	print("\n--- two visits ---")
	var rules := RulesUKPool.new()
	rules.reset()
	rules.broken = true
	rules.table_open = false
	rules.groups = [RulesUKPool.REDS, RulesUKPool.YELLOWS]

	# Player 1 goes in-off.
	var sim := _table()
	rules.begin_shot(sim)
	_hit(sim, 3)
	sim.shot_log.append({"type": "pocket", "t": 0.3, "a": 0, "pocket": 0})
	rules.end_shot(sim)
	check("a foul hands over the table", rules.player == 1)
	check("with two visits", rules.visits_left == RulesUKPool.VISITS_AFTER_FOUL)
	check("and ball in hand anywhere", rules.ball_in_hand and not rules.in_hand_in_d())

	# Player 2 misses. That is one visit gone, not the table.
	var sim2 := _table()
	rules.begin_shot(sim2)
	_hit(sim2, 11)
	_cushion(sim2, 11)
	rules.end_shot(sim2)
	check("missing spends a visit but keeps the table",
		rules.player == 1 and rules.visits_left == 1)
	check("the second shot is not in hand", not rules.ball_in_hand)

	# Missing again does hand it back.
	var sim3 := _table()
	rules.begin_shot(sim3)
	_hit(sim3, 11)
	_cushion(sim3, 11)
	rules.end_shot(sim3)
	check("missing twice hands it back", rules.player == 0)
	check("and the next player has the usual single visit", rules.visits_left == 1)


func test_opponents_ball_is_a_foul() -> void:
	print("\n--- potting the wrong colour ---")
	var rules := RulesUKPool.new()
	rules.reset()
	rules.broken = true
	rules.table_open = false
	rules.groups = [RulesUKPool.REDS, RulesUKPool.YELLOWS]

	var sim := _table()
	rules.begin_shot(sim)
	_hit(sim, 3)                      # own colour first, legally
	_pot(sim, 11)                     # but an opponent's ball drops
	var report := rules.end_shot(sim)
	check("potting an opponent's ball is a foul", report["foul"], report["reason"])
	check("it is not returned to the table", (report["respot"] as Array).is_empty())
	check("and the opponent gets two visits",
		rules.player == 1 and rules.visits_left == 2)

	# Hitting one first is a foul in its own right.
	var rules2 := RulesUKPool.new()
	rules2.reset()
	rules2.broken = true
	rules2.table_open = false
	rules2.groups = [RulesUKPool.REDS, RulesUKPool.YELLOWS]
	var sim2 := _table()
	rules2.begin_shot(sim2)
	_hit(sim2, 11)
	_cushion(sim2, 11)
	var report2 := rules2.end_shot(sim2)
	check("hitting one first is too", report2["foul"], report2["reason"])


func test_the_black() -> void:
	print("\n--- the black ---")
	# Potted early: loss of frame.
	var rules := RulesUKPool.new()
	rules.reset()
	rules.broken = true
	rules.table_open = false
	rules.groups = [RulesUKPool.REDS, RulesUKPool.YELLOWS]
	var sim := _table()
	rules.begin_shot(sim)
	_hit(sim, 3)
	_pot(sim, 8)
	var report := rules.end_shot(sim)
	check("the black potted early loses the frame",
		report["game_over"] and rules.winner == 1, report["reason"])

	# All seven down, then the black: that is the frame.
	var rules2 := RulesUKPool.new()
	rules2.reset()
	rules2.broken = true
	rules2.table_open = false
	rules2.groups = [RulesUKPool.REDS, RulesUKPool.YELLOWS]
	var sim2 := _table()
	_clear_group(sim2, RulesUKPool.REDS)
	check("with the reds gone the striker is on the black", rules2.on_black(sim2))
	rules2.begin_shot(sim2)
	_hit(sim2, 8)
	_pot(sim2, 8)
	var report2 := rules2.end_shot(sim2)
	check("the black potted on the black wins it",
		report2["game_over"] and rules2.winner == 0)

	# In-off while potting the black is still a loss.
	var rules3 := RulesUKPool.new()
	rules3.reset()
	rules3.broken = true
	rules3.table_open = false
	rules3.groups = [RulesUKPool.REDS, RulesUKPool.YELLOWS]
	var sim3 := _table()
	_clear_group(sim3, RulesUKPool.REDS)
	rules3.begin_shot(sim3)
	_hit(sim3, 8)
	_pot(sim3, 8)
	sim3.shot_log.append({"type": "pocket", "t": 0.4, "a": 0, "pocket": 1})
	var report3 := rules3.end_shot(sim3)
	check("going in-off with it loses instead",
		report3["game_over"] and rules3.winner == 1, report3["reason"])


## You come to the black by clearing your colour, and the black is on from the
## *next* stroke. The shot that pots your last one is played on your colour, and
## is judged that way -- even though by the time the engine looks at the table
## the colour it was played on is already off it.
func test_coming_to_the_black() -> void:
	print("\n--- coming to the black ---")
	var rules := RulesUKPool.new()
	rules.reset()
	rules.broken = true
	rules.table_open = false
	rules.groups = [RulesUKPool.YELLOWS, RulesUKPool.REDS]

	# Six yellows already gone; 15 is the last one.
	var sim := _table()
	for n: int in [9, 10, 11, 12, 13, 14]:
		_find(sim, n).state = PoolBall.POCKETED
	check("still on the colour with one left", not rules.on_black(sim))

	rules.begin_shot(sim)
	_hit(sim, 15)
	_pot(sim, 15)
	var report := rules.end_shot(sim)
	check("potting the last of the colour is not a foul",
		not report["foul"], report["reason"])
	check("and the striker stays at the table",
		not report["turn_passes"] and rules.player == 0)
	check("now they are on the black", rules.on_black(sim))

	# Same shot, but the black drops with it. That is potting the black before
	# being on it: loss of frame, not a win.
	var rules2 := RulesUKPool.new()
	rules2.reset()
	rules2.broken = true
	rules2.table_open = false
	rules2.groups = [RulesUKPool.YELLOWS, RulesUKPool.REDS]
	var sim2 := _table()
	for n2: int in [9, 10, 11, 12, 13, 14]:
		_find(sim2, n2).state = PoolBall.POCKETED
	rules2.begin_shot(sim2)
	_hit(sim2, 15)
	_pot(sim2, 15)
	_pot(sim2, 8)
	var report2 := rules2.end_shot(sim2)
	check("the last colour and the black together loses the frame",
		report2["game_over"] and rules2.winner == 1, report2["reason"])


func test_off_the_table() -> void:
	print("\n--- balls off the table ---")
	var rules := RulesUKPool.new()
	rules.reset()
	rules.broken = true
	rules.table_open = false
	rules.groups = [RulesUKPool.REDS, RulesUKPool.YELLOWS]
	var sim := _table()
	rules.begin_shot(sim)
	_hit(sim, 3)
	_cushion(sim, 3)                  # so the only thing wrong is where it ended
	_off_table(sim, 3)
	var report := rules.end_shot(sim)
	check("a ball off the table is a foul", report["foul"], report["reason"])
	check("and comes back", (report["respot"] as Array).has(3))

	# The black leaving the table is loss of frame, not a re-spot.
	var rules2 := RulesUKPool.new()
	rules2.reset()
	rules2.broken = true
	rules2.table_open = false
	rules2.groups = [RulesUKPool.REDS, RulesUKPool.YELLOWS]
	var sim2 := _table()
	_clear_group(sim2, RulesUKPool.REDS)
	rules2.begin_shot(sim2)
	_hit(sim2, 8)
	_off_table(sim2, 8)
	var report2 := rules2.end_shot(sim2)
	check("the black off the table loses the frame",
		report2["game_over"] and rules2.winner == 1, report2["reason"])
	check("and is not re-spotted", not (report2["respot"] as Array).has(8))
