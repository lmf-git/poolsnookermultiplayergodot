extends Node

## Plays a killer frame through the real game scene, headlessly.
##
##     /Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
##         res://tests/KillerMatch.tscn -- [players] [level]
##
## The rules are checked in RulesKillerTest; what this checks is the shell around
## them -- that a game with more than two seats racks, plans, strokes, eliminates
## and finishes without the two-player assumptions elsewhere tripping over it.

var main: Node
var _last := ""


func _on_message(text: String, _kind: String) -> void:
	_last = text


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var seats: int = int(args[0]) if args.size() > 0 else 4
	var level: int = int(args[1]) if args.size() > 1 else AIPlayer.MEDIUM

	main = load("res://scenes/Main.tscn").instantiate()
	main.start_in_menu = false
	add_child(main)
	await get_tree().process_frame

	var cpu := []
	for _i in range(seats):
		cpu.append(true)
	main.start_match({
		"game": PoolPhys.GAME_KILLER, "players": seats, "cpu": cpu,
		"level": level, "breaker": 0,
	})
	await get_tree().process_frame
	main.rules.message.connect(_on_message)

	print("=== killer: %d players, level %s ===" % [seats,
		AIPlayer.LEVEL_NAMES[level]])
	var shots := 0
	var guard := 0
	while not main.rules.game_over and shots < 60 and guard < 40000:
		var before: int = main.rules.player
		var alive_before: int = main.rules.alive_count()
		while main.state != main.OVER and main.rules.player == before \
				and main.rules.alive_count() == alive_before and guard < 40000:
			await get_tree().process_frame
			guard += 1
		shots += 1
		print("  shot %2d  player %d  alive %d  %s"
			% [shots, before + 1, main.rules.alive_count(), _last])
		_last = ""

	print("-> %d shots, winner: %s" % [shots,
		("player %d" % (main.rules.winner + 1)) if main.rules.winner >= 0
			else "unfinished"])
	if guard >= 40000:
		print("!! gave up waiting")
	get_tree().quit(0 if main.rules.game_over else 1)
