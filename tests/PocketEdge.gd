extends Node

## Balls left hanging on the edge of a pocket, which is where the game was
## reported to die.
##
##     /Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
##         res://tests/PocketEdge.tscn
##
## A ball at rest a hair from a drop line is the nastiest state on the table: it
## is the one place where the pocket test, the jaw circles, the rail plateau and
## the "is there anything underneath this" surface query all meet, and where a
## micrometre either way flips the answer. The end of a turn then runs three
## things straight over that state -- the rules, the aim guide's trace, and the
## CPU's planner, which plays out dozens of whole shots from it.
##
## Everything here is checked for being a *number*. A NaN or an infinity that
## survives into a mesh or a node transform is not a visible glitch: it takes the
## renderer down with it, with no Godot error and nothing in the crash reporter,
## which is exactly what a silent disappearance looks like.

var _passed := 0
var _failed := 0
var _cases := 0


func check(what: String, ok: bool, detail := "") -> void:
	if ok:
		_passed += 1
	else:
		_failed += 1
		print("  FAIL  %s%s" % [what, "   " + detail if detail != "" else ""])


func _ready() -> void:
	for mode: int in [PoolPhys.POOL, PoolPhys.SNOOKER]:
		PoolPhys.configure(mode)
		print("\n--- %s ---" % ["UK pool" if mode == PoolPhys.POOL else "snooker"])
		_sweep(mode)
	print("\n%d cases, %d checks passed, %d failed" % [_cases, _passed, _failed])
	get_tree().quit(1 if _failed > 0 else 0)


## Park a ball at a spread of offsets around every pocket mouth -- outside it, on
## the line, and past it -- and put the game through its end-of-turn paces.
func _sweep(mode: int) -> void:
	var table := PoolTable.new()
	for pk in table.pockets:
		for along: float in [-0.6, -0.2, 0.0, 0.2, 0.6]:
			for depth: float in [-0.030, -0.012, -0.004, -0.0005, 0.0, 0.0008]:
				_one_case(table, mode, pk, along, depth)


func _one_case(table: PoolTable, mode: int, pk: PoolTable.Pocket, along: float,
		depth: float) -> void:
	_cases += 1
	var side := Vector2(-pk.normal.y, pk.normal.x)
	# `depth` is measured along the pocket's own normal, so 0 is exactly on the
	# drop line and positive is past it, hanging over nothing.
	var at: Vector2 = pk.mouth + pk.normal * depth \
		+ side * (along * pk.half_width)

	var sim := PoolSim.new(table)
	var cue := PoolBall.new(0, 0)
	cue.place(Vector3(0.0, 0.0, PoolPhys.baulk_z() * 0.5))
	sim.add_ball(cue)

	var hanger := PoolBall.new(1, 1 if mode == PoolPhys.SNOOKER else 3)
	hanger.place(Vector3(at.x, 0.0, at.y))
	sim.add_ball(hanger)

	# A second ball out in open play, so the planner has something to choose
	# between and the rules have a legal target either way.
	var other := PoolBall.new(2, 1 if mode == PoolPhys.SNOOKER else 5)
	other.place(Vector3(PoolPhys.HALF_W * 0.3, 0.0, -PoolPhys.HALF_L * 0.2))
	sim.add_ball(other)

	var label := "pocket %d along %.1f depth %.4f" % [pk.id, along, depth]

	# 1. Settling. The ball is placed, not struck: whatever the table decides is
	#    underneath it, it must reach a definite state and stay finite.
	sim.begin_shot()
	for _i in range(40):
		sim.advance(0.05)
		sim.advance_drops(0.05)
		if sim.is_shot_over():
			break
	for b in sim.balls:
		check("ball stays finite while settling  (%s)" % label, _finite(b.pos),
			"%v" % b.pos)

	# 2. The aim guide's trace, which runs every frame the player is aiming and
	#    is the one thing that feeds simulated positions straight into a mesh.
	for aim: Vector3 in [Vector3(0, 0, -1), (Vector3(at.x, 0.0, at.y)
			- sim.cue.pos).normalized(), Vector3(1, 0, -1).normalized()]:
		var trace := sim.predict_cue_path(aim, 3.0, 0.2, -0.2, 0.0, 1.1, 0.0)
		var path: PackedVector3Array = trace["path"]
		for p in path:
			check("guide path stays finite  (%s)" % label, _finite(p), "%v" % p)
		for key: String in ["contact", "object_dir", "cue_dir_after", "object_at"]:
			check("guide %s stays finite  (%s)" % [key, label],
				_finite(trace[key]), "%v" % trace[key])

	# 3. The end of a turn, and the CPU planning a whole turn from this table --
	#    which plays out dozens of complete shots off the hanging ball.
	var rules = RulesSnooker.new() if mode == PoolPhys.SNOOKER else RulesUKPool.new()
	rules.reset()
	if mode == PoolPhys.POOL:
		rules.broken = true
	sim.begin_shot()
	sim.shot_log.append({"type": "ball", "t": 0.1, "a": 0, "b": hanger.number,
		"speed": 1.0})
	sim.shot_log.append({"type": "cushion", "t": 0.2, "a": hanger.number,
		"speed": 1.0})
	rules.end_shot(sim)

	var ai := AIPlayer.new(AIPlayer.HARD, 4242)
	ai.begin(sim, rules, mode, false)
	var guard := 0
	while not ai.think(1000.0) and guard < 400:
		guard += 1
	check("the planner finishes  (%s)" % label, ai.shot != null,
		"gave up after %d slices" % guard)
	if ai.shot != null:
		check("and picks a real stroke  (%s)" % label,
			_finite(ai.shot.aim) and is_finite(ai.shot.speed)
				and ai.shot.aim.length() > 0.5,
			"aim %v speed %f" % [ai.shot.aim, ai.shot.speed])
	for b in sim.balls:
		check("the table survives planning  (%s)" % label, _finite(b.pos),
			"%v" % b.pos)


static func _finite(v: Vector3) -> bool:
	return is_finite(v.x) and is_finite(v.y) and is_finite(v.z)
