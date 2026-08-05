class_name TableView
extends Node3D

## Builds the visible table from code, matching PoolTable's collision geometry
## exactly: every cushion prism has its nose on the same line the solver uses,
## and every rounded jaw is drawn where the collision circle actually is. If the
## two ever disagree the game feels broken even when the physics is right.

const APRON_DEPTH := 0.180
## Thickness of the visible outer skirt. Kept thin enough that it never reaches
## in over a pocket cavity -- see _build_body.
const APRON_THICKNESS := 0.050
const TABLE_HEIGHT := 0.790      # cloth height above the floor (WPA spec)

var cloth_mat: StandardMaterial3D
var cushion_mat: StandardMaterial3D
var rail_mat: StandardMaterial3D
var apron_mat: StandardMaterial3D
var pocket_mat: StandardMaterial3D
var liner_mat: StandardMaterial3D
var sight_mat: StandardMaterial3D

var _table: PoolTable


func build(table: PoolTable) -> void:
	_table = table
	_make_materials()
	_build_bed()
	_build_cushions()
	_build_rails()
	_build_sights()
	_build_markings()
	_build_pockets()
	_build_body()


# ---------------------------------------------------------------------------
# materials
# ---------------------------------------------------------------------------

func _make_materials() -> void:
	cloth_mat = StandardMaterial3D.new()
	cloth_mat.albedo_color = Color(0.094, 0.330, 0.243)
	cloth_mat.roughness = 0.92
	cloth_mat.metallic = 0.0
	# A high-frequency normal map is what sells worsted cloth; without it the
	# bed reads as painted plastic under a bright lamp.
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.frequency = 0.28
	var nt := NoiseTexture2D.new()
	nt.noise = noise
	nt.as_normal_map = true
	nt.bump_strength = 1.4
	nt.width = 256
	nt.height = 256
	nt.seamless = true
	cloth_mat.normal_enabled = true
	cloth_mat.normal_texture = nt
	cloth_mat.normal_scale = 0.35
	# UVs on the bed are in metres, so this is weave repeats per metre.
	cloth_mat.uv1_scale = Vector3(55.0, 55.0, 1.0)

	# Cushions: same cloth, but back faces culled. They were two-sided, which on a
	# swept tube means you see its far inner wall straight through the near one --
	# it reads as two cushions overlapping, with the lighting fighting itself.
	# Culling is safe here because _quad derives winding from the intended normal
	# rather than assuming one.
	cushion_mat = cloth_mat.duplicate()
	cushion_mat.cull_mode = BaseMaterial3D.CULL_BACK
	cushion_mat.uv1_scale = Vector3(24.0, 24.0, 1.0)

	rail_mat = StandardMaterial3D.new()
	rail_mat.albedo_color = Color(0.235, 0.118, 0.059)
	rail_mat.roughness = 0.32
	rail_mat.metallic = 0.05

	apron_mat = StandardMaterial3D.new()
	apron_mat.albedo_color = Color(0.132, 0.066, 0.034)
	apron_mat.roughness = 0.45

	pocket_mat = StandardMaterial3D.new()
	# Dark, but not so dark that a ball resting in the pocket is invisible.
	pocket_mat.albedo_color = Color(0.075, 0.070, 0.066)
	pocket_mat.roughness = 0.95

	liner_mat = StandardMaterial3D.new()
	liner_mat.albedo_color = Color(0.055, 0.040, 0.030)
	liner_mat.roughness = 0.70

	sight_mat = StandardMaterial3D.new()
	sight_mat.albedo_color = Color(0.925, 0.902, 0.820)
	sight_mat.roughness = 0.28


# ---------------------------------------------------------------------------
# geometry
# ---------------------------------------------------------------------------

func _add(mesh: Mesh, mat: Material, pos: Vector3, rot_y := 0.0) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = pos
	if rot_y != 0.0:
		mi.rotation.y = rot_y
	add_child(mi)
	return mi


func _box(size: Vector3) -> BoxMesh:
	var b := BoxMesh.new()
	b.size = size
	return b


func _inner_x() -> float:
	return PoolPhys.HALF_W + PoolPhys.CUSHION_DEPTH


func _inner_z() -> float:
	return PoolPhys.HALF_L + PoolPhys.CUSHION_DEPTH


## The bed is an upward-facing surface at y = 0 with the pocket openings cut out
## of it, so a ball dropping in is a ball falling through a real hole.
##
## The outline comes straight from PoolTable.cloth_polygon(), which chamfers each
## corner along that pocket's drop line and notches each side pocket -- the exact
## same lines the solver uses to decide a ball has lost support. Triangulating
## that polygon directly gives an exact cut: no rasterised stair-steps, and no
## cover ring needed to hide them. An earlier version approximated the openings
## with circles centred outside each corner, which bulged back into the playing
## surface and looked like round holes punched in the table.
func _build_bed() -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for poly in _table.cloth_pieces():
		var tris := Geometry2D.triangulate_polygon(poly)
		for i in range(0, tris.size(), 3):
			var a := poly[tris[i]]
			var b := poly[tris[i + 1]]
			var c := poly[tris[i + 2]]
			_tri(st, Vector3(a.x, 0.0, a.y), Vector3(b.x, 0.0, b.y),
				Vector3(c.x, 0.0, c.y), Vector3.UP)
	# Required, not optional: the cloth material is normal mapped, and a mesh with
	# UVs but no tangent array leaves the shader with an undefined tangent basis.
	st.generate_tangents()

	var mi := MeshInstance3D.new()
	mi.name = "Bed"
	mi.mesh = st.commit()
	mi.material_override = cloth_mat
	add_child(mi)


## Emit a quad p0-p1-p2-p3 whose front face points along `nrm`.
##
## Triangle winding is derived from the desired normal rather than assumed,
## because getting it wrong is not a harmless mistake: Godot flips authored
## normals on back-facing triangles, so a reversed quad does not merely get
## culled -- it renders pure black even with two-sided rendering and correct
## normals. That cost an entire debugging session on this table's bed.
##
## Calibrated against Godot's convention: for correct winding,
## (p2 - p0) x (p1 - p0) points along the front face.
func _quad(st: SurfaceTool, p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3,
		nrm: Vector3, uv0: Vector2, uv1: Vector2, uv2: Vector2, uv3: Vector2) -> void:
	var pts := [p0, p1, p2, p3]
	var uvs := [uv0, uv1, uv2, uv3]
	var order := [0, 1, 2, 0, 2, 3]
	if (p2 - p0).cross(p1 - p0).dot(nrm) < 0.0:
		order = [0, 2, 1, 0, 3, 2]
	for idx: int in order:
		st.set_normal(nrm)
		st.set_uv(uvs[idx])
		st.add_vertex(pts[idx])


## Same, for a single triangle.
func _tri(st: SurfaceTool, p0: Vector3, p1: Vector3, p2: Vector3, nrm: Vector3) -> void:
	var pts := [p0, p1, p2]
	var order := [0, 1, 2]
	if (p2 - p0).cross(p1 - p0).dot(nrm) < 0.0:
		order = [0, 2, 1]
	for idx: int in order:
		var v: Vector3 = pts[idx]
		st.set_normal(nrm)
		st.set_uv(Vector2(v.x, v.z))
		st.add_vertex(v)


func _bed_quad(st: SurfaceTool, x0: float, x1: float, z0: float, z1: float) -> void:
	# UVs are in metres so the cloth weave tiles at a fixed real-world scale
	# regardless of how the strips happen to be merged.
	_quad(st,
		Vector3(x0, 0.0, z0), Vector3(x1, 0.0, z0),
		Vector3(x1, 0.0, z1), Vector3(x0, 0.0, z1),
		Vector3.UP,
		Vector2(x0, z0), Vector2(x1, z0), Vector2(x1, z1), Vector2(x0, z1))


## How far the cushion's underside sits below the cloth.
##
## The jaw overhangs the pocket opening, so the underside is genuinely on show
## from any low angle and has to be built. Dropping it a hair under the bed is
## what lets it be: at cloth level it would z-fight with the cloth along the whole
## length of every cushion, and that is why it used to be left out altogether.
const UNDERSIDE_Y := -0.0012


## Extrude a 2D cushion cross-section along a cushion run.
##
## Profile coordinates are (depth behind the nose, height above the cloth). The
## nose bulges forward of the rest of the face at exactly CUSHION_HEIGHT, which
## is the point the collision model treats as the contact.
func _cushion_profile() -> PackedVector2Array:
	return PackedVector2Array([
		Vector2(0.000, PoolPhys.CUSHION_HEIGHT),   # nose
		Vector2(0.007, UNDERSIDE_Y),               # face sweeping down under the cloth
		Vector2(PoolPhys.CUSHION_DEPTH, UNDERSIDE_Y),       # back, under the cloth
		Vector2(PoolPhys.CUSHION_DEPTH, PoolPhys.RAIL_TOP),          # back, at rail height
		Vector2(0.010, PoolPhys.RAIL_TOP),                  # top edge, just behind the nose
	])


## One cushion, ends included, as a single continuous mesh.
##
## The rounded ends used to be separate cylinders parked at the segment
## endpoints -- a different height and a different cross-section from the cushion
## they were supposed to finish, which is exactly why they read as bolted on. Here
## the same cross-section is swept along a path that runs straight down the
## cushion and then carries on round each jaw, so the rounded end *is* the
## cushion.
func _build_cushions() -> void:
	var profile := _cushion_profile()
	for c in _table.cushions:
		var mi := MeshInstance3D.new()
		mi.mesh = _sweep_cushion(profile, c)
		mi.material_override = cushion_mat
		add_child(mi)


## How many cross-sections the rounded part of a jaw is built from. A jaw is
## looked at from a hand's breadth away whenever a pot is lined up, so it wants
## more segments than its size suggests.
const JAW_STEPS := 18


## How far round the jaw the cushion is carried.
##
## A half turn, which is the whole of it: the cushion leaves the back of its own
## cross-section, comes round the end and closes on the nose line, so the end is a
## rounded cap and there is no flat left anywhere on it. Snooker and English pool
## jaws are rounded, not bevelled -- the rubber and the cloth over it are carried
## around the end of the cushion -- and it is the shape a ball rattles off.
##
## Anything short of PI leaves the cushion cut off at an angle, tapering away from
## the mouth: an American pocket facing, on a table that has none.
func _jaw_sweep() -> float:
	return PI


## The radius the jaw is rounded to at a given depth behind the nose.
##
## Nothing at the nose and half the depth at the back of the cushion, so the round
## *opens* into the pocket: the nose stops dead on the end of its own collision
## segment and the body behind it swings out past it. A cushion narrowing to a
## point as it reaches the pocket is the wrong way round -- the jaw is widest
## where it meets the rail.
##
## Half the depth is not a taste: it is what makes the back of the cushion sweep
## the collision jaw circle exactly (JAW_R is half the cushion's depth), so the
## outline a ball rattles off is the outline that is drawn. It also keeps the whole
## round inside the cushion's own depth -- past that is the wood, which is cut away
## for the pocket right where the round would come through.
func _jaw_radius(depth: float) -> float:
	return 0.5 * depth


## One cross-section of a rounded jaw, `phi` radians round the turn.
##
## Each point of the profile rides its own arc, curling *forward* -- its centre is
## its own jaw radius in front of it, on the plane the cushion ends at. At phi = 0
## the ring is the cushion's own cross-section, at PI/2 it is out past the end of
## the cushion, and at PI every point has come home to the nose line: the arcs are
## all tangent there, so the cap closes on a single line at the end of the nose
## instead of on a face.
##
## What that draws is a half-disc lying in the mouth of the pocket, bounded by the
## arc the *back* of the cushion travels -- which is the collision jaw circle, to
## the millimetre, because the jaw radius is half the cushion's depth. The rubber
## a ball rattles off and the circle the solver bounces it off are the same curve.
##
## Rolling a separate circle for each profile point, rather than swinging the
## whole cross-section about one axis, is what makes this work at all: the profile
## is deeper than the jaw radius, so revolving it bodily passes the far side of it
## through the axis and turns the cushion inside out -- the old "weird bumpers"
## curling into the mouths of the middle pockets. Here nothing rotates, so nothing
## can invert.
func _jaw_ring(profile: PackedVector2Array, nose: Vector3, back: Vector3,
		out_dir: Vector3, phi: float) -> Dictionary:
	var radial := back * cos(phi) + out_dir * sin(phi)
	var pts := PackedVector3Array()
	for p in profile:
		var r := _jaw_radius(p.x)
		# Centre of this point's arc: r in front of it, on the end plane.
		var centre := nose + back * (p.x - r)
		pts.append(centre + radial * r + Vector3.UP * p.y)
	return {"pts": pts, "back": radial}


func _sweep_cushion(profile: PackedVector2Array, c: PoolTable.Cushion) -> ArrayMesh:
	var n3 := Vector3(c.normal.x, 0.0, c.normal.y)
	var t3 := Vector3(c.tangent.x, 0.0, c.tangent.y)
	var a3 := Vector3(c.a.x, 0.0, c.a.y)
	var b3 := Vector3(c.b.x, 0.0, c.b.y)
	var sweep := _jaw_sweep()
	# Round one jaw, run straight down the cushion, round the other. The phi = 0
	# ring at each end is already a section of the straight run, so the run needs
	# no rings of its own: every point of it travels at a fixed depth and height
	# between the two, which is exactly the prism.
	var rings: Array = []
	for i in range(JAW_STEPS, -1, -1):
		rings.append(_jaw_ring(profile, a3, -n3, -t3, sweep * float(i) / JAW_STEPS))
	for i in range(JAW_STEPS + 1):
		rings.append(_jaw_ring(profile, b3, -n3, t3, sweep * float(i) / JAW_STEPS))
	return _sweep_rings(profile, rings, t3)


## Newell normal of a closed loop of points, pointed to agree with `hint`.
func _plane_normal(pts: PackedVector3Array, hint: Vector3) -> Vector3:
	var acc := Vector3.ZERO
	var m := pts.size()
	for i in range(m):
		var p := pts[i]
		var q := pts[(i + 1) % m]
		acc += Vector3((p.z + q.z) * (p.y - q.y), (p.x + q.x) * (p.z - q.z),
			(p.y + q.y) * (p.x - q.x))
	if acc.length_squared() < 1.0e-16:
		return hint.normalized()
	return acc.normalized() * (-1.0 if acc.dot(hint) < 0.0 else 1.0)


## Skin a run of cross-sections, and close the two open ends.
func _sweep_rings(profile: PackedVector2Array, rings: Array,
		along: Vector3) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var n := profile.size()

	var centroid := Vector2.ZERO
	for p in profile:
		centroid += p
	centroid /= float(n)

	# Arc length around the cross-section, for a weave that does not stretch.
	var arc := PackedFloat64Array()
	arc.resize(n + 1)
	arc[0] = 0.0
	for i in range(n):
		arc[i + 1] = arc[i] + profile[i].distance_to(profile[(i + 1) % n])

	var run := 0.0
	for k in range(rings.size() - 1):
		var r0: Dictionary = rings[k]
		var r1: Dictionary = rings[k + 1]
		var p0: PackedVector3Array = r0["pts"]
		var p1: PackedVector3Array = r1["pts"]
		var seg: float = p0[0].distance_to(p1[0])
		var back: Vector3 = ((r0["back"] as Vector3) + (r1["back"] as Vector3)).normalized()
		for i in range(n):
			var q0 := profile[i]
			var q1 := profile[(i + 1) % n]
			var e := q1 - q0
			var n2 := Vector2(e.y, -e.x).normalized()
			if n2.dot((q0 + q1) * 0.5 - centroid) < 0.0:
				n2 = -n2
			var nrm := (back * n2.x + Vector3.UP * n2.y).normalized()
			# The facing rings are sheared, so the profile-derived normal is only
			# right for the straight run. Take the surface's own normal where it
			# exists and use the profile one just to settle which way it faces.
			var geo := (p0[(i + 1) % n] - p0[i]).cross(p1[i] - p0[i])
			if geo.length_squared() > 1.0e-16:
				nrm = geo.normalized() * (-1.0 if geo.dot(nrm) < 0.0 else 1.0)
			_quad(st, p0[i], p0[(i + 1) % n], p1[(i + 1) % n], p1[i], nrm,
				Vector2(run, arc[i]), Vector2(run, arc[i + 1]),
				Vector2(run + seg, arc[i + 1]), Vector2(run + seg, arc[i]))
		run += seg

	# The two end faces. A half turn brings the cap back to the plane the cushion
	# ends at, with the taper having eaten most of its depth, so what is left to
	# close is a sliver lying inside the cushion's own cross-section -- but it is a
	# sliver at the mouth of a pocket, so it still gets its own plane normal rather
	# than the cushion's tangent.
	var first: PackedVector3Array = (rings[0] as Dictionary)["pts"]
	var last: PackedVector3Array = (rings[rings.size() - 1] as Dictionary)["pts"]
	var n_first := _plane_normal(first, -along)
	var n_last := _plane_normal(last, along)
	for i in range(1, n - 1):
		_tri(st, first[0], first[i + 1], first[i], n_first)
		_tri(st, last[0], last[i], last[i + 1], n_last)

	st.generate_tangents()
	return st.commit()


func _build_rails() -> void:
	var ix := _inner_x()
	var iz := _inner_z()
	var ox := ix + PoolPhys.RAIL_WIDTH
	var oz := iz + PoolPhys.RAIL_WIDTH

	var strips: Array[PackedVector2Array] = [
		# Side rails run the full outer length so the corners are filled.
		PackedVector2Array([Vector2(ix, -oz), Vector2(ox, -oz), Vector2(ox, oz), Vector2(ix, oz)]),
		PackedVector2Array([Vector2(-ox, -oz), Vector2(-ix, -oz), Vector2(-ix, oz), Vector2(-ox, oz)]),
		PackedVector2Array([Vector2(-ix, iz), Vector2(ix, iz), Vector2(ix, oz), Vector2(-ix, oz)]),
		PackedVector2Array([Vector2(-ix, -oz), Vector2(ix, -oz), Vector2(ix, -iz), Vector2(-ix, -iz)]),
	]

	# Everything taken out of the wood: a round hole at each pocket -- not the
	# mouth slot, which would run out to the outer edge and leave the rail an
	# open-ended channel -- and the mitre across each corner.
	var cutters: Array[PackedVector2Array] = []
	for pk in _table.pockets:
		cutters.append(_table.pocket_rail_cut(pk))
	cutters.append_array(_corner_cutters())

	for strip in strips:
		var pieces: Array[PackedVector2Array] = [strip]
		for cutter in cutters:
			var next: Array[PackedVector2Array] = []
			for piece in pieces:
				for r in Geometry2D.clip_polygons(piece, cutter):
					next.append(r)
			pieces = next
		for piece in pieces:
			var mesh := _prism(piece, PoolPhys.RAIL_TOP, 0.0)
			if mesh != null:
				_add(mesh, rail_mat, Vector3.ZERO)


## The wedge each mitred corner takes out of the woodwork.
##
## The mitre is a property of the table, not of the view -- a ball running the
## rail loses its support on exactly this line -- so the line comes from
## PoolTable and is only *drawn* here.
func _corner_cutters() -> Array[PackedVector2Array]:
	var out: Array[PackedVector2Array] = []
	# Comfortably larger than the table, so the wedge covers everything outside
	# the mitre however the strip it is cutting happens to be shaped.
	var reach := (_table.rail_outer_x() + _table.rail_outer_z()) * 3.0
	for pk in _table.pockets:
		if not pk.is_corner:
			continue
		var side := Vector2(-pk.normal.y, pk.normal.x)
		var far := pk.normal * _table.corner_cut_distance(pk)
		out.append(PackedVector2Array([
			far + side * reach, far - side * reach,
			far - side * reach + pk.normal * reach,
			far + side * reach + pk.normal * reach]))
	return out


## Solid slab from a 2D outline: top face, bottom face and side walls.
func _prism(poly: PackedVector2Array, y_top: float, y_bottom: float) -> ArrayMesh:
	if poly.size() < 3:
		return null
	var tris := Geometry2D.triangulate_polygon(poly)
	if tris.is_empty():
		return null

	var centroid := Vector2.ZERO
	for v in poly:
		centroid += v
	centroid /= float(poly.size())

	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in range(0, tris.size(), 3):
		var a := poly[tris[i]]
		var b := poly[tris[i + 1]]
		var c := poly[tris[i + 2]]
		_tri(st, Vector3(a.x, y_top, a.y), Vector3(b.x, y_top, b.y),
			Vector3(c.x, y_top, c.y), Vector3.UP)
		_tri(st, Vector3(a.x, y_bottom, a.y), Vector3(b.x, y_bottom, b.y),
			Vector3(c.x, y_bottom, c.y), Vector3.DOWN)

	for i in range(poly.size()):
		var p := poly[i]
		var q := poly[(i + 1) % poly.size()]
		var edge := q - p
		if edge.length() < 1.0e-9:
			continue
		var n2 := Vector2(edge.y, -edge.x).normalized()
		if n2.dot((p + q) * 0.5 - centroid) < 0.0:
			n2 = -n2
		var nrm := Vector3(n2.x, 0.0, n2.y)
		_quad(st,
			Vector3(p.x, y_top, p.y), Vector3(p.x, y_bottom, p.y),
			Vector3(q.x, y_bottom, q.y), Vector3(q.x, y_top, q.y), nrm,
			Vector2(0, 0), Vector2(0, 1), Vector2(1, 1), Vector2(1, 0))

	return st.commit()


## The 18 sights ("diamonds"), on the standard eighths of the long rails and
## quarters of the short rails, skipping the positions the pockets occupy.
func _build_sights() -> void:
	var inset := PoolPhys.CUSHION_DEPTH + PoolPhys.RAIL_WIDTH * 0.5
	var mesh := _box(Vector3(0.016, 0.0025, 0.016))
	var y := PoolPhys.RAIL_TOP + 0.0006

	for i in range(1, 8):
		if i == 4:
			continue          # side pocket
		var z := (float(i) - 4.0) * (PoolPhys.PLAY_L / 8.0)
		for sx: float in [-1.0, 1.0]:
			_add(mesh, sight_mat, Vector3(sx * (PoolPhys.HALF_W + inset), y, z), PI * 0.25)

	for j in range(1, 4):
		var x := (float(j) - 2.0) * (PoolPhys.PLAY_W / 4.0)
		for sz: float in [-1.0, 1.0]:
			_add(mesh, sight_mat, Vector3(x, y, sz * (PoolPhys.HALF_L + inset)), PI * 0.25)


## The baulk line, the D and the spots. Neither table is blank cloth: the D is
## what the break is played from and what in-hand means before a game starts,
## and the far spot is where the black is racked and where a ball knocked off
## the table comes back.
func _build_markings() -> void:
	var mark := StandardMaterial3D.new()
	mark.albedo_color = Color(0.80, 0.79, 0.74)
	mark.roughness = 0.85
	# Sits a hair above the cloth so it never z-fights with the bed surface.
	var y := 0.0006

	# The baulk line, and the D on it: a semicircle bulging toward the baulk
	# cushion. Both games have both, drawn the same way at each table's scale.
	_add(_box(Vector3(PoolPhys.PLAY_W, 0.0004, 0.003)), mark,
		Vector3(0.0, y, PoolPhys.baulk_z()))
	_add(_arc(PoolPhys.d_radius(), 0.003, 0.0, PI, 40), mark,
		Vector3(0.0, y, PoolPhys.baulk_z()))

	if PoolPhys.mode == PoolPhys.SNOOKER:
		for value in range(2, 8):
			var sp := PoolPhys.snooker_spot(value)
			_add(_spot_mesh(), mark, Vector3(sp.x, y + 0.0002, sp.y))
		return

	# Pool: the black spot, and the centre spot the middle pockets line up with.
	for sz: float in [PoolPhys.FOOT_SPOT_Z, 0.0]:
		_add(_spot_mesh(), mark, Vector3(0.0, y + 0.0002, sz))


func _spot_mesh() -> CylinderMesh:
	var spot := CylinderMesh.new()
	spot.top_radius = 0.005
	spot.bottom_radius = 0.005
	spot.height = 0.0005
	spot.radial_segments = 16
	return spot


## Flat arc of the given line width, lying on the cloth.
func _arc(radius: float, width: float, a0: float, a1: float, steps: int) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var inner := radius - width * 0.5
	var outer := radius + width * 0.5
	for i in range(steps):
		var t0 := a0 + (a1 - a0) * float(i) / float(steps)
		var t1 := a0 + (a1 - a0) * float(i + 1) / float(steps)
		var d0 := Vector3(cos(t0), 0.0, sin(t0))
		var d1 := Vector3(cos(t1), 0.0, sin(t1))
		_quad(st, d0 * inner, d0 * outer, d1 * outer, d1 * inner, Vector3.UP,
			Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1))
	return st.commit()


## Each pocket is a shaft below the cut in the bed, with a shelf at the bottom
## for the ball to land on. Only the part of the shaft framed by the cut is ever
## visible, so a plain circle is enough -- the cloth hides the rest.
func _build_pockets() -> void:
	for pk in _table.pockets:
		_add(_tube(pk.cavity_radius, -0.001, -PoolPhys.POCKET_DEPTH, 44),
			pocket_mat, Vector3(pk.cavity.x, 0.0, pk.cavity.y))
		_add(_annulus(0.0, pk.cavity_radius, 44), liner_mat,
			Vector3(pk.cavity.x, -PoolPhys.POCKET_DEPTH, pk.cavity.y))


## Flat ring in the XZ plane, facing up.
func _annulus(r_inner: float, r_outer: float, segments: int) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in range(segments):
		var a0 := TAU * float(i) / float(segments)
		var a1 := TAU * float(i + 1) / float(segments)
		var d0 := Vector3(cos(a0), 0.0, sin(a0))
		var d1 := Vector3(cos(a1), 0.0, sin(a1))
		_quad(st, d0 * r_inner, d0 * r_outer, d1 * r_outer, d1 * r_inner, Vector3.UP,
			Vector2(d0.x * r_inner, d0.z * r_inner), Vector2(d0.x * r_outer, d0.z * r_outer),
			Vector2(d1.x * r_outer, d1.z * r_outer), Vector2(d1.x * r_inner, d1.z * r_inner))
	return st.commit()


## Capless cylinder with normals pointing inward, so it reads as a shaft you are
## looking down rather than a solid post.
func _tube(radius: float, y_top: float, y_bottom: float, segments: int) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for i in range(segments):
		var a0 := TAU * float(i) / float(segments)
		var a1 := TAU * float(i + 1) / float(segments)
		var d0 := Vector3(cos(a0), 0.0, sin(a0))
		var d1 := Vector3(cos(a1), 0.0, sin(a1))
		# Normal points inward: this is a shaft being looked down, not a post.
		var mid := -(d0 + d1).normalized()
		_quad(st,
			d0 * radius + Vector3(0.0, y_top, 0.0),
			d0 * radius + Vector3(0.0, y_bottom, 0.0),
			d1 * radius + Vector3(0.0, y_bottom, 0.0),
			d1 * radius + Vector3(0.0, y_top, 0.0),
			mid,
			Vector2(a0, y_top), Vector2(a0, y_bottom),
			Vector2(a1, y_bottom), Vector2(a1, y_top))
	return st.commit()


func _build_body() -> void:
	var ix := _inner_x()
	var iz := _inner_z()
	var ox := ix + PoolPhys.RAIL_WIDTH
	var oz := iz + PoolPhys.RAIL_WIDTH

	# The apron is four perimeter slabs, NOT a box. A box has a top face spanning
	# the whole footprint, and that face sits directly under every pocket opening
	# -- so looking down a pocket you saw apron wood a millimetre below the cloth
	# and the ball vanished the instant it dropped. Slabs at the outer edge leave
	# the pocket cavities clear all the way down to their floors.
	var y_mid := -0.001 - APRON_DEPTH * 0.5
	# The skirt stops where the corner is mitred and a diagonal slab carries it
	# across, so the body tapers into the pocket the same way the rail above it
	# does. A skirt run to the square corner would stand out past the mitre and
	# put the corner back.
	var cut := _table.corner_cut_distance(_table.pockets[0]) * sqrt(2.0)
	var zc := cut - ox              # half-length of a side skirt
	var xc := cut - oz              # half-length of an end skirt
	for sx: float in [-1.0, 1.0]:
		_add(_box(Vector3(APRON_THICKNESS, APRON_DEPTH, 2.0 * zc)), apron_mat,
			Vector3(sx * (ox - APRON_THICKNESS * 0.5), y_mid, 0.0))
	for sz: float in [-1.0, 1.0]:
		_add(_box(Vector3(2.0 * xc, APRON_DEPTH, APRON_THICKNESS)),
			apron_mat, Vector3(0.0, y_mid, sz * (oz - APRON_THICKNESS * 0.5)))
	var face := (ox - xc) * sqrt(2.0)
	var diag := _box(Vector3(APRON_THICKNESS, APRON_DEPTH, face))
	for sx: float in [-1.0, 1.0]:
		for sz: float in [-1.0, 1.0]:
			var n := Vector2(sx, sz).normalized()
			var mid := Vector2(sx * (ox + xc), sz * (oz + zc)) * 0.5 \
				- n * (APRON_THICKNESS * 0.5)
			_add(diag, apron_mat, Vector3(mid.x, y_mid, mid.y), atan2(-sx, sz))

	# Legs start below the pocket floors for the same reason.
	var leg_top := -PoolPhys.POCKET_DEPTH - 0.008
	var leg_len := TABLE_HEIGHT + leg_top
	var leg := _box(Vector3(0.10, leg_len, 0.10))
	for sx: float in [-1.0, 1.0]:
		for sz: float in [-1.0, 1.0]:
			_add(leg, apron_mat, Vector3(
				sx * (ox - 0.085), leg_top - leg_len * 0.5, sz * (oz - 0.085)))

	# The floor the legs stand on belongs to RoomView, which builds it at
	# -TABLE_HEIGHT along with the rest of the room.
