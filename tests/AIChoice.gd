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
	test_delivered_speed()
	test_travel_with_spin()
	test_the_pot_still_gets_there()
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


## How hard the CPU thinks it is hitting the ball, against how hard it is really
## hitting it. Everything about pace rests on this one inversion, and while it
## was a centre-ball, level-cue idealisation the CPU was quietly under-hitting
## every draw, every follow and every shot played from near a cushion.
func test_delivered_speed() -> void:
	print("\n--- the stroke delivers the speed it was chosen for ---")
	for want: float in [0.9, 2.2, 4.0]:
		for tip: Vector2 in [Vector2.ZERO, Vector2(0.0, 0.38),
				Vector2(0.0, -0.38), Vector2(0.30, 0.10)]:
			for elev: float in [0.0, deg_to_rad(20.0)]:
				var speed := AIPlayer._cue_speed_for_ball_speed(want, tip, elev)
				# A stroke held to the ends of the player's own range is not
				# claiming to deliver the speed that was asked for.
				if speed >= PoolPhys.max_cue_speed(elev) - 1.0e-6 \
						or speed <= PoolPhys.CUE_SPEED_MIN + 1.0e-6:
					continue
				var sim := PoolSim.new(PoolTable.new())
				var cue := PoolBall.new(0, 0)
				cue.place(Vector3(0.0, 0.0, 0.0))
				sim.add_ball(cue)
				sim.begin_shot()
				PoolSim.cue_strike(cue, Vector3(0, 0, -1), speed, tip.x, tip.y,
					elev, true, 0.0)
				var got := Vector2(cue.vel.x, cue.vel.z).length()
				check("tip %+.2f,%+.2f at %.0f deg wanting %.1f m/s"
					% [tip.x, tip.y, rad_to_deg(elev), want],
					absf(got - want) < 0.06 * want, "got %.2f m/s" % got)
	# And the whole point of it: the same wanted speed asks for a firmer stroke
	# once the cue is off centre or in the air.
	var level_centre := AIPlayer._cue_speed_for_ball_speed(2.0)
	var screwed := AIPlayer._cue_speed_for_ball_speed(2.0, Vector2(0.0, -0.38))
	var lifted := AIPlayer._cue_speed_for_ball_speed(2.0, Vector2.ZERO,
		deg_to_rad(25.0))
	check("a screw shot has to be struck harder than a centre-ball one",
		screwed > level_centre * 1.15, "%.2f vs %.2f" % [screwed, level_centre])
	check("and so does one played with the butt in the air",
		lifted > level_centre * 1.05, "%.2f vs %.2f" % [lifted, level_centre])


## How far the ball actually runs, against how far the planner thinks it will.
## The old model was the centre-ball one for every stroke, which is 40% wrong for
## a follow shot in one direction and 30% wrong for a screw shot in the other.
func test_travel_with_spin() -> void:
	print("\n--- travel allows for the spin the stroke put on ---")
	var d := 1.0
	for tip_y: float in [0.0, 0.38, -0.38]:
		var sim := PoolSim.new(PoolTable.new())
		var cue := PoolBall.new(0, 0)
		# Started up the table so a metre of roll never reaches a cushion.
		cue.place(Vector3(0.0, 0.0, PoolPhys.HALF_L - 0.30))
		sim.add_ball(cue)
		sim.begin_shot()
		var launch := 2.0
		var speed := AIPlayer._cue_speed_for_ball_speed(launch,
			Vector2(0.0, tip_y))
		PoolSim.cue_strike(cue, Vector3(0, 0, -1), speed, 0.0, tip_y, 0.0,
			true, 0.0)
		# Roll it exactly `d` metres and read the speed there.
		var start := cue.pos.z
		var got := 0.0
		for _i in range(4000):
			sim.advance(0.002)
			if absf(cue.pos.z - start) >= d:
				got = Vector2(cue.vel.x, cue.vel.z).length()
				break
		var want := AIPlayer.speed_after(launch, d, tip_y)
		check("tip %+.2f: %.2f m/s a metre on, model says %.2f"
			% [tip_y, got, want], absf(got - want) < 0.15 * maxf(want, 0.2))

	check("a follow shot keeps more of its speed than a centre-ball one",
		AIPlayer.speed_after(2.0, 1.0, 0.38) > AIPlayer.speed_after(2.0, 1.0),
		"%.2f vs %.2f" % [AIPlayer.speed_after(2.0, 1.0, 0.38),
			AIPlayer.speed_after(2.0, 1.0)])
	check("and a screw shot keeps less",
		AIPlayer.speed_after(2.0, 1.0, -0.38) < AIPlayer.speed_after(2.0, 1.0),
		"%.2f vs %.2f" % [AIPlayer.speed_after(2.0, 1.0, -0.38),
			AIPlayer.speed_after(2.0, 1.0)])


## The bug this is all about: a shot aimed right and struck light, with the ball
## stopping short of the pocket. The stroke the planner chooses has to drop the
## ball *and* still drop it when the level's own hands come up light on it.
func test_the_pot_still_gets_there() -> void:
	print("\n--- the pace it chooses pots the ball, light stroke and all ---")
	var table := PoolTable.new()
	# A corner pocket, and the line into it from out in the table.
	var pocket: PoolTable.Pocket = null
	for pk in table.pockets:
		if pk.is_corner:
			pocket = pk
			break
	var aim_pt: Vector2 = pocket.mouth + pocket.normal * AIPlayer.POCKET_AIM_DEPTH
	# Into the table, along the pocket's own line: square into the corner, which
	# is the pot with nothing else going on in it.
	var away := -pocket.normal.normalized()
	# A corner's line runs diagonally, so everything has to fit on that diagonal.
	var gap := 0.45

	for level in range(4):
		var ai := AIPlayer.new(level, 4242)
		for d_obj: float in [0.4, 0.8]:
			for tip: Vector2 in [Vector2.ZERO, Vector2(0.0, -0.38)]:
				var sim := PoolSim.new(table)
				var obj2 := aim_pt + away * d_obj
				var cue2 := aim_pt + away * (d_obj + gap)
				var cue := PoolBall.new(0, 0)
				cue.place(Vector3(cue2.x, 0.0, cue2.y))
				sim.add_ball(cue)
				var obj := PoolBall.new(1, 3)
				obj.place(Vector3(obj2.x, 0.0, obj2.y))
				sim.add_ball(obj)
				sim.begin_shot()

				var elev := sim.clearance_elevation(
					Vector3(-away.x, 0.0, -away.y))
				# Cue ball to ghost ball, which is a diameter short of the object.
				var speed: float = ai._speed_for_pot(gap - PoolPhys.BALL_D,
					d_obj, 1.0, tip, elev)
				# Struck as light as the level's hands are likely to make it.
				speed *= 1.0 - AIPlayer.POWER_MARGIN_SIGMAS * ai.skill.power_error
				PoolSim.cue_strike(cue, Vector3(-away.x, 0.0, -away.y), speed,
					tip.x, tip.y, elev, true, 0.0)
				sim.simulate_to_rest(30.0)
				check("%s, %.1f m pot%s, struck light: down"
					% [AIPlayer.LEVEL_NAMES[level], d_obj,
						" with screw" if tip.y < 0.0 else ""],
					obj.state == PoolBall.POCKETED,
					"ended %.3f m short of the pocket"
						% Vector2(obj.pos.x, obj.pos.z).distance_to(aim_pt))


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
