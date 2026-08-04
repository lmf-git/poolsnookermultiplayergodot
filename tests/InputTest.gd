extends Node

## Drives the real game through synthetic input events, so the interactive path
## -- mouse aiming, click-to-place, charge and release -- is exercised exactly as
## a player would drive it. The scripted PlayTest bypasses all of that by poking
## state directly, which is why it can pass while the game misbehaves in a
## player's hands.
##
##     /Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
##         res://tests/InputTest.tscn

const SHOTS := 10

var main: Node


func _ready() -> void:
	main = load("res://scenes/Main.tscn").instantiate()
	add_child(main)
	await get_tree().process_frame

	for shot in range(SHOTS):
		print("--- shot %d: state=%d bih=%s ---"
			% [shot, main.state, main.rules.ball_in_hand])

		# Nudge the mouse around, then click. In PLACING that positions the cue
		# ball; in AIM it turns the cue.
		for k in range(6):
			_motion(Vector2(600.0 + 20.0 * float(k), 500.0), Vector2(14.0, 6.0))
			await get_tree().process_frame

		if main.state == main.PLACING:
			_click(true)
			await get_tree().process_frame
			_click(false)
			await get_tree().process_frame

		print("    after place: state=%d cue=%v" % [main.state, main.sim.cue.pos])

		for k in range(4):
			_motion(Vector2(700.0, 500.0), Vector2(-30.0, 0.0))
			await get_tree().process_frame

		_key(KEY_SPACE, true)
		for _i in range(24):
			await get_tree().process_frame
		_key(KEY_SPACE, false)
		await get_tree().process_frame

		print("    struck: state=%d power=%.2f aim=%v" % [main.state, main.power, main.aim_dir])

		var frames := 0
		while main.state == main.SHOOTING and frames < 3000:
			await get_tree().process_frame
			frames += 1
		for _i in range(30):
			await get_tree().process_frame

		var off := 0
		for b in main.sim.balls:
			if b.state == PoolBall.OFF_TABLE:
				off += 1
		print("    settled in %d frames: state=%d off_table=%d falling=%d cue=%v"
			% [frames, main.state, off, main.sim.falling.size(), main.sim.cue.pos])

		if main.state == main.OVER:
			main._rack()
			await get_tree().process_frame

	print("input test complete")
	await get_tree().process_frame
	get_tree().quit()


func _motion(at: Vector2, rel: Vector2) -> void:
	var e := InputEventMouseMotion.new()
	e.position = at
	e.global_position = at
	e.relative = rel
	Input.parse_input_event(e)


func _click(pressed: bool) -> void:
	var e := InputEventMouseButton.new()
	e.button_index = MOUSE_BUTTON_LEFT
	e.pressed = pressed
	e.position = Vector2(600.0, 500.0)
	Input.parse_input_event(e)


func _key(code: Key, pressed: bool) -> void:
	var e := InputEventKey.new()
	e.keycode = code
	e.physical_keycode = code
	e.pressed = pressed
	Input.parse_input_event(e)
