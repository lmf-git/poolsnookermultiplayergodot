extends Node
## Close-ups of a side pocket and a corner pocket, straight down, for inspecting
## the cushion ends and the felt cut.

var main: Node
var _dir := "/tmp"

func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		_dir = args[0]
	main = load("res://scenes/Main.tscn").instantiate()
	add_child(main)
	await get_tree().process_frame
	await get_tree().process_frame
	main.state = main.AIM
	main.show_guide = false
	main.hud.visible = false

	# Park the camera by hand, looking straight down at each pocket in turn.
	var cam: Camera3D = main.cam
	main.set_process(false)
	for spot: Array in [
			["30_side_pocket", Vector3(PoolPhys.HALF_W, 0.0, 0.0)],
			["31_corner_pocket", Vector3(PoolPhys.HALF_W, 0.0, PoolPhys.HALF_L)],
			["32_corner_angled", Vector3(PoolPhys.HALF_W, 0.0, PoolPhys.HALF_L)]]:
		var name: String = spot[0]
		var at: Vector3 = spot[1]
		if name.ends_with("angled"):
			cam.global_position = at + Vector3(-0.16, 0.20, -0.16)
			cam.look_at(at + Vector3(0.03, 0.0, 0.03), Vector3.UP)
		else:
			cam.global_position = at + Vector3(0.0, 0.34, 0.0)
			cam.look_at(at, Vector3(0, 0, -1))
		for _i in range(4):
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png("%s/%s.png" % [_dir, name])
		print("saved %s" % name)
	get_tree().quit()
