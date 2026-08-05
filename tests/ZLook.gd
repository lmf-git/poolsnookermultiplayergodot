extends Node
## Scratch: straight-down orthographic views of one jaw, to judge the plan shape.

var _dir := "/tmp"


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		_dir = args[0]
	var cam := Camera3D.new()
	cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	add_child(cam)
	var key := DirectionalLight3D.new()
	key.rotation_degrees = Vector3(-70.0, -35.0, 0.0)
	key.light_energy = 1.4
	add_child(key)
	var env := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_COLOR
	e.background_color = Color(0.9, 0.2, 0.9)
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.7, 0.7, 0.75)
	e.ambient_light_energy = 0.7
	env.environment = e
	add_child(env)

	for mode: int in [PoolPhys.POOL, PoolPhys.SNOOKER]:
		var tag := "pool" if mode == PoolPhys.POOL else "snooker"
		PoolPhys.configure(mode)
		var table := PoolTable.new()
		var view := TableView.new()
		add_child(view)
		view.build(table)
		# Middle pocket, straight down.
		await _plan(cam, Vector3(PoolPhys.HALF_W, 0.0, 0.0), 0.34, "%s_mid_plan" % tag)
		# Corner pocket, straight down.
		await _plan(cam, Vector3(PoolPhys.HALF_W, 0.0, PoolPhys.HALF_L), 0.40,
			"%s_corner_plan" % tag)
		view.queue_free()
		await get_tree().process_frame
	get_tree().quit()


func _plan(cam: Camera3D, at: Vector3, size: float, name: String) -> void:
	cam.size = size
	cam.global_position = at + Vector3(0.0, 1.0, 0.0)
	cam.rotation_degrees = Vector3(-90.0, 0.0, 0.0)
	await RenderingServer.frame_post_draw
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png("%s/%s.png" % [_dir, name])
	print("wrote ", name)
