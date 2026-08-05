class_name PoolPhys
extends RefCounted

## Physical constants for cue sports, SI units.
##
## Coordinate system: Godot's native Y-up. The cloth is the y = 0 plane, the
## playing surface spans x (short axis / width) and z (long axis / length).
## A ball at rest has its centre at y = BALL_R.
##
## Every value below is a measured quantity from the billiards literature
## (Marlow, "The Physics of Pocket Billiards"; Han 2005; Mathavan et al. 2010)
## or a WPA equipment spec. They are the only tuning knobs in the simulation --
## the motion and collision models themselves are derived, not fudged.

## Which game the table is set up for. Quantities that differ between the two --
## ball size and mass, table dimensions, pocket cut, cushion height -- are static
## vars rather than constants so a single `configure()` call reshapes the whole
## simulation. Everything derived from them is recomputed there.
##
## This is deliberately global: one table, one game at a time. Tests that care
## must call configure() themselves.
enum { POOL, SNOOKER }
static var mode: int = POOL

## Which game is being played, as distinct from which table it is played on.
##
## The two were the same thing while there were only two games. Killer is UK
## pool's table, balls and physics with entirely different rules, so the table a
## game wants and the rules it runs under have to be asked for separately.
enum { GAME_EIGHT_BALL, GAME_SNOOKER, GAME_KILLER }

const GAME_NAMES := ["UK 8-ball", "Snooker", "Killer"]


## The table a game is played on.
static func table_for(game: int) -> int:
	return SNOOKER if game == GAME_SNOOKER else POOL


## Set the table up for a game. Call before building a PoolTable or any balls.
static func configure(p_mode: int) -> void:
	mode = p_mode
	if p_mode == SNOOKER:
		# 12 ft x 6 ft, 52.5 mm balls. Snooker pockets are far tighter than pool
		# ones and the jaws are rounded, which is most of why the game is harder.
		BALL_R = 0.02625
		BALL_M = 0.142
		PLAY_W = 1.7783                       # 70 in
		PLAY_L = 3.5687                       # 140.5 in
		# WPBSA: 3.5 in corner pockets, 4 in centres, measured between the fall
		# points. Snooker's corners are barely wider than the ball -- 1.69 balls
		# against a pub table's 1.80 -- which is most of why the game is harder.
		CORNER_MOUTH = 0.0889
		SIDE_MOUTH = 0.1016
		JAW_R = 0.022
		CUSHION_DEPTH = 0.050
		CORNER_SHELF = 0.020
		SIDE_SHELF = 0.004
		POCKET_DEPTH = 0.100
		RAIL_TOP = 0.042
		RAIL_WIDTH = 0.150
		CUE_M = 0.525
		CUE_TIP_R = 0.0047                    # ~9.5 mm tip
		CUE_BUTT_R = 0.0125
		CUE_LENGTH = 1.46
		SQUIRT_DEG = 4.5                      # thinner shaft, less deflection
		# Snooker cloth is napped and runs faster than pool cloth.
		MU_ROLL = 0.011
	else:
		# UK eight-ball pool: an 8 ft pub table, 7 ft x 3 ft 6 in between the
		# cushion noses, with 2 in balls. Not an American table with different
		# coloured balls -- the balls are a quarter lighter and the pockets are cut
		# noticeably tighter relative to the ball, which is why the same shot plays
		# completely differently on it.
		BALL_R = 0.0254                       # 2 in diameter
		BALL_M = 0.119                        # ~4.2 oz
		PLAY_W = 1.0668                       # 42 in
		PLAY_L = 2.1336                       # 84 in
		# Corner mouth 3.6 in across the diagonal, middles 4.3 in: a pub table's
		# pockets are about 1.8 balls wide where an American corner is 2.
		CORNER_MOUTH = 0.0914
		SIDE_MOUTH = 0.1092
		JAW_R = 0.020
		CUSHION_DEPTH = 0.040
		CORNER_SHELF = 0.018
		SIDE_SHELF = 0.002
		POCKET_DEPTH = 0.080
		RAIL_TOP = 0.040
		RAIL_WIDTH = 0.115
		CUE_M = 0.510
		CUE_TIP_R = 0.0045                    # ~9 mm tip
		CUE_BUTT_R = 0.0135
		CUE_LENGTH = 1.42
		SQUIRT_DEG = 5.5
		# Napped wool cloth, slower than a snooker bed but faster than the
		# worsted an American table is covered in.
		MU_ROLL = 0.013
	_recompute()


## Everything that is a function of the above.
static func _recompute() -> void:
	BALL_D = 2.0 * BALL_R
	INERTIA = 0.4 * BALL_M * BALL_R * BALL_R
	SLIDE_ANG_ACC = 2.5 * MU_SLIDE * G / BALL_R
	ROLL_DECEL = MU_ROLL * G
	SPIN_DECEL = 2.5 * MU_SPIN * G / BALL_R
	CUSHION_HEIGHT = 0.635 * BALL_D
	HALF_W = 0.5 * PLAY_W
	HALF_L = 0.5 * PLAY_L
	CORNER_JAW = (CORNER_MOUTH + 2.0 * JAW_R) / sqrt(2.0) - JAW_R
	SIDE_JAW = 0.5 * SIDE_MOUTH + JAW_R
	if mode == SNOOKER:
		# Baulk line is 29 in from the bottom cushion; the black spot 12.75 in
		# from the top. FOOT_SPOT_Z is reused as the black spot, HEAD_STRING_Z as
		# the baulk line, so shared code keeps working.
		FOOT_SPOT_Z = -HALF_L + 0.3239
		HEAD_STRING_Z = HALF_L - 0.7366
	else:
		# UK pool marks both ends a fifth of the table's length in: the baulk line
		# with its D at one end, the black spot at the other. Same two names as
		# snooker, same meanings -- FOOT_SPOT_Z is the black spot, which is also
		# where a ball knocked off the table is returned to.
		FOOT_SPOT_Z = -HALF_L + PLAY_L / 5.0
		HEAD_STRING_Z = HALF_L - PLAY_L / 5.0


# --- Ball -------------------------------------------------------------------
static var BALL_R := 0.028575                      # 2 1/4 in diameter
static var BALL_D := 2.0 * BALL_R
static var BALL_M := 0.170097                      # 6 oz
## Solid sphere: I = 2/5 m R^2
static var INERTIA := 0.4 * BALL_M * BALL_R * BALL_R

const G := 9.80665

# --- Ball / cloth friction --------------------------------------------------
## Sliding (kinetic) friction while the contact point skids on the nap.
const MU_SLIDE := 0.20
## Rolling resistance once the ball rolls without slipping. Published values for
## billiard cloth span roughly 0.005-0.020 (deceleration 0.05-0.20 m/s^2); this
## sits mid-range, which also keeps roll-out times in the 4-6 s a real table
## gives rather than the 10-14 s the low end produces.
static var MU_ROLL := 0.015
## Effective friction of the contact patch about the vertical axis, which is
## what bleeds off "english" while the ball is otherwise rolling or still.
const MU_SPIN := 0.0132

## Derived accelerations.
## Sliding: the slip velocity always decays along a *fixed* direction at
## 7/2 * mu * g (see PoolBall.begin_phase for the derivation), while the centre
## of mass decelerates at mu * g and spin changes at 5 mu g / 2R.
const SLIDE_DECEL := MU_SLIDE * G
static var SLIDE_ANG_ACC := 2.5 * MU_SLIDE * G / BALL_R
const SLIP_DECAY := 3.5 * MU_SLIDE * G
static var ROLL_DECEL := MU_ROLL * G
static var SPIN_DECEL := 2.5 * MU_SPIN * G / BALL_R

# --- Collisions -------------------------------------------------------------
## Ball-ball: nearly elastic along the line of centres, lightly frictional
## across it. The tangential term is what produces "throw" and cut-induced
## throw, and transfers english between balls.
const E_BALL := 0.95
const MU_BALL := 0.06

## Ball-cushion. E_CUSHION is the restitution at the rubber contact point; the
## *apparent* normal restitution measured at the ball centre comes out lower
## (~0.72) because the cushion nose sits above centre height -- see
## PoolSim._resolve_cushion.
const E_CUSHION := 0.85
const MU_CUSHION := 0.20
## WPA: cushion nose height is 62.5%-65% of ball diameter. This offset above
## the ball's equator is the reason cushions impart topspin and why running /
## reverse english changes the rebound angle.
static var CUSHION_HEIGHT := 0.635 * BALL_D

## Hard ceiling on the vertical kick, on top of the proportional one. A rail does
## not throw a ball metres into the air no matter how hard it is struck.
const CUSHION_KICK_MAX := 0.35

## Ceiling on angular velocity, in rad/s.
##
## Nothing in the impulse code bounds a ball's spin, and an impulse applied over
## and over in the same place -- a ball wedged against a jaw on the lip of a
## pocket, taking a contact every zero-length event -- can pump it until it
## overflows to infinity. What that costs is not a comically fast ball: the
## orientation update divides by the spin's own magnitude, so an infinite spin
## makes `orient` a quaternion of NaNs, and a NaN quaternion handed to a node
## transform takes the renderer down with no error logged anywhere.
##
## A hard break puts perhaps 200 rad/s on the cue ball, so this is far outside
## anything a cue can do and exists only to keep the number finite.
const MAX_SPIN := 1000.0

## Ceiling on how much vertical speed a cushion may impart, either way, as a
## fraction of the speed the ball arrived at.
##
## The cushion nose sits above the ball's equator, so the contact genuinely has a
## vertical component -- balls really do hop a few millimetres off a hard rail.
## But the ball is resting on the slate throughout that contact, and the slate
## reacts the vertical part rather than letting it accumulate.
##
## Without this bound the numbers get silly in both directions. Unbounded, the
## friction impulse can lever a fast spinning ball upward; and unbounded downward
## it is worse, because a ball a couple of millimetres airborne gets driven down at
## 5 m/s and the cloth bounce then returns half of it -- a rail contact turning
## into a 31 cm launch. Capping the vertical kick symmetrically fixes both.
const CUSHION_VERTICAL_KICK := 0.10

## Ball landing back on the cloth after a hop or a jump shot.
const E_CLOTH := 0.50
const MU_CLOTH := 0.30

## Inside a pocket: the ball is a free body bouncing off the liner and the shelf.
##
## A real corner pocket has a shelf a few centimetres below the cloth that the
## ball lands on, rather than a shaft it disappears down. Keeping the depth
## shallow reproduces that -- the ball comes to rest where you can still see it
## through the opening, which is what makes a drop read as "it went in" instead
## of "it vanished".
static var POCKET_DEPTH := 0.090
const E_POCKET_WALL := 0.35
const E_POCKET_FLOOR := 0.28
## The pocket cavity is wider than the capture circle, so a ball that drops in
## at the edge of the mouth is not shoved sideways as it enters.
const POCKET_CAVITY_MARGIN := 0.020

## An elevated cue drives the ball down into the slate, and the rebound is what
## makes a jump shot possible. Applied to the downward component of the strike.
##
## This is deliberately well below the ball-on-cloth restitution: the tip is still
## in contact while the ball rebounds, and the tip only has the ball's radius of
## downward travel to work with. Tuned so a proper jump stroke clears an
## intervening ball (~6 cm) but an ordinary shot with the butt raised a few
## degrees over a rail barely leaves the cloth.
const CUE_JUMP_E := 0.27
## Below this downward speed the cloth simply absorbs the stroke.
const CUE_JUMP_MIN := 0.70
## The cue must be *deliberately* raised this far before a stroke can launch the
## ball. The couple of degrees the cue tilts automatically to clear a rail is a
## geometric accommodation for where the shaft has to go, not a stab down into the
## slate, and a level cue must not be able to chip the ball.
const JUMP_MIN_ELEV := 0.1396          # 8 degrees

# --- Cue --------------------------------------------------------------------
## Shaft radii at the tip and the butt. A snooker cue is markedly thinner than a
## pool cue, which is not only a look: less wood out at the end means less end
## mass, and less end mass means the cue ball is deflected less by side spin.
static var CUE_TIP_R := 0.0065
static var CUE_BUTT_R := 0.0145
static var CUE_LENGTH := 1.44
static var CUE_M := 0.539                          # 19 oz
const CUE_E := 1.0                            # leather tip, treated as elastic
## The stroke a cue can be delivered at, from the gentlest controllable touch to
## a full-blooded break. Both the player's power meter and the CPU's chosen
## stroke are held to this range -- the computer plays with the same cue action
## as the person it is playing.
const CUE_SPEED_MIN := 0.55
const CUE_SPEED_MAX := 9.0

## Tip offset from centre, as a fraction of R, at which the tip starts to slip.
## Real players get a hair over half a ball before the tip skids off the side.
const MAX_TIP_OFFSET := 0.52
## The tip can be placed out to here, but everything past MAX_TIP_OFFSET is a
## progressively worse miscue rather than a hard wall: less of the stroke is
## transferred and the contact goes off line. Aiming very low to chip the ball is
## therefore possible, and appropriately unreliable.
const MISCUE_LIMIT := 0.66
## Fraction of the impulse still delivered at MISCUE_LIMIT.
const MISCUE_POWER_FLOOR := 0.35
## Random direction error at MISCUE_LIMIT, degrees.
const MISCUE_SCATTER_DEG := 5.0
## Scoop. A tip that gets under the ball does not simply drive it along the shaft:
## part of the blow acts along the contact normal, which for a low hit points up
## and forward, and the ball chips into the air. This is the scoop jump -- a real
## stroke, and illegal in tournament play precisely because it works.
##
## It only starts once the tip is genuinely under the ball (SCOOP_START), so
## ordinary draw is unaffected and a level cue still cannot chip the ball from a
## normal stroke. SCOOP_MAX is the fraction of the impulse redirected at the very
## bottom of the ball.
const SCOOP_START := 0.40
const SCOOP_MAX := 0.50

## Cue-ball squirt (deflection): a side hit sends the ball slightly *opposite*
## to the english because of the shaft's end mass. Degrees per unit of a/R.
static var SQUIRT_DEG := 7.0

## How far above the rail the shaft is kept when a cushion is behind the shot,
## and the ceiling on the tilt that produces. A level cue drives straight through
## the cushion and rail cap whenever the cue ball is near a rail, which is why a
## real player raises the butt.
const CUE_RAIL_CLEARANCE := 0.012
const CLEARANCE_ELEV_MAX := 0.6109        # 35 degrees


## Distance from `from` to the edge of the playing area along `dir`. Slab
## intersection from a point known to be inside the rectangle.
static func distance_to_play_edge(from: Vector3, dir: Vector3) -> float:
	var best := INF
	if dir.x > 1.0e-6:
		best = minf(best, (HALF_W - from.x) / dir.x)
	elif dir.x < -1.0e-6:
		best = minf(best, (-HALF_W - from.x) / dir.x)
	if dir.z > 1.0e-6:
		best = minf(best, (HALF_L - from.z) / dir.z)
	elif dir.z < -1.0e-6:
		best = minf(best, (-HALF_L - from.z) / dir.z)
	return maxf(best, 0.0)


## The smallest butt elevation that keeps the shaft clear of the rail behind a
## shot played from `pos` along `aim`.
##
## The shaft rises linearly with distance behind the tip, so clearing the *inner*
## rail edge -- the nearest obstruction -- clears the whole rail. Both the player
## and the CPU go through here, so a stroke is simulated at the angle it is
## actually played at.
static func rail_clearance_elevation(pos: Vector3, aim: Vector3) -> float:
	var back := -Vector3(aim.x, 0.0, aim.z).normalized()
	var d := distance_to_play_edge(pos, back)
	var rise := RAIL_TOP + CUE_RAIL_CLEARANCE - BALL_R
	if rise <= 0.0:
		return 0.0
	if d <= 1.0e-4:
		return CLEARANCE_ELEV_MAX
	return minf(atan2(rise, d), CLEARANCE_ELEV_MAX)

# --- Numerical thresholds ---------------------------------------------------
## Below this slip speed the contact is treated as rolling.
const SLIP_EPS := 1.0e-6
## Below this centre speed the ball is treated as stopped.
const STOP_EPS := 1.0e-4
## Below this spin the ball is treated as spin-free.
const SPIN_EPS := 1.0e-4
## Vertical speed below which a bounce is absorbed instead of reflected.
const BOUNCE_EPS := 0.08
## Upward speed a ball on the cloth needs before it actually leaves the bed.
## Frictional impulses between two rolling balls legitimately produce a tiny
## vertical kick; without a floor here those become zero-length flight phases
## that the event solver would grind on forever.
const LIFTOFF_EPS := 0.08
## Height above resting centre at which a ball counts as airborne.
const AIR_EPS := 1.0e-5

# --- Table (9 foot, WPA) ----------------------------------------------------
static var PLAY_W := 1.2700                        # 50 in between cushion noses
static var PLAY_L := 2.5400                        # 100 in
static var HALF_W := 0.5 * PLAY_W
static var HALF_L := 0.5 * PLAY_L

## The pocket openings, measured between the two fall points -- the gap a ball
## actually has to pass through. This is the quantity every rulebook specifies
## and the one a player feels, so it is the input here; the cushion cut-backs
## below are worked out from it.
static var CORNER_MOUTH := 0.1143               # 4.5 in
static var SIDE_MOUTH := 0.1270                 # 5 in

## Distance from a corner, measured along each rail, at which the cushion is cut
## away for the pocket.
##
## Derived, not measured. The jaw is a circle of radius JAW_R tangent to the
## cushion face at the cut, so half of it stands proud of the cut and into the
## mouth: the gap a ball threads is JAW_R narrower at each jaw than the distance
## between the cut-backs. Quoting the cut-backs directly is what made these
## pockets play far tighter than the sizes they were documented with -- a pub
## table's centres came out at 2.7 in against the 4.3 in intended, tighter than
## its own corners, which is backwards for every real table.
static var CORNER_JAW := 0.0812
static var SIDE_JAW := 0.0680
## Radius of the rounded pocket jaw -- the cushion end a ball rattles against.
##
## Both games round the jaw rather than bevelling it: the rubber is carried right
## around the end of the cushion in a half turn, so what a ball meets on the way
## into a pocket is a circle of this radius and nothing else. The circle is the
## collision jaw as well as the drawn one, which is why the number lives here
## rather than in the view.
static var JAW_R := 0.018
## How far the cloth and cushion body extend past the nose line.
static var CUSHION_DEPTH := 0.045
## Height of the rail surface above the cloth, and how wide the wood is outside
## the cushion. The cushion top is flush with the rail, so together they form one
## flat plateau that a ball can land on and run along.
static var RAIL_TOP := 0.045
static var RAIL_WIDTH := 0.135

## Pocket shelf: how far a ball's centre may travel past the mouth line before it
## loses support and drops.
##
## This is what a pocket actually is -- a straight mouth between two cushion noses
## opening outward, with a shelf behind it -- not a circle sitting in the middle of
## the cloth. It is also why balls hang in the jaws instead of always dropping.
## Corner pockets have a real shelf; side pockets have almost none.
static var CORNER_SHELF := 0.025
static var SIDE_SHELF := 0.002

## The foot spot (rack apex) and head string sit a quarter-length from each end.
static var FOOT_SPOT_Z := -0.25 * PLAY_L           # -0.635
static var HEAD_STRING_Z := 0.25 * PLAY_L          # +0.635

# --- Ball identity ----------------------------------------------------------
## Pool: `number` is 1-7 for the reds, 9-15 for the yellows and 8 for the black,
##   0 = cue. UK balls carry no printed number, but keeping the two groups on
##   either side of the 8 means "which group is this" stays a comparison.
## Snooker: `number` is the ball's *value*, which is all the rules need.
##   0 = cue, 1 = red (fifteen of them), 2 yellow, 3 green, 4 brown,
##   5 blue, 6 pink, 7 black.
const UK_RED := Color(0.72, 0.09, 0.07)
const UK_YELLOW := Color(0.94, 0.74, 0.05)
const UK_BLACK := Color(0.05, 0.05, 0.06)

const SNOOKER_COLORS := {
	1: Color(0.62, 0.05, 0.05),   # red
	2: Color(0.90, 0.72, 0.06),   # yellow
	3: Color(0.04, 0.36, 0.13),   # green
	4: Color(0.33, 0.19, 0.07),   # brown
	5: Color(0.04, 0.20, 0.62),   # blue
	6: Color(0.90, 0.45, 0.55),   # pink
	7: Color(0.04, 0.04, 0.05),   # black
}

const SNOOKER_NAMES := {
	1: "red", 2: "yellow", 3: "green", 4: "brown",
	5: "blue", 6: "pink", 7: "black",
}


static func ball_color(number: int) -> Color:
	if number == 0:
		return Color(0.97, 0.96, 0.93)
	if mode == SNOOKER:
		return SNOOKER_COLORS.get(number, Color(0.6, 0.6, 0.6))
	if number == 8:
		return UK_BLACK
	return UK_RED if number < 8 else UK_YELLOW



static func snooker_name(value: int) -> String:
	return SNOOKER_NAMES.get(value, "?")


## Rack apex, chosen so the ball that has to sit on a spot does.
##
## Snooker racks the reds behind the pink and nothing in the triangle is spotted,
## so the apex is placed directly. UK pool spots the *black*, which sits in the
## middle of the third row -- two row-pitches behind the apex -- so the apex is
## worked backwards from the black spot.
static func rack_apex_z() -> float:
	if mode == SNOOKER:
		return FOOT_SPOT_Z
	return FOOT_SPOT_Z + 2.0 * rack_row_pitch()


## Distance between successive rows of a rack, centre to centre.
static func rack_row_pitch() -> float:
	return (BALL_D + 0.0002) * sqrt(3.0) * 0.5


# --- Baulk end and spots ----------------------------------------------------
## Both games are played from a D on the baulk line, and both put the black at
## the far end. -Z is the top (black) end of the table; +Z is baulk.
##
## The D is a sixth of the table's width in radius on either table, which is
## where snooker's 11.5 in comes from; it is quoted exactly there and derived
## here, so the pool D scales with the bed instead of being a second magic
## number.
static func d_radius() -> float:
	return 0.292 if mode == SNOOKER else PLAY_W / 6.0


static func baulk_z() -> float:
	return HEAD_STRING_Z


## Where each colour is spotted, by value.
static func snooker_spot(value: int) -> Vector2:
	match value:
		2: return Vector2(d_radius(), baulk_z())        # yellow, right of the D
		3: return Vector2(-d_radius(), baulk_z())       # green, left of the D
		4: return Vector2(0.0, baulk_z())               # brown, centre of baulk
		5: return Vector2(0.0, 0.0)                     # blue, centre spot
		6: return Vector2(0.0, -HALF_L * 0.5)           # pink
		7: return Vector2(0.0, FOOT_SPOT_Z)             # black
	return Vector2(0.0, FOOT_SPOT_Z)
