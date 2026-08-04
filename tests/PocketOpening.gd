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

	# Square on, both pockets take a ball with room to spare -- but a middle
	# never has as much of it as a corner, at any angle.
	check("a corner is open square on", _open(corner, 0.0) > 0.02,
		"%.1f mm" % (_open(corner, 0.0) * 1000.0))
	check("a middle is open square on", _open(side, 0.0) > 0.015,
		"%.1f mm" % (_open(side, 0.0) * 1000.0))
	for deg: float in [0.0, 20.0, 30.0, 40.0]:
		check("a middle is tighter than a corner at %.0f deg" % deg,
			_open(side, deg) < _open(corner, deg),
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
	check("a middle is shut by 50 degrees", _open(side, 50.0) <= 0.0,
		"%.1f mm" % (_open(side, 50.0) * 1000.0))
	check("and a corner still takes 50 degrees better than a middle",
		_open(corner, 50.0) > _open(side, 50.0),
		"%.1f vs %.1f mm" % [_open(corner, 50.0) * 1000.0,
			_open(side, 50.0) * 1000.0])


## Gap left for a ball arriving `deg` off the pocket's own normal.
func _open(pk: PoolTable.Pocket, deg: float) -> float:
	return pk.opening_along(-pk.normal.rotated(deg_to_rad(deg)))


func _is_a_jaw(table: PoolTable, p: Vector2) -> bool:
	for j in table.jaws:
		if j.center.distance_to(p) < 1.0e-6:
			return true
	return false
