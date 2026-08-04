extends Node

## Plays complete CPU-versus-CPU frames through the real game scene, headlessly.
##
##     /Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
##         res://tests/CpuMatch.tscn -- [pool|snooker] [level] [frames] [shot cap]
##
## This is the harness the computer player is actually judged by. A CPU that
## crashes, stalls, or fouls its way through a frame shows up here rather than in
## front of a player, and the per-shot log is what the difficulty levels were
## tuned against: fouls should be rare at Pro and common at Easy, and the time
## spent planning should stay inside a frame's budget.

## A snooker frame runs to well over a hundred visits, so the cap is an argument:
## a short run is for checking the CPU plays at all, a long one for watching how
## it plays.
var max_shots := 220

var main: Node
var _plan_ms_total := 0.0
var _plan_frames := 0
var _last_message := ""


func _on_message(text: String, kind: String) -> void:
	_last_message = "%s|%s" % [kind, text]


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var mode: int = PoolPhys.SNOOKER if args.size() > 0 and args[0] == "snooker" \
		else PoolPhys.POOL
	var level: int = int(args[1]) if args.size() > 1 else AIPlayer.HARD
	var frames: int = int(args[2]) if args.size() > 2 else 1
	if args.size() > 3:
		max_shots = int(args[3])

	main = load("res://scenes/Main.tscn").instantiate()
	main.start_in_menu = false
	add_child(main)
	await get_tree().process_frame

	for frame in range(frames):
		await _play_frame(mode, level, frame)

	print("\nplanning: %.1f ms per thinking frame over %d frames"
		% [_plan_ms_total / maxf(float(_plan_frames), 1.0), _plan_frames])
	print("cpu match complete")
	get_tree().quit()


func _play_frame(mode: int, level: int, index: int) -> void:
	main.start_match({
		"game": mode, "cpu": [true, true], "level": level, "breaker": index % 2,
	})
	await get_tree().process_frame
	print("\n=== frame %d: %s, level %s ===" % [index + 1,
		"snooker" if mode == PoolPhys.SNOOKER else "UK pool",
		AIPlayer.LEVEL_NAMES[level]])

	var shots := 0
	var fouls := 0
	var pots := 0
	# Straight off the rules engine's own commentary, which is the same thing the
	# player sees on the HUD.
	_last_message = ""
	main.rules.message.connect(_on_message)

	while shots < max_shots and main.state != main.OVER:
		var before := _potted_count()
		var think_start := Time.get_ticks_usec()
		var frames_thinking := 0
		# Let the CPU plan, line up and stroke.
		while main.state == main.CPU:
			await get_tree().process_frame
			frames_thinking += 1
			if frames_thinking > 900:
				push_error("CPU never played a shot")
				return
		if main.state == main.OVER:
			break
		_plan_ms_total += float(Time.get_ticks_usec() - think_start) / 1000.0
		_plan_frames += maxi(frames_thinking, 1)

		var settle := 0
		while main.state == main.SHOOTING and settle < 4000:
			await get_tree().process_frame
			settle += 1
		for _i in range(30):
			await get_tree().process_frame

		shots += 1
		var gained := _potted_count() - before
		pots += maxi(gained, 0)
		if _last_message.begins_with("bad"):
			fouls += 1
		print("  shot %3d  p%d  potted %d  %s"
			% [shots, main.rules.player + 1, gained, _last_message])
		_last_message = ""

		if main.state != main.CPU and main.state != main.OVER:
			# A human seat should never come up in a CPU-versus-CPU frame.
			push_error("unexpected state %d with player %d"
				% [main.state, main.rules.player])
			return

	var result := "player %d" % (main.rules.winner + 1) if main.state == main.OVER \
		else "unfinished"
	print("  -> %d shots, %d balls potted, %d fouls, winner: %s"
		% [shots, pots, fouls, result])


func _potted_count() -> int:
	var n := 0
	for b in main.sim.balls:
		if not b.is_active():
			n += 1
	return n
