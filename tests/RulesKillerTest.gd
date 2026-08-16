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
## taking a life off the wrong player, passing the table to somebody already out,
## or failing to notice that only one is left.

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
	test_missing_costs_a_life()
	test_fouls_cost_a_life()
	test_the_break_is_free()
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


## Rules for `n` players, with the pack already broken so the shot under test is
## judged as an ordinary visit. The break has rules of its own -- it asks for a
## fair break rather than a pot, which `test_the_break_is_free` covers -- and
## everything else here is about what happens once it has been played.
func _rules(n: int, broken := true) -> RulesKiller:
	var r := RulesKiller.new()
	r.reset(n)
	r.broken = broken
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


## A break that pots nothing but sends two balls to a cushion, which is all the
## break is asked for.
func _break_off(rules: RulesKiller) -> Dictionary:
	var sim := _table()
	rules.begin_shot(sim)
	_hit(sim, 1)
	_cushion(sim, 1)
	_cushion(sim, 2)
	return rules.end_shot(sim)


# ---------------------------------------------------------------------------

func test_potting_survives() -> void:
	print("\n--- potting a ball survives the visit ---")
	var rules := _rules(4)
	var report := _survive(rules, 3)
	check("potting is not a foul", not report["foul"], report["reason"])
	check("nobody loses a life", report["lost_life"] == -1)
	check("and the striker keeps all of theirs",
		rules.lives[0] == RulesKiller.LIVES)
	check("all four are still in", rules.alive_count() == 4)
	# One shot a visit: the table passes even though the shot was successful.
	check("the table still passes", rules.player == 1)


func test_missing_costs_a_life() -> void:
	print("\n--- missing costs a life, and three of them puts you out ---")
	var rules := _rules(3)
	var report := _miss(rules)
	check("a shot that pots nothing takes a life",
		report["lost_life"] == 0, report["reason"])
	check("but does not put the striker out", report["eliminated"] == -1)
	check("player 1 is still in", rules.is_alive(0))
	check("with one life gone", rules.lives[0] == RulesKiller.LIVES - 1,
		"%d left" % rules.lives[0])
	check("all three are in", rules.alive_count() == 3)
	check("and player 2 is up", rules.player == 1)

	# The same player again, on their last life.
	var rules2 := _rules(3)
	rules2.lives[0] = 1
	var report2 := _miss(rules2)
	check("missing on your last life puts you out",
		report2["eliminated"] == 0, report2["reason"])
	check("player 1 is out", not rules2.is_alive(0))
	check("the other two are in", rules2.alive_count() == 2)


func test_fouls_cost_a_life() -> void:
	print("\n--- fouling costs a life too ---")
	# In-off, even though a ball went down.
	var rules := _rules(3)
	var sim := _table()
	rules.begin_shot(sim)
	_hit(sim, 3)
	_pot(sim, 3)
	_pot_cue(sim)
	var report := rules.end_shot(sim)
	check("going in-off is a foul", report["foul"], report["reason"])
	check("and the pot does not save you", report["lost_life"] == 0)
	check("the next player has it in hand", rules.ball_in_hand)

	# Hitting nothing at all.
	var rules2 := _rules(3)
	var sim2 := _table()
	rules2.begin_shot(sim2)
	var report2 := rules2.end_shot(sim2)
	check("hitting nothing is a foul", report2["foul"], report2["reason"])
	check("and costs a life", report2["lost_life"] == 0)

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
	check("and the striker pays for it", report3["lost_life"] == 0)


## The break is the one visit that does not have to pot. A full pack is nobody's
## chance, so all it is asked for is a proper break.
func test_the_break_is_free() -> void:
	print("\n--- the break costs nothing if it is a fair break ---")
	var rules := _rules(4, false)
	var report := _break_off(rules)
	check("a break that pots nothing is not a foul", not report["foul"],
		report["reason"])
	check("and costs nobody a life", report["lost_life"] == -1)
	check("the breaker still has all three",
		rules.lives[0] == RulesKiller.LIVES)
	check("the report says it was the break", report["break_shot"])
	check("the table passes", rules.player == 1)
	check("and the pack is broken now", rules.broken)

	# One ball to a cushion is a nudge, not a break.
	var rules2 := _rules(4, false)
	var sim2 := _table()
	rules2.begin_shot(sim2)
	_hit(sim2, 1)
	_cushion(sim2, 1)
	var report2 := rules2.end_shot(sim2)
	check("fewer than two balls to a cushion is not a break",
		report2["foul"], report2["reason"])
	check("and it costs a life", report2["lost_life"] == 0)

	# A short break that pots is a break whatever the cushions did.
	var rules3 := _rules(4, false)
	var sim3 := _table()
	rules3.begin_shot(sim3)
	_hit(sim3, 1)
	_pot(sim3, 1)
	var report3 := rules3.end_shot(sim3)
	check("potting off the break settles it", not report3["foul"],
		report3["reason"])
	check("and costs nothing", report3["lost_life"] == -1)

	# Fouls are still fouls on the break.
	var rules4 := _rules(4, false)
	var sim4 := _table()
	rules4.begin_shot(sim4)
	_hit(sim4, 1)
	_cushion(sim4, 1)
	_cushion(sim4, 2)
	_pot_cue(sim4)
	var report4 := rules4.end_shot(sim4)
	check("going in-off on the break is still a foul", report4["foul"],
		report4["reason"])
	check("and still costs a life", report4["lost_life"] == 0)
	check("the breaker is down to two", rules4.lives[0] == RulesKiller.LIVES - 1)

	# A ball rattling in and out of a pocket is what a full pack does.
	var rules5 := _rules(4, false)
	var sim5 := _table()
	rules5.begin_shot(sim5)
	_hit(sim5, 1)
	_cushion(sim5, 1)
	_cushion(sim5, 2)
	sim5.shot_log.append({"type": "escaped_pocket", "t": 0.4, "a": 2})
	var report5 := rules5.end_shot(sim5)
	check("a ball jumping back out of a pocket is not a foul on the break",
		not report5["foul"], report5["reason"])
	check("and costs nothing", report5["lost_life"] == -1)

	# And once the pack is broken, the pot is required again.
	var rules6 := _rules(4, false)
	_break_off(rules6)
	var report6 := _miss(rules6)
	check("the visit after the break has to pot", report6["lost_life"] == 1,
		report6["reason"])
	check("only the striker pays", rules6.lives[0] == RulesKiller.LIVES
		and rules6.lives[1] == RulesKiller.LIVES - 1)


func test_the_table_skips_the_eliminated() -> void:
	print("\n--- the table skips players who are out ---")
	var rules := _rules(4)
	# Player 1 is on their last life, misses and is out; play should reach
	# 2, 3, 4 then back to 2.
	rules.lives[0] = 1
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
	# Everybody misses every visit, so they go out in seating order and the frame
	# is decided the moment the second-to-last life goes.
	var rules := _rules(3)
	var visits := 0
	while not rules.game_over and visits < 64:
		_miss(rules)
		visits += 1
	check("it takes three lives each to settle it",
		visits == 3 * RulesKiller.LIVES - 1, "%d visits" % visits)
	check("the frame is over once only one is left", rules.game_over)
	check("and player 3 has won", rules.winner == 2,
		"winner %d" % (rules.winner + 1))

	# Heads-up, the same thing with one fewer player round the table.
	var rules2 := _rules(2)
	var visits2 := 0
	while not rules2.game_over and visits2 < 64:
		_miss(rules2)
		visits2 += 1
	check("heads-up it takes one player's lives, plus their opponent's misses",
		visits2 == 2 * RulesKiller.LIVES - 1, "%d visits" % visits2)
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
	check("and nobody pays for it", report["lost_life"] == -1)


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
	check("nobody loses a life for it", report["lost_life"] == -1)
	check("it asks for a re-rack", report["rerack"])
	check("which is a break again", not rules.broken and rules.in_hand_in_d())
	check("and the next player breaks it", rules.player == 1)

	# The fresh rack is broken like any other, so it is free too.
	var report2 := _break_off(rules)
	check("the re-racked break costs nothing either",
		report2["lost_life"] == -1, report2["reason"])
	check("and everyone still has their lives",
		rules.lives[1] == RulesKiller.LIVES)
