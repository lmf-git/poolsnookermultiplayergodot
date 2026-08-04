extends Node

## Do the J and K stance keys actually set up a shot that gets the ball airborne?

var main: Node

func _ready() -> void:
	main = load("res://scenes/Main.tscn").instantiate()
	add_child(main)
	await get_tree().process_frame

	# Two positions: close behind the head rail, and out in open table. The cue
	# tilts up automatically to clear whatever rail is behind the shot, and that
	# tilt works against a scoop.
	for setup: Array in [[KEY_J, 0.9], [KEY_K, 0.9], [KEY_J, 0.0], [KEY_K, 0.0]]:
		var key: Key = setup[0]
		var z: float = setup[1]
		main.state = main.AIM
		main.sim.return_to_table(main.sim.cue, Vector3(0.0, PoolPhys.BALL_R, z))
		main.aim_dir = Vector3(0, 0, -1)
		_key(key, true)
		await get_tree().process_frame
		_key(key, false)
		await get_tree().process_frame
		var name := "J (jump)" if key == KEY_J else "K (scoop)"
		print("%s at z=%.1f -> set %.0f deg, applied %.1f deg, tip %+.2f" % [
			name, z, rad_to_deg(main.elevation), rad_to_deg(main._elev()),
			main.spin.y])

		main.power = 1.0
		# Let the guide refresh at the power the shot will actually be played at.
		main._predict_dirty = true
		await get_tree().process_frame
		await get_tree().process_frame
		print("     predicted hop %.2f cm (path %d pts, hit %d)" % [
			main._predict_hop * 100.0,
			(main._predict.get("path", PackedVector3Array()) as PackedVector3Array).size(),
			main._predict.get("hit_number", -1)])
		main._shoot()
		var peak := 0.0
		for _i in range(400):
			await get_tree().process_frame
			peak = maxf(peak, main.sim.cue.pos.y - PoolPhys.BALL_R)
			if main.state != main.SHOOTING:
				break
		print("     peak %.2f cm%s" % [peak * 100.0,
			"   CLEARS A BALL" if peak > PoolPhys.BALL_D else ""])
		if main.state == main.PLACING:
			main.state = main.AIM
	print("ball diameter %.2f cm" % (PoolPhys.BALL_D * 100.0))
	get_tree().quit()


func _key(code: Key, pressed: bool) -> void:
	var e := InputEventKey.new()
	e.keycode = code
	e.physical_keycode = code
	e.pressed = pressed
	Input.parse_input_event(e)
