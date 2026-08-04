extends Node

## Plays a whole game through the real Main scene, headlessly, so the shot ->
## rules -> respot -> next-shot cycle is exercised end to end. Any script error
## in that loop shows up here instead of in front of the player.
##
##     /Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
##         res://tests/PlayTest.tscn

const SHOTS := 24

var main: Node
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	_rng.seed = 12345
	main = load("res://scenes/Main.tscn").instantiate()
	# These harnesses drive the game directly, with nobody to click Start.
	main.start_in_menu = false
	add_child(main)
	await get_tree().process_frame

	for shot in range(SHOTS):
		# Place the ball if the rules demand it, exactly as a player would.
		if main.state == main.PLACING:
			main.state = main.AIM

		if main.state == main.OVER:
			print("shot %d: game over, winner %d -- re-racking" % [shot, main.rules.winner])
			main._rack()
			main.state = main.AIM
			await get_tree().process_frame

		if main.state != main.AIM:
			print("shot %d: unexpected state %d" % [shot, main.state])
			break

		main.aim_dir = Vector3(_rng.randf_range(-1.0, 1.0), 0.0,
			_rng.randf_range(-1.0, 1.0)).normalized()
		main.spin = Vector2(_rng.randf_range(-0.45, 0.45), _rng.randf_range(-0.45, 0.45))
		main.elevation = _rng.randf_range(0.0, 0.3)
		main.power = _rng.randf_range(0.25, 1.0)
		main._shoot()

		var frames := 0
		while main.state == main.SHOOTING and frames < 3000:
			await get_tree().process_frame
			frames += 1

		var potted := 0
		for b in main.sim.balls:
			if not b.is_active():
				potted += 1
		print("shot %2d: %4d frames, state=%d, off table=%d, potted=%d, falling=%d, p%d to shoot"
			% [shot, frames, main.state, _off_table(), potted, main.sim.falling.size(),
			main.rules.player + 1])

		# Let any drop finish before the next shot.
		for _i in range(40):
			await get_tree().process_frame

	print("play test complete")
	await get_tree().process_frame
	get_tree().quit()


func _off_table() -> int:
	var n := 0
	for b in main.sim.balls:
		if b.state == PoolBall.OFF_TABLE:
			n += 1
	return n
