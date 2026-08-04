extends Node

## Development harness: boots the real game, drives a scripted break, and writes
## PNGs so the rendering can be checked without a human at the keyboard.
##
##     /Applications/Godot.app/Contents/MacOS/Godot --path . \
##         res://tests/Capture.tscn -- <output_dir>

var main: Node
var _dir := "/tmp"


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() > 0:
		_dir = args[0]

	main = load("res://scenes/Main.tscn").instantiate()
	# These harnesses drive the game directly, with nobody to click Start.
	main.start_in_menu = false
	add_child(main)
	await get_tree().process_frame
	await get_tree().process_frame

	# Aim view, cue ball placed for the break.
	main.state = main.AIM
	main.aim_dir = (Vector3(0.0, PoolPhys.BALL_R, PoolPhys.FOOT_SPOT_Z)
		- main.sim.cue.pos).normalized()
	await _settle(40)
	await _shot("01_aim")

	main.cam_mode = main.CAM_TOP
	await _settle(40)
	await _shot("02_overhead")

	main.cam_mode = main.CAM_AIM
	main.spin = Vector2(0.35, -0.30)
	await _settle(30)
	await _shot("03_english_and_guide")

	# Break.
	main.power = 0.92
	main.spin = Vector2.ZERO
	main._shoot()
	await _settle(24)
	await _shot("04_break_early")
	await _settle(90)
	await _shot("05_break_spread")

	# Let it finish, then look at the resulting layout.
	for _i in range(700):
		await get_tree().process_frame
		if main.state != main.SHOOTING:
			break
	main.cam_mode = main.CAM_ORBIT
	await _settle(60)
	await _shot("06_after_break")

	main.hud.show_help = true
	await _settle(20)
	await _shot("07_help")
	main.hud.show_help = false

	# Close-up on a pocket drop: the ball should tip over the edge and fall in.
	main.sim.cue.place(Vector3(PoolPhys.HALF_W - 0.26, 0.0, PoolPhys.HALF_L - 0.26))
	main.state = main.AIM
	main.cam_mode = main.CAM_AIM
	main._aim_dist = 0.62
	main.aim_dir = (Vector3(PoolPhys.HALF_W + 0.02, PoolPhys.BALL_R, PoolPhys.HALF_L + 0.02)
		- main.sim.cue.pos).normalized()
	main.power = 0.30
	await _settle(45)
	await _shot("08_pocket_aim")
	main._shoot()
	for i in range(6):
		await _settle(4)
		await _shot("09_drop_%d" % i)

	# Several seconds later: is the ball still sitting in the pocket?
	for _i in range(240):
		await get_tree().process_frame
	main.cam_mode = main.CAM_ORBIT
	main._orbit_pitch = -1.05
	main._orbit_dist = 1.15
	main._orbit_yaw = deg_to_rad(35.0)
	await _settle(50)
	await _shot("09b_resting_in_pocket")
	for b in main.sim.balls:
		if b.state == PoolBall.POCKETED:
			print("  pocketed #%d at y=%.4f falling=%s" % [b.number, b.pos.y, b.falling])

	# Cue against the head rail: the butt must be raised clear of the wood.
	for _i in range(400):
		await get_tree().process_frame
		if main.state != main.SHOOTING:
			break
	main.rules.ball_in_hand = false
	main.sim.cue.place(Vector3(0.0, 0.0, PoolPhys.HALF_L - PoolPhys.BALL_R - 0.004))
	main.state = main.AIM
	main.cam_mode = main.CAM_ORBIT
	main._orbit_pitch = -0.16
	main._orbit_yaw = 0.0
	main._orbit_dist = 1.5
	main.aim_dir = Vector3(0, 0, -1)
	await _settle(50)
	await _shot("10_cue_off_the_rail")

	print("captured to %s" % _dir)
	get_tree().quit()


func _settle(frames: int) -> void:
	for _i in range(frames):
		await get_tree().process_frame


func _shot(name: String) -> void:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var path := "%s/%s.png" % [_dir, name]
	var err := img.save_png(path)
	print("%s -> %s" % ["ok " if err == OK else "FAIL", path])
