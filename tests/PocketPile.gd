extends Node

## Balls dropping into a pocket that already has balls resting in it.
##
##     /Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
##         res://tests/PocketPile.tscn
##
## Potted balls are not taken off the table -- they come to rest at the bottom of
## the pocket and stay there, so you can look down the hole and see them. That
## means every later ball into the same pocket lands on a pile that is already
## there, and by the end of a frame that pile can be seven or eight deep.
##
## What is checked: the drop always finishes, every position stays a number, and
## nothing ends up somewhere it could not physically be. A non-finite position
## here is not a cosmetic bug -- it goes straight into a node transform and takes
## the renderer down with it.

var _passed := 0
var _failed := 0


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
		for corner: bool in [true, false]:
			_pile(mode, corner)
			_brink(mode, corner)
	print("\n%d passed, %d failed" % [_passed, _failed])
	get_tree().quit(1 if _failed > 0 else 0)


## Send `count` balls into the same pocket, one shot each, without ever clearing
## the ones already down there.
func _pile(mode: int, corner: bool, count := 8) -> void:
	var table := PoolTable.new()
	var pk: PoolTable.Pocket = null
	for p in table.pockets:
		if p.is_corner == corner:
			pk = p
			break
	var label := "%s pocket" % ["corner" if corner else "middle"]

	var sim := PoolSim.new(table)
	var cue := PoolBall.new(0, 0)
	cue.place(Vector3(0.0, 0.0, PoolPhys.HEAD_STRING_Z))
	sim.add_ball(cue)

	var aim_pt: Vector2 = pk.mouth + pk.normal * 0.02
	var resting := 0
	for k in range(count):
		# A fresh ball a short way out, rolled straight at the pocket. Struck
		# firmly on purpose: a ball arriving with pace is the one that lands hard
		# on whatever is already down there.
		var b := PoolBall.new(k + 1, k + 1)
		var start := aim_pt - pk.normal * 0.45
		b.place(Vector3(start.x, 0.0, start.y))
		var v0 := 2.6
		b.vel = Vector3(pk.normal.x, 0.0, pk.normal.y) * v0
		b.avel = Vector3(pk.normal.y, 0.0, -pk.normal.x) * (v0 / PoolPhys.BALL_R)
		b.begin_phase()
		sim.add_ball(b)

		sim.begin_shot()
		var t := 0.0
		while t < 8.0 and not sim.is_shot_over():
			sim.advance(1.0 / 60.0)
			sim.advance_drops(1.0 / 60.0)
			t += 1.0 / 60.0

		check("the shot ends with %d already in the %s" % [resting, label],
			sim.is_shot_over(), "gave up after %.1f s" % t)
		check("ball %d is potted  (%s)" % [k + 1, label],
			b.state == PoolBall.POCKETED, "state %d" % b.state)
		check("nothing is left falling  (%s)" % label, sim.falling.is_empty(),
			"%d still falling" % sim.falling.size())

		for other in sim.balls:
			check("ball %d stays finite  (%s)" % [other.number, label],
				_finite(other.pos), "%v" % other.pos)
			# Nothing may end up below the floor of the pocket, or out beyond its
			# liner. Either would mean a ball has been pushed through the world.
			if other.state == PoolBall.POCKETED:
				check("ball %d rests inside the pocket  (%s)"
					% [other.number, label],
					other.pos.y >= -PoolPhys.POCKET_DEPTH - 0.001,
					"y %.4f" % other.pos.y)
		resting += 1


## A ball arriving at an empty pocket off-centre, so it catches the lip or a jaw
## on its way in rather than dropping cleanly. This is the state the game was
## reported to die in: nearly there, nothing else in the pocket.
##
## Spin is what is really under test. A ball grinding against a jaw takes an
## impulse every event, and nothing in the impulse code bounds what that does to
## its angular velocity -- but the orientation update divides by that magnitude,
## so letting it run away turns `orient` into NaNs and the next transform write
## into a renderer crash.
func _brink(mode: int, corner: bool) -> void:
	var table := PoolTable.new()
	var pk: PoolTable.Pocket = null
	for p in table.pockets:
		if p.is_corner == corner:
			pk = p
			break
	var label := "%s pocket, %s" % ["corner" if corner else "middle",
		"pool" if mode == PoolPhys.POOL else "snooker"]
	var along := Vector2(-pk.normal.y, pk.normal.x)
	var aim_pt: Vector2 = pk.mouth + pk.normal * 0.02

	# Across the mouth as well as into it, at a spread of paces: a ball creeping
	# on to the lip behaves quite differently from one arriving with the shot
	# still on it.
	for offset: float in [-0.9, -0.6, -0.3, 0.0, 0.3, 0.6, 0.9]:
		for speed: float in [0.35, 1.2, 3.4]:
			var sim := PoolSim.new(table)
			sim.quiet = true
			var b := PoolBall.new(1, 1)
			var target: Vector2 = aim_pt + along * (offset * pk.half_width)
			var start := target - pk.normal * 0.35
			if not table.is_legal_center(start):
				continue
			b.place(Vector3(start.x, 0.0, start.y))
			b.vel = Vector3(pk.normal.x, 0.0, pk.normal.y) * speed
			# Heavy side, which is what loads a jaw contact up.
			b.avel = Vector3(pk.normal.y, 0.0, -pk.normal.x) * (speed / PoolPhys.BALL_R)
			b.avel.y = 60.0
			b.begin_phase()
			sim.add_ball(b)

			sim.begin_shot()
			var t := 0.0
			var case := "%s off %.1f at %.1f m/s" % [label, offset, speed]
			# Sampled every step but reported once: these run to thousands of
			# steps per case, and building a detail string for each would cost
			# more than the simulation.
			var bad_pos := false
			var bad_spin := false
			var worst_spin := 0.0
			var bad_orient := Quaternion.IDENTITY
			var any_bad_orient := false
			while t < 10.0 and not sim.is_shot_over():
				sim.advance(1.0 / 60.0)
				sim.advance_drops(1.0 / 60.0)
				t += 1.0 / 60.0
				if not _finite(b.pos):
					bad_pos = true
				if not _finite(b.avel):
					bad_spin = true
				else:
					worst_spin = maxf(worst_spin, b.avel.length())
				# The one that matters: this is written straight into a node
				# transform every frame.
				if not _unit_quat(b.orient):
					any_bad_orient = true
					bad_orient = b.orient
			check("position stays finite  (%s)" % case, not bad_pos)
			check("spin stays finite  (%s)" % case, not bad_spin)
			check("spin stays bounded  (%s)" % case,
				worst_spin <= PoolPhys.MAX_SPIN + 1.0,
				"peaked at %.1f rad/s" % worst_spin)
			check("orientation is safe to draw  (%s)" % case, not any_bad_orient,
				str(bad_orient))
			check("the shot ends  (%s)" % case, sim.is_shot_over(),
				"still going after %.1f s" % t)


static func _finite(v: Vector3) -> bool:
	return is_finite(v.x) and is_finite(v.y) and is_finite(v.z)


static func _unit_quat(q: Quaternion) -> bool:
	if not (is_finite(q.x) and is_finite(q.y) and is_finite(q.z)
			and is_finite(q.w)):
		return false
	return absf(q.length_squared() - 1.0) < 0.01
