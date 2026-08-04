class_name MainMenu
extends Control

## The menu the game opens on, and the one `M` brings back mid-frame.
##
## Built in code like everything else here, so there is no scene file to drift
## out of step with it. It sits over a live table -- the balls are racked and the
## camera drifts round them behind the panel -- rather than over a black screen.

signal start_requested(config: Dictionary)
signal resume_requested()
## Ask the shell to open a listening socket, or to reach one. The menu does not
## own the connection -- it only collects the address and says when to try.
signal host_requested(config: Dictionary, port: int)
signal join_requested(address: String, port: int)
## The host has everyone it is waiting for and wants the frame dealt.
signal begin_requested()

const PANEL_BG := Color(0.055, 0.060, 0.075, 0.96)
const EDGE := Color(1, 1, 1, 0.14)
const TEXT := Color(0.92, 0.93, 0.95)
const DIM := Color(0.62, 0.65, 0.70)
const ACCENT := Color(0.40, 0.72, 1.00)

## Which side of the table the humans are on.
enum { TWO_HUMANS, VS_CPU, CPU_VS_CPU }

const PLAYER_OPTIONS := ["2 players", "you vs CPU", "CPU vs CPU"]
const GAME_OPTIONS := ["UK 8-ball", "Snooker", "Killer"]
const BREAK_OPTIONS := ["player 1", "player 2"]
## Killer only: how many are round the table. Everything else seats two.
const SEAT_OPTIONS := ["3", "4", "5", "6", "7", "8"]
## Killer only: which seats the computer takes. "you and CPUs" fills every seat
## but the first, which is the game most people opening this want.
enum { KILLER_ALL_HUMAN, KILLER_ONE_HUMAN, KILLER_ALL_CPU }
const KILLER_WHO_OPTIONS := ["all human", "you vs CPUs", "all CPU"]

## Where the other players are. "Host" opens a socket others connect to; "join"
## reaches one. Both are direct addresses -- there is no lobby server to find
## anybody for you, so somebody has to say where they are.
enum { NET_LOCAL, NET_HOST, NET_JOIN }
const NET_OPTIONS := ["this table", "host", "join"]
const DEFAULT_ADDRESS := "127.0.0.1"

## Defaults: the thing most people opening this want is a game against the
## computer at a level that will not embarrass them.
var game: int = PoolPhys.GAME_EIGHT_BALL
var players: int = VS_CPU
var level: int = AIPlayer.MEDIUM
var breaker := 0
## Index into SEAT_OPTIONS, so 1 is four players.
var seats := 1
var killer_who: int = KILLER_ONE_HUMAN
var net_mode: int = NET_LOCAL
var address := DEFAULT_ADDRESS
var port := NetGame.DEFAULT_PORT

var _skill_buttons: Array[Button] = []
var _skill_label: Label
var _players_buttons: Array[Button] = []
var _players_label: Label
var _seats_buttons: Array[Button] = []
var _seats_label: Label
var _killer_who_buttons: Array[Button] = []
var _killer_who_label: Label
var _break_buttons: Array[Button] = []
var _break_label: Label
var _net_buttons: Array[Button] = []
var _net_label: Label
var _address_row: HBoxContainer
var _address_edit: LineEdit
var _port_edit: LineEdit
var _start: Button
var _begin: Button
var _lobby: Label
var _resume: Button
var _can_resume := false


func _ready() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	_build()
	_refresh()


## Called by the shell when a frame is already under way, so the menu can offer
## to go back to it instead of only starting a new one.
func set_resumable(value: bool) -> void:
	_can_resume = value
	if _resume != null:
		_resume.visible = value


func config() -> Dictionary:
	if game == PoolPhys.GAME_KILLER:
		return _killer_config()
	var cpu := [false, false]
	match players:
		VS_CPU:
			cpu = [false, true]
		CPU_VS_CPU:
			cpu = [true, true]
	return {
		"game": game,
		"cpu": cpu,
		"level": level,
		"breaker": breaker,
	}


## Killer seats three to eight, so who is human is a per-seat question rather
## than the three fixed pairings the two-player games offer.
func _killer_config() -> Dictionary:
	var n := int(SEAT_OPTIONS[seats])
	var cpu := []
	for i in range(n):
		match killer_who:
			KILLER_ALL_CPU:
				cpu.append(true)
			KILLER_ONE_HUMAN:
				cpu.append(i != 0)
			_:
				cpu.append(false)
	return {
		"game": game,
		"players": n,
		"cpu": cpu,
		"level": level,
		"breaker": 0,
	}


# ---------------------------------------------------------------------------

func _build() -> void:
	var shade := ColorRect.new()
	shade.color = Color(0.0, 0.0, 0.0, 0.55)
	shade.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(shade)

	var centre := CenterContainer.new()
	centre.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	centre.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(centre)

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _panel_style())
	centre.add_child(panel)

	var margin := MarginContainer.new()
	for side in ["left", "right"]:
		margin.add_theme_constant_override("margin_" + side, 40)
	for side in ["top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 32)
	panel.add_child(margin)

	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 14)
	margin.add_child(box)

	box.add_child(_heading("POOL,  SNOOKER  &  KILLER", 30, TEXT))
	box.add_child(_heading(
		"an event-driven cue-sports simulation", 14, DIM))
	box.add_child(_spacer(10))

	var pick_game := func(i: int) -> void:
		game = i
		_refresh()
	var pick_seats := func(i: int) -> void:
		seats = i
		_refresh()
	var pick_killer_who := func(i: int) -> void:
		killer_who = i
		_refresh()
	var pick_players := func(i: int) -> void:
		players = i
		_refresh()
	var pick_level := func(i: int) -> void:
		level = i
	var pick_breaker := func(i: int) -> void:
		breaker = i
	var pick_net := func(i: int) -> void:
		net_mode = i
		_refresh()

	_add_row(box, "GAME", GAME_OPTIONS, game, pick_game)
	_players_label = _row_label("PLAYERS")
	_players_buttons = _add_row(box, "", PLAYER_OPTIONS, players, pick_players,
		_players_label)
	_seats_label = _row_label("KILLERS")
	_seats_buttons = _add_row(box, "", SEAT_OPTIONS, seats, pick_seats,
		_seats_label)
	_killer_who_label = _row_label("WHO")
	_killer_who_buttons = _add_row(box, "", KILLER_WHO_OPTIONS, killer_who,
		pick_killer_who, _killer_who_label)
	_skill_label = _row_label("CPU SKILL")
	_skill_buttons = _add_row(box, "", AIPlayer.LEVEL_NAMES, level, pick_level,
		_skill_label)
	_break_label = _row_label("BREAK")
	_break_buttons = _add_row(box, "", BREAK_OPTIONS, breaker, pick_breaker,
		_break_label)
	_net_label = _row_label("OPPONENTS")
	_net_buttons = _add_row(box, "", NET_OPTIONS, net_mode, pick_net, _net_label)
	_build_address_row(box)

	_lobby = _heading("", 13, ACCENT)
	box.add_child(_lobby)

	box.add_child(_spacer(12))

	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 10)
	buttons.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_child(buttons)

	_start = Button.new()
	_start.text = "START"
	_start.custom_minimum_size = Vector2(180, 44)
	_style_button(_start, true)
	_start.pressed.connect(_on_start)
	buttons.add_child(_start)

	# Only the host sees this, and only once it is listening: it is the moment
	# the frame is dealt, so it is deliberately a separate press from "host".
	_begin = Button.new()
	_begin.text = "START FRAME"
	_begin.custom_minimum_size = Vector2(160, 44)
	_style_button(_begin)
	_begin.visible = false
	_begin.pressed.connect(func() -> void: emit_signal("begin_requested"))
	buttons.add_child(_begin)

	_resume = Button.new()
	_resume.text = "RESUME"
	_resume.custom_minimum_size = Vector2(140, 44)
	_style_button(_resume)
	_resume.visible = false
	_resume.pressed.connect(func() -> void: emit_signal("resume_requested"))
	buttons.add_child(_resume)

	box.add_child(_spacer(6))
	box.add_child(_heading(
		"H in game for the controls        M reopens this menu", 12, DIM))

	_start.grab_focus()


## Address and port, as text. Typed rather than discovered: there is no lobby
## server here, so joining means somebody telling you where they are.
func _build_address_row(parent: VBoxContainer) -> void:
	_address_row = HBoxContainer.new()
	_address_row.add_theme_constant_override("separation", 6)
	_address_row.add_child(_row_label("ADDRESS"))

	_address_edit = LineEdit.new()
	_address_edit.text = address
	_address_edit.placeholder_text = "host address"
	_address_edit.custom_minimum_size = Vector2(220, 34)
	_address_edit.add_theme_font_size_override("font_size", 14)
	_address_edit.text_changed.connect(func(t: String) -> void: address = t)
	_address_row.add_child(_address_edit)

	_port_edit = LineEdit.new()
	_port_edit.text = str(port)
	_port_edit.placeholder_text = "port"
	_port_edit.custom_minimum_size = Vector2(90, 34)
	_port_edit.add_theme_font_size_override("font_size", 14)
	_port_edit.text_changed.connect(func(t: String) -> void:
		port = int(t) if t.is_valid_int() else NetGame.DEFAULT_PORT)
	_address_row.add_child(_port_edit)

	parent.add_child(_address_row)


func _on_start() -> void:
	match net_mode:
		NET_HOST:
			emit_signal("host_requested", config(), port)
		NET_JOIN:
			emit_signal("join_requested", address, port)
		_:
			emit_signal("start_requested", config())


## Called by the shell as peers come and go, so the lobby line says who is here.
func set_lobby(text: String, can_begin: bool) -> void:
	if _lobby != null:
		_lobby.text = text
	if _begin != null:
		_begin.visible = can_begin


func _panel_style() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = PANEL_BG
	sb.border_color = EDGE
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(6)
	return sb


## Named `font_size` rather than `size`, which is a Control property this would
## otherwise shadow.
func _heading(text: String, font_size: int, col: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_color_override("font_color", col)
	return l


func _spacer(h: int) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0, h)
	return c


func _row_label(text: String) -> Label:
	var l := Label.new()
	l.text = text
	l.custom_minimum_size = Vector2(118, 0)
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.add_theme_font_size_override("font_size", 13)
	l.add_theme_color_override("font_color", DIM)
	return l


## One labelled row of mutually exclusive choices. `existing_label` lets a caller
## keep hold of the label so it can be dimmed when the row does not apply.
func _add_row(parent: VBoxContainer, label: String, options: Array, initial: int,
		on_pick: Callable, existing_label: Label = null) -> Array[Button]:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	row.add_child(existing_label if existing_label != null else _row_label(label))

	var group := ButtonGroup.new()
	var made: Array[Button] = []
	for i in range(options.size()):
		var b := Button.new()
		b.text = str(options[i])
		b.toggle_mode = true
		b.button_group = group
		b.button_pressed = i == initial
		b.custom_minimum_size = Vector2(104, 34)
		_style_button(b)
		var idx := i
		b.pressed.connect(func() -> void: on_pick.call(idx))
		row.add_child(b)
		made.append(b)
	parent.add_child(row)
	return made


func _style_button(b: Button, primary := false) -> void:
	b.add_theme_font_size_override("font_size", 14)
	b.add_theme_color_override("font_color", DIM)
	b.add_theme_color_override("font_hover_color", TEXT)
	b.add_theme_color_override("font_pressed_color", Color(0.06, 0.08, 0.11))
	b.add_theme_color_override("font_focus_color", TEXT)
	b.add_theme_color_override("font_disabled_color", Color(0.35, 0.37, 0.41))
	b.add_theme_stylebox_override("normal", _button_style(
		Color(0.10, 0.11, 0.14, 0.9), EDGE))
	b.add_theme_stylebox_override("hover", _button_style(
		Color(0.16, 0.18, 0.23, 0.95), Color(1, 1, 1, 0.25)))
	b.add_theme_stylebox_override("focus", _button_style(
		Color(0.14, 0.16, 0.20, 0.95), ACCENT))
	b.add_theme_stylebox_override("disabled", _button_style(
		Color(0.08, 0.09, 0.11, 0.7), Color(1, 1, 1, 0.06)))
	# A toggled-on segment and the primary action share a look: this is the one
	# thing on the row that is true.
	var on := _button_style(ACCENT if primary else Color(0.30, 0.56, 0.82, 0.95),
		Color(1, 1, 1, 0.30))
	b.add_theme_stylebox_override("pressed", on)
	if primary:
		b.add_theme_stylebox_override("normal", _button_style(
			Color(0.22, 0.44, 0.68, 0.95), Color(1, 1, 1, 0.22)))
		b.add_theme_stylebox_override("hover", _button_style(
			ACCENT, Color(1, 1, 1, 0.35)))
		b.add_theme_color_override("font_color", TEXT)


func _button_style(bg: Color, border: Color) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = border
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(4)
	sb.content_margin_left = 10
	sb.content_margin_right = 10
	return sb


## Show only the rows the chosen game actually has, and grey out the skill row
## when no computer is playing. Killer asks how many are round the table and who
## among them is human; the two-player games ask neither, and killer has no
## "who breaks" because seat one always does.
func _refresh() -> void:
	var is_killer := game == PoolPhys.GAME_KILLER
	# Joining settles nothing: the host picks the game, the seats and who is a
	# computer, so showing those choices to a joiner would only be a lie.
	var joining := net_mode == NET_JOIN
	_show_row(_players_label, _players_buttons, not is_killer and not joining)
	_show_row(_break_label, _break_buttons, not is_killer and not joining)
	_show_row(_seats_label, _seats_buttons, is_killer and not joining)
	_show_row(_killer_who_label, _killer_who_buttons, is_killer and not joining)
	if _address_row != null:
		_address_row.visible = net_mode != NET_LOCAL
	if _address_edit != null:
		# The host does not type an address, only the port it listens on.
		_address_edit.visible = joining
	if _start != null:
		_start.text = ["START", "HOST", "JOIN"][net_mode]
	if _begin != null and net_mode != NET_HOST:
		_begin.visible = false
	if _lobby != null and net_mode == NET_LOCAL:
		_lobby.text = ""

	var cpu_playing := not joining and ((killer_who != KILLER_ALL_HUMAN) \
		if is_killer else (players != TWO_HUMANS))
	for b in _skill_buttons:
		b.disabled = not cpu_playing
	if _skill_label != null:
		_skill_label.add_theme_color_override("font_color",
			DIM if cpu_playing else Color(0.35, 0.37, 0.41))


## Rows are a single HBoxContainer holding the label and its buttons, so hiding
## the label's parent hides the whole row.
func _show_row(label: Label, _buttons: Array[Button], shown: bool) -> void:
	if label != null and label.get_parent() != null:
		(label.get_parent() as Control).visible = shown


## Enter starts. Escape and M go back to the frame, when there is one to go back
## to -- the keys the game shell hands on rather than swallowing.
func handle_key(keycode: Key) -> bool:
	match keycode:
		KEY_ENTER, KEY_KP_ENTER:
			_on_start()
			return true
		KEY_ESCAPE, KEY_M:
			if _can_resume:
				emit_signal("resume_requested")
				return true
	return false
