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

const DEFAULT_PORT := 27015
## Godot's own limit on an ENet peer count here is far higher; this is the seat
## limit, which is what actually constrains a game.
const MAX_PEERS := 8

enum { OFF, HOSTING, JOINING, CONNECTED }

var status := OFF
## seat -> peer id. 1 is the host. 0 means the seat has nobody in it, and is
## therefore the host's computer player.
var seat_peer: Array[int] = []
var seats := 2
var last_error := ""

var _peer: ENetMultiplayerPeer


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

func host(port := DEFAULT_PORT, p_seats := 2) -> bool:
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
	return true


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
	if _peer != null:
		_peer.close()
	_peer = null
	if multiplayer.multiplayer_peer != null:
		multiplayer.multiplayer_peer = null
	_disconnect_signals()
	status = OFF
	seat_peer.clear()


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
