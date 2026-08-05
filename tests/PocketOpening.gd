extends Node

## What the jaws leave open, as a function of how the ball arrives.
##
##     /Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
##         res://tests/PocketOpening.tscn
##
## Pure geometry, no simulation: `Pocket.opening_along` is derived from the same
## jaw circles the physics collides against, so this checks the derivation rather
## than the physics. It exists because the CPU's planner reads this number to
## decide whether a pot is on at all, and the number it used to read -- the mouth
## measured straight across, whatever the angle -- said a middle pocket was the
## most forgiving on the table when it is the least.

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
	for mode: int in [PoolPhys.SNOOKER, PoolPhys.POOL]:
		PoolPhys.configure(mode)
		print("\n--- %s ---"
			% ["snooker" if mode == PoolPhys.SNOOKER else "UK pool"])
		_check_table()
	print("\n%d passed, %d failed" % [_passed, _failed])
	get_tree().quit(1 if _failed > 0 else 0)


func _check_table() -> void:
	var table := PoolTable.new()
	var corner: PoolTable.Pocket = null
	var side: PoolTable.Pocket = null
	for pk in table.pockets:
		if pk.is_corner and corner == null:
			corner = pk
		if not pk.is_corner and side == null:
			side = pk

	# The jaw centres have to be the ones the physics uses, or the planner is
	# reasoning about a different table from the one the ball rolls on.
	for pk in table.pockets:
		check("pocket %d's jaws are real jaws" % pk.id,
			_is_a_jaw(table, pk.jaw_a) and _is_a_jaw(table, pk.jaw_b))

	print("  approach   corner      middle")
	for deg: float in [0.0, 20.0, 30.0, 40.0, 50.0, 60.0, 75.0]:
		print("    %2.0f deg  %8.1f mm %8.1f mm"
			% [deg, _open(corner, deg) * 1000.0, _open(side, deg) * 1000.0])

	# The openings have to be the sizes the table is documented as having. This
	# is the check that matters most: the jaw is a circle tangent to the cushion
	# face, so half of it stands into the mouth, and quoting the cushion cut-back
	# as though it were the mouth quietly costs a jaw radius at each side. That
	# had a pub table's centres playing at 2.7 in against the 4.3 in intended.
	check("a corner is its specified mouth, less a ball",
		absf(_open(corner, 0.0) - (PoolPhys.CORNER_MOUTH - PoolPhys.BALL_D)) < 5.0e-4,
		"%.1f mm, want %.1f" % [_open(corner, 0.0) * 1000.0,
			(PoolPhys.CORNER_MOUTH - PoolPhys.BALL_D) * 1000.0])
	check("a middle is its specified mouth, less a ball",
		absf(_open(side, 0.0) - (PoolPhys.SIDE_MOUTH - PoolPhys.BALL_D)) < 5.0e-4,
		"%.1f mm, want %.1f" % [_open(side, 0.0) * 1000.0,
			(PoolPhys.SIDE_MOUTH - PoolPhys.BALL_D) * 1000.0])

	# Square on, a middle is the more forgiving of the two -- it is cut wider on
	# both tables, and a straight pot into one is the easiest shot there is.
	# What makes it the harder pocket in play is where the ball has to come
	# from, not how much room it leaves a ball arriving square.
	check("a middle is cut wider than a corner", PoolPhys.SIDE_MOUTH > PoolPhys.CORNER_MOUTH,
		"%.1f vs %.1f mm" % [PoolPhys.SIDE_MOUTH * 1000.0, PoolPhys.CORNER_MOUTH * 1000.0])
	for deg: float in [0.0, 20.0, 30.0, 40.0]:
		check("a middle is the more open of the two at %.0f deg" % deg,
			_open(side, deg) > _open(corner, deg),
			"%.1f vs %.1f mm" % [_open(side, deg) * 1000.0,
				_open(corner, deg) * 1000.0])

	# The gap only ever closes as the arrival steepens.
	var last := INF
	for deg: float in [0.0, 10.0, 20.0, 30.0, 40.0, 50.0]:
		var w := _open(side, deg)
		check("a middle closes by %.0f deg" % deg, w <= last + 1.0e-9,
			"%.1f mm" % (w * 1000.0))
		last = w

	# The point of the whole exercise: a ball sent across the mouth of a middle
	# pocket does not go in, however well it is struck. The old planner rated
	# these up to 78 degrees.
	check("a middle is shut by 60 degrees", _open(side, 60.0) <= 0.0,
		"%.1f mm" % (_open(side, 60.0) * 1000.0))

	# And this is the comparison that actually decides shot selection, which is
	# not "same angle off each pocket's own normal" -- the two normals point
	# nowhere near the same way. A ball running the length of the table meets a
	# corner square down its diagonal and a middle dead across its face, which is
	# why the corner is the pot that is on from distance and the middle is not.
	# A ball running dead parallel to the long rail is right on the edge of a
	# corner either way -- a pub table gives it a couple of millimetres, a
	# snooker table a couple less than none, which is exactly why hugging the
	# cushion is a safety. Against a middle it is not a shot at all.
	var down_table := Vector2(0.0, 1.0)
	var c_open := corner.opening_along(down_table)
	var s_open := side.opening_along(down_table)
	check("a ball down the table is within a hair of a corner", absf(c_open) < 0.010,
		"%.1f mm" % (c_open * 1000.0))
	check("and nowhere near a middle", s_open < c_open - 0.050,
		"%.1f vs %.1f mm" % [s_open * 1000.0, c_open * 1000.0])


## Gap left for a ball arriving `deg` off the pocket's own normal.
func _open(pk: PoolTable.Pocket, deg: float) -> float:
	return pk.opening_along(-pk.normal.rotated(deg_to_rad(deg)))


func _is_a_jaw(table: PoolTable, p: Vector2) -> bool:
	for j in table.jaws:
		if j.center.distance_to(p) < 1.0e-6:
			return true
	return false
