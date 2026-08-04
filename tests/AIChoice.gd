extends Node

## What the computer player thinks a shot is worth.
##
##     /Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
##         res://tests/AIChoice.tscn
##
## The planner picks its shot from a single noiseless playout -- the shot it
## *means* to play -- and only afterwards perturbs the aim by what its hands are
## up to. So on its own the search cannot tell a pot with a ball's width to spare
## from one that drops exactly once, struck perfectly. `_aim_allowance` and
## `_robustness` are what close that gap, and this checks both the arithmetic and
## the behaviour it is supposed to produce.

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
	test_allowance()
	test_robustness()
	test_it_takes_the_makeable_pot()
	print("\n%d passed, %d failed" % [_passed, _failed])
	get_tree().quit(1 if _failed > 0 else 0)


# ---------------------------------------------------------------------------

## A comfortable corner pocket's clear opening, square on.
func _opening() -> float:
	var table := PoolTable.new()
	for pk in table.pockets:
		if pk.is_corner:
			return pk.opening_along(-pk.normal)
	return 0.03


func test_allowance() -> void:
	print("\n--- how far the aim may be out ---")
	var ai := AIPlayer.new(AIPlayer.PRO, 1)
	var w := _opening()

	var near := ai._aim_allowance(0.3, 0.5, w)
	var far := ai._aim_allowance(1.5, 0.5, w)
	check("a longer cue-ball travel forgives less", far < near,
		"%.5f vs %.5f rad" % [far, near])

	var close_obj := ai._aim_allowance(0.6, 0.3, w)
	var far_obj := ai._aim_allowance(0.6, 1.6, w)
	check("so does a longer pot", far_obj < close_obj,
		"%.5f vs %.5f rad" % [far_obj, close_obj])

	var wide := ai._aim_allowance(0.6, 0.8, w)
	var narrow := ai._aim_allowance(0.6, 0.8, w * 0.25)
	check("a tighter opening forgives less", narrow < wide,
		"%.5f vs %.5f rad" % [narrow, wide])
	check("and a shut pocket forgives nothing",
		ai._aim_allowance(0.6, 0.8, -0.01) == 0.0)


func test_robustness() -> void:
	print("\n--- how likely the shot is to come off ---")
	var w := _opening()

	# A sitter: cue ball on it, ball on the pocket, struck gently.
	var sitter := AIPlayer.Candidate.new()
	sitter.cue_dist = 0.20
	sitter.speed = 1.5
	sitter.aim_allow = 0.0

	# A long thin one into a nearly shut pocket.
	var nasty := AIPlayer.Candidate.new()
	nasty.cue_dist = 1.6
	nasty.speed = 3.5
	nasty.aim_allow = 0.0

	for level in [AIPlayer.EASY, AIPlayer.PRO]:
		var ai := AIPlayer.new(level, 1)
		sitter.aim_allow = ai._aim_allowance(0.20, 0.15, w)
		nasty.aim_allow = ai._aim_allowance(1.60, 1.50, w * 0.18)
		var rs := ai._robustness(sitter)
		var rn := ai._robustness(nasty)
		check("%s is sure of a sitter" % AIPlayer.LEVEL_NAMES[level], rs > 0.9,
			"%.3f" % rs)
		check("%s is not sure of a long thin one"
			% AIPlayer.LEVEL_NAMES[level], rn < rs, "%.3f vs %.3f" % [rn, rs])

	# The better player is surer of the same hard shot -- that is what the levels
	# differ in, and the model has to reflect it or every level plays alike.
	var easy := AIPlayer.new(AIPlayer.EASY, 1)
	var pro := AIPlayer.new(AIPlayer.PRO, 1)
	nasty.aim_allow = easy._aim_allowance(1.20, 1.00, w * 0.4)
	check("and a better player is surer of a hard one",
		pro._robustness(nasty) > easy._robustness(nasty),
		"pro %.3f vs easy %.3f"
			% [pro._robustness(nasty), easy._robustness(nasty)])

	# Nothing that is not a pot is discounted: a safety has no pocket to miss.
	var safety := AIPlayer.Candidate.new()
	check("a shot with nothing to hit forgives everything",
		pro._robustness(safety) == 1.0)
	check("and its value is left alone",
		pro._weigh_by_certainty(safety, 40.0) == 40.0)

	# The contract, stated exactly: two shots that the playout says are worth the
	# same are not worth the same if one of them needs a perfect stroke.
	var sure := AIPlayer.Candidate.new()
	sure.cue_dist = 0.35
	sure.speed = 1.6
	sure.aim_allow = pro._aim_allowance(0.35, 0.25, w)
	var dicey := AIPlayer.Candidate.new()
	dicey.cue_dist = 1.7
	dicey.speed = 3.6
	dicey.aim_allow = pro._aim_allowance(1.70, 1.40, w * 0.2)
	check("of two shots the playout rates alike, the surer one scores higher",
		pro._weigh_by_certainty(sure, 100.0)
			> pro._weigh_by_certainty(dicey, 100.0),
		"%.1f vs %.1f" % [pro._weigh_by_certainty(sure, 100.0),
			pro._weigh_by_certainty(dicey, 100.0)])
	# A shot already worth less than missing is not improved by being unlikely.
	check("but a bad shot is not flattered by being a long shot",
		pro._weigh_by_certainty(dicey, -500.0) == -500.0)


## The point of the whole exercise: offered a certain pot and a marginal one, it
## takes the certain one.
func test_it_takes_the_makeable_pot() -> void:
	print("\n--- it takes the pot it can make ---")
	var table := PoolTable.new()
	var sim := PoolSim.new(table)

	var cue := PoolBall.new(0, 0)
	cue.place(Vector3(0.0, 0.0, 0.30))
	sim.add_ball(cue)

	# A sitter: a ball hanging over the near corner, straight in front of the cue
	# ball. Number 3, so it is a red.
	var easy_ball := PoolBall.new(1, 3)
	easy_ball.place(Vector3(-PoolPhys.HALF_W + 0.16, 0.0,
		PoolPhys.HALF_L - 0.16))
	sim.add_ball(easy_ball)

	# The other red, right down the far end and cut thin into the far corner:
	# legal, findable, and a great deal harder.
	var hard_ball := PoolBall.new(2, 5)
	hard_ball.place(Vector3(PoolPhys.HALF_W - 0.30, 0.0,
		-PoolPhys.HALF_L + 0.22))
	sim.add_ball(hard_ball)

	var rules := RulesUKPool.new()
	rules.reset()
	rules.broken = true
	rules.ball_in_hand = false
	rules.table_open = false
	rules.groups = [RulesUKPool.REDS, RulesUKPool.YELLOWS]

	# Medium and Hard only. Pro shoots to about a millimetre at a metre and plays
	# for position as hard as it plays for the pot, so taking the longer ball to
	# be better placed afterwards is a defensible choice rather than a lapse --
	# asserting it must always take the sitter would be asserting the wrong thing.
	for level in [AIPlayer.MEDIUM, AIPlayer.HARD]:
		var ai := AIPlayer.new(level, 20250803)
		ai.begin(sim, rules, PoolPhys.GAME_EIGHT_BALL, false)
		var guard := 0
		while not ai.think(1000.0) and guard < 400:
			guard += 1
		check("%s settles on a shot" % AIPlayer.LEVEL_NAMES[level],
			ai.shot != null)
		if ai.shot != null:
			check("%s goes for the ball it can actually pot"
				% AIPlayer.LEVEL_NAMES[level], ai.shot.target == 3,
				"chose ball %d" % ai.shot.target)
