extends Node

## Does hosting actually get the port opened on this network?
##
##     /Applications/Godot.app/Contents/MacOS/Godot --headless --path . \
##         res://tests/NetUpnp.tscn
##
## Talks to the real router, so what it proves depends on the network it is run
## on: a refusal is a legitimate result, not a failure. What it does check is
## that hosting is never blocked or delayed by the attempt, that an answer always
## arrives, and that the mapping is handed back on close.

var _net: NetGame
var _answered := false


func _ready() -> void:
	_net = NetGame.new()
	add_child(_net)

	# The address anyone in the same building has to use. Printed first because
	# it is the one that gets forgotten: a host that hands out only its forwarded
	# address is joinable from the internet and not from the next room, since
	# routers are under no obligation to send a packet back in the way it came.
	var lan := NetGame.local_address()
	print("local address for this network: %s:%d" % [lan, NetGame.DEFAULT_PORT])
	if lan == "":
		print("FAIL  no usable local address found -- nobody on this network can join")
		get_tree().quit(1)
		return

	_net.net_message.connect(func(t: String) -> void: print("  net: ", t))
	_net.upnp_changed.connect(_on_upnp)

	var t0 := Time.get_ticks_msec()
	var ok := _net.host(NetGame.DEFAULT_PORT, 2)
	var took := Time.get_ticks_msec() - t0
	print("host() -> %s in %d ms (status %d)" % [ok, took, _net.upnp_status])
	if not ok:
		print("FAIL  could not listen at all: ", _net.last_error)
		get_tree().quit(1)
		return
	if took > 250:
		print("FAIL  host() blocked for %d ms -- discovery is not off the main thread"
			% took)
		get_tree().quit(1)
		return
	if _net.upnp_status != NetGame.UPNP_SEARCHING:
		print("FAIL  expected UPNP_SEARCHING right after host(), got ", _net.upnp_status)
		get_tree().quit(1)
		return

	# The menu has to stay live while the router thinks. Keep ticking.
	var waited := 0.0
	while not _answered and waited < 20.0:
		await get_tree().process_frame
		waited += get_process_delta_time()
	if not _answered:
		print("FAIL  no answer after %.0f s" % waited)
		get_tree().quit(1)
		return

	print("answered after %.1f s" % waited)
	_net.close()
	print("closed; upnp_status back to %d" % _net.upnp_status)
	if _net.upnp_status != NetGame.UPNP_UNTRIED:
		print("FAIL  close() left upnp state behind")
		get_tree().quit(1)
		return
	# Give the release thread a moment so the mapping is gone before we exit.
	await get_tree().create_timer(3.0).timeout
	print("\nPASS  hosting is never blocked, an answer always arrives, "
		+ "and the mapping is released")
	get_tree().quit(0)


func _on_upnp(state: int, address: String) -> void:
	_answered = state == NetGame.UPNP_MAPPED or state == NetGame.UPNP_REFUSED
	match state:
		NetGame.UPNP_SEARCHING:
			print("  upnp: searching")
		NetGame.UPNP_MAPPED:
			print("  upnp: MAPPED, external address %s" % address)
		NetGame.UPNP_REFUSED:
			print("  upnp: refused -- %s" % _net.upnp_error)
