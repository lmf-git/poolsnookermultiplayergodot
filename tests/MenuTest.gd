extends Node

## Checks the start menu: that the game opens on it, that what it is showing is
## what it starts, and that the keys it owns do what they say.
##
##     /Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
##         res://tests/MenuTest.tscn
##
## The menu is the one part of the game a headless test can reach but a person
## cannot check at a glance, so it is worth pinning down: a menu that quietly
## starts the wrong game is not obvious until several shots in.

var main: Node
var _passed := 0
var _failed := 0


func check(what: String, ok: bool, detail := "") -> void:
	if ok:
		_passed += 1
		print("  PASS  %s%s" % [what, "   " + detail if detail != "" else ""])
	else:
		_failed += 1
		print("  FAIL  %s%s" % [what, "   " + detail if detail != "" else ""])


func _ready() -> void:
	main = load("res://scenes/Main.tscn").instantiate()
	add_child(main)
	await get_tree().process_frame
	await get_tree().process_frame

	check("the game opens on the menu", main.menu_open)
	check("the pointer is free while the menu is up",
		Input.mouse_mode == Input.MOUSE_MODE_VISIBLE)
	check("a table is racked behind it", main.sim != null and main.sim.balls.size() == 16,
		"%d balls" % main.sim.balls.size())
	check("nothing to resume before a game has started",
		not main.menu._resume.visible)

	# Everything the menu can be set to, started, and read back off the game.
	main.menu.game = PoolPhys.GAME_SNOOKER
	main.menu.players = MainMenu.VS_CPU
	main.menu.level = AIPlayer.PRO
	main.menu.breaker = 1
	main.start_match(main.menu.config())
	await get_tree().process_frame

	check("it starts the game that was showing", main.game_mode == PoolPhys.SNOOKER)
	check("with the snooker rules", main.rules is RulesSnooker)
	check("and the snooker balls", main.sim.balls.size() == 22,
		"%d balls" % main.sim.balls.size())
	check("player 2 is the computer", main.cpu == [false, true])
	check("at the level asked for", main.cpu_level == AIPlayer.PRO)
	check("player 2 breaks", main.rules.player == 1)
	check("so it is the computer's turn", main.state == main.CPU)
	check("the menu is out of the way", not main.menu_open and not main.menu.visible)

	# Let the computer break, to be sure a menu-started game actually plays.
	var frames := 0
	while main.state == main.CPU and frames < 1200:
		await get_tree().process_frame
		frames += 1
	check("the computer played its break", main.state != main.CPU,
		"after %d frames" % frames)

	while main.state == main.SHOOTING and frames < 6000:
		await get_tree().process_frame
		frames += 1

	# Reopening mid-frame offers to go back to it.
	main._open_menu(true)
	await get_tree().process_frame
	check("reopening offers to resume", main.menu._resume.visible)
	check("escape resumes rather than restarting",
		main.menu.handle_key(KEY_ESCAPE) and not main.menu_open)

	# And a two-player game really has no computer in it.
	main.menu.game = PoolPhys.GAME_EIGHT_BALL
	main.menu.players = MainMenu.TWO_HUMANS
	main.start_match(main.menu.config())
	await get_tree().process_frame
	check("two players means no computer", main.cpu == [false, false])
	check("with the UK pool rules", main.rules is RulesUKPool)
	check("and a human to place the cue ball", main.state == main.PLACING)
	check("in hand in the D for the break", main.rules.in_hand_in_d())

	print("\n%d passed, %d failed" % [_passed, _failed])
	get_tree().quit(1 if _failed > 0 else 0)
