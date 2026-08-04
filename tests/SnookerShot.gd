extends Node

## Boots the real game, switches to snooker, plays some shots, and screenshots
## both tables.

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
	main.cam_mode = main.CAM_TOP
	await _settle(40)
	await _shot("20_pool_overhead")

	main._new_game(PoolPhys.SNOOKER)
	await _settle(60)
	print("snooker: %d balls, table %.3f x %.3f, ball r=%.5f"
		% [main.sim.balls.size(), PoolPhys.PLAY_W, PoolPhys.PLAY_L, PoolPhys.BALL_R])
	main.state = main.AIM
	main.cam_mode = main.CAM_TOP
	await _settle(40)
	await _shot("21_snooker_overhead")

	main.cam_mode = main.CAM_ORBIT
	main._orbit_pitch = -0.42
	main._orbit_dist = 3.4
	await _settle(50)
	await _shot("22_snooker_view")

	# Play a few shots at the pack and report scoring.
	for i in range(4):
		main.state = main.AIM
		main.aim_dir = (Vector3(0.0, PoolPhys.BALL_R, -PoolPhys.HALF_L * 0.55)
			- main.sim.cue.pos).normalized()
		main.power = 0.55
		main._shoot()
		for _j in range(1200):
			await get_tree().process_frame
			if main.state != main.SHOOTING:
				break
		print("  shot %d: scores=%s break=%d on=%s reds=%d" % [
			i, main.rules.score, main.rules.break_score,
			main.rules.required_name(main.sim), main.rules.reds_left(main.sim)])
		if main.state == main.PLACING:
			main.state = main.AIM
	await _settle(30)
	await _shot("23_snooker_after")
	print("done")
	get_tree().quit()

func _settle(n: int) -> void:
	for _i in range(n):
		await get_tree().process_frame

func _shot(name: String) -> void:
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("%s/%s.png" % [_dir, name])
