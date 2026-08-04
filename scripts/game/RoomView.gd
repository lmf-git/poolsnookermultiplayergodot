class_name RoomView
extends Node3D

## The room the table stands in.
##
## Built from the table outward, so both games get a room in proportion to
## themselves: a snooker table needs half as much again in every direction
## before a cue stops hitting the wall, and a room sized for one looks wrong
## around the other.
##
## Everything here is geometry plus two procedural shaders (`wood.gdshader` and
## `plaster.gdshader`). There are no textures to load, which is the same rule the
## balls and the table are built under.
##
## It is deliberately dim. A billiard room is lit from directly over the cloth
## and falls away to nothing at the walls -- that is what makes the table read as
## the only thing in the world, and it is why the pendant lamps look like lamps
## instead of like ambient light with a bulb drawn on.

const WOOD_SHADER := "res://shaders/wood.gdshader"
const PLASTER_SHADER := "res://shaders/plaster.gdshader"

## Clear space between the outside of the table and the wall. A cue is about
## 1.45 m, so this is the room you need to play every shot on the table without
## resting the butt against the plaster.
const PLAY_SPACE := 1.62
## Floor to ceiling.
const ROOM_HEIGHT := 2.82
## Height of the dado rail, and of the skirting board, above the floor.
const DADO_HEIGHT := 1.02
const SKIRTING_HEIGHT := 0.145
const TRIM_DEPTH := 0.022

var floor_y := -TableView.TABLE_HEIGHT

var wood_mat: ShaderMaterial
var panel_mat: ShaderMaterial
var trim_mat: StandardMaterial3D
var plaster_mat: ShaderMaterial
var ceiling_mat: ShaderMaterial

## Height of the pendant lamps above the cloth.
const LAMP_Y := 1.02

## The shade, bulb and rod meshes. Main hides them when the camera climbs above
## them, since otherwise they sit squarely between an overhead view and the
## table.
var lamp_meshes: Array[Node3D] = []

var _hx := 3.0
var _hz := 4.0


func build(table: PoolTable) -> void:
	_hx = table.rail_outer_x() + PLAY_SPACE
	_hz = table.rail_outer_z() + PLAY_SPACE
	_make_materials()
	_build_floor()
	_build_walls()
	_build_ceiling()
	_build_trim()
	_build_lamps()
	_build_cue_rack()
	_build_scoreboard()
	_build_lighting()


func ceiling_y() -> float:
	return floor_y + ROOM_HEIGHT


## How far a camera orbiting the middle of the table at `pitch` can be pulled
## back and still be inside the room.
##
## Outside it, the walls are backfaces and simply are not drawn -- you get a
## table floating in a void, which is worse than not having built a room at all.
## The overhead view is deliberately not held to this: from above the ceiling you
## are looking straight down through it, which is the cutaway that view wants.
func max_camera_distance(pitch: float) -> float:
	const MARGIN := 0.25
	var horizontal: float = maxf(cos(pitch), 0.05)
	var rise: float = maxf(-sin(pitch), 0.05)
	var by_wall := (minf(_hx, _hz) - MARGIN) / horizontal
	var by_ceiling := (ceiling_y() - MARGIN) / rise
	return maxf(minf(by_wall, by_ceiling), 0.6)


# ---------------------------------------------------------------------------
# materials
# ---------------------------------------------------------------------------

func _make_materials() -> void:
	var wood: Shader = load(WOOD_SHADER)
	var plaster: Shader = load(PLASTER_SHADER)

	# The floor: wide, dark, well-worn boards running the length of the room.
	wood_mat = ShaderMaterial.new()
	wood_mat.shader = wood
	wood_mat.set_shader_parameter("base_color", Color(0.093, 0.052, 0.028))
	wood_mat.set_shader_parameter("grain_color", Color(0.196, 0.112, 0.056))
	wood_mat.set_shader_parameter("board_width", 0.168)
	wood_mat.set_shader_parameter("board_length", 1.45)
	wood_mat.set_shader_parameter("groove", 0.005)
	wood_mat.set_shader_parameter("base_roughness", 0.46)

	# The panelling below the dado rail: narrower boards, a warmer finish, and
	# the grain running upright the way panelling is hung.
	panel_mat = ShaderMaterial.new()
	panel_mat.shader = wood
	panel_mat.set_shader_parameter("base_color", Color(0.112, 0.058, 0.030))
	panel_mat.set_shader_parameter("grain_color", Color(0.232, 0.128, 0.062))
	panel_mat.set_shader_parameter("board_width", 0.132)
	panel_mat.set_shader_parameter("board_length", 2.4)
	panel_mat.set_shader_parameter("groove", 0.004)
	panel_mat.set_shader_parameter("base_roughness", 0.34)
	panel_mat.set_shader_parameter("across", true)

	trim_mat = StandardMaterial3D.new()
	trim_mat.albedo_color = Color(0.088, 0.048, 0.028)
	trim_mat.roughness = 0.36
	trim_mat.metallic = 0.0
	trim_mat.metallic_specular = 0.4

	plaster_mat = ShaderMaterial.new()
	plaster_mat.shader = plaster
	plaster_mat.set_shader_parameter("wall_color", Color(0.128, 0.126, 0.126))
	plaster_mat.set_shader_parameter("mottle_color", Color(0.176, 0.170, 0.158))
	plaster_mat.set_shader_parameter("shade_from", floor_y + 1.1)
	plaster_mat.set_shader_parameter("shade_to", floor_y + ROOM_HEIGHT)
	plaster_mat.set_shader_parameter("shade_depth", 0.42)

	# The ceiling is above the lamps and catches almost nothing, so it is barely
	# shaded at all -- but it must not be pure black, or the room has no lid.
	ceiling_mat = ShaderMaterial.new()
	ceiling_mat.shader = plaster
	ceiling_mat.set_shader_parameter("wall_color", Color(0.070, 0.068, 0.070))
	ceiling_mat.set_shader_parameter("mottle_color", Color(0.098, 0.094, 0.092))
	ceiling_mat.set_shader_parameter("shade_depth", 0.0)
	ceiling_mat.set_shader_parameter("base_roughness", 0.95)


# ---------------------------------------------------------------------------
# geometry helpers
# ---------------------------------------------------------------------------

## A quad with UVs measured in metres, so a shader working in real-world units
## covers it at the right scale whatever size it is.
##
## The winding is derived from the intended normal rather than assumed, using the
## same test the table's geometry uses: pass the corners in either direction and
## the face still points the right way.
func _quad(a: Vector3, b: Vector3, c: Vector3, d: Vector3, normal: Vector3,
		u_axis: Vector3, v_axis: Vector3) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var pts := [a, b, c, d]
	var order := [0, 1, 2, 0, 2, 3]
	if (c - a).cross(b - a).dot(normal) < 0.0:
		order = [0, 2, 1, 0, 3, 2]
	for idx: int in order:
		var p: Vector3 = pts[idx]
		var rel := p - a
		st.set_normal(normal)
		st.set_uv(Vector2(rel.dot(u_axis), rel.dot(v_axis)))
		st.add_vertex(p)
	st.generate_tangents()
	return st.commit()


func _add(mesh: Mesh, mat: Material, pos := Vector3.ZERO) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.material_override = mat
	mi.position = pos
	add_child(mi)
	return mi


## A trim box -- skirting, dado rail, a picture frame. Boxes get world-sized UVs
## from the mesh's own dimensions, which is close enough for something a few
## centimetres across.
func _add_box(size: Vector3, mat: Material, pos: Vector3) -> MeshInstance3D:
	var b := BoxMesh.new()
	b.size = size
	return _add(b, mat, pos)


# ---------------------------------------------------------------------------
# the room
# ---------------------------------------------------------------------------

func _build_floor() -> void:
	# Boards run the length of the room, as they would be laid.
	_add(_quad(
		Vector3(-_hx, floor_y, -_hz), Vector3(-_hx, floor_y, _hz),
		Vector3(_hx, floor_y, _hz), Vector3(_hx, floor_y, -_hz),
		Vector3.UP, Vector3(0, 0, 1), Vector3(1, 0, 0)), wood_mat)


func _build_ceiling() -> void:
	var y := ceiling_y()
	_add(_quad(
		Vector3(-_hx, y, -_hz), Vector3(_hx, y, -_hz),
		Vector3(_hx, y, _hz), Vector3(-_hx, y, _hz),
		Vector3.DOWN, Vector3(1, 0, 0), Vector3(0, 0, 1)), ceiling_mat)


## Each wall is two surfaces: panelling up to the dado rail, plaster above it.
func _build_walls() -> void:
	var dado := floor_y + DADO_HEIGHT
	var top := ceiling_y()
	for side: float in [-1.0, 1.0]:
		# The two long walls, at x = +/- _hx, facing inward.
		var n := Vector3(-side, 0.0, 0.0)
		_wall_section(Vector3(side * _hx, floor_y, -_hz),
			Vector3(side * _hx, dado, _hz), n, panel_mat)
		_wall_section(Vector3(side * _hx, dado, -_hz),
			Vector3(side * _hx, top, _hz), n, plaster_mat)
		# The two end walls, at z = +/- _hz.
		var n2 := Vector3(0.0, 0.0, -side)
		_wall_section(Vector3(-_hx, floor_y, side * _hz),
			Vector3(_hx, dado, side * _hz), n2, panel_mat)
		_wall_section(Vector3(-_hx, dado, side * _hz),
			Vector3(_hx, top, side * _hz), n2, plaster_mat)


## A rectangular piece of wall between two opposite corners, facing `normal`.
func _wall_section(lo: Vector3, hi: Vector3, normal: Vector3, mat: Material) -> void:
	var along := Vector3(hi.x - lo.x, 0.0, hi.z - lo.z)
	var up := Vector3(0.0, hi.y - lo.y, 0.0)
	_add(_quad(lo, lo + along, lo + along + up, lo + up, normal,
		along.normalized(), Vector3.UP), mat)


func _build_trim() -> void:
	var dado := floor_y + DADO_HEIGHT
	var skirt_y := floor_y + SKIRTING_HEIGHT * 0.5
	for side: float in [-1.0, 1.0]:
		# Long walls.
		var x := side * (_hx - TRIM_DEPTH * 0.5)
		_add_box(Vector3(TRIM_DEPTH, SKIRTING_HEIGHT, 2.0 * _hz), trim_mat,
			Vector3(x, skirt_y, 0.0))
		_add_box(Vector3(TRIM_DEPTH * 1.6, 0.048, 2.0 * _hz), trim_mat,
			Vector3(side * (_hx - TRIM_DEPTH * 0.8), dado, 0.0))
		# End walls.
		var z := side * (_hz - TRIM_DEPTH * 0.5)
		_add_box(Vector3(2.0 * _hx, SKIRTING_HEIGHT, TRIM_DEPTH), trim_mat,
			Vector3(0.0, skirt_y, z))
		_add_box(Vector3(2.0 * _hx, 0.048, TRIM_DEPTH * 1.6), trim_mat,
			Vector3(0.0, dado, side * (_hz - TRIM_DEPTH * 0.8)))


# ---------------------------------------------------------------------------
# what is in the room
# ---------------------------------------------------------------------------

## The pendants over the table: shaded lamps on rods that go up to the ceiling.
##
## How many, and how far apart, comes from the table -- two over a pub table and
## three over a snooker table, which is what a room with each in it has. The
## light they cast is the only light on the cloth, so the spacing is not
## decoration: it is why the middle of a snooker table is not a dark patch.
func _build_lamps() -> void:
	lamp_meshes.clear()
	var count := clampi(int(round(PoolPhys.PLAY_L / 1.05)), 2, 4)
	var spread := PoolPhys.PLAY_L * 0.62
	var shade_r: float = clampf(PoolPhys.PLAY_W * 0.15, 0.165, 0.28)

	var shade_mat := StandardMaterial3D.new()
	shade_mat.albedo_color = Color(0.10, 0.09, 0.09)
	shade_mat.roughness = 0.5
	var bulb_mat := StandardMaterial3D.new()
	bulb_mat.albedo_color = Color(1.0, 0.94, 0.84)
	bulb_mat.emission_enabled = true
	bulb_mat.emission = Color(1.0, 0.93, 0.80)
	bulb_mat.emission_energy_multiplier = 2.4

	var rod_bottom := LAMP_Y + 0.08
	var rod_top := ceiling_y()

	for i in range(count):
		var t: float = 0.0 if count == 1 else float(i) / float(count - 1) - 0.5
		var lamp := Node3D.new()
		lamp.position = Vector3(0.0, LAMP_Y, t * spread)
		add_child(lamp)

		var shade := MeshInstance3D.new()
		var cyl := CylinderMesh.new()
		cyl.top_radius = shade_r * 0.38
		cyl.bottom_radius = shade_r
		cyl.height = 0.16
		shade.mesh = cyl
		shade.material_override = shade_mat
		lamp.add_child(shade)
		lamp_meshes.append(shade)

		var bulb := MeshInstance3D.new()
		var disc := CylinderMesh.new()
		disc.top_radius = shade_r * 0.85
		disc.bottom_radius = shade_r * 0.85
		disc.height = 0.006
		bulb.mesh = disc
		bulb.material_override = bulb_mat
		bulb.position = Vector3(0.0, -0.082, 0.0)
		lamp.add_child(bulb)
		lamp_meshes.append(bulb)

		# The rod runs all the way to the ceiling, because the ceiling is now
		# there to run to.
		var rod := MeshInstance3D.new()
		var rc := CylinderMesh.new()
		rc.top_radius = 0.008
		rc.bottom_radius = 0.008
		rc.height = maxf(rod_top - rod_bottom, 0.05)
		rod.mesh = rc
		rod.material_override = shade_mat
		rod.position = Vector3(0.0, (rod_bottom + rod_top) * 0.5 - LAMP_Y, 0.0)
		lamp.add_child(rod)
		lamp_meshes.append(rod)

		var spot := SpotLight3D.new()
		spot.position = Vector3(0.0, -0.09, 0.0)
		spot.rotation = Vector3(-PI * 0.5, 0.0, 0.0)
		spot.light_energy = 2.3
		spot.light_color = Color(1.0, 0.95, 0.87)
		spot.spot_range = 4.0
		spot.spot_angle = 68.0
		spot.spot_attenuation = 0.9
		spot.shadow_enabled = true
		# Tight enough to keep the contact shadow under each ball; a wider blur
		# smears it away entirely.
		spot.shadow_blur = 0.55
		spot.shadow_bias = 0.008
		spot.shadow_normal_bias = 0.4
		spot.light_specular = 0.8
		lamp.add_child(spot)

## A rack of spare cues against one of the long walls. Two things it does: it
## gives the eye something at the edge of the light to judge the room's depth by,
## and it puts an object of known length next to the table.
func _build_cue_rack() -> void:
	var x := _hx - 0.06
	var z0 := -0.9
	var board := StandardMaterial3D.new()
	board.albedo_color = Color(0.075, 0.042, 0.024)
	board.roughness = 0.42

	_add_box(Vector3(0.055, 1.62, 0.44), board, Vector3(x, floor_y + 1.02, z0))

	var shaft := StandardMaterial3D.new()
	shaft.albedo_color = Color(0.52, 0.36, 0.20)
	shaft.roughness = 0.28
	var butt := StandardMaterial3D.new()
	butt.albedo_color = Color(0.13, 0.055, 0.040)
	butt.roughness = 0.30

	for i in range(4):
		var z := z0 - 0.16 + 0.107 * float(i)
		var lean := deg_to_rad(4.0)
		var length := 1.46
		var mid := floor_y + length * 0.5 * cos(lean)
		var cue := Node3D.new()
		cue.position = Vector3(x - 0.075 - 0.012 * float(i % 2), mid, z)
		cue.rotation = Vector3(0.0, 0.0, lean)
		add_child(cue)
		_cue_section(cue, shaft, 0.007, 0.011, length * 0.55, length * 0.225)
		_cue_section(cue, butt, 0.011, 0.016, length * 0.45, -length * 0.275)


func _cue_section(parent: Node3D, mat: Material, r_top: float, r_bottom: float,
		length: float, offset: float) -> void:
	var c := CylinderMesh.new()
	c.top_radius = r_top
	c.bottom_radius = r_bottom
	c.height = length
	c.radial_segments = 10
	var mi := MeshInstance3D.new()
	mi.mesh = c
	mi.material_override = mat
	mi.position = Vector3(0.0, offset, 0.0)
	parent.add_child(mi)


## The scoring board every club has on the wall, in the dark where it belongs.
func _build_scoreboard() -> void:
	var x := -_hx + 0.035
	var y := floor_y + 1.62
	var frame := StandardMaterial3D.new()
	frame.albedo_color = Color(0.085, 0.046, 0.026)
	frame.roughness = 0.34
	var face := StandardMaterial3D.new()
	face.albedo_color = Color(0.045, 0.058, 0.050)
	face.roughness = 0.88

	_add_box(Vector3(0.05, 0.60, 1.05), frame, Vector3(x, y, 0.0))
	_add_box(Vector3(0.02, 0.48, 0.93), face, Vector3(x + 0.038, y, 0.0))
	# Two brass slider rails across it.
	var brass := StandardMaterial3D.new()
	brass.albedo_color = Color(0.52, 0.40, 0.16)
	brass.metallic = 0.85
	brass.roughness = 0.30
	for dy: float in [-0.11, 0.11]:
		_add_box(Vector3(0.012, 0.012, 0.88), brass, Vector3(x + 0.050, y + dy, 0.0))


## One very dim, shadowless light high in the room.
##
## The pendants over the table are the only real light source and they point
## straight down, so without this the walls are black and the room may as well
## not be there. It is well below the level where it competes with the table.
func _build_lighting() -> void:
	var fill := OmniLight3D.new()
	fill.position = Vector3(0.0, ceiling_y() - 0.35, 0.0)
	fill.light_energy = 0.55
	fill.light_color = Color(0.86, 0.84, 0.92)
	fill.omni_range = maxf(_hx, _hz) * 2.4
	fill.omni_attenuation = 1.6
	fill.shadow_enabled = false
	add_child(fill)
