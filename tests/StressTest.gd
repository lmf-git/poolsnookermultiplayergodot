extends Node

## Hammers the real game with randomised input -- shots, stances, mode switches,
## re-racks, ball placement -- looking for whatever is making it fall over.

var main: Node
var _rng := RandomNumberGenerator.new()
var _shots := 0

func _ready() -> void:
	_rng.seed = 987654
	main = load("res://scenes/Main.tscn").instantiate()
	# These harnesses drive the game directly, with nobody to click Start.
	main.start_in_menu = false
	add_child(main)
	await get_tree().process_frame

	for round_i in range(60):
		match _rng.randi() % 12:
			0:
				# Switch games, the way the menu does it. Pressing M would open
				# the menu, which has a button on it that nobody is here to
				# click; going through start_match exercises the same path the
				# menu takes.
				main.start_match({
					"game": PoolPhys.GAME_EIGHT_BALL
						if main.game_kind == PoolPhys.GAME_SNOOKER
						else PoolPhys.GAME_SNOOKER,
					"cpu": [false, false], "level": AIPlayer.MEDIUM, "breaker": 0,
				})
				await _wait(4)
			1:
				_key(KEY_R)                       # re-rack
				await _wait(4)
			2:
				_key(KEY_J)
			3:
				_key(KEY_K)
			4:
				_key(KEY_C)
			5:
				_key(KEY_B)                       # ball in hand
				await _wait(2)
				_click()
				await _wait(2)
			6:
				_key(KEY_G)
			7:
				_key(KEY_T)
			8:
				_key(KEY_X)
			9:
				_key(KEY_ESCAPE)
			_:
				pass
		await _wait(2)

		if main.state == main.PLACING:
			for _m in range(4):
				_motion(Vector2(_rng.randf_range(-40, 40), _rng.randf_range(-40, 40)))
				await get_tree().process_frame
			_click()
			await _wait(2)

		if main.state == main.AIM:
			for _m in range(3):
				_motion(Vector2(_rng.randf_range(-60, 60), 0))
				await get_tree().process_frame
			main.spin = Vector2(_rng.randf_range(-0.5, 0.5), _rng.randf_range(-0.6, 0.4))
			main.elevation = _rng.randf_range(0.0, deg_to_rad(55.0))
			main.power = _rng.randf_range(0.2, 1.0)
			main._shoot()
			_shots += 1
			var frames := 0
			while main.state == main.SHOOTING and frames < 2500:
				await get_tree().process_frame
				frames += 1
		if round_i % 10 == 0:
			print("round %d ok (%d shots, mode=%s, state=%d)"
				% [round_i, _shots,
				"snooker" if main.game_mode == PoolPhys.SNOOKER else "pool",
				main.state])
	print("stress complete: %d shots, no crash" % _shots)
	get_tree().quit()


func _wait(n: int) -> void:
	for _i in range(n):
		await get_tree().process_frame

func _key(code: Key) -> void:
	for pressed in [true, false]:
		var e := InputEventKey.new()
		e.keycode = code
		e.physical_keycode = code
		e.pressed = pressed
		Input.parse_input_event(e)

func _click() -> void:
	for pressed in [true, false]:
		var e := InputEventMouseButton.new()
		e.button_index = MOUSE_BUTTON_LEFT
		e.pressed = pressed
		e.position = Vector2(700, 450)
		Input.parse_input_event(e)

func _motion(rel: Vector2) -> void:
	var e := InputEventMouseMotion.new()
	e.position = Vector2(700, 450)
	e.global_position = e.position
	e.relative = rel
	Input.parse_input_event(e)
