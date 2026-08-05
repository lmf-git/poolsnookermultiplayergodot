class_name HUD
extends Control

## All 2D overlay drawing: power meter, the tip-offset target that shows where
## the cue will strike the ball, elevation readout, whose turn it is, what each
## player owns -- a group, a score or the lives they have left, depending on the
## game -- and the balls already down.

const PANEL := Color(0.055, 0.060, 0.075, 0.82)
const EDGE := Color(1, 1, 1, 0.13)
const TEXT := Color(0.92, 0.93, 0.95)
const DIM := Color(0.62, 0.65, 0.70)
const GOOD := Color(0.42, 0.83, 0.50)
const BAD := Color(0.94, 0.44, 0.40)
const ACCENT := Color(0.40, 0.72, 1.00)

# Driven by Main every frame.
var power := 0.0                 # 0..1
var charging := false
var spin := Vector2.ZERO         # tip offset in units of ball radius
var elevation := 0.0             # radians, as actually applied to the strike
var elevation_forced := false    # true when a rail is what is raising the butt
var turn := 0
var groups := [RulesUKPool.OPEN, RulesUKPool.OPEN]
var table_open := true
var ball_in_hand := false
## True when the ball in hand has to go in the D rather than anywhere.
var in_d := false
## UK pool: visits the striker has left. Two means a foul is being paid for.
var visits := 1
var placing := false
## The player has no controls right now -- the balls are rolling, or it is the
## computer's turn. The power meter and tip target are theirs, so they go away.
var hide_controls := false
## Which players are the computer, and how good it is set to be.
var cpu := [false, false]
var cpu_name := ""
var thinking := false
var slow_motion := false
var potted: Array[int] = []
var show_help := false
var winner := -1
var pointer_locked := true
var hop := 0.0                   # predicted height off the cloth, metres
var ball_diameter := 0.05715
# Snooker only.
var snooker := false
var score := [0, 0]
var break_score := 0
var required := ""
# Killer only.
var killer := false
## Seats at the table. Only killer ever seats more than two.
var players := 2
## Lives remaining per player; zero is eliminated.
var lives: Array[int] = []

## Who is at the table. Announced on every hand-over, because "whose go is it?"
## is the one question a player should never have to hunt for.
var watching := ""
## ...and whether this machine can do anything about it. Waiting on the computer
## or on somebody at the other end of a connection leaves the notice up for the
## whole visit; a hot seat passing between two people at one keyboard does not,
## since the person it is passing to is sitting right there and can play.
var waiting := false
var _watch := ""
var _watch_time := 0.0

## How long the hand-over is announced in the middle of the screen before it
## shrinks to something that can be watched past.
const ANNOUNCE_HOLD := 2.0
const ANNOUNCE_FADE := 0.45

var _msg := ""
var _msg_kind := "info"
var _msg_time := 0.0

var _font: Font


func _ready() -> void:
	_font = ThemeDB.fallback_font
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)


func show_message(text: String, kind := "info") -> void:
	if text == "":
		clear_message()
		return
	_msg = text
	_msg_kind = kind
	_msg_time = 4.0


## Take the message down now. Not the same as showing an empty one, which used
## to leave the panel on screen for the full four seconds with nothing written
## on it -- a black box in the middle of the top of the screen.
func clear_message() -> void:
	_msg = ""
	_msg_time = 0.0


func _process(delta: float) -> void:
	if _msg_time > 0.0:
		_msg_time -= delta
	if watching != _watch:
		_watch = watching
		_watch_time = 0.0
	elif watching != "":
		_watch_time += delta
	queue_redraw()


func _draw() -> void:
	# Not `size`: a Control freshly added under a CanvasLayer has not been laid
	# out yet on the first draw, which silently pushed every viewport-relative
	# element off screen.
	var vp := get_viewport_rect().size
	_draw_status(vp)
	_draw_potted(vp)
	if not hide_controls and winner < 0:
		_draw_power(vp)
		_draw_tip_target(vp)
	if thinking and winner < 0:
		_draw_thinking(vp)
	_draw_watching(vp)
	_draw_message(vp)
	if show_help:
		_draw_help(vp)
	else:
		_text(Vector2(vp.x - 116.0, vp.y - 16.0), "H  help", 13, DIM)
	if winner >= 0:
		_draw_winner(vp)


## `alpha` fades the whole panel, backing and edge together. A panel that keeps
## its backing while the text on it fades out does not read as something on its
## way out -- it reads as a piece of UI that has failed to draw.
func _panel(r: Rect2, alpha := 1.0) -> void:
	draw_rect(r, Color(PANEL.r, PANEL.g, PANEL.b, PANEL.a * alpha), true)
	draw_rect(r, Color(EDGE.r, EDGE.g, EDGE.b, EDGE.a * alpha), false, 1.0)


func _text(at: Vector2, s: String, sz := 15, col := TEXT) -> void:
	draw_string(_font, at, s, HORIZONTAL_ALIGNMENT_LEFT, -1, sz, col)


# ---------------------------------------------------------------------------

func _draw_status(_vp: Vector2) -> void:
	# Killer seats up to eight, so the panel grows with them rather than the two
	# the other games are fixed at.
	var seats: int = maxi(2, players) if killer else 2
	var r := Rect2(16, 16, 316, 62.0 + 30.0 * float(seats))
	_panel(r)
	for p in range(seats):
		var y := 40.0 + float(p) * 30.0
		var out: bool = killer and p < lives.size() and lives[p] <= 0
		var active := p == turn and winner < 0 and not out
		var col := ACCENT if active else DIM
		if out:
			col = Color(BAD.r, BAD.g, BAD.b, 0.55)
		if active:
			draw_rect(Rect2(r.position.x + 8.0, y - 13.0, 4.0, 17.0), ACCENT, true)
		var who := "Player %d" % (p + 1)
		if p < cpu.size() and cpu[p]:
			who = "CPU %s" % cpu_name
		_text(Vector2(r.position.x + 20.0, y), who, 16, col)
		if killer:
			_draw_lives(Vector2(r.position.x + 132.0, y), p, out, active)
		elif snooker:
			_text(Vector2(r.position.x + 132.0, y), "%d" % score[p], 16,
				TEXT if active else DIM)
		else:
			var g: String = "open" if groups[p] == RulesUKPool.OPEN \
				else RulesUKPool.group_name(groups[p])
			_text(Vector2(r.position.x + 132.0, y), g, 15,
				PoolPhys.ball_color(1 if groups[p] == RulesUKPool.REDS else 9) \
					if groups[p] != RulesUKPool.OPEN else DIM)
	# The footer sits under the last seat, wherever that ended up.
	var foot := r.position.y + r.size.y - 14.0
	if snooker:
		var note := "on: %s" % required
		if break_score > 0:
			note += "     break %d" % break_score
		_text(Vector2(r.position.x + 20.0, foot), note, 13, ACCENT)
	elif killer:
		if winner < 0:
			_text(Vector2(r.position.x + 20.0, foot),
				"one shot each -- pot or you are out", 13, ACCENT)
	elif visits > 1 and winner < 0:
		# The whole shape of a UK frame is in this number: two visits means the
		# striker can miss once and stay at the table.
		_text(Vector2(r.position.x + 20.0, foot), "TWO SHOTS", 13, GOOD)
	if ball_in_hand and winner < 0:
		_text(Vector2(r.position.x + 206.0, 40.0),
			"IN HAND (D)" if in_d else "BALL IN HAND", 13, GOOD)
	if placing:
		_text(Vector2(r.position.x + 206.0, 70.0), "click to place", 13, DIM)
	if slow_motion:
		_text(Vector2(r.position.x + 200.0, foot), "slow motion", 13, ACCENT)


## Lives as pips, because the count is small and the shape of it -- who is nearly
## out -- reads faster than a number does. A player with none left keeps their row
## so the running order stays legible, but is struck through.
func _draw_lives(at: Vector2, p: int, out: bool, active: bool) -> void:
	if out:
		_text(at, "OUT", 14, Color(BAD.r, BAD.g, BAD.b, 0.75))
		return
	var n: int = lives[p] if p < lives.size() else 0
	for i in range(n):
		var c := Vector2(at.x + 6.0 + float(i) * 15.0, at.y - 5.0)
		draw_circle(c, 5.0, GOOD if active else DIM)


## Whose turn it is, when it is not yours.
##
## Said in the middle of the screen, because the corner of the panel is not where
## anyone is looking: with the cue locked out and the table doing nothing, a
## player who has missed the hand-over reads it as the game having frozen. It
## announces itself full size, then shrinks up out of the way and stays there for
## the rest of the visit -- long enough to answer "whose go is it?" at a glance,
## small enough to watch the shot through.
func _draw_watching(vp: Vector2) -> void:
	if watching == "" or winner >= 0:
		return
	var t: float = clampf((_watch_time - ANNOUNCE_HOLD) / ANNOUNCE_FADE, 0.0, 1.0)
	# Smoothed, so it settles into place rather than sliding at a constant rate.
	t = t * t * (3.0 - 2.0 * t)
	# Waiting on somebody else: shrink up out of the way and stay there. Handing
	# the table across a hot seat: say it once, at full size, and go.
	var shrink: float = t if waiting else 0.0
	var alpha: float = 1.0 if waiting else 1.0 - t
	if alpha <= 0.01:
		return
	var sz := int(round(lerpf(30.0, 15.0, shrink)))
	var text := "%s to play" % watching
	var w := _font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, sz).x
	# Settles below the message line (which sits at 78), not on top of it: the
	# hand-over and "you cannot pot the black yet" are both worth reading.
	var y: float = lerpf(vp.y * 0.44, 132.0, shrink)
	var pad: float = lerpf(30.0, 14.0, shrink)
	var high: float = lerpf(58.0, 30.0, shrink)
	var at := Vector2(vp.x * 0.5 - w * 0.5, y)
	_panel(Rect2(at.x - pad, y - high * 0.72, w + pad * 2.0, high),
		lerpf(0.92, 0.72, shrink) * alpha)
	draw_string(_font, at, text, HORIZONTAL_ALIGNMENT_LEFT, -1, sz,
		Color(ACCENT.r, ACCENT.g, ACCENT.b, alpha))


## Said plainly, because a game that has simply stopped responding for a moment
## is indistinguishable from one that has hung.
func _draw_thinking(vp: Vector2) -> void:
	var s := "CPU is thinking"
	var w := _font.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, 16).x
	var at := Vector2(vp.x * 0.5 - w * 0.5, vp.y - 46.0)
	_panel(Rect2(at.x - 18.0, at.y - 24.0, w + 36.0, 36.0))
	draw_string(_font, at, s, HORIZONTAL_ALIGNMENT_LEFT, -1, 16, ACCENT)


## Balls already off the table, as coloured chips. Neither game's balls carry a
## number, so neither do these: colour is the whole identity.
func _draw_potted(_vp: Vector2) -> void:
	if potted.is_empty():
		return
	var pitch := 21.0
	var r := Rect2(348, 16, pitch * float(potted.size()) + 16.0, 40)
	_panel(r)
	for i in range(potted.size()):
		var n: int = potted[i]
		var c := Vector2(r.position.x + 18.0 + pitch * float(i), r.position.y + 20.0)
		draw_circle(c, 8.5, PoolPhys.ball_color(n))
		draw_circle(c, 8.5, Color(0, 0, 0, 0.45), false, 1.0)
		# A little off-centre highlight, so a black ball still reads as a ball.
		draw_circle(c + Vector2(-2.6, -2.6), 2.4, Color(1, 1, 1, 0.30))


func _draw_power(vp: Vector2) -> void:
	var w := 260.0
	var h := 18.0
	var r := Rect2(vp.x * 0.5 - w * 0.5, vp.y - 54.0, w, h)
	_panel(Rect2(r.position - Vector2(10, 24), r.size + Vector2(20, 40)))
	draw_rect(r, Color(0.10, 0.11, 0.13), true)
	# Green through amber to red: a full-power stroke is rarely what you want.
	var fill := Rect2(r.position, Vector2(r.size.x * power, r.size.y))
	var col := Color(0.35, 0.80, 0.45).lerp(Color(0.95, 0.30, 0.25), power)
	draw_rect(fill, col, true)
	draw_rect(r, EDGE, false, 1.0)
	for frac: float in [0.25, 0.5, 0.75]:
		var x := r.position.x + r.size.x * frac
		draw_line(Vector2(x, r.position.y), Vector2(x, r.end.y), Color(0, 0, 0, 0.35), 1.0)
	var label := "drag the mouse back to draw the cue" if not charging else "release to play the stroke"
	_text(Vector2(r.position.x, r.position.y - 8.0), label, 13, DIM)
	_text(Vector2(r.end.x - 44.0, r.end.y + 16.0), "%3d %%" % int(power * 100.0), 14, TEXT)


## The cue ball seen from behind, with a crosshair where the tip will land.
func _draw_tip_target(vp: Vector2) -> void:
	var radius := 46.0
	var c := Vector2(vp.x - 84.0, vp.y - 154.0)
	_panel(Rect2(c - Vector2(radius + 18.0, radius + 18.0),
		Vector2(radius * 2.0 + 36.0, radius * 2.0 + 122.0)))
	draw_circle(c, radius, Color(0.90, 0.90, 0.88))
	draw_circle(c, radius, Color(0, 0, 0, 0.35), false, 1.0)
	# Inner ring: where the tip starts to slip. Outer ring: as low as it can be
	# placed at all. Between them the stroke still lands, just badly.
	draw_arc(c, radius * PoolPhys.MAX_TIP_OFFSET, 0.0, TAU, 48,
		Color(0.85, 0.55, 0.20, 0.55), 1.0)
	draw_arc(c, radius * PoolPhys.MISCUE_LIMIT, 0.0, TAU, 48,
		Color(0.85, 0.28, 0.24, 0.60), 1.0)
	draw_line(c - Vector2(radius, 0), c + Vector2(radius, 0), Color(0, 0, 0, 0.13), 1.0)
	draw_line(c - Vector2(0, radius), c + Vector2(0, radius), Color(0, 0, 0, 0.13), 1.0)

	# Screen y is down, tip offset y is up.
	var tip := c + Vector2(spin.x, -spin.y) * radius
	var miscuing := spin.length() > PoolPhys.MAX_TIP_OFFSET
	draw_line(c, tip, Color(0.15, 0.35, 0.65, 0.6), 1.5)
	draw_circle(tip, 7.0, Color(0.90, 0.35, 0.25) if miscuing else Color(0.13, 0.45, 0.85))
	draw_circle(tip, 7.0, Color(1, 1, 1, 0.85), false, 1.5)

	if miscuing:
		_text(Vector2(c.x - radius - 8.0, c.y + radius + 30.0),
			"arrows: english          MISCUE", 12, BAD)
	else:
		_text(Vector2(c.x - radius - 8.0, c.y + radius + 30.0),
			"arrows: english", 12, DIM)
	_draw_cue_angle(Vector2(c.x - radius - 8.0, c.y + radius + 62.0))


## A side-on view of the cue against the table. "W raises, S lowers" means nothing
## on its own -- a picture of the actual angle does, and it is the difference
## between a stroke that can jump the ball and one that cannot.
func _draw_cue_angle(at: Vector2) -> void:
	var w := 118.0
	var base := at + Vector2(0.0, 18.0)
	# The table line and the ball sitting on it.
	draw_line(base, base + Vector2(w, 0.0), Color(0.55, 0.58, 0.62), 1.5)
	draw_circle(base + Vector2(w * 0.72, -5.0), 5.0, Color(0.92, 0.92, 0.88))

	# The cue, pivoting on the ball at the elevation actually being applied.
	var tip := base + Vector2(w * 0.72 - 6.0, -5.0)
	var dir := Vector2(-cos(elevation), -sin(elevation))
	var col := ACCENT if elevation > deg_to_rad(20.0) else DIM
	draw_line(tip, tip + dir * (w * 0.62), col, 2.5)

	var label := "W raise   S lower      %d deg" % int(round(rad_to_deg(elevation)))
	if elevation_forced:
		label += " (rail)"
	_text(at + Vector2(0.0, -6.0), label, 12, DIM)

	# What this stroke will actually do, straight off the traced shot.
	if hop > 0.002:
		var clears := hop > ball_diameter
		_text(base + Vector2(0.0, 18.0),
			"JUMP %.0f cm%s" % [hop * 100.0,
				"  clears a ball" if clears else "  too low to clear a ball"],
			12, GOOD if clears else BAD)
	elif elevation < deg_to_rad(10.0):
		_text(base + Vector2(0.0, 18.0), "level cue -- cannot jump", 12, DIM)


func _draw_message(vp: Vector2) -> void:
	if _msg_time <= 0.0 or _msg == "":
		return
	var col := TEXT
	if _msg_kind == "bad":
		col = BAD
	elif _msg_kind == "good":
		col = GOOD
	var sz := 22
	var w := _font.get_string_size(_msg, HORIZONTAL_ALIGNMENT_LEFT, -1, sz).x
	var at := Vector2(vp.x * 0.5 - w * 0.5, 78.0)
	var fade: float = clampf(_msg_time / 0.7, 0.0, 1.0)
	_panel(Rect2(at.x - 16.0, at.y - 24.0, w + 32.0, 38.0), fade)
	draw_string(_font, at, _msg, HORIZONTAL_ALIGNMENT_LEFT, -1, sz,
		Color(col.r, col.g, col.b, fade))


const HELP_LINES := [
	"mouse          aim at the table",
	"Q / E          fine aim      SHIFT: precision aim",
	"left-drag      draw the cue back, release to shoot",
	"SPACE          replay the last power",
	"arrow keys     tip offset (draw, follow, english)",
	"W              RAISE the butt (S lowers it back down)",
	"J              jump stance: butt up, tip on centre",
	"K              scoop stance: cue level, tip under ball",
	"               a level cue cannot jump, and aiming at the",
	"               bottom of the ball halves the height",
	"X              reset tip to centre",
	"right drag     orbit camera        wheel  zoom",
	"C              cycle camera        G      aim guide",
	"T              slow motion         R      re-rack",
	"click          place the cue ball when in hand",
	"M              menu: game, opponent, CPU skill, host / join",
	"ESC            release / recapture the mouse",
]


func _draw_help(vp: Vector2) -> void:
	var w := 430.0
	var h := 26.0 + 20.0 * float(HELP_LINES.size())
	var r := Rect2(vp.x - w - 16.0, vp.y - h - 16.0, w, h)
	_panel(r)
	for i in range(HELP_LINES.size()):
		_text(r.position + Vector2(16.0, 26.0 + 20.0 * float(i)), HELP_LINES[i], 14, DIM)


func _draw_winner(vp: Vector2) -> void:
	var s := "Player %d wins" % (winner + 1)
	var sz := 44
	var w := _font.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, sz).x
	var at := Vector2(vp.x * 0.5 - w * 0.5, vp.y * 0.5)
	_panel(Rect2(at.x - 30.0, at.y - 52.0, w + 60.0, 96.0))
	draw_string(_font, at, s, HORIZONTAL_ALIGNMENT_LEFT, -1, sz, GOOD)
	var sub := "R to rack again"
	var sw := _font.get_string_size(sub, HORIZONTAL_ALIGNMENT_LEFT, -1, 16).x
	draw_string(_font, Vector2(vp.x * 0.5 - sw * 0.5, at.y + 28.0), sub,
		HORIZONTAL_ALIGNMENT_LEFT, -1, 16, DIM)
