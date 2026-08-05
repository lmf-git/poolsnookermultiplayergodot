class_name PoolTable
extends RefCounted

## Collision geometry of the table, at whatever size PoolPhys is configured for.
##
## Cushions are straight segments; every segment end carries a circular "jaw"
## whose centre is pushed one jaw-radius *behind* the cushion line, so the round
## end is tangent to the flat cushion. That single detail is what lets balls
## rattle in and out of pockets the way they really do, instead of being swallowed
## by an invisible box.

class Cushion extends RefCounted:
	var a := Vector2.ZERO      # endpoint, (x, z)
	var b := Vector2.ZERO
	var normal := Vector2.ZERO # unit, pointing into the playing area
	var tangent := Vector2.ZERO
	var length := 0.0

	func _init(p_a: Vector2, p_b: Vector2, p_normal: Vector2) -> void:
		a = p_a
		b = p_b
		normal = p_normal.normalized()
		var d := b - a
		length = d.length()
		tangent = d / length


class Jaw extends RefCounted:
	var center := Vector2.ZERO
	var radius := PoolPhys.JAW_R

	func _init(p_center: Vector2) -> void:
		center = p_center


## A pocket is a straight *drop line* -- the mouth between two cushion noses,
## pushed outward by the shelf depth -- plus a cavity underneath for the ball to
## fall into.
##
## It is deliberately not a circle. A circular pocket centred outside the corner
## bulges back into the playing surface, so balls vanish while they still look to
## be out on the cloth, and the opening cut in the bed looks like a round hole
## punched in the table instead of a corner cut away.
class Pocket extends RefCounted:
	var id := 0
	var is_corner := true
	## Point on the drop line, and the unit normal pointing out of the table.
	## A ball drops when (centre - mouth) . normal > 0.
	var mouth := Vector2.ZERO
	var normal := Vector2.ZERO
	## Circular cavity below the cloth: the shaft the ball falls down. Set when
	## the table is built, from the opening it has to sit under.
	var cavity := Vector2.ZERO
	var cavity_radius := 0.0

	func _init(p_id: int, p_mouth: Vector2, p_normal: Vector2, p_corner: bool) -> void:
		id = p_id
		mouth = p_mouth
		normal = p_normal.normalized()
		is_corner = p_corner

	## How wide the opening is across the mouth. Set when the table is built.
	var half_width := 0.0

	## Radius, measured from the mouth, of the hole this pocket makes in the table.
	##
	## The opening is not the mouth. Past the mouth the cloth has been cut away and
	## the cushions have already ended, and it stays open until the woodwork starts
	## -- so what a player actually sees is the region between the drop line and the
	## inner edges of the two rails. This is the smallest circle about the mouth
	## that contains it, and it is what the wood is cut to and what the shaft below
	## has to cover. Set when the table is built.
	var opening_radius := 0.0

	## Centres of the two jaw circles the mouth runs between. Set when the table
	## is built, from the same cushion noses the jaws themselves come from.
	var jaw_a := Vector2.ZERO
	var jaw_b := Vector2.ZERO

	## The clear width left between the jaws for a ball arriving along `dir`.
	##
	## The jaws are circles, so what an arriving ball has to thread is their
	## separation measured *across* its line of travel, less a ball's width of
	## clearance at each. Arrive square and that is the full mouth; arrive across
	## it and the gap closes with the cosine, and it reaches nothing well before
	## the ball is running parallel to the rail.
	##
	## This is what makes a middle pocket a different proposition from a corner.
	## A corner has its jaws cut back off the mouth, so the separation stays
	## generous as the angle steepens. A middle pocket's are square to the rail
	## and only as far apart as the mouth is wide, so it shuts much sooner --
	## which is why balls sent at one from down the table catch a jaw instead of
	## dropping.
	##
	## Negative means the ball cannot pass at all, however well it is struck.
	func opening_along(dir: Vector2) -> float:
		var d := dir.normalized()
		var across := Vector2(-d.y, d.x)
		return absf((jaw_b - jaw_a).dot(across)) \
			- 2.0 * (PoolPhys.JAW_R + PoolPhys.BALL_R)

	## Signed distance past the drop line. Positive means the ball is unsupported.
	func depth_past_lip(p: Vector2) -> float:
		return (p - mouth).dot(normal)

	## Is this point actually over the opening?
	##
	## The drop line on its own is an unbounded half-plane, which is fine for a
	## ball on the cloth -- the cushions mean it can only reach the far side
	## through the mouth. It is not fine for the rail, where the half-plane of a
	## side pocket otherwise swallows the entire length of that rail.
	func over_opening(p: Vector2, eps := 0.0) -> bool:
		if depth_past_lip(p) <= -eps:
			return false
		var along := Vector2(-normal.y, normal.x)
		return absf((p - mouth).dot(along)) <= half_width


var cushions: Array[Cushion] = []
var jaws: Array[Jaw] = []
var pockets: Array[Pocket] = []


func _init() -> void:
	_build()


func _build() -> void:
	var hw := PoolPhys.HALF_W
	var hl := PoolPhys.HALF_L
	var cj := PoolPhys.CORNER_JAW
	var sj := PoolPhys.SIDE_JAW
	var jr := PoolPhys.JAW_R

	# Six cushion runs: one across each end, two down each side (split by the
	# side pockets). Normals point inward.
	var foot := Cushion.new(Vector2(-hw + cj, -hl), Vector2(hw - cj, -hl), Vector2(0, 1))
	var head := Cushion.new(Vector2(-hw + cj, hl), Vector2(hw - cj, hl), Vector2(0, -1))
	var left_lo := Cushion.new(Vector2(-hw, -hl + cj), Vector2(-hw, -sj), Vector2(1, 0))
	var left_hi := Cushion.new(Vector2(-hw, sj), Vector2(-hw, hl - cj), Vector2(1, 0))
	var right_lo := Cushion.new(Vector2(hw, -hl + cj), Vector2(hw, -sj), Vector2(-1, 0))
	var right_hi := Cushion.new(Vector2(hw, sj), Vector2(hw, hl - cj), Vector2(-1, 0))
	cushions = [foot, head, left_lo, left_hi, right_lo, right_hi]

	# Jaw circles: segment endpoints offset outward (opposite the inward normal)
	# by the jaw radius, making the facing tangent to the cushion face.
	for c in cushions:
		var back := -c.normal * jr
		jaws.append(Jaw.new(c.a + back))
		jaws.append(Jaw.new(c.b + back))

	# Pockets: each is the straight mouth between two cushion noses, pushed
	# outward by the shelf depth.
	var shelf_c := PoolPhys.CORNER_SHELF
	var shelf_s := PoolPhys.SIDE_SHELF
	pockets.clear()
	var pid := 0
	# The jaw centres each mouth runs between are the same points appended to
	# `jaws` above, named here from the pocket's own corner so the pocket can say
	# what it leaves open along a given line.
	for sz: float in [-1.0, 1.0]:
		for sx: float in [-1.0, 1.0]:
			var n := Vector2(sx, sz).normalized()
			# Midpoint of the mouth, halfway between the two jaw points.
			var mid := Vector2(sx * (hw - cj * 0.5), sz * (hl - cj * 0.5))
			var pk := Pocket.new(pid, mid + n * shelf_c, n, true)
			# One jaw off the end cushion, one off the side cushion.
			pk.jaw_a = Vector2(sx * (hw - cj), sz * (hl + jr))
			pk.jaw_b = Vector2(sx * (hw + jr), sz * (hl - cj))
			pockets.append(pk)
			pid += 1
	for sx: float in [-1.0, 1.0]:
		var pk2 := Pocket.new(pid, Vector2(sx * (hw + shelf_s), 0.0),
			Vector2(sx, 0.0), false)
		# Both jaws off the same rail, square to it and only the mouth apart.
		pk2.jaw_a = Vector2(sx * (hw + jr), -sj)
		pk2.jaw_b = Vector2(sx * (hw + jr), sj)
		pockets.append(pk2)
		pid += 1

	# What is left of each pocket once the cloth and the wood have been cut for
	# it: how far the hole reaches, and the shaft that has to sit under it.
	var ix := hw + PoolPhys.CUSHION_DEPTH
	var iz := hl + PoolPhys.CUSHION_DEPTH
	for pk in pockets:
		pk.half_width = mouth_width(pk) * 0.5
		# The far corner of the opening: where the rail's inner edge meets the
		# lateral bound of the cut. A corner pocket opens all the way to the point
		# the two rails would have met at; a side pocket only as wide as its mouth.
		var far := Vector2(signf(pk.normal.x) * ix, signf(pk.normal.y) * iz)
		if not pk.is_corner:
			far = Vector2(signf(pk.normal.x) * ix, pk.half_width)
		pk.opening_radius = pk.mouth.distance_to(far)
		# The shaft sits a shelf's depth back from the mouth -- a ball that drops
		# in settles where it can still be seen, rather than under the cloth.
		var set_back: float = shelf_c if pk.is_corner else shelf_s
		pk.cavity = pk.mouth + pk.normal * set_back
		# Wide enough to be hidden by the wood from every angle, and wide enough
		# that a ball crossing the drop line anywhere along the mouth is already
		# inside it: a ball caught between the two is shoved sideways by the liner
		# at the moment it drops, which reads as the pocket spitting at it.
		pk.cavity_radius = maxf(
			pk.opening_radius + WOOD_LIP + SHAFT_MARGIN,
			Vector2(set_back, pk.half_width).length() + PoolPhys.BALL_R)


## The mouth edge is bowed rather than dead straight. Cloth on a real table is cut
## in a smooth curve between the jaw facings, and a ruler-straight edge is one of
## the things that makes a rendered pocket look wrong. The sagitta is small enough
## that the felt edge never disagrees with the straight drop line the solver uses
## by more than a few millimetres.
const MOUTH_SAGITTA := 0.014


## The opening a pocket makes in the cloth.
##
## Visible mouth first: a bowed lip running between the two jaw noses. Then the cut
## keeps going *sideways* past each nose before it turns outward, because the cloth
## does not stop at the nose line -- it runs on under the cushions to the outer edge
## of the bed. Ending the cut at the noses left a wedge of cloth stranded past the
## drop line at every pocket, standing out in the open where the cushions have
## already ended: green where the hole should be. The shoulders are hidden under
## the cushion bodies, so widening the cut costs nothing that can be seen.
func pocket_cut_polygon(pk: Pocket, width: float, reach := 0.32) -> PackedVector2Array:
	var side := Vector2(-pk.normal.y, pk.normal.x)
	var along := side * (width * 0.5)
	var a := pk.mouth + along
	var b := pk.mouth - along
	# Far enough sideways to clear the cloth that runs in under the cushion.
	var ext := PoolPhys.CUSHION_DEPTH + 0.030
	var flare := width * 0.5 + ext
	var poly := PackedVector2Array()
	# Curved lip, bowing back toward the table across the middle of the mouth.
	var steps := 16
	for i in range(steps + 1):
		var u := float(i) / float(steps)          # 0..1 across the mouth
		var bow := -MOUTH_SAGITTA * (1.0 - pow(2.0 * u - 1.0, 2.0))
		poly.append(a.lerp(b, u) + pk.normal * bow)
	# Shoulder past the far nose, still on the drop line.
	poly.append(pk.mouth - side * flare)
	# The throat behind the mouth widens on an arc instead of two ruled lines, so
	# nothing about the opening reads as straight.
	for i in range(steps + 1):
		var u := float(i) / float(steps)
		var ang := PI * u
		poly.append(pk.mouth + pk.normal * (reach * 0.35 + reach * 0.65 * sin(ang * 0.5))
			- side * cos(ang) * flare)
	poly.append(pk.mouth + side * flare)
	return poly


## How much wood is taken back past the opening, so the rail does not run out to
## a knife edge where the cut meets it.
const WOOD_LIP := 0.006

## How much wider than the hole in the wood the shaft below it is cut, so the
## wood overhangs the shaft rather than being flush with it and letting the eye
## straight past its rim.
const SHAFT_MARGIN := 0.008


## The opening for the woodwork: a round hole on the mouth, only as big as the
## hole the pocket already makes in the table.
##
## The rails get this instead of the mouth slot, which would run out to the
## outside edge and leave the rail an open-ended channel. It used to be struck
## from the shaft below instead -- shaft radius plus a lip -- which is backwards,
## and it showed: the shaft is deliberately wider than the opening, so the wood
## was cut a good 5 cm wider than the pocket all the way round and each rail was
## scooped out for a quarter of a metre either side of every corner. The wood is
## now cut to the opening, which is what a real rail is cut to.
func pocket_rail_cut(pk: Pocket) -> PackedVector2Array:
	var poly := PackedVector2Array()
	var r := pk.opening_radius + WOOD_LIP
	for i in range(28):
		var t := TAU * float(i) / 28.0
		poly.append(pk.mouth + Vector2(cos(t), sin(t)) * r)
	return poly


## Mouth width of a pocket: the actual distance between the two jaw noses.
##
## It used to be padded well beyond that, which put the straight sides of the cut
## outside the jaws where they were plainly visible as ruled lines. Matching the
## real mouth lets the jaw facings round those sides off instead.
func mouth_width(pk: Pocket) -> float:
	if pk.is_corner:
		return PoolPhys.CORNER_JAW * sqrt(2.0)
	return 2.0 * PoolPhys.SIDE_JAW


## Outline of the cloth: the bed rectangle with its four corners chamfered along
## their drop lines and a notch cut at each side pocket.
##
## Every pocket cut reaches the boundary, so the result is a single simple polygon
## with no holes -- which is what lets the bed be cut exactly rather than
## rasterised on a grid and patched over with a cover ring.
## Cloth outline, as the bed rectangle with every pocket opening subtracted.
## Returns a list of pieces because the boolean may split it.
func cloth_pieces() -> Array[PackedVector2Array]:
	var ix := PoolPhys.HALF_W + PoolPhys.CUSHION_DEPTH
	var iz := PoolPhys.HALF_L + PoolPhys.CUSHION_DEPTH
	var pieces: Array[PackedVector2Array] = [PackedVector2Array([
		Vector2(-ix, -iz), Vector2(ix, -iz), Vector2(ix, iz), Vector2(-ix, iz)])]
	for pk in pockets:
		var cut := pocket_cut_polygon(pk, mouth_width(pk))
		var next: Array[PackedVector2Array] = []
		for piece in pieces:
			for r in Geometry2D.clip_polygons(piece, cut):
				next.append(r)
		pieces = next
	return pieces


func cloth_polygon() -> PackedVector2Array:
	var ix := PoolPhys.HALF_W + PoolPhys.CUSHION_DEPTH
	var iz := PoolPhys.HALF_L + PoolPhys.CUSHION_DEPTH
	var sj := PoolPhys.SIDE_JAW
	# Corner drop line is sx*x + sz*z = c.
	var c := PoolPhys.HALF_W + PoolPhys.HALF_L - PoolPhys.CORNER_JAW \
		+ PoolPhys.CORNER_SHELF * sqrt(2.0)
	var chamfer_x := c - iz          # where the chamfer meets the end rail
	var chamfer_z := c - ix          # where it meets the side rail
	var notch := PoolPhys.HALF_W + PoolPhys.SIDE_SHELF

	return PackedVector2Array([
		Vector2(chamfer_x, iz), Vector2(-chamfer_x, iz),      # head rail
		Vector2(-ix, chamfer_z),                              # head-left chamfer
		Vector2(-ix, sj), Vector2(-notch, sj),                # left side pocket
		Vector2(-notch, -sj), Vector2(-ix, -sj),
		Vector2(-ix, -chamfer_z),
		Vector2(-chamfer_x, -iz), Vector2(chamfer_x, -iz),    # foot rail
		Vector2(ix, -chamfer_z),
		Vector2(ix, -sj), Vector2(notch, -sj),                # right side pocket
		Vector2(notch, sj), Vector2(ix, sj),
		Vector2(ix, chamfer_z),
	])


## Height of whatever a ball at (x, z) would rest on: the cloth inside the
## cushions, the rail plateau outside them, and nothing at all over a pocket
## opening or past the outer edge of the woodwork.
##
## NO_SURFACE is what makes "if the ball is going over the side it just goes over
## the side" work: there is no support out there, so a ball that arrives above it
## keeps falling instead of being caught.
const NO_SURFACE := -10.0


func rail_outer_x() -> float:
	return PoolPhys.HALF_W + PoolPhys.CUSHION_DEPTH + PoolPhys.RAIL_WIDTH


func rail_outer_z() -> float:
	return PoolPhys.HALF_L + PoolPhys.CUSHION_DEPTH + PoolPhys.RAIL_WIDTH


## How much wood is left outside the pocket shaft once the corner is mitred.
##
## Wide enough to carry the skirt hanging below it: the diagonal slab that closes
## the mitre is APRON_THICKNESS deep and hangs just inside the cut, so anything
## less and the skirt would stand in the pocket shaft where it can be seen from
## above.
const CORNER_LIP := 0.060


## How far out along a corner pocket's own diagonal the woodwork is cut off.
##
## Every real table is mitred across its corner pockets: the two rails meet at 45
## degrees with the pocket set into the cut, so the whole assembly tapers into the
## pocket. Squared off instead, the corner is a block of wood with a round bite
## out of it and the rail visibly fails to go anywhere.
##
## Measured from the shaft rather than from the hole in the wood, because what the
## mitre must not cut into is the shaft.
func corner_cut_distance(pk: Pocket) -> float:
	return pk.cavity.dot(pk.normal) + pk.cavity_radius + CORNER_LIP


## Is this point cut away by one of the mitred corners?
func past_corner_cut(p: Vector2, eps := 0.0) -> bool:
	for pk in pockets:
		if not pk.is_corner:
			continue
		if p.dot(pk.normal) > corner_cut_distance(pk) - eps:
			return true
	return false


func surface_height(p: Vector2) -> float:
	if absf(p.x) <= PoolPhys.HALF_W and absf(p.y) <= PoolPhys.HALF_L:
		return 0.0
	const EDGE_EPS := 1.0e-6
	if absf(p.x) > rail_outer_x() - EDGE_EPS or absf(p.y) > rail_outer_z() - EDGE_EPS:
		return NO_SURFACE
	if past_corner_cut(p, EDGE_EPS):
		return NO_SURFACE
	for pk in pockets:
		if pk.over_opening(p, EDGE_EPS):
			return NO_SURFACE
	return PoolPhys.RAIL_TOP


## Earliest time in (0, cap] at which a ball following p(t) = p0 + v t + a t^2 / 2
## leaves the rail plateau it is standing on. INF if it stays put.
func time_leaving_rail(pos: Vector3, vel: Vector3, acc: Vector3, cap: float) -> float:
	var best := INF
	# The four straight edges: back over the cushion nose, or out past the wood.
	var lines := [
		[Vector2(1, 0), PoolPhys.HALF_W], [Vector2(-1, 0), PoolPhys.HALF_W],
		[Vector2(0, 1), PoolPhys.HALF_L], [Vector2(0, -1), PoolPhys.HALF_L],
		[Vector2(1, 0), -rail_outer_x()], [Vector2(-1, 0), -rail_outer_x()],
		[Vector2(0, 1), -rail_outer_z()], [Vector2(0, -1), -rail_outer_z()],
	]
	# And the mitre across each corner pocket, which is an edge of the plateau
	# exactly like the outside of the wood is.
	for pk in pockets:
		if pk.is_corner:
			lines.append([pk.normal, corner_cut_distance(pk)])
	for l in lines:
		var n: Vector2 = l[0]
		var d: float = l[1]
		# Crossing when n . p = d.
		var c0 := n.x * pos.x + n.y * pos.z - d
		var c1 := n.x * vel.x + n.y * vel.z
		var c2 := 0.5 * (n.x * acc.x + n.y * acc.z)
		var t := PoolRoots.quadratic_smallest(c2, c1, c0, 1.0e-9, cap)
		best = minf(best, t)
	# And the pocket openings, which the plateau is cut away for.
	for pk in pockets:
		var n3 := pk.normal
		var c0 := (Vector2(pos.x, pos.z) - pk.mouth).dot(n3)
		var c1 := n3.x * vel.x + n3.y * vel.z
		var c2 := 0.5 * (n3.x * acc.x + n3.y * acc.z)
		var t := PoolRoots.quadratic_smallest(c2, c1, c0, 1.0e-9, cap)
		best = minf(best, t)
	return best


## Is a resting ball centre at (x, z) inside the playing area and clear of every
## cushion? Used to validate ball-in-hand placement.
##
## `lip_margin` is how far clear of a pocket's drop line the centre has to be. The
## default keeps a placed ball off the very edge, where a millimetre of rounding
## either way decides whether it stays put or falls in. It is a placement
## courtesy, not a law of the table: a ball that rolls to a stop hanging over the
## pocket is somewhere a ball is perfectly entitled to be, so anything asking
## "could a ball legitimately be resting here" should pass 0.0.
func is_legal_center(p: Vector2, lip_margin := 0.002) -> bool:
	for pk in pockets:
		if pk.depth_past_lip(p) > -lip_margin:
			return false
	# Must be on the inward side of every cushion it projects onto.
	for c in cushions:
		var rel := p - c.a
		var s := rel.dot(c.tangent)
		if s < 0.0 or s > c.length:
			continue
		if rel.dot(c.normal) < PoolPhys.BALL_R:
			return false
	for j in jaws:
		if p.distance_to(j.center) < j.radius + PoolPhys.BALL_R - 0.0005:
			return false
	# Reject anything well outside the bed (e.g. past a pocket mouth).
	if absf(p.x) > PoolPhys.HALF_W + 0.01 or absf(p.y) > PoolPhys.HALF_L + 0.01:
		return false
	return true


## Nearest legal resting position to p, searched outward in rings. Keeps
## ball-in-hand and post-foul re-spots from ever leaving a ball inside geometry.
func nearest_legal_center(p: Vector2) -> Vector2:
	if is_legal_center(p):
		return p
	var step := 0.004
	for ring in range(1, 90):
		var r := step * ring
		for k in range(24):
			var ang := TAU * float(k) / 24.0
			var q := p + Vector2(cos(ang), sin(ang)) * r
			if is_legal_center(q):
				return q
	return Vector2(0.0, PoolPhys.HEAD_STRING_Z)


## The eight-ball triangle, positioned so the black lands on the black spot: it
## is the one ball in the rack that is spotted, and it sits in the middle of the
## third row rather than at the apex. Each ball gets a fraction of a millimetre
## of jitter so no two breaks are identical, which is exactly how real racks
## behave.
static func rack_positions(rng: RandomNumberGenerator) -> Array[Vector2]:
	var spacing := PoolPhys.BALL_D + 0.0002
	var row_dz := PoolPhys.rack_row_pitch()
	var apex := PoolPhys.rack_apex_z()
	var out: Array[Vector2] = []
	for row in range(5):
		for i in range(row + 1):
			var x := (float(i) - 0.5 * float(row)) * spacing
			var z := apex - float(row) * row_dz
			out.append(Vector2(
				x + rng.randf_range(-0.00015, 0.00015),
				z + rng.randf_range(-0.00015, 0.00015)))
	return out


## Which colour goes in which slot. UK rules ask for two things and leave the
## rest to the racker: the black in the centre of the third row, and the two
## balls in the back corners of a different colour from each other.
static func rack_numbers(rng: RandomNumberGenerator) -> Array[int]:
	var reds: Array[int] = [1, 2, 3, 4, 5, 6, 7]
	var yellows: Array[int] = [9, 10, 11, 12, 13, 14, 15]
	_shuffle(reds, rng)
	_shuffle(yellows, rng)

	var slots: Array[int] = []
	slots.resize(15)
	slots.fill(0)
	slots[4] = 8                          # centre of the third row: the black
	# Back-row corners: one of each colour.
	if rng.randi() % 2 == 0:
		slots[10] = reds.pop_back()
		slots[14] = yellows.pop_back()
	else:
		slots[10] = yellows.pop_back()
		slots[14] = reds.pop_back()

	var rest: Array[int] = []
	rest.append_array(reds)
	rest.append_array(yellows)
	_shuffle(rest, rng)
	for i in range(15):
		if slots[i] == 0:
			slots[i] = rest.pop_back()
	return slots


## Snooker: the fifteen reds, packed in a triangle with its apex just behind the
## pink and pointing at baulk.
static func snooker_red_positions() -> Array[Vector2]:
	var gap := PoolPhys.BALL_D + 0.0002
	var row_dz := gap * sqrt(3.0) * 0.5
	var apex_z := -PoolPhys.HALF_L * 0.5 - PoolPhys.BALL_D - 0.004
	var out: Array[Vector2] = []
	for row in range(5):
		for i in range(row + 1):
			out.append(Vector2(
				(float(i) - 0.5 * float(row)) * gap,
				apex_z - float(row) * row_dz))
	return out


static func _shuffle(arr: Array, rng: RandomNumberGenerator) -> void:
	for i in range(arr.size() - 1, 0, -1):
		var j := rng.randi_range(0, i)
		var tmp: Variant = arr[i]
		arr[i] = arr[j]
		arr[j] = tmp
