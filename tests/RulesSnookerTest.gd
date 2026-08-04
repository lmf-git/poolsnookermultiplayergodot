extends Node

## The snooker rules, checked directly.
##
##     /Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
##         res://tests/RulesSnookerTest.tscn
##
## Same approach as RulesTest: the engine reads `PoolSim.shot_log` and nothing
## else, so a shot can be described rather than played.
##
## The emphasis here is fouls, because a foul is how snooker is scored against
## you: the striker never loses anything, the *opponent* is awarded the penalty,
## and if that award goes missing the game quietly stops keeping score properly.

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
	PoolPhys.configure(PoolPhys.SNOOKER)
	test_missing_everything()
	test_wrong_ball_first()
	test_in_off()
	test_potting_the_wrong_ball()
	test_ball_off_the_table()
	test_penalties_go_to_the_opponent()
	test_a_legal_red_scores()
	test_respotting()
	test_planner_sees_respotted_colours()
	print("\n%d passed, %d failed" % [_passed, _failed])
	get_tree().quit(1 if _failed > 0 else 0)


# ---------------------------------------------------------------------------

## Cue ball, fifteen reds and the six colours.
func _table() -> PoolSim:
	var sim := PoolSim.new(PoolTable.new())
	var cue := PoolBall.new(0, 0)
	cue.place(Vector3(0.0, 0.0, PoolPhys.HEAD_STRING_Z))
	sim.add_ball(cue)
	var id := 1
	for i in range(15):
		var r := PoolBall.new(id, 1)
		r.place(Vector3(-0.30 + 0.05 * float(i), 0.0, -0.60))
		sim.add_ball(r)
		id += 1
	for v in range(2, 8):
		var c := PoolBall.new(id, v)
		var s := PoolPhys.snooker_spot(v)
		c.place(Vector3(s.x, 0.0, s.y))
		sim.add_ball(c)
		id += 1
	return sim


func _rules() -> RulesSnooker:
	var r := RulesSnooker.new()
	r.reset()
	return r


func _find(sim: PoolSim, value: int) -> PoolBall:
	for b in sim.balls:
		if b.number == value and b.is_active():
			return b
	return null


func _hit(sim: PoolSim, value: int) -> void:
	sim.shot_log.append({"type": "ball", "t": 0.1, "a": 0, "b": value,
		"speed": 1.0})


func _pot(sim: PoolSim, value: int) -> void:
	var b := _find(sim, value)
	if b != null:
		b.state = PoolBall.POCKETED
	sim.shot_log.append({"type": "pocket", "t": 0.3, "a": value, "pocket": 0})


func _pot_cue(sim: PoolSim) -> void:
	sim.cue.state = PoolBall.POCKETED
	sim.shot_log.append({"type": "pocket", "t": 0.3, "a": 0, "pocket": 0})


func _off_table(sim: PoolSim, value: int) -> void:
	var b := _find(sim, value)
	if b != null:
		b.state = PoolBall.OFF_TABLE
	sim.shot_log.append({"type": "off_table", "t": 0.3, "a": value})


# ---------------------------------------------------------------------------

func test_missing_everything() -> void:
	print("\n--- missing every ball ---")
	var rules := _rules()
	var sim := _table()
	rules.begin_shot(sim)
	var report := rules.end_shot(sim)
	check("hitting nothing is a foul", report["foul"], report["reason"])
	check("worth the minimum four", report["penalty"] == RulesSnooker.MIN_FOUL,
		"%d" % report["penalty"])
	check("and the four go to the opponent", rules.score[1] == 4,
		"%s" % [rules.score])
	check("who is now at the table", rules.player == 1)


func test_wrong_ball_first() -> void:
	print("\n--- hitting the wrong ball first ---")
	# On a red, striking the black: the penalty is the higher of the two values,
	# so seven.
	var rules := _rules()
	var sim := _table()
	rules.begin_shot(sim)
	_hit(sim, 7)
	var report := rules.end_shot(sim)
	check("hitting the black when on a red is a foul", report["foul"],
		report["reason"])
	check("worth seven", report["penalty"] == 7, "%d" % report["penalty"])
	check("awarded to the opponent", rules.score[1] == 7, "%s" % [rules.score])

	# The same foul with a low colour is only worth the minimum.
	var rules2 := _rules()
	var sim2 := _table()
	rules2.begin_shot(sim2)
	_hit(sim2, 2)
	var report2 := rules2.end_shot(sim2)
	check("hitting the yellow instead is worth four",
		report2["penalty"] == 4, "%d" % report2["penalty"])


func test_in_off() -> void:
	print("\n--- in-off ---")
	var rules := _rules()
	var sim := _table()
	rules.begin_shot(sim)
	_hit(sim, 1)
	_pot(sim, 1)
	_pot_cue(sim)
	var report := rules.end_shot(sim)
	check("going in-off is a foul", report["foul"], report["reason"])
	check("worth at least four", report["penalty"] >= RulesSnooker.MIN_FOUL,
		"%d" % report["penalty"])
	check("the opponent is awarded it", rules.score[1] == report["penalty"],
		"%s" % [rules.score])
	check("the striker scores nothing for the red", rules.score[0] == 0,
		"%s" % [rules.score])
	check("and plays from the D next", rules.ball_in_hand)


func test_potting_the_wrong_ball() -> void:
	print("\n--- potting a ball that was not on ---")
	var rules := _rules()
	var sim := _table()
	rules.begin_shot(sim)
	_hit(sim, 1)                       # legal contact
	_pot(sim, 5)                       # but the blue drops
	var report := rules.end_shot(sim)
	check("potting the blue when on a red is a foul", report["foul"],
		report["reason"])
	check("worth five", report["penalty"] == 5, "%d" % report["penalty"])
	check("the opponent gets them", rules.score[1] == 5, "%s" % [rules.score])
	check("and the blue goes back on its spot",
		(report["respot"] as Array).has(5))


func test_ball_off_the_table() -> void:
	print("\n--- a ball forced off the table ---")
	# On a red, and a red is driven off the table. Snooker calls that a foul
	# worth four; the ball does not come back until the reds are done.
	var rules := _rules()
	var sim := _table()
	rules.begin_shot(sim)
	_hit(sim, 1)
	_off_table(sim, 1)
	var report := rules.end_shot(sim)
	check("a red off the table is a foul", report["foul"], report["reason"])
	check("worth four", report["penalty"] == RulesSnooker.MIN_FOUL,
		"%d" % report["penalty"])
	check("the opponent is awarded it", rules.score[1] == report["penalty"],
		"%s" % [rules.score])
	check("and the striker is not credited with a pot", rules.score[0] == 0,
		"%s" % [rules.score])

	# A colour off the table is worth its own value.
	var rules2 := _rules()
	var sim2 := _table()
	rules2.begin_shot(sim2)
	_hit(sim2, 1)
	_pot(sim2, 1)
	rules2.end_shot(sim2)              # red down, now on a colour
	var sim3 := _table()
	rules2.begin_shot(sim3)
	_hit(sim3, 6)
	_off_table(sim3, 6)
	var report3 := rules2.end_shot(sim3)
	check("the pink off the table is a foul", report3["foul"], report3["reason"])
	# Seven rather than six: with a colour on and no way to nominate one, the
	# engine values the ball on at the highest colour, which in-off already does
	# too. The penalty is the greater of that and the ball concerned.
	check("worth at least the pink", report3["penalty"] >= 6,
		"%d" % report3["penalty"])
	check("and seven, priced off the ball on", report3["penalty"] == 7,
		"%d" % report3["penalty"])


func test_penalties_go_to_the_opponent() -> void:
	print("\n--- penalties accumulate on the right side ---")
	var rules := _rules()
	# Player 1 fouls twice in a row (player 2 fouls in between to hand it back).
	var sim := _table()
	rules.begin_shot(sim)
	_hit(sim, 7)
	rules.end_shot(sim)                # p1 fouls: 7 to p2
	check("first foul scores to player 2", rules.score[1] == 7,
		"%s" % [rules.score])
	check("and the striker's own score is untouched", rules.score[0] == 0,
		"%s" % [rules.score])

	var sim2 := _table()
	rules.begin_shot(sim2)
	_hit(sim2, 7)
	rules.end_shot(sim2)               # p2 fouls: 7 to p1
	check("the next foul scores the other way",
		rules.score[0] == 7 and rules.score[1] == 7, "%s" % [rules.score])


func test_a_legal_red_scores() -> void:
	print("\n--- a legal pot still scores ---")
	var rules := _rules()
	var sim := _table()
	rules.begin_shot(sim)
	_hit(sim, 1)
	_pot(sim, 1)
	var report := rules.end_shot(sim)
	check("a red potted legally is not a foul", not report["foul"],
		report["reason"])
	check("worth one", report["points"] == 1, "%d" % report["points"])
	check("to the striker", rules.score[0] == 1, "%s" % [rules.score])
	check("who stays at the table", rules.player == 0)
	check("and is now on a colour", not rules.on_red)


func test_respotting() -> void:
	print("\n--- respotting colours ---")
	var sim := _table()
	var blue := _find(sim, 5)
	blue.state = PoolBall.POCKETED
	var p := RulesSnooker.respot_position(sim, 5, blue)
	check("a colour returns to its own spot",
		p.distance_to(PoolPhys.snooker_spot(5)) < 0.001,
		"%v" % p)

	# With its own spot occupied it takes another, and one that is actually free.
	var sim2 := _table()
	var pink := _find(sim2, 6)
	pink.state = PoolBall.POCKETED
	var pink_spot := PoolPhys.snooker_spot(6)
	_find(sim2, 1).place(Vector3(pink_spot.x, 0.0, pink_spot.y))
	var p2 := RulesSnooker.respot_position(sim2, 6, pink)
	check("a colour whose spot is taken goes somewhere else",
		p2.distance_to(pink_spot) > PoolPhys.BALL_R, "%v" % p2)
	check("somewhere legal", sim2.table.is_legal_center(p2), "%v" % p2)
	check("and somewhere clear", sim2.spot_clear(p2, pink),
		"%v" % p2)


## The planner judges what a shot leaves -- what is on next, whether the line to
## it is clear -- off the table as it simulated it. In snooker that table is
## wrong until the colours are back on their spots.
func test_planner_sees_respotted_colours() -> void:
	print("\n--- the planner sees respotted colours ---")
	var rules := _rules()
	var sim := _table()
	var ai := AIPlayer.new(AIPlayer.HARD, 11)
	ai.begin(sim, rules, PoolPhys.SNOOKER, false)

	var state := sim.clone_for_prediction()
	var black: PoolBall = null
	for b in state.balls:
		if b.number == 7:
			black = b
			break
	black.state = PoolBall.POCKETED
	check("the black is off the simulated table to begin with",
		not black.is_active())

	ai._restore_respots(state, {
		"potted": [7] as Array[int], "off_table": [] as Array[int]})
	check("the planner puts it back", black.is_active())
	check("on its spot", Vector2(black.pos.x, black.pos.z)
		.distance_to(PoolPhys.snooker_spot(7)) < 0.01, "%v" % black.pos)

	# During the clearance the colour that was on stays down.
	var rules2 := _rules()
	rules2.reds_done = true
	rules2.colour_order = 7
	var sim3 := _table()
	var ai2 := AIPlayer.new(AIPlayer.HARD, 11)
	ai2.begin(sim3, rules2, PoolPhys.SNOOKER, false)
	var state2 := sim3.clone_for_prediction()
	var black2: PoolBall = null
	for b in state2.balls:
		if b.number == 7:
			black2 = b
			break
	black2.state = PoolBall.POCKETED
	ai2._restore_respots(state2, {
		"potted": [7] as Array[int], "off_table": [] as Array[int]})
	check("but the colour on in the clearance stays down",
		not black2.is_active())
