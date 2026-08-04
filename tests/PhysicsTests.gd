extends Node

## Headless validation of the billiards engine.
##
##     /Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
##         res://tests/TestRunner.tscn
##
## These are not smoke tests. Each one checks the simulation against a result
## that is either analytically derivable or a well-known fact about how real
## pool balls behave (the 5/7 rule, the 90-degree rule, draw/stun/follow
## ordering, cushions rebounding long, throw on a cut shot).

var _passed := 0
var _failed := 0
var _lines: PackedStringArray = []


func _ready() -> void:
	# The table spec is global and configurable now, so pin it for the suite.
	PoolPhys.configure(PoolPhys.POOL)
	_header("polynomial root finding")
	test_roots()
	_header("single-ball motion phases")
	test_five_sevenths()
	test_slide_time()
	test_spin_decay()
	_header("cue strike")
	test_strike_speed()
	test_english_costs_power()
	test_squirt()
	_header("ball-ball collisions")
	test_ninety_degree_rule()
	test_draw_stun_follow()
	test_throw()
	test_momentum_and_energy()
	_header("cushions")
	test_cushion_rebounds_long()
	test_english_changes_rebound()
	test_cushion_never_adds_energy()
	test_cushion_never_launches()
	test_scoop_jump()
	test_spin_converts_to_speed()
	test_no_tunnelling()
	_header("pockets")
	test_rail_roll_pots()
	test_potted_ball_stays_in_the_pocket()
	test_centre_roll_does_not_pot()
	test_pocket_rattle_is_possible()
	_header("full rack")
	test_break_is_sane()
	test_event_budget_survives_play()
	test_break_performance()
	_header("aiming")
	test_prediction_matches_reality()
	test_swerve()
	test_prediction_is_cheap()
	_header("the rail top")
	test_ball_lands_on_the_rail()
	test_ball_clearing_the_rail_leaves_the_table()
	test_ball_runs_along_the_rail_then_falls_off()
	test_ball_falling_off_the_rail_inward_returns_to_play()
	_header("determinism")
	test_jumps_are_deterministic()
	test_only_miscues_are_random()
	test_repeatability()
	test_step_size_independence()
	test_break_outcome_is_step_independent()

	print("")
	for l in _lines:
		print(l)
	print("")
	print("%d passed, %d failed" % [_passed, _failed])
	await get_tree().process_frame
	get_tree().quit(1 if _failed > 0 else 0)


# ---------------------------------------------------------------------------
# harness
# ---------------------------------------------------------------------------

func _header(name: String) -> void:
	_lines.append("")
	_lines.append("--- %s ---" % name)


func _ok(name: String, detail := "") -> void:
	_passed += 1
	_lines.append("  PASS  %s%s" % [name, ("   " + detail) if detail != "" else ""])


func _bad(name: String, detail := "") -> void:
	_failed += 1
	_lines.append("  FAIL  %s%s" % [name, ("   " + detail) if detail != "" else ""])


func check(name: String, cond: bool, detail := "") -> void:
	if cond:
		_ok(name, detail)
	else:
		_bad(name, detail)


func close_to(name: String, got: float, want: float, tol: float) -> void:
	var d := absf(got - want)
	check(name, d <= tol, "got %.6f want %.6f (tol %.6f)" % [got, want, tol])


# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------

func _bare_ball(v: Vector3, w := Vector3.ZERO) -> PoolBall:
	var b := PoolBall.new(0, 0)
	b.place(Vector3.ZERO)
	b.vel = v
	b.avel = w
	b.begin_phase()
	return b


## Integrate one ball with no table, stepping exactly to each phase boundary.
func _run_phases(b: PoolBall, max_steps := 64) -> void:
	for _i in range(max_steps):
		if b.state == PoolBall.STATIONARY:
			return
		b.integrate(maxf(b.phase_left, 1.0e-9))
		b.begin_phase()


func _sim_with(cue_pos: Vector3, objects := {}) -> PoolSim:
	var sim := PoolSim.new()
	var cb := PoolBall.new(0, 0)
	cb.place(cue_pos)
	sim.add_ball(cb)
	var id := 1
	for num in objects.keys():
		var b := PoolBall.new(id, num)
		b.place(objects[num])
		sim.add_ball(b)
		id += 1
	sim.begin_shot()
	return sim


## Advance until the first ball-ball contact, then snapshot velocity and position
## of every ball at that instant (before any further motion).
func _state_at_first_contact(sim: PoolSim) -> Dictionary:
	for _i in range(40000):
		if sim.settled():
			break
		var before := sim.shot_log.size()
		sim.advance(0.0005)
		for k in range(before, sim.shot_log.size()):
			if sim.shot_log[k]["type"] == "ball":
				var vels := {}
				var poss := {}
				for b in sim.balls:
					vels[b.number] = b.vel
					poss[b.number] = b.pos
				return {"vel": vels, "pos": poss}
	return {}


## An aim direction that lands a dead-full hit despite squirt, by pre-rotating
## the cue against the deflection the strike model is about to apply.
func _squirt_corrected_aim(dir: Vector3, side: float) -> Vector3:
	return dir.rotated(Vector3.UP, -deg_to_rad(PoolPhys.SQUIRT_DEG) * side)


func _total_ke(sim: PoolSim) -> float:
	var e := 0.0
	for b in sim.balls:
		if not b.is_active():
			continue
		e += 0.5 * PoolPhys.BALL_M * b.vel.length_squared()
		e += 0.5 * PoolPhys.INERTIA * b.avel.length_squared()
	return e


func _rack(sim: PoolSim, seed_value: int) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var pos := PoolTable.rack_positions(rng)
	var nums := PoolTable.rack_numbers(rng)
	for i in range(15):
		var b := PoolBall.new(i + 1, nums[i])
		b.place(Vector3(pos[i].x, 0.0, pos[i].y))
		sim.add_ball(b)


# ---------------------------------------------------------------------------
# roots
# ---------------------------------------------------------------------------

func test_roots() -> void:
	# (t-1)(t-2)(t-3)(t-4) = t^4 -10t^3 +35t^2 -50t +24
	close_to("quartic: smallest of four real roots",
		PoolRoots.quartic_smallest(1, -10, 35, -50, 24, 0.0, 10.0), 1.0, 1e-9)
	close_to("quartic: window skips earlier roots",
		PoolRoots.quartic_smallest(1, -10, 35, -50, 24, 2.5, 10.0), 3.0, 1e-9)
	check("quartic: no root in empty window",
		PoolRoots.quartic_smallest(1, -10, 35, -50, 24, 4.5, 10.0) == INF)
	# Double root at t=2: (t-2)^2 (t^2+1) -- a grazing contact.
	close_to("quartic: tangential (double) root found",
		PoolRoots.quartic_smallest(1, -4, 5, -4, 4, 0.0, 10.0), 2.0, 1e-5)
	# Degenerate leading terms (equal accelerations) must fall back cleanly.
	close_to("quartic: degenerates to quadratic",
		PoolRoots.quartic_smallest(0, 0, 1, -3, 2, 0.0, 10.0), 1.0, 1e-9)
	close_to("quartic: degenerates to cubic",
		PoolRoots.quartic_smallest(0, 1, -6, 11, -6, 0.0, 10.0), 1.0, 1e-9)
	var c := PoolRoots.cubic_roots(1, 0, -1, 0)   # t^3 - t = 0 -> -1, 0, 1
	var arr := Array(c)
	arr.sort()
	check("cubic: three real roots", arr.size() == 3 and absf(arr[0] + 1.0) < 1e-9
		and absf(arr[1]) < 1e-9 and absf(arr[2] - 1.0) < 1e-9, str(arr))


# ---------------------------------------------------------------------------
# single-ball motion
# ---------------------------------------------------------------------------

## A ball struck dead centre slides, then rolls, and classical analysis says it
## has lost exactly 2/7 of its speed when slipping stops.
func test_five_sevenths() -> void:
	var v0 := 3.0
	var b := _bare_ball(Vector3(0, 0, -v0))
	check("centre hit starts sliding", b.state == PoolBall.SLIDING)
	b.integrate(b.phase_left)
	b.begin_phase()
	close_to("speed at end of slide is 5/7 v0", b.speed_h(), 5.0 / 7.0 * v0, 1e-6)
	check("transitions to rolling", b.state == PoolBall.ROLLING,
		"state=%d" % b.state)
	# Tolerance is set by Godot's single-precision Vector3, not by the solver:
	# w ~ 75 rad/s only has ~5e-6 of resolution in float32.
	close_to("rolling constraint w = v/R", b.avel.x,
		-v0 * 5.0 / 7.0 / PoolPhys.BALL_R, 1e-4)


func test_slide_time() -> void:
	var v0 := 4.0
	var b := _bare_ball(Vector3(v0, 0, 0))
	var want := 2.0 * v0 / (7.0 * PoolPhys.MU_SLIDE * PoolPhys.G)
	close_to("slide duration = 2 u0 / 7 mu g", b.phase_left, want, 1e-9)
	_run_phases(b)
	check("ball comes to rest", b.state == PoolBall.STATIONARY)
	check("no residual velocity", b.vel.length() < 1e-9 and b.avel.length() < 1e-9)


func test_spin_decay() -> void:
	var b := _bare_ball(Vector3.ZERO, Vector3(0, 40.0, 0))
	check("pure vertical spin does not translate", b.state == PoolBall.SPINNING)
	_run_phases(b)
	check("spinning ball stays put", b.pos.distance_to(Vector3(0, PoolPhys.BALL_R, 0)) < 1e-12)
	check("spin bleeds off", absf(b.avel.y) < 1e-9)


# ---------------------------------------------------------------------------
# cue strike
# ---------------------------------------------------------------------------

func test_strike_speed() -> void:
	var b := PoolBall.new(0, 0)
	b.place(Vector3.ZERO)
	var cue_v := 2.0
	PoolSim.cue_strike(b, Vector3(0, 0, -1), cue_v, 0.0, 0.0, 0.0)
	# Elastic 1-D limit for a centre hit: v = 2M/(M+m) * V.
	var want: float = 2.0 * PoolPhys.CUE_M / (PoolPhys.CUE_M + PoolPhys.BALL_M) * cue_v
	close_to("centre hit reaches the elastic limit", b.vel.length(), want, 1e-6)
	check("centre hit imparts no spin", b.avel.length() < 1e-9)
	check("cue ball travels along the aim line", absf(b.vel.x) < 1e-12 and b.vel.z < 0.0)


func test_english_costs_power() -> void:
	var centre := PoolBall.new(0, 0)
	centre.place(Vector3.ZERO)
	PoolSim.cue_strike(centre, Vector3(0, 0, -1), 3.0, 0.0, 0.0, 0.0)
	var english := PoolBall.new(0, 0)
	english.place(Vector3.ZERO)
	PoolSim.cue_strike(english, Vector3(0, 0, -1), 3.0, 0.5, 0.0, 0.0)
	check("max english loses speed vs centre ball",
		english.vel.length() < centre.vel.length() * 0.75,
		"%.3f vs %.3f m/s" % [english.vel.length(), centre.vel.length()])
	check("right english gives counter-clockwise spin (seen from above)",
		english.avel.y > 0.0, "wy=%.2f" % english.avel.y)

	var draw := PoolBall.new(0, 0)
	draw.place(Vector3.ZERO)
	PoolSim.cue_strike(draw, Vector3(0, 0, -1), 3.0, 0.0, -0.45, 0.0)
	# Travelling in -Z, natural roll needs wx < 0; backspin is wx > 0.
	check("below-centre hit produces backspin", draw.avel.x > 0.0, "wx=%.2f" % draw.avel.x)
	var follow := PoolBall.new(0, 0)
	follow.place(Vector3.ZERO)
	PoolSim.cue_strike(follow, Vector3(0, 0, -1), 3.0, 0.0, 0.45, 0.0)
	check("above-centre hit produces topspin", follow.avel.x < 0.0, "wx=%.2f" % follow.avel.x)


func test_squirt() -> void:
	var b := PoolBall.new(0, 0)
	b.place(Vector3.ZERO)
	PoolSim.cue_strike(b, Vector3(0, 0, -1), 3.0, 0.5, 0.0, 0.0)
	# Aiming down -Z, +X is to the right; right english must squirt the ball left.
	check("right english squirts the cue ball left", b.vel.x < 0.0, "vx=%.4f" % b.vel.x)
	var ang := rad_to_deg(atan2(absf(b.vel.x), absf(b.vel.z)))
	check("squirt angle is a realistic few degrees", ang > 1.0 and ang < 6.0, "%.2f deg" % ang)


# ---------------------------------------------------------------------------
# ball-ball
# ---------------------------------------------------------------------------

## The 90-degree rule: on any cut shot where the cue ball arrives sliding with
## no vertical spin, cue ball and object ball separate at right angles.
func test_ninety_degree_rule() -> void:
	# Object ball offset laterally from the cue ball's line of travel, so the
	# perpendicular miss distance sets the cut angle: asin(0.03 / 2R) = 31.6 deg.
	# Short distance and a hard hit keep the cue ball sliding with almost no
	# accumulated topspin, which is the precondition for the rule.
	var sim := _sim_with(Vector3(0.0, 0.0, 0.18), {1: Vector3(0.03, 0.0, 0.0)})
	PoolSim.cue_strike(sim.cue, Vector3(0, 0, -1), 6.0, 0.0, 0.0, 0.0)
	var snap := _state_at_first_contact(sim)
	check("contact detected", not snap.is_empty())
	if snap.is_empty():
		return
	var vc: Vector3 = snap["vel"][0]
	var vo: Vector3 = snap["vel"][1]
	var ang := rad_to_deg(Vector2(vc.x, vc.z).angle_to(Vector2(vo.x, vo.z)))
	check("stun cut separates at ~90 degrees", absf(absf(ang) - 90.0) < 6.0,
		"%.2f deg" % ang)


## Draw, stun and follow have to order themselves correctly. The object ball is
## lifted off the table the instant it is struck: otherwise it rebounds off the
## foot cushion, comes back, hits the cue ball again, and the measurement is
## meaningless (which is exactly what happened the first time round).
func test_draw_stun_follow() -> void:
	var travel := {}
	for label in ["draw", "stun", "follow"]:
		var vert: float = {"draw": -0.42, "stun": 0.0, "follow": 0.42}[label]
		var sim := _sim_with(Vector3(0.0, 0.0, 0.55), {1: Vector3(0.0, 0.0, 0.0)})
		PoolSim.cue_strike(sim.cue, Vector3(0, 0, -1), 3.2, 0.0, vert, 0.0)
		var snap := _state_at_first_contact(sim)
		if snap.is_empty():
			travel[label] = NAN
			continue
		var z_at_contact: float = sim.cue.pos.z
		sim.balls[1].state = PoolBall.POCKETED     # remove it from play
		for _i in range(120):
			sim.advance(0.005)                     # 0.6 s, no cushion in reach
		# Positive means the cue ball moved back toward the shooter.
		travel[label] = sim.cue.pos.z - z_at_contact
	check("draw pulls the cue ball back off a full hit",
		travel["draw"] > 0.1, "%.3f m back" % travel["draw"])
	check("follow drives the cue ball forward through the contact",
		travel["follow"] < -0.1, "%.3f m" % travel["follow"])
	check("draw > stun > follow",
		travel["draw"] > travel["stun"] and travel["stun"] > travel["follow"],
		"draw %+.3f, stun %+.3f, follow %+.3f"
			% [travel["draw"], travel["stun"], travel["follow"]])


## Throw: friction across the line of centres drags the object ball off the line
## the geometry alone would predict. The aim is squirt-corrected so the hit is
## genuinely full and the only lateral push left is the throw itself.
func test_throw() -> void:
	var dirs := {}
	for label in ["left", "none", "right"]:
		var side: float = {"left": -0.45, "none": 0.0, "right": 0.45}[label]
		var sim := _sim_with(Vector3(0.0, 0.0, 0.40), {1: Vector3(0.0, 0.0, 0.0)})
		var aim := _squirt_corrected_aim(Vector3(0, 0, -1), side)
		PoolSim.cue_strike(sim.cue, aim, 2.4, side, 0.0, 0.0)
		var snap := _state_at_first_contact(sim)
		if snap.is_empty():
			dirs[label] = NAN
			continue
		# Throw is measured against the line of centres at the moment of impact.
		var loc: Vector3 = snap["pos"][1] - snap["pos"][0]
		var vo: Vector3 = snap["vel"][1]
		dirs[label] = rad_to_deg(Vector2(loc.x, loc.z).angle_to(Vector2(vo.x, vo.z)))
	check("no english throws a full hit straight", absf(dirs["none"]) < 0.2,
		"%.3f deg" % dirs["none"])
	check("side english throws the object ball a realistic few degrees",
		absf(dirs["right"]) > 1.0 and absf(dirs["right"]) < 8.0,
		"right english throws %.2f deg" % dirs["right"])
	check("left and right english throw opposite ways",
		signf(dirs["right"]) != signf(dirs["left"]),
		"right %+.2f deg, left %+.2f deg" % [dirs["right"], dirs["left"]])


func test_momentum_and_energy() -> void:
	var sim := _sim_with(Vector3(0.0, 0.0, 0.40), {1: Vector3(0.02, 0.0, 0.0)})
	PoolSim.cue_strike(sim.cue, Vector3(0, 0, -1), 4.0, 0.2, 0.2, 0.0)
	var prev := _total_ke(sim)
	var start := prev
	var grew := false
	for _i in range(4000):
		if sim.settled():
			break
		sim.advance(0.002)
		var now := _total_ke(sim)
		if now > prev + 1.0e-9:
			grew = true
		prev = now
	check("kinetic energy never increases", not grew)
	check("energy is fully dissipated", prev < 1.0e-9, "%.9f J left of %.9f" % [prev, start])


# ---------------------------------------------------------------------------
# cushions
# ---------------------------------------------------------------------------

## Fire a ball at the foot cushion and return its velocity the instant it comes
## off. `spin_y` is added on top of natural roll.
func _rebound(incidence_deg: float, speed: float, spin_y := 0.0) -> Vector3:
	var sim := _sim_with(Vector3(0.0, 0.0, 0.0))
	var dir := Vector3(sin(deg_to_rad(incidence_deg)), 0.0,
		-cos(deg_to_rad(incidence_deg))).normalized()
	sim.cue.vel = dir * speed
	sim.cue.avel = Vector3.UP.cross(sim.cue.vel) / PoolPhys.BALL_R + Vector3(0.0, spin_y, 0.0)
	sim.cue.begin_phase()
	for _i in range(40000):
		var before := sim.shot_log.size()
		sim.advance(0.0005)
		for k in range(before, sim.shot_log.size()):
			if sim.shot_log[k]["type"] == "cushion":
				return sim.cue.vel
		if sim.settled():
			break
	return Vector3.ZERO


## Angle from the cushion normal. The foot cushion's normal is +Z, so a larger
## value means the ball travelled further along the rail -- it "came off long".
func _angle_from_normal(v: Vector3) -> float:
	return rad_to_deg(atan2(absf(v.x), absf(v.z)))


## Because the nose sits above the ball's equator the normal component is damped
## far more than the tangential one, so a plain-ball rebound comes off the rail
## *longer* than the mirror angle. Every pool player relies on this.
func test_cushion_rebounds_long() -> void:
	var incidence := 45.0
	var out := _rebound(incidence, 2.0)
	check("cushion contact happened", out.length() > 0.01)
	var ang_out := _angle_from_normal(out)
	check("rebound angle exceeds incidence (comes off long)",
		ang_out > incidence + 0.5 and ang_out < 80.0,
		"in %.1f deg, out %.1f deg (from the normal)" % [incidence, ang_out])
	check("speed is reduced by the rail", out.length() < 2.0,
		"%.3f m/s from 2.000" % out.length())


## Running english is the spin that lets the ball roll *along* the cushion
## without scrubbing against it: heading down the rail in +X, that is
## w_y = +v_x / R. It kills the tangential slip, so friction stops robbing
## along-rail speed and the ball comes off longer. Reverse english doubles the
## slip instead, and bites much harder -- which is why hold-up english changes
## the angle far more than running english does.
func test_english_changes_rebound() -> void:
	var results := {}
	for label in ["running", "none", "reverse"]:
		var spin: float = {"running": 150.0, "none": 0.0, "reverse": -150.0}[label]
		results[label] = _angle_from_normal(_rebound(40.0, 2.5, spin))
	check("running english lengthens the rebound",
		results["running"] > results["none"] + 0.4,
		"running %.2f vs plain %.2f deg" % [results["running"], results["none"]])
	check("reverse english shortens the rebound",
		results["reverse"] < results["none"] - 1.0,
		"reverse %.1f vs plain %.1f deg" % [results["reverse"], results["none"]])


## A cushion can never hand back more energy than it received, whatever spin
## arrives with the ball.
##
## This is checked separately from the ball-ball energy test because the cushion
## impulse deliberately couples spin into velocity, and a sign error in that
## coupling shows up as a ball accelerating away from the rail -- the single most
## obvious way for the simulation to look fake.
func test_cushion_never_adds_energy() -> void:
	var worst_gain := 0.0
	var cushion_hits := 0
	for trial in range(18):
		var sim := _sim_with(Vector3(0.0, 0.0, 0.0))
		var incidence := deg_to_rad(-60.0 + 8.0 * float(trial % 9))
		var dir := Vector3(sin(incidence), 0.0, -cos(incidence)).normalized()
		sim.cue.vel = dir * 3.0
		# Cycle through natural roll, heavy draw, heavy follow and side spin.
		var spin_kind := trial / 9
		sim.cue.avel = Vector3.UP.cross(sim.cue.vel) / PoolPhys.BALL_R
		if spin_kind == 1:
			sim.cue.avel = -sim.cue.avel + Vector3(0.0, 120.0, 0.0)
		sim.cue.begin_phase()

		var prev := _total_ke(sim)
		for _i in range(4000):
			if sim.settled():
				break
			var before := sim.shot_log.size()
			sim.advance(0.0005)
			for k in range(before, sim.shot_log.size()):
				if sim.shot_log[k]["type"] == "cushion":
					cushion_hits += 1
			var now := _total_ke(sim)
			worst_gain = maxf(worst_gain, now - prev)
			prev = now
	check("cushions were actually exercised", cushion_hits > 18,
		"%d cushion contacts" % cushion_hits)
	check("no cushion contact increases total energy", worst_gain < 1.0e-9,
		"worst gain %.12f J" % worst_gain)


## The legitimate reasons a ball's speed changes on its own, pinned down so that
## nobody "fixes" them later as if they were bugs.
##
## Excess topspin is converted into forward speed by the cloth, so a following
## ball really does accelerate; backspin does the reverse and drags the ball back
## towards the shooter. Both end at the rolling speed (5v + 2Rw)/7, which is what
## the magnitudes below check against.
##
## Travelling along -Z, natural roll is w_x = -v/R. More negative than that is
## follow; less negative (or positive) is draw.
func test_spin_converts_to_speed() -> void:
	var v0 := 0.40
	var natural := -v0 / PoolPhys.BALL_R           # about -14 rad/s

	var over := natural - 46.0                     # well past natural roll
	var follow := _bare_ball(Vector3(0.0, 0.0, -v0), Vector3(over, 0.0, 0.0))
	check("over-rolling ball starts out sliding", follow.state == PoolBall.SLIDING)
	var peak := follow.speed_h()
	for _i in range(600):
		follow.integrate(minf(follow.phase_left, 0.005))
		follow.begin_phase()
		peak = maxf(peak, follow.speed_h())
		if follow.state == PoolBall.STATIONARY:
			break
	# Taken from the spin actually applied, not from a number that happened to
	# come out round on one particular ball size.
	var want_follow: float = (5.0 * v0 + 2.0 * PoolPhys.BALL_R * absf(over)) / 7.0
	check("follow converts topspin into forward speed",
		peak > v0 * 1.2 and absf(peak - want_follow) < 0.01,
		"%.3f -> peak %.3f m/s (predicted %.3f)" % [v0, peak, want_follow])
	check("follow keeps travelling the same way", follow.pos.z < 0.0,
		"final z = %.3f" % follow.pos.z)

	var draw := _bare_ball(Vector3(0.0, 0.0, -v0), Vector3(60.0, 0.0, 0.0))
	var reversed_dir := false
	for _i in range(600):
		draw.integrate(minf(draw.phase_left, 0.005))
		draw.begin_phase()
		if draw.vel.z > 0.01:
			reversed_dir = true
		if draw.state == PoolBall.STATIONARY:
			break
	check("draw drags the ball back towards the shooter", reversed_dir,
		"final z = %.3f" % draw.pos.z)


## A cushion must never launch a ball into the air.
##
## Regression test for a real bug: the cushion nose is above centre, so a hard
## contact drove the ball downward at several m/s; if the ball was even a
## millimetre airborne at the time, the cloth bounce returned half of that as
## upward speed and the ball took off. Peak heights of 31 cm were coming out of
## ordinary rail contacts.
func test_cushion_never_launches() -> void:
	var worst := 0.0
	var worst_case := ""
	for elev_deg: float in [0.0, 10.0, 20.0, 30.0]:
		for vert: float in [0.3, 0.0, -0.35]:
			var sim := _sim_with(Vector3(0.0, 0.0, 1.05))
			PoolSim.cue_strike(sim.cue, Vector3(0, 0, -1), 7.0, 0.35, vert,
				deg_to_rad(elev_deg), true)
			var peak := 0.0
			var saw_cushion := false
			for _i in range(1600):
				var before := sim.shot_log.size()
				sim.advance(1.0 / 480.0)
				for k in range(before, sim.shot_log.size()):
					if sim.shot_log[k]["type"] == "cushion":
						saw_cushion = true
				if saw_cushion:
					peak = maxf(peak, sim.cue.pos.y - PoolPhys.BALL_R)
				if sim.settled():
					break
			if peak > worst:
				worst = peak
				worst_case = "elev %.0f deg, tip %+.2f" % [elev_deg, vert]
	# A few centimetres is a real rail hop; anything approaching a ball diameter
	# is the cushion acting as a springboard.
	check("a cushion never launches a ball off the table", worst < 0.04,
		"worst %.1f cm (%s)" % [worst * 100.0, worst_case])


## Peak height off the cloth for a level-cue stroke at a given tip height.
func _level_cue_hop(tip: float) -> float:
	var sim := _sim_with(Vector3(0.0, 0.0, 1.0))
	PoolSim.cue_strike(sim.cue, Vector3(0, 0, -1), 9.0, 0.0, tip, 0.0, true, 0.0)
	var peak := 0.0
	for _i in range(1500):
		sim.advance(1.0 / 480.0)
		peak = maxf(peak, sim.cue.pos.y - PoolPhys.BALL_R)
		if sim.settled():
			break
	return peak


## The scoop jump: a tip that gets under the ball redirects part of the blow along
## the contact normal, which points up and forward, and chips the ball into the
## air even with a level cue. It is a real stroke -- illegal in tournament play
## precisely because it works.
##
## The other half of this test matters just as much: an ordinary draw shot, however
## low, must keep the ball on the cloth. A level cue that chipped the ball on any
## low hit would be plain wrong.
func test_scoop_jump() -> void:
	for tip: float in [0.0, -0.20, -0.35, -PoolPhys.SCOOP_START]:
		var hop := _level_cue_hop(tip)
		check("level cue at tip %+.2f keeps the ball down" % tip, hop < 0.001,
			"%.2f cm" % (hop * 100.0))

	var deep := _level_cue_hop(-PoolPhys.MAX_TIP_OFFSET)
	check("getting under the ball scoops it into the air", deep > 0.02,
		"%.2f cm at the legal limit" % (deep * 100.0))
	check("a full scoop can clear a ball", deep > PoolPhys.BALL_D * 0.9,
		"%.2f cm against a %.2f cm ball" % [deep * 100.0, PoolPhys.BALL_D * 100.0])


## A ball fired at the rail at extreme speed must not escape. This is the
## property a fixed-timestep engine cannot guarantee.
func test_no_tunnelling() -> void:
	var worst := 0.0
	for trial in range(40):
		var sim := _sim_with(Vector3(0.0, 0.0, 0.0))
		var ang := TAU * float(trial) / 40.0
		sim.cue.vel = Vector3(cos(ang), 0, sin(ang)) * 60.0   # ~4x a real break
		sim.cue.begin_phase()
		sim.simulate_to_rest(120.0)
		if sim.cue.state == PoolBall.OFF_TABLE:
			worst = 999.0
			break
		if sim.cue.is_active():
			worst = maxf(worst, absf(sim.cue.pos.x) - PoolPhys.HALF_W)
			worst = maxf(worst, absf(sim.cue.pos.z) - PoolPhys.HALF_L)
	check("60 m/s ball never leaves the table", worst < 0.02,
		"worst overshoot %.4f m" % worst)


# ---------------------------------------------------------------------------
# pockets
# ---------------------------------------------------------------------------

## You can cheat a corner pocket along the rail, because its mouth runs diagonally
## across the ball's path -- but you cannot cheat a side pocket, whose mouth is
## parallel to the rail. A ball hugging the long cushion rolls straight past it.
## Both of those are real, and both fall out of the mouth-line pocket model; the
## circular pockets this replaced got the side pocket wrong.
func test_rail_roll_pots() -> void:
	var rail_x := PoolPhys.HALF_W - PoolPhys.BALL_R - 0.001

	var sim := _sim_with(Vector3(rail_x, 0.0, 0.30))
	sim.cue.vel = Vector3(0, 0, 1.2)
	sim.cue.begin_phase()
	sim.simulate_to_rest()
	check("ball rolling down the rail drops in the corner",
		sim.cue.state == PoolBall.POCKETED, "state=%d pos=%v" % [sim.cue.state, sim.cue.pos])

	var sim2 := _sim_with(Vector3(rail_x, 0.0, PoolPhys.HALF_L * 0.5))
	sim2.cue.vel = Vector3(0, 0, -0.9)
	sim2.cue.begin_phase()
	sim2.simulate_to_rest()
	# Where it ends up is not the claim -- on a short table it runs all the way
	# down to the corner. The claim is that the side pocket did not take it.
	var side_took_it := sim2.cue.state == PoolBall.POCKETED \
		and not sim2.table.pockets[sim2.cue.pocket_id].is_corner
	check("ball hugging the rail rolls past the side pocket",
		not side_took_it and sim2.cue.pos.z < -0.05,
		"state=%d pocket=%d pos=%v"
			% [sim2.cue.state, sim2.cue.pocket_id, sim2.cue.pos])

	# Angled into the mouth, it drops. The angle is taken off the table's own
	# dimensions: the same start point is a comfortable 20 degrees into one
	# table's middle pocket and a hopeless 47 into the other's.
	var sim3 := _sim_with(Vector3(0.0, 0.0, PoolPhys.HALF_L * 0.20))
	var mouth := Vector3(PoolPhys.HALF_W + 0.03, PoolPhys.BALL_R, 0.0)
	sim3.cue.vel = (mouth - sim3.cue.pos).normalized() * 1.4
	sim3.cue.begin_phase()
	sim3.simulate_to_rest()
	check("ball played into the side pocket mouth drops",
		sim3.cue.state == PoolBall.POCKETED,
		"state=%d pos=%v" % [sim3.cue.state, sim3.cue.pos])


## A potted ball has to stay in the pocket, however hard it arrives. Without a
## wall from the moment of entry a fast ball crosses the opening while still
## falling and leaves the table out the back.
func test_potted_ball_stays_in_the_pocket() -> void:
	# Seeded negative: this tracks how far *outside* the cavity the worst ball
	# ended up, and staying inside means the value never rises above zero.
	var worst := -1.0
	var escapes := 0
	for speed: float in [1.5, 3.0, 5.0, 8.0]:
		var sim := _sim_with(Vector3(0.0, 0.0, 0.0))
		var corner := Vector3(PoolPhys.HALF_W, PoolPhys.BALL_R, PoolPhys.HALF_L)
		sim.cue.vel = (corner - sim.cue.pos).normalized() * speed
		sim.cue.begin_phase()
		for _i in range(4000):
			sim.advance(1.0 / 240.0)
			sim.advance_drops(1.0 / 240.0)
			if sim.settled() and sim.falling.is_empty():
				break
		if sim.cue.state != PoolBall.POCKETED:
			escapes += 1
			continue
		# Must have come to rest inside the pocket cavity, below the cloth.
		var pk: PoolTable.Pocket = sim.table.pockets[sim.cue.pocket_id]
		var d := Vector2(sim.cue.pos.x - pk.cavity.x,
			sim.cue.pos.z - pk.cavity.y).length()
		worst = maxf(worst, d - pk.cavity_radius)
		check("potted at %.0f m/s comes to rest below the cloth" % speed,
			sim.cue.pos.y < 0.0, "y = %.4f" % sim.cue.pos.y)
	check("a ball driven hard into a pocket is still potted", escapes == 0,
		"%d of 4 escaped" % escapes)
	check("a potted ball stays inside the pocket cavity", worst < 0.0,
		"worst overshoot %.4f m" % worst)


func test_centre_roll_does_not_pot() -> void:
	var potted := 0
	for trial in range(24):
		var sim := _sim_with(Vector3(0.0, 0.0, 0.0))
		var ang := TAU * float(trial) / 24.0
		# Slow enough to die on the table; must never find a pocket from centre.
		sim.cue.vel = Vector3(cos(ang), 0, sin(ang)) * 0.9
		sim.cue.begin_phase()
		sim.simulate_to_rest()
		if not sim.cue.is_active():
			potted += 1
	check("a ball from the centre spot is not swallowed by phantom pockets",
		potted <= 6, "%d/24 trials ended in a pocket" % potted)


## The rounded jaws must be able to reject a ball, otherwise pockets behave like
## funnels and the game loses all its tension.
func test_pocket_rattle_is_possible() -> void:
	var rejected := 0
	var tried := 0
	for i in range(24):
		var sim := _sim_with(Vector3(0.0, 0.0, 0.0))
		# Fan shots at the top-right corner, deliberately off-line.
		var target := Vector3(PoolPhys.HALF_W, PoolPhys.BALL_R, PoolPhys.HALF_L)
		var base := (target - sim.cue.pos).normalized()
		var off := deg_to_rad(-6.0 + 0.5 * float(i))
		sim.cue.vel = base.rotated(Vector3.UP, off) * 3.0
		sim.cue.begin_phase()
		sim.simulate_to_rest()
		tried += 1
		if sim.cue.is_active():
			rejected += 1
	check("some near-miss shots rattle out instead of dropping",
		rejected > 0 and rejected < tried,
		"%d of %d rejected" % [rejected, tried])


# ---------------------------------------------------------------------------
# full rack
# ---------------------------------------------------------------------------

func test_break_is_sane() -> void:
	for seed_value in [1, 7, 99, 2024]:
		var sim := PoolSim.new()
		var cb := PoolBall.new(0, 0)
		cb.place(Vector3(0.05, 0.0, PoolPhys.HEAD_STRING_Z + 0.1))
		sim.add_ball(cb)
		_rack(sim, seed_value)
		sim.begin_shot()
		PoolSim.cue_strike(sim.cue, (Vector3(0.0, PoolPhys.BALL_R, PoolPhys.FOOT_SPOT_Z)
			- cb.pos).normalized(), 8.0, 0.0, 0.0, 0.0)
		var t := sim.simulate_to_rest(90.0)

		check("break %d settles" % seed_value, sim.settled(), "%.2fs of table time" % t)
		var off := 0
		var illegal := 0
		var overlap := 0.0
		for b in sim.balls:
			if b.state == PoolBall.OFF_TABLE:
				off += 1
			if not b.is_active():
				continue
			if not sim.table.is_legal_center(Vector2(b.pos.x, b.pos.z)):
				illegal += 1
		for i in range(sim.balls.size()):
			for j in range(i + 1, sim.balls.size()):
				var a: PoolBall = sim.balls[i]
				var b: PoolBall = sim.balls[j]
				if not a.is_active() or not b.is_active():
					continue
				overlap = maxf(overlap, PoolPhys.BALL_D - a.pos.distance_to(b.pos))
		check("break %d loses no balls off the table" % seed_value, off == 0, "%d off" % off)
		check("break %d leaves every ball in a legal spot" % seed_value, illegal == 0,
			"%d illegal" % illegal)
		check("break %d leaves no overlapping balls" % seed_value, overlap < 1.0e-6,
			"max overlap %.9f m" % overlap)
		var cushions := 0
		for e in sim.shot_log:
			if e["type"] == "cushion":
				cushions += 1
		check("break %d drives balls to the rails" % seed_value, cushions >= 4,
			"%d cushion contacts" % cushions)


func _break_snapshot(step: float) -> PackedFloat64Array:
	var sim := PoolSim.new()
	var cb := PoolBall.new(0, 0)
	cb.place(Vector3(0.03, 0.0, PoolPhys.HEAD_STRING_Z + 0.05))
	sim.add_ball(cb)
	_rack(sim, 4242)
	sim.begin_shot()
	PoolSim.cue_strike(sim.cue, Vector3(0, 0, -1), 7.5, 0.15, -0.2, 0.0)
	var guard := 0
	while not sim.settled() and guard < 200000:
		sim.advance(step)
		guard += 1
	var snap := PackedFloat64Array()
	for b in sim.balls:
		snap.append(b.pos.x)
		snap.append(b.pos.z)
		snap.append(float(b.state))
	return snap


func _max_diff(a: PackedFloat64Array, b: PackedFloat64Array) -> float:
	var worst := 0.0
	for i in range(a.size()):
		worst = maxf(worst, absf(a[i] - b[i]))
	return worst


## Signature of a whole shot: where every ball ended up and in what state.
## `deterministic` is left false so this is the path a player actually gets.
func _shot_signature(side: float, vert: float, elev: float) -> PackedFloat64Array:
	var sim := PoolSim.new()
	var cb := PoolBall.new(0, 0)
	cb.place(Vector3(0.04, 0.0, PoolPhys.HEAD_STRING_Z))
	sim.add_ball(cb)
	var rng := RandomNumberGenerator.new()
	rng.seed = 31415
	var pos := PoolTable.rack_positions(rng)
	var nums := PoolTable.rack_numbers(rng)
	for i in range(15):
		var b := PoolBall.new(i + 1, nums[i])
		b.place(Vector3(pos[i].x, 0.0, pos[i].y))
		sim.add_ball(b)
	sim.begin_shot()
	PoolSim.cue_strike(sim.cue, Vector3(0, 0, -1), 7.5, side, vert, elev)
	var guard := 0
	while not (sim.settled() and sim.falling.is_empty()) and guard < 60000:
		sim.advance(1.0 / 240.0)
		sim.advance_drops(1.0 / 240.0)
		guard += 1
	var sig := PackedFloat64Array()
	for b in sim.balls:
		sig.append(b.pos.x)
		sig.append(b.pos.y)
		sig.append(b.pos.z)
		sig.append(float(b.state))
	return sig


## Jumps and scoops are as reproducible as any other stroke. They go through the
## same strike model and the same event solver -- there is no sampling, no
## randomness and no frame-rate dependence anywhere in the airborne path.
func test_jumps_are_deterministic() -> void:
	var jump_a := _shot_signature(0.0, 0.10, deg_to_rad(45.0))
	var jump_b := _shot_signature(0.0, 0.10, deg_to_rad(45.0))
	check("a jump shot replays exactly", _max_diff(jump_a, jump_b) == 0.0)

	var scoop_a := _shot_signature(0.0, -PoolPhys.MAX_TIP_OFFSET, 0.0)
	var scoop_b := _shot_signature(0.0, -PoolPhys.MAX_TIP_OFFSET, 0.0)
	check("a scoop shot replays exactly", _max_diff(scoop_a, scoop_b) == 0.0)

	# Note the magnitude: sqrt(0.40^2 + 0.20^2) = 0.447, inside the 0.52 legal
	# limit. Picking 0.45/0.30 puts the tip at 0.54 -- past the limit and into the
	# miscue band, where the scatter is random by design.
	var spin_a := _shot_signature(0.40, -0.20, deg_to_rad(12.0))
	var spin_b := _shot_signature(0.40, -0.20, deg_to_rad(12.0))
	check("a swerving side-spin shot replays exactly",
		_max_diff(spin_a, spin_b) == 0.0,
		"tip offset %.3f of the radius" % Vector2(0.40, -0.20).length())


## The one deliberate exception, pinned down so it stays deliberate: past the
## miscue limit the tip skids off unpredictably, and that is modelled with an
## actual random deflection. Everything inside the legal tip area is repeatable.
func test_only_miscues_are_random() -> void:
	var legal_a := _shot_signature(0.0, -PoolPhys.MAX_TIP_OFFSET, 0.0)
	var legal_b := _shot_signature(0.0, -PoolPhys.MAX_TIP_OFFSET, 0.0)
	check("a stroke at the legal tip limit is still repeatable",
		_max_diff(legal_a, legal_b) == 0.0)

	var mis_a := _shot_signature(0.0, -PoolPhys.MISCUE_LIMIT, 0.0)
	var mis_b := _shot_signature(0.0, -PoolPhys.MISCUE_LIMIT, 0.0)
	check("a miscue does not repeat -- it is random on purpose",
		_max_diff(mis_a, mis_b) > 0.0,
		"max difference %.6f m" % _max_diff(mis_a, mis_b))


## Bit-for-bit repeatability with the same step schedule -- there is no hidden
## state and nothing reads a clock.
func test_repeatability() -> void:
	check("the same break replays exactly",
		_max_diff(_break_snapshot(0.01), _break_snapshot(0.01)) == 0.0)


## Step-size independence, tested on a shot that is not chaotic: one ball around
## three cushions. The event solver puts contacts at the same instant regardless
## of how the caller slices time, so only float32 round-off separates the runs.
func test_step_size_independence() -> void:
	var ends := []
	for step: float in [0.001, 0.05]:
		var sim := _sim_with(Vector3(0.1, 0.0, 0.4))
		sim.cue.vel = Vector3(0.55, 0.0, -1.9)
		sim.cue.begin_phase()
		var guard := 0
		while not sim.settled() and guard < 200000:
			sim.advance(step)
			guard += 1
		ends.append(sim.cue.pos)
	var d: float = (ends[0] as Vector3).distance_to(ends[1] as Vector3)
	check("1 ms and 50 ms callers agree on a multi-rail shot", d < 1.0e-4,
		"%.7f m apart after %d cushions" % [d, 3])


## On a break, float32 round-off is amplified by the chaos of a 16-ball cluster,
## so positions cannot agree to the micron across different step schedules. What
## must still agree is the outcome that the rules care about.
func test_break_outcome_is_step_independent() -> void:
	var fine := _break_snapshot(0.001)
	var coarse := _break_snapshot(0.05)
	var pocketed_fine := 0
	var pocketed_coarse := 0
	var off := 0
	for i in range(0, fine.size(), 3):
		if int(fine[i + 2]) == PoolBall.POCKETED:
			pocketed_fine += 1
		if int(coarse[i + 2]) == PoolBall.POCKETED:
			pocketed_coarse += 1
		if int(fine[i + 2]) == PoolBall.OFF_TABLE or int(coarse[i + 2]) == PoolBall.OFF_TABLE:
			off += 1
	check("both step sizes agree the break is legal and lose no balls", off == 0)
	check("both step sizes pot a similar number of balls",
		absi(pocketed_fine - pocketed_coarse) <= 1,
		"%d vs %d potted" % [pocketed_fine, pocketed_coarse])


## The event budget must survive ordinary play.
##
## Regression test for a shot that ground the solver to a halt: two balls left
## touching and closing at about 2 cm/s are resting against each other, not
## colliding. The elastic impulse from a closing speed that small is itself
## negligible, so the pair stayed in contact and the same contact was re-detected
## on every event until the budget ran out -- in the middle of a quiet table.
func test_event_budget_survives_play() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 20240730
	var overflows := 0
	var shots := 40
	for _shot in range(shots):
		var sim := PoolSim.new()
		var cb := PoolBall.new(0, 0)
		cb.place(Vector3(rng.randf_range(-0.5, 0.5), 0.0, rng.randf_range(0.2, 1.1)))
		sim.add_ball(cb)
		var pos := PoolTable.rack_positions(rng)
		var nums := PoolTable.rack_numbers(rng)
		for i in range(15):
			var b := PoolBall.new(i + 1, nums[i])
			b.place(Vector3(pos[i].x, 0.0, pos[i].y))
			sim.add_ball(b)
		sim.begin_shot()
		# Include the strokes that provoked it: scoops and jumps.
		var elev := 0.0
		var vert := rng.randf_range(-0.5, 0.4)
		match rng.randi() % 3:
			1:
				elev = deg_to_rad(rng.randf_range(30.0, 55.0))
				vert = rng.randf_range(-0.1, 0.3)
			2:
				vert = -PoolPhys.MAX_TIP_OFFSET
		PoolSim.cue_strike(sim.cue, Vector3(rng.randf_range(-1, 1), 0,
			rng.randf_range(-1, -0.2)).normalized(),
			rng.randf_range(2.0, 9.0), rng.randf_range(-0.4, 0.4), vert, elev,
			true, elev)
		var t := 0.0
		while t < 70.0 and not sim.overflowed:
			sim.advance(1.0 / 240.0)
			sim.advance_drops(1.0 / 240.0)
			t += 1.0 / 240.0
			if sim.settled() and sim.falling.is_empty():
				break
		if sim.overflowed:
			overflows += 1
	check("%d varied shots never exhaust the event budget" % shots,
		overflows == 0, "%d overflowed" % overflows)


func test_break_performance() -> void:
	var sim := PoolSim.new()
	var cb := PoolBall.new(0, 0)
	cb.place(Vector3(0.0, 0.0, PoolPhys.HEAD_STRING_Z + 0.1))
	sim.add_ball(cb)
	_rack(sim, 31337)
	sim.begin_shot()
	PoolSim.cue_strike(sim.cue, Vector3(0, 0, -1), 9.0, 0.0, 0.0, 0.0)
	var t0 := Time.get_ticks_usec()
	var table_time := sim.simulate_to_rest(90.0)
	var ms := float(Time.get_ticks_usec() - t0) / 1000.0
	check("a full break simulates faster than real time",
		ms < table_time * 1000.0,
		"%.1f ms of CPU for %.2f s of table time (%.0fx real time)"
			% [ms, table_time, table_time * 1000.0 / maxf(ms, 0.001)])


# ---------------------------------------------------------------------------
# aiming
# ---------------------------------------------------------------------------

## The aim guide traces a throwaway simulation of the shot, so it must agree with
## what the real simulation then does. This is the test for "it said I would hit a
## ball and I did not": a straight line drawn along the cue disagrees with the
## physics as soon as there is side spin on the ball.
func test_prediction_matches_reality() -> void:
	var cue_pos := Vector3(0.06, 0.0, 0.95)
	var obj := Vector3(-0.14, 0.0, 0.0)
	var aim := (Vector3(obj.x, PoolPhys.BALL_R, obj.z) - Vector3(cue_pos.x,
		PoolPhys.BALL_R, cue_pos.z)).normalized()
	var side := 0.45
	var vert := -0.10
	var elev := deg_to_rad(7.0)
	var speed := 3.0

	var sim := _sim_with(cue_pos, {3: obj})
	var pred := sim.predict_cue_path(aim, speed, side, vert, elev)

	# Play exactly the same shot for real.
	PoolSim.cue_strike(sim.cue, aim, speed, side, vert, elev, true)
	var snap := _state_at_first_contact(sim)
	check("the shot actually reaches a ball", not snap.is_empty())
	if snap.is_empty():
		return
	var actual_contact: Vector3 = snap["pos"][0]

	check("guide names the ball that really gets hit", pred["hit_number"] == 3,
		"predicted %d" % pred["hit_number"])
	# The residual here is sampling granularity in this test, not error in the
	# guide: the two runs record the contact at the end of different step sizes.
	# 3 mm is a twentieth of a ball, well under anything visible.
	var err: float = (pred["contact"] as Vector3).distance_to(actual_contact)
	check("guide puts the contact within a few millimetres of the truth", err < 0.003,
		"%.5f m off" % err)

	# And the straight line the guide used to draw would have been wrong.
	var naive := Vector2(aim.x, aim.z).angle_to(
		Vector2(actual_contact.x - cue_pos.x, actual_contact.z - cue_pos.z))
	check("a straight aim line would have missed by a visible angle",
		absf(rad_to_deg(naive)) > 0.5,
		"%.2f deg between the cue line and the real path" % rad_to_deg(naive))


## Deviation of the cue ball's path from the straight line it set off along.
func _path_bend(side: float, elev: float) -> float:
	var sim := _sim_with(Vector3(0.0, 0.0, 1.05))
	var pred := sim.predict_cue_path(Vector3(0, 0, -1), 3.0, side, 0.0, elev, 0.9)
	var path: PackedVector3Array = pred["path"]
	if path.size() < 4:
		return 0.0
	# Direction it launched along, taken from the first samples.
	var launch := (path[2] - path[0])
	launch.y = 0.0
	if launch.length() < 1.0e-6:
		return 0.0
	launch = launch.normalized()
	var worst := 0.0
	for i in range(path.size()):
		var rel := path[i] - path[0]
		rel.y = 0.0
		worst = maxf(worst, absf(rel.cross(launch).y))
	return worst


## Swerve. With the cue elevated the spin axis tilts, so side spin has a component
## that bites into the cloth and bends the path. A level plain-ball shot must run
## dead straight, and left and right english must bend opposite ways.
func test_swerve() -> void:
	close_to("plain ball with a level cue runs straight", _path_bend(0.0, 0.0), 0.0, 0.0005)

	var elev := deg_to_rad(12.0)
	var right := _path_bend(0.45, elev)
	check("side spin with an elevated cue swerves", right > 0.004,
		"%.4f m of bend over 0.9 s" % right)

	# Signed comparison: the two must curve to opposite sides.
	var sim_r := _sim_with(Vector3(0.0, 0.0, 1.05))
	var pr: PackedVector3Array = sim_r.predict_cue_path(
		Vector3(0, 0, -1), 3.0, 0.45, 0.0, elev, 0.9)["path"]
	var sim_l := _sim_with(Vector3(0.0, 0.0, 1.05))
	var pl: PackedVector3Array = sim_l.predict_cue_path(
		Vector3(0, 0, -1), 3.0, -0.45, 0.0, elev, 0.9)["path"]
	check("left and right english swerve opposite ways",
		signf(pr[pr.size() - 1].x) != signf(pl[pl.size() - 1].x),
		"right ends x=%+.4f, left ends x=%+.4f"
			% [pr[pr.size() - 1].x, pl[pl.size() - 1].x])


func test_prediction_is_cheap() -> void:
	var sim := PoolSim.new()
	var cb := PoolBall.new(0, 0)
	cb.place(Vector3(0.0, 0.0, PoolPhys.HEAD_STRING_Z))
	sim.add_ball(cb)
	_rack(sim, 5)
	sim.begin_shot()
	var t0 := Time.get_ticks_usec()
	for _i in range(20):
		sim.predict_cue_path(Vector3(0, 0, -1), 3.0, 0.2, 0.0, 0.05)
	var ms := float(Time.get_ticks_usec() - t0) / 1000.0 / 20.0
	# Only recomputed when the shot inputs change, so a few milliseconds is fine;
	# this is a guard against it quietly becoming tens.
	check("tracing the guide costs well under a frame", ms < 9.0,
		"%.2f ms per refresh with a full rack on the table" % ms)


# ---------------------------------------------------------------------------
# the rail top
# ---------------------------------------------------------------------------

## Horizontal speed that brings a ball launched at `vy` back down to cloth height
## at `x_target`. Derived rather than tuned, because the two tables put their
## woodwork in different places and a hardcoded speed only lands on one of them.
func _speed_to_land_at(x_target: float, from_x: float, vy: float) -> float:
	return (x_target - from_x) / (2.0 * vy / PoolPhys.G)


## Launch a ball from `x0` with the given velocity and run it until it settles.
func _rail_shot(x0: float, vx: float, vy: float) -> PoolSim:
	# z = 0.5 keeps the flight well clear of the side pocket, which sits at z = 0.
	var sim := _sim_with(Vector3(x0, 0.0, 0.5))
	sim.cue.vel = Vector3(vx, vy, 0.0)
	sim.cue.begin_phase()
	for _i in range(6000):
		sim.advance(1.0 / 480.0)
		sim.advance_drops(1.0 / 480.0)
		if sim.settled() and sim.falling.is_empty():
			break
	return sim


## A ball whose flight brings it down over the woodwork lands on it and stays
## there, rather than dropping through into the table.
func test_ball_lands_on_the_rail() -> void:
	var from_x := PoolPhys.HALF_W * 0.65
	var sim := _sim_with(Vector3(from_x, 0.0, 0.5))
	var b := sim.cue
	# Aimed at the middle of the rail plateau, between the cushion nose and the
	# outer edge of the wood.
	var mid := 0.5 * (PoolPhys.HALF_W + sim.table.rail_outer_x())
	b.vel = Vector3(_speed_to_land_at(mid, from_x, 1.80), 1.80, 0.0)
	b.begin_phase()

	# It arrives at the wood at about 1.5 m/s downward, so it bounces rather than
	# settling -- which is what a real ball does. What matters is that the rail is
	# solid under it: it makes contact at rail height instead of passing through.
	var touched_rail := false
	var lowest_over_rail := INF
	for _i in range(6000):
		sim.advance(1.0 / 480.0)
		sim.advance_drops(1.0 / 480.0)
		if b.ground_y == PoolPhys.RAIL_TOP:
			lowest_over_rail = minf(lowest_over_rail, b.pos.y)
			if b.pos.y <= PoolPhys.RAIL_TOP + PoolPhys.BALL_R + 1.0e-3:
				touched_rail = true
		if sim.settled() and sim.falling.is_empty():
			break
	check("a ball whose flight brings it down over the woodwork lands on it",
		touched_rail, "never reached rail height while over the rail")
	check("the rail is solid: it never sinks below the wood",
		lowest_over_rail > PoolPhys.RAIL_TOP + PoolPhys.BALL_R - 1.0e-3,
		"lowest y over the rail = %.4f, rail top + R = %.4f"
			% [lowest_over_rail, PoolPhys.RAIL_TOP + PoolPhys.BALL_R])


## The other half of the requirement: if the ball is genuinely going over the
## side, it goes over the side. The rail is a surface, not a catcher, so a ball
## that is still past the outer edge when it falls to rail height keeps going.
func test_ball_clearing_the_rail_leaves_the_table() -> void:
	# Same flight, more speed across: it is still past the outer edge when it
	# falls back to rail height, so there is nothing under it to land on.
	var from_x := PoolPhys.HALF_W * 0.65
	var sim := _rail_shot(from_x, _speed_to_land_at(
		PoolTable.new().rail_outer_x() + 0.12, from_x, 1.80), 1.80)
	check("a ball flying clear over the rail is not caught by it",
		sim.cue.state == PoolBall.OFF_TABLE,
		"state=%d pos=%v" % [sim.cue.state, sim.cue.pos])


## A ball put down on the rail runs along it and then falls off the end, rather
## than rolling forever on an infinite ledge.
func test_ball_runs_along_the_rail_then_falls_off() -> void:
	var sim := _sim_with(Vector3(0.0, 0.0, 0.0))
	var b := sim.cue
	b.pos = Vector3(PoolPhys.HALF_W + PoolPhys.CUSHION_DEPTH + 0.04,
		PoolPhys.RAIL_TOP + PoolPhys.BALL_R, 0.55)
	b.ground_y = PoolPhys.RAIL_TOP
	b.vel = Vector3(0.0, 0.0, -1.1)
	b.begin_phase()
	check("starts supported by the rail", b.ground_y > 0.0)

	var travelled_on_rail := 0.0
	var last_z := b.pos.z
	for _i in range(6000):
		sim.advance(1.0 / 480.0)
		sim.advance_drops(1.0 / 480.0)
		if b.ground_y == PoolPhys.RAIL_TOP:
			travelled_on_rail += absf(b.pos.z - last_z)
		last_z = b.pos.z
		if sim.settled() and sim.falling.is_empty():
			break
	check("it actually ran some distance along the rail", travelled_on_rail > 0.10,
		"%.3f m on the wood" % travelled_on_rail)
	check("and left the rail rather than staying up there forever",
		b.ground_y != PoolPhys.RAIL_TOP,
		"ground_y=%.4f pos=%v state=%d" % [b.ground_y, b.pos, b.state])


## Nudged back over the cushion, it drops onto the cloth and plays on.
func test_ball_falling_off_the_rail_inward_returns_to_play() -> void:
	var sim := _sim_with(Vector3(0.0, 0.0, 0.0))
	var b := sim.cue
	b.pos = Vector3(PoolPhys.HALF_W + 0.02, PoolPhys.RAIL_TOP + PoolPhys.BALL_R, 0.5)
	b.ground_y = PoolPhys.RAIL_TOP
	b.vel = Vector3(-0.9, 0.0, 0.0)
	b.begin_phase()
	for _i in range(6000):
		sim.advance(1.0 / 480.0)
		if sim.settled():
			break
	check("a ball leaving the rail inward comes back onto the cloth",
		b.is_active() and absf(b.pos.y - PoolPhys.BALL_R) < 1.0e-3
			and absf(b.pos.x) < PoolPhys.HALF_W,
		"state=%d pos=%v" % [b.state, b.pos])
