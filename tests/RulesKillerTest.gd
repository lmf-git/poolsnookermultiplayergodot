extends Node

## Killer, checked directly.
##
##     /Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
##         res://tests/RulesKillerTest.tscn
##
## Same approach as the other two rules tests: the engine reads
## `PoolSim.shot_log` and nothing else, so a shot can be described rather than
## played.
##
## Killer is a knockout, so most of what can go wrong is about who is still in:
## eliminating the wrong player, passing the table to somebody already out, or
## failing to notice that only one is left.

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
	test_potting_survives()
	test_missing_is_out()
	test_fouls_are_out()
	test_the_table_skips_the_eliminated()
	test_last_one_standing()
	test_every_ball_is_on()
	test_clearing_the_table_re_racks()
	print("\n%d passed, %d failed" % [_passed, _failed])
	get_tree().quit(1 if _failed > 0 else 0)


# ---------------------------------------------------------------------------

## Cue ball and the fifteen pool balls.
func _table() -> PoolSim:
	var sim := PoolSim.new(PoolTable.new())
	var cue := PoolBall.new(0, 0)
	cue.place(Vector3(0.0, 0.0, PoolPhys.HEAD_STRING_Z))
	sim.add_ball(cue)
	var id := 1
	for n in range(1, 16):
		var b := PoolBall.new(id, n)
		b.place(Vector3(-0.3 + 0.04 * float(id), 0.0, -0.6 + 0.05 * float(id)))
		sim.add_ball(b)
		id += 1
	return sim


func _rules(n: int) -> RulesKiller:
	var r := RulesKiller.new()
	r.reset(n)
	return r


func _find(sim: PoolSim, number: int) -> PoolBall:
	for b in sim.balls:
		if b.number == number:
			return b
	return null


func _hit(sim: PoolSim, number: int) -> void:
	sim.shot_log.append({"type": "ball", "t": 0.1, "a": 0, "b": number,
		"speed": 1.0})


func _cushion(sim: PoolSim, number: int) -> void:
	sim.shot_log.append({"type": "cushion", "t": 0.2, "a": number, "speed": 1.0})


func _pot(sim: PoolSim, number: int) -> void:
	var b := _find(sim, number)
	if b != null:
		b.state = PoolBall.POCKETED
	sim.shot_log.append({"type": "pocket", "t": 0.3, "a": number, "pocket": 0})


func _pot_cue(sim: PoolSim) -> void:
	sim.shot_log.append({"type": "pocket", "t": 0.3, "a": 0, "pocket": 0})


func _off_table(sim: PoolSim, number: int) -> void:
	var b := _find(sim, number)
	if b != null:
		b.state = PoolBall.OFF_TABLE
	sim.shot_log.append({"type": "off_table", "t": 0.3, "a": number})


## One shot that pots a ball, for driving a game forward.
func _survive(rules: RulesKiller, ball: int) -> Dictionary:
	var sim := _table()
	rules.begin_shot(sim)
	_hit(sim, ball)
	_pot(sim, ball)
	return rules.end_shot(sim)


## One shot that pots nothing.
func _miss(rules: RulesKiller) -> Dictionary:
	var sim := _table()
	rules.begin_shot(sim)
	_hit(sim, 3)
	_cushion(sim, 3)
	return rules.end_shot(sim)


# ---------------------------------------------------------------------------

func test_potting_survives() -> void:
	print("\n--- potting a ball survives the visit ---")
	var rules := _rules(4)
	var report := _survive(rules, 3)
	check("potting is not a foul", not report["foul"], report["reason"])
	check("nobody goes out", report["eliminated"] == -1)
	check("all four are still in", rules.alive_count() == 4)
	# One shot a visit: the table passes even though the shot was successful.
	check("the table still passes", rules.player == 1)


func test_missing_is_out() -> void:
	print("\n--- missing puts you out ---")
	var rules := _rules(3)
	var report := _miss(rules)
	check("a shot that pots nothing eliminates the striker",
		report["eliminated"] == 0, report["reason"])
	check("player 1 is out", not rules.is_alive(0))
	check("the other two are in", rules.alive_count() == 2)
	check("and player 2 is up", rules.player == 1)


func test_fouls_are_out() -> void:
	print("\n--- fouling puts you out too ---")
	# In-off, even though a ball went down.
	var rules := _rules(3)
	var sim := _table()
	rules.begin_shot(sim)
	_hit(sim, 3)
	_pot(sim, 3)
	_pot_cue(sim)
	var report := rules.end_shot(sim)
	check("going in-off is a foul", report["foul"], report["reason"])
	check("and the pot does not save you", report["eliminated"] == 0)
	check("the next player has it in hand", rules.ball_in_hand)

	# Hitting nothing at all.
	var rules2 := _rules(3)
	var sim2 := _table()
	rules2.begin_shot(sim2)
	var report2 := rules2.end_shot(sim2)
	check("hitting nothing is a foul", report2["foul"], report2["reason"])
	check("and puts you out", report2["eliminated"] == 0)

	# A ball off the table.
	var rules3 := _rules(3)
	var sim3 := _table()
	rules3.begin_shot(sim3)
	_hit(sim3, 3)
	_cushion(sim3, 3)
	_off_table(sim3, 3)
	var report3 := rules3.end_shot(sim3)
	check("a ball off the table is a foul", report3["foul"], report3["reason"])
	check("it comes back on the spot", (report3["respot"] as Array).has(3))
	check("and the striker is out", report3["eliminated"] == 0)


func test_the_table_skips_the_eliminated() -> void:
	print("\n--- the table skips players who are out ---")
	var rules := _rules(4)
	# Player 1 misses and is out; play should reach 2, 3, 4 then back to 2.
	_miss(rules)
	check("player 1 is out", not rules.is_alive(0))
	check("player 2 is up", rules.player == 1)
	_survive(rules, 3)
	check("then player 3", rules.player == 2)
	_survive(rules, 4)
	check("then player 4", rules.player == 3)
	_survive(rules, 5)
	check("and round to player 2, not the eliminated player 1",
		rules.player == 1, "player %d" % (rules.player + 1))


func test_last_one_standing() -> void:
	print("\n--- last one standing wins ---")
	var rules := _rules(3)
	_miss(rules)                       # p1 out, p2 up
	check("two left", rules.alive_count() == 2 and not rules.game_over)
	_miss(rules)                       # p2 out, p3 up
	check("the frame is over once only one is left", rules.game_over)
	check("and player 3 has won", rules.winner == 2,
		"winner %d" % (rules.winner + 1))

	# With two players it takes a single miss.
	var rules2 := _rules(2)
	_miss(rules2)
	check("heads-up, one miss decides it", rules2.game_over)
	check("the other player wins", rules2.winner == 1)


func test_every_ball_is_on() -> void:
	print("\n--- every ball is a legal target ---")
	var rules := _rules(3)
	var sim := _table()
	check("all fifteen are on", rules.legal_targets(sim).size() == 15)
	check("including the black", rules.is_legal_first_hit(sim, 8))
	check("and the cue ball is not", not rules.is_legal_first_hit(sim, 0))

	# Potting the black is an ordinary pot, worth exactly one survived visit.
	var report := _survive(rules, 8)
	check("potting the black is not a foul", not report["foul"],
		report["reason"])
	check("and nobody is out for it", report["eliminated"] == -1)


func test_clearing_the_table_re_racks() -> void:
	print("\n--- clearing the table re-racks ---")
	var rules := _rules(3)
	var sim := _table()
	# Everything down but one, then the striker pots the last of them.
	for n in range(1, 15):
		_find(sim, n).state = PoolBall.POCKETED
	rules.begin_shot(sim)
	_hit(sim, 15)
	_pot(sim, 15)
	var report := rules.end_shot(sim)
	check("clearing the table is not a foul", not report["foul"],
		report["reason"])
	check("nobody is eliminated for it", report["eliminated"] == -1)
	check("it asks for a re-rack", report["rerack"])
	check("which is a break again", not rules.broken and rules.in_hand_in_d())
	check("and the next player breaks it", rules.player == 1)
