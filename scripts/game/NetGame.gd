class_name NetGame
extends Node

## Two or more machines playing the same frame, over a LAN or a direct address.
##
## The whole design rests on one property the simulator already had: a shot is a
## pure function of the table and the stroke. `PhysicsTests` proves it -- the same
## break replays exactly, and a 1 ms caller and a 50 ms caller agree to a
## thirtieth of a millimetre after three cushions. So nothing sends ball
## positions. A peer sends the *stroke* -- aim, speed, spin, elevation and the
## seed for its miscue -- and every machine plays it out and arrives at the same
## table.
##
## That is a few dozen bytes a turn, there is no interpolation, no rollback and
## no authoritative physics, and a mid-shot packet loss cannot desync anything
## because there are no mid-shot packets. What it costs is strictness: every
## source of randomness a shot touches has to be seeded and sent, which is why
## `PoolSim.rng` exists and why racks carry a seed.
##
## Seats, not peers, are what the rules engines know about. A seat is owned by
## exactly one machine; whoever owns the seat whose turn it is decides the stroke
## and broadcasts it. Seats nobody has joined are computer players, and the host
## owns those -- the CPU is *not* deterministic across machines (it is timed in
## milliseconds and has its own generator), so it has to be run in one place and
## its stroke sent like anyone else's.

signal peers_changed()
signal match_started(config: Dictionary)
signal placement_received(seat: int, x: float, z: float)
signal stroke_received(seat: int, stroke: Dictionary)
signal net_message(text: String)
signal disconnected()
## The router has been asked to forward the port, and has answered one way or the
## other. Carries the address to hand out, empty if there is nothing to hand out.
signal upnp_changed(state: int, address: String)

const DEFAULT_PORT := 27015
## Godot's own limit on an ENet peer count here is far higher; this is the seat
## limit, which is what actually constrains a game.
const MAX_PEERS := 8

enum { OFF, HOSTING, JOINING, CONNECTED }

## What the router has to say about forwarding the port.
##
## UPNP_UNTRIED is also where a host that turned it off stays. UPNP_REFUSED
## covers everything from "no gateway on this network" to "the gateway has UPnP
## switched off", because none of them are distinguishable to a player and all of
## them mean the same thing: the port is not open from outside, so anyone beyond
## the LAN will need it forwarded by hand.
enum { UPNP_UNTRIED, UPNP_SEARCHING, UPNP_MAPPED, UPNP_REFUSED }

var status := OFF
var upnp_status := UPNP_UNTRIED
## The address to give people outside the LAN. Only set once UPNP_MAPPED.
var external_address := ""
var upnp_error := ""
## seat -> peer id. 1 is the host. 0 means the seat has nobody in it, and is
## therefore the host's computer player.
var seat_peer: Array[int] = []
var seats := 2
var last_error := ""

var _peer: ENetMultiplayerPeer
var _upnp_thread: Thread
var _mapped_port := 0


func is_active() -> bool:
	return status != OFF


func is_host() -> bool:
	return status == HOSTING


## Which seat this machine plays. -1 when it has none yet.
func my_seat() -> int:
	var id := multiplayer.get_unique_id() if is_active() else 0
	for s in range(seat_peer.size()):
		if seat_peer[s] == id:
			return s
	return -1


## True when this machine is the one that decides `seat`'s stroke: its own seat,
## or -- on the host -- any seat nobody has joined, which the computer plays.
func controls(seat: int) -> bool:
	if not is_active():
		return true
	if seat < 0 or seat >= seat_peer.size():
		return false
	if seat_peer[seat] == multiplayer.get_unique_id():
		return true
	return is_host() and seat_peer[seat] == 0


## Is `seat` a computer player? Only meaningful once a match has started.
func is_cpu_seat(seat: int) -> bool:
	if not is_active():
		return false
	return seat >= 0 and seat < seat_peer.size() and seat_peer[seat] == 0


func humans_connected() -> int:
	var n := 0
	for p in seat_peer:
		if p != 0:
			n += 1
	return n


# ---------------------------------------------------------------------------
# connecting
# ---------------------------------------------------------------------------

func host(port := DEFAULT_PORT, p_seats := 2, upnp := true) -> bool:
	close()
	seats = clampi(p_seats, 2, MAX_PEERS)
	_peer = ENetMultiplayerPeer.new()
	var err := _peer.create_server(port, MAX_PEERS)
	if err != OK:
		last_error = "could not listen on port %d (%s)" % [port, error_string(err)]
		_peer = null
		return false
	multiplayer.multiplayer_peer = _peer
	_connect_signals()
	status = HOSTING
	# The host always takes seat one; the rest fill as people join.
	seat_peer.clear()
	for i in range(seats):
		seat_peer.append(0)
	seat_peer[0] = multiplayer.get_unique_id()
	emit_signal("peers_changed")
	emit_signal("net_message", "hosting on port %d" % port)
	if upnp:
		_open_port(port)
	return true


# ---------------------------------------------------------------------------
# UPnP
# ---------------------------------------------------------------------------
#
# Hosting works on a LAN with no help. From anywhere else it does not: the
# host is behind a router doing NAT, and an unsolicited packet arriving at the
# router has nothing telling it which machine inside wants it, so it is dropped.
# Asking the router over UPnP to forward the port is what turns "everyone has to
# be in the same building" into "send them your address".
#
# It is a courtesy, never a requirement. Plenty of networks have no gateway that
# answers, have UPnP deliberately switched off, or put the player behind carrier
# NAT where no amount of asking the local router helps. All of those come back as
# UPNP_REFUSED and hosting carries on regardless -- the LAN game is unaffected,
# and the player is told what they would have to forward by hand.


## ENet is UDP, so that is the only protocol worth mapping.
const UPNP_PROTO := "UDP"
const UPNP_DESC := "Realistic Pool"


## Ask the router to forward `port`, on a thread.
##
## Threaded because UPNP.discover() broadcasts and then waits for gateways to
## answer, which takes a couple of seconds it is not willing to be interrupted
## during. On the main thread that is a couple of seconds of frozen menu every
## time somebody presses "host".
func _open_port(port: int) -> void:
	_join_upnp_thread()
	upnp_status = UPNP_SEARCHING
	external_address = ""
	upnp_error = ""
	emit_signal("upnp_changed", upnp_status, "")
	emit_signal("net_message", "asking the router to forward port %d" % port)
	_upnp_thread = Thread.new()
	_upnp_thread.start(_upnp_worker.bind(port))


## Runs off the main thread: nothing here may touch the scene tree, so results go
## back through call_deferred.
func _upnp_worker(port: int) -> void:
	var upnp := UPNP.new()
	var found := upnp.discover()
	if found != UPNP.UPNP_RESULT_SUCCESS:
		_upnp_done.call_deferred(false, "", "no router answered (%d)" % found, port)
		return
	var gateway := upnp.get_gateway()
	if gateway == null or not gateway.is_valid_gateway():
		_upnp_done.call_deferred(false, "", "no gateway that forwards ports", port)
		return
	var mapped := upnp.add_port_mapping(port, port, UPNP_DESC, UPNP_PROTO, 0)
	if mapped != UPNP.UPNP_RESULT_SUCCESS:
		# Most likely a mapping left behind by a run that did not shut down
		# cleanly, which the router sees as a conflict. Clear it and try once
		# more. Only on this path: deleting a mapping that was never there logs a
		# router error of its own, and doing that on every successful host would
		# put a red herring in the console every time.
		upnp.delete_port_mapping(port, UPNP_PROTO)
		mapped = upnp.add_port_mapping(port, port, UPNP_DESC, UPNP_PROTO, 0)
	if mapped != UPNP.UPNP_RESULT_SUCCESS:
		_upnp_done.call_deferred(false, "", "the router refused to forward it (%d)"
			% mapped, port)
		return
	_upnp_done.call_deferred(true, upnp.query_external_address(), "", port)


## Back on the main thread, with whatever the router said.
func _upnp_done(ok: bool, address: String, err: String, port: int) -> void:
	# The player may have backed out of hosting while the router was thinking.
	if status != HOSTING:
		if ok:
			_mapped_port = port
			_close_port()
		return
	if not ok:
		upnp_status = UPNP_REFUSED
		upnp_error = err
		emit_signal("upnp_changed", upnp_status, "")
		emit_signal("net_message",
			"%s -- players outside this network need UDP %d forwarded to this machine"
			% [err, port])
		return
	_mapped_port = port
	upnp_status = UPNP_MAPPED
	external_address = address
	emit_signal("upnp_changed", upnp_status, address)
	emit_signal("net_message", "port forwarded -- others can join at %s:%d"
		% [address, port])


## Hand the port back. A mapping added with no lease outlives the process, so
## leaving without doing this quietly leaves a hole in the player's router.
func _close_port() -> void:
	if _mapped_port == 0:
		return
	var port := _mapped_port
	_mapped_port = 0
	_join_upnp_thread()
	_upnp_thread = Thread.new()
	_upnp_thread.start(func() -> void:
		var upnp := UPNP.new()
		if upnp.discover() != UPNP.UPNP_RESULT_SUCCESS:
			return
		var gateway := upnp.get_gateway()
		if gateway != null and gateway.is_valid_gateway():
			upnp.delete_port_mapping(port, UPNP_PROTO))


func _join_upnp_thread() -> void:
	if _upnp_thread != null:
		if _upnp_thread.is_started():
			_upnp_thread.wait_to_finish()
		_upnp_thread = null


## The port has to be given back even when the game is being torn down, and by
## then close() may already have run or never run at all.
func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE or what == NOTIFICATION_WM_CLOSE_REQUEST:
		_close_port()
		_join_upnp_thread()


func join(address: String, port := DEFAULT_PORT) -> bool:
	close()
	_peer = ENetMultiplayerPeer.new()
	var err := _peer.create_client(address, port)
	if err != OK:
		last_error = "could not reach %s:%d (%s)" % [address, port,
			error_string(err)]
		_peer = null
		return false
	multiplayer.multiplayer_peer = _peer
	_connect_signals()
	status = JOINING
	emit_signal("net_message", "connecting to %s:%d" % [address, port])
	return true


func close() -> void:
	_close_port()
	if _peer != null:
		_peer.close()
	_peer = null
	if multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer = null
	_disconnect_signals()
	status = OFF
	seat_peer.clear()
	upnp_status = UPNP_UNTRIED
	external_address = ""
	upnp_error = ""


func _connect_signals() -> void:
	if not multiplayer.peer_connected.is_connected(_on_peer_connected):
		multiplayer.peer_connected.connect(_on_peer_connected)
		multiplayer.peer_disconnected.connect(_on_peer_disconnected)
		multiplayer.connected_to_server.connect(_on_connected)
		multiplayer.connection_failed.connect(_on_connect_failed)
		multiplayer.server_disconnected.connect(_on_server_gone)


func _disconnect_signals() -> void:
	if multiplayer.peer_connected.is_connected(_on_peer_connected):
		multiplayer.peer_connected.disconnect(_on_peer_connected)
		multiplayer.peer_disconnected.disconnect(_on_peer_disconnected)
		multiplayer.connected_to_server.disconnect(_on_connected)
		multiplayer.connection_failed.disconnect(_on_connect_failed)
		multiplayer.server_disconnected.disconnect(_on_server_gone)


func _on_peer_connected(id: int) -> void:
	if not is_host():
		return
	# First free seat, so joining order is seating order.
	for s in range(seat_peer.size()):
		if seat_peer[s] == 0:
			seat_peer[s] = id
			break
	_rpc_seats.rpc(seat_peer)
	emit_signal("peers_changed")
	emit_signal("net_message", "a player joined")


func _on_peer_disconnected(id: int) -> void:
	if not is_host():
		return
	# Their seat reverts to the computer, so the frame can be played out rather
	# than abandoned. A frame that stops dead because somebody closed a laptop is
	# a worse outcome than one finished against the machine.
	for s in range(seat_peer.size()):
		if seat_peer[s] == id:
			seat_peer[s] = 0
			emit_signal("net_message", "player in seat %d left -- CPU takes over"
				% (s + 1))
	_rpc_seats.rpc(seat_peer)
	emit_signal("peers_changed")


func _on_connected() -> void:
	status = CONNECTED
	emit_signal("net_message", "connected")
	emit_signal("peers_changed")


func _on_connect_failed() -> void:
	last_error = "connection refused"
	close()
	emit_signal("net_message", "could not connect")
	emit_signal("disconnected")


func _on_server_gone() -> void:
	close()
	emit_signal("net_message", "host disconnected")
	emit_signal("disconnected")


# ---------------------------------------------------------------------------
# the wire
# ---------------------------------------------------------------------------

## The host owns the seating chart; everyone else is told it.
@rpc("authority", "call_remote", "reliable")
func _rpc_seats(chart: Array) -> void:
	seat_peer.clear()
	for v in chart:
		seat_peer.append(int(v))
	seats = seat_peer.size()
	emit_signal("peers_changed")


## Start the frame everyone is about to play. Carries the rack seed, because a
## pool rack is shuffled and both machines have to shuffle it the same way.
func start_match(config: Dictionary) -> void:
	if not is_host():
		return
	_rpc_start.rpc(config)
	_rpc_start(config)


@rpc("authority", "call_remote", "reliable")
func _rpc_start(config: Dictionary) -> void:
	emit_signal("match_started", config)


func send_placement(seat: int, x: float, z: float) -> void:
	if not is_active():
		return
	_rpc_place.rpc(seat, x, z)


@rpc("any_peer", "call_remote", "reliable")
func _rpc_place(seat: int, x: float, z: float) -> void:
	if not _sender_owns(seat):
		return
	emit_signal("placement_received", seat, x, z)


func send_stroke(seat: int, stroke: Dictionary) -> void:
	if not is_active():
		return
	_rpc_stroke.rpc(seat, stroke)


@rpc("any_peer", "call_remote", "reliable")
func _rpc_stroke(seat: int, stroke: Dictionary) -> void:
	if not _sender_owns(seat):
		return
	emit_signal("stroke_received", seat, stroke)


## A peer may only play the seat it holds -- or, if it is the host, a seat the
## computer is playing. Without this any peer could stroke on anyone's turn.
func _sender_owns(seat: int) -> bool:
	var from := multiplayer.get_remote_sender_id()
	if seat < 0 or seat >= seat_peer.size():
		return false
	if seat_peer[seat] == from:
		return true
	# Seat is a CPU: only the host runs those.
	return seat_peer[seat] == 0 and from == 1
