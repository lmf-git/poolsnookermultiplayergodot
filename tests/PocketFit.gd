extends Node
## Does everything cut for a pocket agree with everything else?
##
## A pocket is four pieces of geometry that have to line up: the mouth between the
## cushion noses, the hole cut in the cloth, the hole cut in the woodwork, and the
## shaft below them. They are derived from each other rather than measured
## separately, and this is what says the derivation holds -- on both tables, where
## the numbers are different enough that a rule fitting one can easily miss the
## other.
##
## The wood cut used to be struck from the shaft, which is deliberately the widest
## of the four, so every rail was scooped out far wider than the pocket it was
## opening. Check 1 is that complaint, as a number.

var failures := 0


func check(what: String, ok: bool, detail: String) -> void:
	if not ok:
		failures += 1
	print("  %s %s -- %s" % ["PASS" if ok else "FAIL", what, detail])


func _ready() -> void:
	for mode: int in [PoolPhys.POOL, PoolPhys.SNOOKER]:
		PoolPhys.configure(mode)
		var table := PoolTable.new()
		print("\n=== ", "POOL" if mode == PoolPhys.POOL else "SNOOKER", " ===")
		print("  bed %.4f x %.4f m (%.1f x %.1f in), ball %.1f mm" % [
			PoolPhys.PLAY_W, PoolPhys.PLAY_L,
			PoolPhys.PLAY_W / 0.0254, PoolPhys.PLAY_L / 0.0254,
			PoolPhys.BALL_D * 1000.0])
		_check_table(table)
	print("\n%d failed" % failures)
	get_tree().quit(1 if failures > 0 else 0)


## How far past the pocket opening the wood cut of radius `hole` runs, measured
## along the inner edge of the rail it eats into -- the one place the two can be
## compared, and the one a player looks at.
##
## Walked rather than solved: the opening is bounded by the drop line at a corner
## and by the mouth at a side pocket, and stepping along the edge asks the same
## question of both without a case for each.
func _rail_bite(table: PoolTable, pk: PoolTable.Pocket, hole: float) -> float:
	var ix := PoolPhys.HALF_W + PoolPhys.CUSHION_DEPTH
	var iz := PoolPhys.HALF_L + PoolPhys.CUSHION_DEPTH
	var sx := signf(pk.normal.x)
	var side := Vector2(-pk.normal.y, pk.normal.x)
	# Down the side rail's inner edge, away from the pocket: a corner starts at the
	# point the two rails meet, a side pocket at the end of its own mouth.
	var from := Vector2(sx * ix, signf(pk.normal.y) * iz) if pk.is_corner \
		else Vector2(sx * ix, pk.half_width)
	var away := Vector2(0.0, -signf(pk.normal.y)) if pk.is_corner else Vector2(0.0, 1.0)
	var step := 0.0001
	var open_end := 0.0
	var cut_end := 0.0
	for i in range(1500):
		var t := float(i) * step
		var p := from + away * t
		# Past the drop line is all it takes at a corner: the cushions have ended
		# and the cloth is cut, so it is open right back to the woodwork. A side
		# pocket is bounded across as well, by the cushions either side of it.
		var in_open := (p - pk.mouth).dot(pk.normal) > 0.0
		if not pk.is_corner:
			in_open = in_open and absf((p - pk.mouth).dot(side)) <= pk.half_width
		if in_open:
			open_end = t
		if p.distance_to(pk.mouth) <= hole:
			cut_end = t
	return maxf(cut_end - open_end, 0.0)


func _check_table(table: PoolTable) -> void:
	var apron := TableView.APRON_THICKNESS
	var rad := PoolPhys.BALL_R

	# The rounded end of a cushion must stay inside the cushion's own depth: it
	# curls back a full jaw diameter, and past the back of the cushion is wood.
	check("jaw cap stays inside the cushion",
		2.0 * PoolPhys.JAW_R <= PoolPhys.CUSHION_DEPTH + 1.0e-9,
		"cap reaches %.1f mm back, cushion is %.1f mm deep" % [
			2000.0 * PoolPhys.JAW_R, 1000.0 * PoolPhys.CUSHION_DEPTH])

	for pk in table.pockets:
		var kind := "corner" if pk.is_corner else "side"
		var hole := pk.opening_radius + PoolTable.WOOD_LIP
		var set_back := (pk.cavity - pk.mouth).dot(pk.normal)
		var mouth := 2.0 * pk.half_width
		print("  -- pocket %d (%s): mouth %.1f mm, opening r %.1f, wood r %.1f, shaft r %.1f"
			% [pk.id, kind, 1000.0 * mouth, 1000.0 * pk.opening_radius,
				1000.0 * hole, 1000.0 * pk.cavity_radius])

		# 1. The hole in the wood is a pocket-sized hole -- measured where it shows,
		#    which is along the rail. A corner opening is wider than its own mouth
		#    whatever is done to it (it runs diagonally back to where the two rails
		#    would have met), so the diameter says nothing; what a player sees is
		#    how far past the opening the rail has been scooped out.
		var bite := _rail_bite(table, pk, hole)
		check("wood cut follows the opening along the rail",
			bite <= PoolTable.WOOD_LIP * sqrt(2.0) + 0.001,
			"cut runs %.1f mm past the opening, lip is %.1f" % [
				1000.0 * bite, 1000.0 * PoolTable.WOOD_LIP])

		# 2. The shaft has to be hidden by the wood from every angle, so the hole
		#    must sit inside it -- worst case out at the hole's own sides, where
		#    the shaft's set-back works against it.
		var worst := Vector2(set_back, hole).length()
		check("wood cut sits inside the shaft", worst <= pk.cavity_radius + 1.0e-9,
			"hole corner %.1f mm from the shaft centre, shaft is %.1f" % [
				1000.0 * worst, 1000.0 * pk.cavity_radius])

		# 3. Nothing may be visible through the gap between the cloth and the wood
		#    except the shaft: every corner of that gap has to be over it.
		var side := Vector2(-pk.normal.y, pk.normal.x)
		for s: float in [-1.0, 1.0]:
			var corner := pk.mouth + side * (s * pk.opening_radius)
			check("opening corner %+.0f is over the shaft" % s,
				corner.distance_to(pk.cavity) <= pk.cavity_radius + 1.0e-9,
				"%.1f mm out, shaft is %.1f" % [
					1000.0 * corner.distance_to(pk.cavity), 1000.0 * pk.cavity_radius])

		# 4. A ball dropping in anywhere along the mouth must already be inside the
		#    shaft, or the liner wall shoves it sideways as it enters.
		var entry := Vector2(set_back, pk.half_width).length() + rad
		check("a ball entering at the edge of the mouth clears the liner",
			entry <= pk.cavity_radius + 1.0e-9,
			"needs %.1f mm, shaft is %.1f" % [1000.0 * entry, 1000.0 * pk.cavity_radius])

		# 5. The skirt below the woodwork must not stand in the shaft, where it
		#    would be looked straight at down the pocket.
		var reach := (pk.cavity - pk.mouth).dot(pk.normal) + pk.cavity_radius
		if pk.is_corner:
			var clear := table.corner_cut_distance(pk) - pk.cavity.dot(pk.normal) \
				- pk.cavity_radius
			check("mitre skirt clears the shaft", clear >= apron,
				"%.1f mm of wood past the shaft, skirt is %.1f deep" % [
					1000.0 * clear, 1000.0 * apron])
		else:
			var clear2 := table.rail_outer_x() - absf(pk.mouth.x) - reach
			check("side skirt clears the shaft", clear2 >= apron,
				"%.1f mm from the shaft to the outside edge, skirt is %.1f deep" % [
					1000.0 * clear2, 1000.0 * apron])
