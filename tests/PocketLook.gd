extends Node

## Development harness: close-up stills of one corner and one side pocket on both
## tables, so the shape of the mouth can be looked at without playing a frame of
## pool.
##
##     /Applications/Godot.app/Contents/MacOS/Godot --path . \
##         res://tests/PocketLook.tscn -- <output_dir>

var _dir := "/tmp"


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		_dir = args[0]

	var cam := Camera3D.new()
	cam.fov = 40.0
	add_child(cam)

	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-58.0, -40.0, 0.0)
	key.light_energy = 1.6
	key.shadow_enabled = true
	add_child(key)
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-25.0, 140.0, 0.0)
	fill.light_energy = 0.5
	add_child(fill)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.06, 0.06, 0.07)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.5, 0.5, 0.55)
	e.ambient_light_energy = 0.5
	env.environment = e
	add_child(env)

	for mode: int in [PoolPhys.POOL, PoolPhys.SNOOKER]:
		var tag := "pool" if mode == PoolPhys.POOL else "snooker"
		PoolPhys.configure(mode)
		var table := PoolTable.new()
		var view := TableView.new()
		add_child(view)
		view.build(table)

		var corner := Vector3(PoolPhys.HALF_W, 0.0, PoolPhys.HALF_L)
		var side := Vector3(PoolPhys.HALF_W, 0.0, 0.0)
		await _look(cam, corner, Vector3(0.30, 0.34, 0.30), "%s_corner_high" % tag)
		await _look(cam, corner, Vector3(0.10, 0.62, 0.10), "%s_corner_top" % tag)
		await _look(cam, corner, Vector3(0.26, 0.10, 0.26), "%s_corner_low" % tag)
		await _look(cam, side, Vector3(0.34, 0.30, 0.0), "%s_side_high" % tag)
		await _look(cam, side, Vector3(0.10, 0.55, 0.0), "%s_side_top" % tag)

		# Tight on a single jaw, where the shape of the round actually reads.
		var jaw := Vector3(PoolPhys.HALF_W - PoolPhys.CORNER_JAW, 0.0, PoolPhys.HALF_L)
		await _look(cam, jaw, Vector3(0.01, 0.22, 0.03), "%s_jaw_top" % tag)
		await _look(cam, jaw, Vector3(-0.10, 0.09, 0.14), "%s_jaw_inside" % tag)
		await _look(cam, jaw, Vector3(-0.16, 0.035, -0.10), "%s_jaw_along" % tag)
		view.queue_free()
		await get_tree().process_frame

	get_tree().quit()


func _look(cam: Camera3D, at: Vector3, offset: Vector3, name: String) -> void:
	cam.position = at + offset
	cam.look_at(at, Vector3.UP)
	for _i in range(4):
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png("%s/%s.png" % [_dir, name])
	print("wrote ", name)
