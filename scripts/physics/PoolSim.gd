class_name PoolSim
extends RefCounted

## Event-driven billiards simulator.
##
## There is no fixed timestep and no penetration solver. Instead: every ball's
## trajectory is an exact quadratic inside its current motion phase, so we solve
## analytically for the earliest moment anything *happens* -- a collision, a
## pocket capture, a slide-to-roll transition -- advance every ball exactly to
## that instant, resolve it, and repeat.
##
## Consequences worth knowing:
##   * No tunnelling. A ball cannot pass through a cushion at any speed,
##     because contact times are roots of a polynomial, not samples.
##   * Frame-rate independent and deterministic: the same shot replays
##     identically at 30 or 300 fps.
##   * Balls at rest are genuinely at rest (phase_left = INF, zero cost), so
##     there is none of the jitter a constraint solver leaves behind.

enum {
	EV_NONE,
	EV_PHASE,     # a motion phase ended (slide->roll, roll->stop, landing)
	EV_BALL,      # ball-ball
	EV_CUSHION,   # ball-cushion (straight run)
	EV_JAW,       # ball-pocket facing (rounded)
	EV_POCKET,    # captured
}

const MAX_EVENTS_PER_STEP := 6000
## Per-call event budget, and whether blowing it is worth complaining about.
##
## The aim guide runs a throwaway copy of the shot every time the shot inputs
## change -- which while aiming is every frame. It gets a much smaller budget and
## a quiet failure: a guide that stops drawing a little early is a non-event,
## whereas spending the full budget sixty times a second is the game locking up.
var max_events := MAX_EVENTS_PER_STEP
var quiet := false
const TIME_EPS := 1.0e-12
## Budget for a guide trace, per advance() call and in total. This runs every
## frame while aiming, so it is bounded far more tightly than a real shot: the
## point of the guide is the first contact, not a full multi-rail journey.
const PREDICT_EVENT_BUDGET := 220
const PREDICT_TOTAL_EVENTS := 700
## Cushions to follow before giving up. Beyond a couple of rails the line is not
## telling the player anything they are aiming with.
const PREDICT_MAX_CUSHIONS := 2

## Generous bound beyond which a ball has left the table entirely.
const OFF_TABLE_MARGIN := 0.13
## Closing speed below which a near-vertical ball-on-ball contact counts as
## resting rather than bouncing.
const REST_CONTACT_SPEED := 0.30
## How briskly a ball perched on another rolls off it.
const ROLL_OFF_SPEED := 0.16
## Closing speed below which a ball-ball contact counts as resting rather than
## colliding. A ball creeping at 2 cm/s carries about a centimetre of travel.
const CONTACT_REST_SPEED := 0.02
## Gap left after separating any two touching things -- ball and ball, ball and
## cushion, ball and jaw. Comfortably above float32 rounding at table coordinates,
## and far below anything visible.
##
## Every contact has to be separated by this, not merely de-penetrated to the
## exact distance at which it touches. A pair left sitting on that distance is
## re-detected immediately, and the resolver then finds nothing to do because the
## contact is already separating: the two grind out events a fraction of a
## microsecond apart, the table clock crawls, and the shot never ends. That is a
## worse failure than it sounds, because every guard against a runaway shot is
## watching the table clock -- so a hang there hangs the game for good.
const SEPARATION_EPS := 1.0e-5

var table: PoolTable
var balls: Array[PoolBall] = []
var cue: PoolBall
## Balls currently falling through a pocket, integrated by advance_drops().
var falling: Array[PoolBall] = []

## The simulator's own source of randomness, for the two places the physics is
## deliberately not repeatable: a miscue's scatter, and which way a ball balanced
## exactly on top of another topples.
##
## It is seeded rather than global because a shot has to be reproducible from its
## inputs alone. Networked play sends the stroke and lets both machines simulate
## it, and "both machines" only agree if every draw agrees too.
var rng := RandomNumberGenerator.new()

## Ordered record of what happened during the current shot; the rules engine
## reads this instead of trying to observe the simulation live.
var shot_log: Array = []
## Impacts waiting to be turned into audio. The presentation layer drains this.
var sound_queue: Array = []
## Whether impacts are queued for audio at all.
##
## Only the table the player is looking at makes any noise. A throwaway copy --
## the aim guide's, or one of the dozens the CPU plays out every turn -- has
## nobody to drain the queue, so every impact it records is an allocation that is
## never read and never freed until the copy dies. On a shot that generates
## events by the thousand that is real memory, for nothing.
var record_sound := true

var shot_time := 0.0
var overflowed := false

## Diagnostics. When enabled, every resolved event is appended to `trace` as
## [time, type, a, b]; the ring is capped so it is safe to leave on.
var trace_events := false
## Prints the vertical bookkeeping of every cushion impulse. Diagnostic only.
var debug_cushion := false
var trace: Array = []
const TRACE_CAP := 400
## Total events resolved in the current shot, for profiling.
var event_count := 0

# Scratch, reused every event search to keep the inner loop allocation-free.
var _ev_t := 0.0
var _ev_type := EV_NONE
var _ev_a := -1
var _ev_b := -1


func _init(p_table: PoolTable = null) -> void:
	table = p_table if p_table != null else PoolTable.new()


func add_ball(b: PoolBall) -> void:
	balls.append(b)
	if b.number == 0:
		cue = b


func settled() -> bool:
	for b in balls:
		if b.is_moving():
			return false
	return true


func begin_shot() -> void:
	shot_log.clear()
	trace.clear()
	shot_time = 0.0
	event_count = 0
	overflowed = false


## Run the simulation forward by dt seconds of table time.
func advance(dt: float) -> void:
	var remaining := dt
	var events := 0
	## Simultaneous contacts legitimately resolve at dt = 0 (a shockwave through
	## a tight rack is a chain of them), but a long unbroken run of them means
	## something is degenerate. Fail loudly rather than silently eat the budget.
	var zero_run := 0
	while remaining > TIME_EPS:
		if settled():
			break
		if events >= max_events:
			overflowed = true
			if not quiet:
				push_warning("PoolSim: event budget exhausted, %.4fs of shot dropped"
					% remaining)
			break
		events += 1
		event_count += 1

		_find_next_event(remaining)
		if trace_events:
			trace.append([shot_time, _ev_t, _ev_type, _ev_a, _ev_b])
			if trace.size() > TRACE_CAP:
				trace.pop_front()
		var step: float = maxf(_ev_t, 0.0)
		if step > 0.0:
			zero_run = 0
			for b in balls:
				b.integrate(step)
			shot_time += step
			remaining -= step
		else:
			zero_run += 1
			if zero_run > 512:
				overflowed = true
				if not quiet:
					push_warning("PoolSim: stalled on zero-length events (%s a=%d b=%d)"
						% [_ev_type, _ev_a, _ev_b])
				break

		match _ev_type:
			EV_BALL:
				_resolve_ball_ball(balls[_ev_a], balls[_ev_b])
			EV_CUSHION:
				_resolve_cushion_run(balls[_ev_a], table.cushions[_ev_b])
			EV_JAW:
				_resolve_jaw(balls[_ev_a], table.jaws[_ev_b])
			EV_POCKET:
				_capture(balls[_ev_a], table.pockets[_ev_b])
			_:
				pass

		# Landing has to be handled before phases are re-derived, otherwise the
		# bounce is lost and the ball just sticks to the cloth.
		# Balls genuinely asleep need none of the per-event bookkeeping. On a
		# settled table that is fifteen of the sixteen, and the saving is most of
		# what the aim guide costs -- it re-traces the shot every frame.
		for b in balls:
			if b.state == PoolBall.STATIONARY and b.vel == Vector3.ZERO \
					and b.avel == Vector3.ZERO:
				continue
			_update_support(b)
		for b in balls:
			if b.state != PoolBall.AIRBORNE or b.vel.y >= 0.0:
				continue
			# Nothing underneath means nothing to land on: the ball is going
			# over the side and should carry on going.
			if b.ground_y == PoolTable.NO_SURFACE:
				continue
			if b.phase_left <= 1.0e-9 or b.pos.y <= b.rest_y():
				_resolve_landing(b)

		_check_off_table()
		for b in balls:
			if b.state == PoolBall.STATIONARY and b.vel == Vector3.ZERO \
					and b.avel == Vector3.ZERO:
				continue
			b.begin_phase()
			_cap_phase_at_ledge(b)


## What is underneath this ball right now.
##
## A ball in flight is given the highest surface it is still above, so it lands on
## the rail if that is where its trajectory takes it, and on the cloth otherwise.
## If there is nothing under it -- out past the woodwork, or over a pocket -- it
## simply keeps falling, which is what makes a ball that is genuinely going over
## the side go over the side instead of being caught by the rail.
func _update_support(b: PoolBall) -> void:
	if not b.is_active():
		return
	var here := table.surface_height(Vector2(b.pos.x, b.pos.z))
	if here == PoolTable.NO_SURFACE:
		b.ground_y = PoolTable.NO_SURFACE
		return
	# Never "support" a ball from above: a ball below the rail top that is over the
	# rail footprint is passing the cushion, not standing on the wood.
	if b.pos.y < here + PoolPhys.BALL_R - 1.0e-4:
		b.ground_y = 0.0 if here > 0.0 else here
		return
	b.ground_y = here


## A ball rolling along the rail has to fall off when it runs out of rail. The
## plateau edges and the pocket openings are all straight lines, so the crossing
## time is a quadratic -- the same machinery the cushions use.
func _cap_phase_at_ledge(b: PoolBall) -> void:
	if not b.is_moving() or b.ground_y <= 0.0 or b.state == PoolBall.AIRBORNE:
		return
	var t := table.time_leaving_rail(b.pos, b.vel, b.acc, b.phase_left)
	if t < b.phase_left:
		b.phase_left = t


## Put a ball back in play. Must be used instead of PoolBall.place() for a ball
## that may have been pocketed, otherwise it stays in the drop integrator and
## gravity keeps dragging it down through the table while the player positions it.
func return_to_table(b: PoolBall, pos: Vector3) -> void:
	falling.erase(b)
	b.falling = false
	b.place(pos)


## Is a ball centred here clear of every other ball on the table?
func spot_clear(p: Vector2, moving: PoolBall) -> bool:
	for b in balls:
		if b == moving or not b.is_active():
			continue
		if p.distance_to(Vector2(b.pos.x, b.pos.z)) < PoolPhys.BALL_D + 0.0005:
			return false
	return true


## The nearest legal, unoccupied centre to `target`, spiralling outward.
##
## Lives here rather than with either rule set because both of them respot balls
## and so does the CPU planner, which has to land them in exactly the same place
## the game will or it is judging a table it will not get.
func free_spot(target: Vector2, moving: PoolBall) -> Vector2:
	var best := table.nearest_legal_center(target)
	if spot_clear(best, moving):
		return best
	for ring in range(1, 80):
		var r := 0.006 * float(ring)
		for k in range(20):
			var ang := TAU * float(k) / 20.0 + float(ring) * 0.31
			var q := target + Vector2(cos(ang), sin(ang)) * r
			if table.is_legal_center(q) and spot_clear(q, moving):
				return q
	return best


## The shot is over only once nothing is moving on the table *and* every ball that
## went into a pocket has finished falling. Waiting for the drops matters: a ball
## can bounce back out of a pocket, and the rules have to see that before they
## judge the shot.
func is_shot_over() -> bool:
	return settled() and falling.is_empty()


## Abandon a shot that will not settle. Everything stops where it is and the
## rules engines see a timeout entry, which they treat as a foul.
func force_stop(reason := "timeout") -> void:
	for b in balls:
		if not b.is_active():
			continue
		b.vel = Vector3.ZERO
		b.avel = Vector3.ZERO
		b.pos.y = b.rest_y()
		b.begin_phase()
	# Balls part-way down a pocket are not "in play" and so are not stopped by the
	# loop above, but they are what `is_shot_over` is still waiting on. Drop them
	# the rest of the way. Without this the abandoned shot never ends either, and
	# the turn hangs on a ball nobody is watching any more.
	for b in falling:
		b.vel = Vector3.ZERO
		b.avel = Vector3.ZERO
		b.pos.y = -PoolPhys.POCKET_DEPTH + PoolPhys.BALL_R
		b.falling = false
	falling.clear()
	shot_log.append({"type": reason, "t": shot_time, "a": -1})


## Speed of the fastest ball still in play, for end-of-shot pacing.
func peak_speed() -> float:
	var s := 0.0
	for b in balls:
		if b.is_moving():
			s = maxf(s, b.vel.length())
	return s


## Convenience for tests and headless analysis.
func simulate_to_rest(max_time := 60.0) -> float:
	var t := 0.0
	while not settled() and t < max_time:
		advance(0.05)
		t += 0.05
	return t


# ---------------------------------------------------------------------------
# Event search
# ---------------------------------------------------------------------------

func _find_next_event(cap: float) -> void:
	_ev_t = cap
	_ev_type = EV_NONE
	_ev_a = -1
	_ev_b = -1

	var n := balls.size()

	# Phase boundaries. Stepping past one would invalidate the closed-form
	# solution, so they are first-class events even when nothing collides.
	for i in range(n):
		var b := balls[i]
		if b.is_moving() and b.phase_left < _ev_t:
			_ev_t = maxf(b.phase_left, 0.0)
			_ev_type = EV_PHASE
			_ev_a = i
			_ev_b = -1

	var contact_d := PoolPhys.BALL_D    # centre distance at which two balls touch

	# Ball-ball.
	for i in range(n):
		var a := balls[i]
		if not a.is_active():
			continue
		var travel_a := a.max_travel(_ev_t)
		for j in range(i + 1, n):
			var b := balls[j]
			if not b.is_active():
				continue
			if a.state == PoolBall.STATIONARY and b.state == PoolBall.STATIONARY:
				continue
			var dp := b.pos - a.pos
			var dist := dp.length()
			# Conservative reachability test: skip the quartic entirely unless
			# the pair could possibly close the gap inside the window.
			if dist - contact_d > travel_a + b.max_travel(_ev_t):
				continue
			var dv := b.vel - a.vel
			if dist < contact_d - 1.0e-9:
				# Already interpenetrating (only reachable through round-off or
				# a bad initial placement): resolve immediately if closing.
				if dv.dot(dp) < 0.0:
					_ev_t = 0.0
					_ev_type = EV_BALL
					_ev_a = i
					_ev_b = j
				continue
			var da := (b.acc - a.acc) * 0.5
			var t := PoolRoots.quartic_smallest(
				da.dot(da),
				2.0 * da.dot(dv),
				dv.dot(dv) + 2.0 * da.dot(dp),
				2.0 * dv.dot(dp),
				dp.dot(dp) - contact_d * contact_d,
				0.0, _ev_t)
			if t < _ev_t:
				_ev_t = t
				_ev_type = EV_BALL
				_ev_a = i
				_ev_b = j

	# Ball vs. table geometry. Only moving balls can initiate these.
	for i in range(n):
		var a := balls[i]
		if not a.is_moving():
			continue
		_scan_cushions(i, a)
		_scan_jaws(i, a)
		_scan_pockets(i, a)


func _scan_cushions(i: int, a: PoolBall) -> void:
	var travel := a.max_travel(_ev_t)
	for ci in range(table.cushions.size()):
		var c: PoolTable.Cushion = table.cushions[ci]
		var n3 := Vector3(c.normal.x, 0.0, c.normal.y)
		var a3 := Vector3(c.a.x, 0.0, c.a.y)
		# A cushion is only ever struck from the playing side. Without this a ball
		# sitting out on the rail counts as deeply penetrating every cushion it is
		# behind, and gets slapped straight back onto the table.
		#
		# The threshold is a full radius, not zero: a ball resting on the wood is
		# clearly outside, but a ball that a hard impact has left a hair past the
		# nose line is still in contact with the cushion and must still bounce.
		# At zero, a 60 m/s impact could leave the ball fractionally outside and it
		# would then ignore that cushion for good and sail off the table.
		var inside := (a.pos - a3).dot(n3)
		if inside < -PoolPhys.BALL_R:
			continue
		# Signed gap between the ball surface and the cushion face.
		var d0 := inside - PoolPhys.BALL_R
		if d0 > travel:
			continue
		var d1 := a.vel.dot(n3)
		var d2 := 0.5 * a.acc.dot(n3)

		var t := INF
		if d0 <= 0.0:
			if d1 < 0.0:
				t = 0.0
		else:
			t = PoolRoots.quadratic_smallest(d2, d1, d0, 0.0, _ev_t)
		if t >= _ev_t:
			continue

		# The contact must land on this run of cushion, and the ball must not be
		# flying over the top of it.
		var p := a.pos + a.vel * t + a.acc * (0.5 * t * t)
		# The cushion body runs all the way up to the rail surface, so anything
		# below that height is still hitting it; only a ball clearing the plateau
		# passes over.
		if p.y > PoolPhys.RAIL_TOP + PoolPhys.BALL_R:
			continue
		var s := (Vector2(p.x, p.z) - c.a).dot(c.tangent)
		if s < 0.0 or s > c.length:
			continue

		_ev_t = t
		_ev_type = EV_CUSHION
		_ev_a = i
		_ev_b = ci


func _scan_jaws(i: int, a: PoolBall) -> void:
	# A ball up on the rail is above the jaws, not rattling between them.
	if a.ground_y > 0.0:
		return
	var travel := a.max_travel(_ev_t)
	for ji in range(table.jaws.size()):
		var j: PoolTable.Jaw = table.jaws[ji]
		var target := PoolPhys.BALL_R + j.radius
		var dp := Vector2(a.pos.x - j.center.x, a.pos.z - j.center.y)
		var dist := dp.length()
		if dist - target > travel:
			continue
		var dv := Vector2(a.vel.x, a.vel.z)
		var t := INF
		if dist < target - 1.0e-9:
			if dv.dot(dp) < 0.0:
				t = 0.0
		else:
			var da := Vector2(a.acc.x, a.acc.z) * 0.5
			t = PoolRoots.quartic_smallest(
				da.dot(da),
				2.0 * da.dot(dv),
				dv.dot(dv) + 2.0 * da.dot(dp),
				2.0 * dv.dot(dp),
				dp.dot(dp) - target * target,
				0.0, _ev_t)
		if t >= _ev_t:
			continue
		var y := a.pos.y + a.vel.y * t + 0.5 * a.acc.y * t * t
		if y > PoolPhys.RAIL_TOP + PoolPhys.BALL_R:
			continue
		_ev_t = t
		_ev_type = EV_JAW
		_ev_a = i
		_ev_b = ji


## A ball drops when its centre passes the pocket's drop line. That line is
## straight -- it is the mouth between two cushion noses, offset outward by the
## shelf -- so the crossing time is a plain quadratic, and the test can never
## reach back into the playing surface the way a circular pocket does.
func _scan_pockets(i: int, a: PoolBall) -> void:
	var travel := a.max_travel(_ev_t)
	for pi in range(table.pockets.size()):
		var pk: PoolTable.Pocket = table.pockets[pi]
		var n3 := Vector3(pk.normal.x, 0.0, pk.normal.y)
		var m3 := Vector3(pk.mouth.x, 0.0, pk.mouth.y)
		# Signed distance still to travel before the centre is unsupported.
		var d0 := (m3 - a.pos).dot(n3)
		if d0 > travel:
			continue
		var t := INF
		if d0 <= 0.0:
			t = 0.0
		else:
			t = PoolRoots.quadratic_smallest(
				-0.5 * a.acc.dot(n3), -a.vel.dot(n3), d0, 0.0, _ev_t)
		if t >= _ev_t:
			continue
		var p := a.pos + a.vel * t + a.acc * (0.5 * t * t)
		# A ball flying over a pocket does not drop in, and neither does one that
		# crossed the drop line's *extension* rather than the mouth itself.
		if p.y > PoolPhys.BALL_R + 0.03:
			continue
		# The tolerance matters: the capture time is the instant the centre reaches
		# the drop line, so the depth there is exactly zero. A strict test rejects
		# its own crossing, and the ball sails straight through the pocket.
		if not pk.over_opening(Vector2(p.x, p.z), 1.0e-6):
			continue
		_ev_t = t
		_ev_type = EV_POCKET
		_ev_a = i
		_ev_b = pi


# ---------------------------------------------------------------------------
# Impulse resolution
# ---------------------------------------------------------------------------

## Ball-ball. Nearly elastic along the line of centres; Coulomb-limited across
## it. The tangential impulse is what produces throw: a cut shot drags the
## object ball slightly off the line of centres, and side spin on the cue ball
## transfers as spin (and a small push) to the object ball.
##
## The impulse needed to kill tangential slip between two equal spheres is
## m|u_t|/7, from  du_t = 2 J (1/m + R^2/I) = 7J/m.
func _resolve_ball_ball(a: PoolBall, b: PoolBall) -> void:
	var n := b.pos - a.pos
	var dist := n.length()
	if dist < 1.0e-12:
		return
	n /= dist

	# A ball can come down and sit on top of another. Nothing in the support model
	# holds it there -- that knows about the cloth and the rail, not other balls --
	# so left alone it bounces with ever-decreasing energy and the solver grinds to
	# a halt on zero-length contacts.
	#
	# Once the contact is slow and near-vertical it is treated as resting: the
	# closing speed is removed rather than bounced, and the upper ball is given the
	# topple it would really get, in whichever direction it is already leaning. It
	# stays where it landed and rolls off from there -- no teleporting.
	if absf(n.y) > 0.7 and absf((a.vel - b.vel).dot(n)) < REST_CONTACT_SPEED:
		var upper: PoolBall = b if n.y > 0.0 else a
		var lower: PoolBall = a if n.y > 0.0 else b
		var closing := (a.vel - b.vel).dot(n)
		a.vel -= n * closing * 0.5
		b.vel += n * closing * 0.5
		# It topples the way it is already off-centre; dead-centre picks a side.
		var lean := Vector3(upper.pos.x - lower.pos.x, 0.0, upper.pos.z - lower.pos.z)
		if lean.length() < 1.0e-4:
			lean = Vector3(1.0, 0.0, 0.0).rotated(Vector3.UP,
				rng.randf_range(0.0, TAU))
		# Set, never accumulate: this contact can be detected many times while the
		# ball settles, and adding the topple each time injects energy without
		# bound and keeps generating fresh contacts.
		var topple := lean.normalized() * ROLL_OFF_SPEED
		var horiz := Vector3(upper.vel.x, 0.0, upper.vel.z)
		if horiz.length() < ROLL_OFF_SPEED:
			upper.vel = Vector3(topple.x, upper.vel.y, topple.z)
		upper.avel *= 0.85
		if dist < PoolPhys.BALL_D:
			var push := (PoolPhys.BALL_D - dist) * 0.5 + 1.0e-9
			a.pos -= n * push
			b.pos += n * push
		return

	var vn := (a.vel - b.vel).dot(n)

	# Two balls touching and barely closing are resting against each other, not
	# colliding. An elastic impulse computed from a near-zero closing speed is
	# itself near zero, so the pair stays in contact and the solver re-detects the
	# same contact on the next event, forever -- which is how a quiet corner of the
	# table could burn the whole event budget. Take the closing speed out outright
	# and push them properly apart instead.
	if vn > 0.0 and vn < CONTACT_REST_SPEED:
		a.vel -= n * (vn * 0.5)
		b.vel += n * (vn * 0.5)
		var gap := PoolPhys.BALL_D - dist
		if gap > 0.0:
			var nudge := gap * 0.5 + SEPARATION_EPS
			a.pos -= n * nudge
			b.pos += n * nudge
		return

	if vn > 0.0:
		var m := PoolPhys.BALL_M
		var rad := PoolPhys.BALL_R
		var jn := 0.5 * (1.0 + PoolPhys.E_BALL) * vn * m

		var uc := (a.vel + a.avel.cross(n * rad)) - (b.vel + b.avel.cross(-n * rad))
		var ut := uc - uc.dot(n) * n
		var utl := ut.length()
		var jt := 0.0
		var th := Vector3.ZERO
		if utl > 1.0e-9:
			th = ut / utl
			jt = minf(PoolPhys.MU_BALL * jn, m * utl / 7.0)

		var imp := -jn * n - jt * th          # on a; -imp on b
		a.vel += imp / m
		b.vel -= imp / m
		var torque := (n * rad).cross(-jt * th) / PoolPhys.INERTIA
		a.avel += torque
		b.avel += torque

		# Positions and outgoing velocities are recorded at the exact contact
		# instant. The aim guide reads these rather than sampling the trajectory,
		# which is the difference between a guide that is right to the millimetre
		# and one that is right to whatever the step size happened to be.
		shot_log.append({
			"type": "ball", "t": shot_time, "a": a.number, "b": b.number, "speed": vn,
			"pos_a": a.pos, "pos_b": b.pos, "vel_a": a.vel, "vel_b": b.vel,
		})
		if record_sound:
			sound_queue.append({
				"kind": "ball", "strength": vn,
				"pos": a.pos + n * rad,
			})

	# Positional cleanup so the pair never starts the next phase overlapping. The
	# margin is 10 micrometres rather than a nanometre: single-precision positions
	# round a nanometre straight back into contact, and the pair starts ringing.
	if dist < PoolPhys.BALL_D:
		var push := (PoolPhys.BALL_D - dist) * 0.5 + SEPARATION_EPS
		a.pos -= n * push
		b.pos += n * push


func _resolve_cushion_run(b: PoolBall, c: PoolTable.Cushion) -> void:
	_cushion_impulse(b, Vector3(c.normal.x, 0.0, c.normal.y))
	# De-penetrate along the face normal.
	var a3 := Vector3(c.a.x, 0.0, c.a.y)
	var n3 := Vector3(c.normal.x, 0.0, c.normal.y)
	var pen := PoolPhys.BALL_R - (b.pos - a3).dot(n3)
	if pen > -SEPARATION_EPS:
		b.pos += n3 * (pen + SEPARATION_EPS)


func _resolve_jaw(b: PoolBall, j: PoolTable.Jaw) -> void:
	var d := Vector2(b.pos.x - j.center.x, b.pos.z - j.center.y)
	var dl := d.length()
	if dl < 1.0e-9:
		return
	var n2 := d / dl
	_cushion_impulse(b, Vector3(n2.x, 0.0, n2.y))
	# Separated by a definite margin, not de-penetrated to exactly touching --
	# see SEPARATION_EPS for what resting on that distance costs.
	var target := PoolPhys.BALL_R + j.radius + SEPARATION_EPS
	if dl < target:
		b.pos += Vector3(n2.x, 0.0, n2.y) * (target - dl)


## Shared cushion impulse. `n` is the inward horizontal normal.
##
## The cushion nose sits CUSHION_HEIGHT above the cloth, i.e. above the ball's
## equator, so the true contact normal is tilted downward by
## asin((h - R)/R) ~ 15.7 degrees. Everything realistic about rail play falls
## out of that tilt plus Coulomb friction at the contact:
##   * apparent normal restitution at the centre drops from 0.85 to ~0.72;
##   * a rolling ball picks up extra topspin off the rail;
##   * running english lengthens the rebound angle, reverse english shortens it;
##   * balls hop a millimetre or two off a hard rail, which is real.
func _cushion_impulse(b: PoolBall, n: Vector3) -> void:
	var rad := PoolPhys.BALL_R
	var sin_t := (PoolPhys.CUSHION_HEIGHT - rad) / rad
	var cos_t := sqrt(maxf(1.0 - sin_t * sin_t, 0.0))
	var nrm := n * cos_t - Vector3.UP * sin_t     # unit contact normal
	var rc := -rad * nrm                          # centre -> contact point

	var uc := b.vel + b.avel.cross(rc)
	var un := uc.dot(nrm)
	if un >= 0.0:
		return
	var m := PoolPhys.BALL_M
	var jn := -(1.0 + PoolPhys.E_CUSHION) * m * un

	var ut := uc - un * nrm
	var utl := ut.length()
	var jt := 0.0
	var th := Vector3.ZERO
	if utl > 1.0e-9:
		th = ut / utl
		jt = minf(PoolPhys.MU_CUSHION * jn, 2.0 * m * utl / 7.0)

	var imp := jn * nrm - jt * th
	var vy_before := b.vel.y
	b.vel += imp / m
	b.avel += rc.cross(imp) / PoolPhys.INERTIA

	# The slate reacts the vertical part of the rail impulse -- see
	# CUSHION_VERTICAL_KICK. The bound is symmetric: capping only the upward
	# direction leaves the ball being driven hard downward instead, which the
	# cloth bounce then converts back into a launch.
	var kick: float = minf(PoolPhys.CUSHION_VERTICAL_KICK * absf(un),
		PoolPhys.CUSHION_KICK_MAX)
	b.vel.y = clampf(b.vel.y, vy_before - kick, vy_before + kick)
	if b.pos.y <= b.rest_y() + 1.0e-6 and b.vel.y < 0.0:
		b.vel.y = 0.0

	if debug_cushion:
		print("    [cushion] un=%.3f jn/m=%.3f jt/m=%.3f  imp/m=%v" % [
			un, jn / m, jt / m, imp / m])
		print("    [cushion] vy %.4f -> %.4f (kick cap %.4f)  state=%d posy=%.5f" % [
			vy_before, b.vel.y, kick, b.state, b.pos.y])

	shot_log.append({"type": "cushion", "t": shot_time, "a": b.number, "speed": absf(un)})
	if record_sound:
		sound_queue.append({"kind": "cushion", "strength": absf(un), "pos": b.pos})


func _resolve_landing(b: PoolBall) -> void:
	var rad := PoolPhys.BALL_R
	var vy := b.vel.y
	b.pos.y = b.rest_y()
	var m := PoolPhys.BALL_M

	if absf(vy) < PoolPhys.BOUNCE_EPS:
		b.vel.y = 0.0
	else:
		b.vel.y = -vy * PoolPhys.E_CLOTH
		if record_sound:
			sound_queue.append({"kind": "cloth", "strength": absf(vy), "pos": b.pos})

	# Friction during the impact bites on the slip at the contact point, which
	# is what makes a jumped ball land and grab rather than skate.
	var jn := (1.0 + PoolPhys.E_CLOTH) * m * absf(vy)
	var u := b.contact_slip()
	var ul := u.length()
	if ul > 1.0e-9 and jn > 0.0:
		var jt := minf(PoolPhys.MU_CLOTH * jn, 2.0 * m * ul / 7.0)
		var th := u / ul
		b.vel -= th * (jt / m)
		b.avel += Vector3(0.0, -rad, 0.0).cross(-th * jt) / PoolPhys.INERTIA


## The ball crosses the pocket's capture circle. It leaves the game immediately
## -- rules and collisions ignore it from here -- but it keeps its velocity and
## spin and is handed to the drop integrator, so it tips over the edge and falls
## in under gravity instead of teleporting.
func _capture(b: PoolBall, pk: PoolTable.Pocket) -> void:
	b.state = PoolBall.POCKETED
	b.pocket_id = pk.id
	b.falling = true
	b.fall_center = pk.cavity
	b.fall_radius = pk.cavity_radius
	b.fall_mouth = pk.mouth
	b.fall_normal = pk.normal
	falling.append(b)
	shot_log.append({"type": "pocket", "t": shot_time, "a": b.number, "pocket": pk.id})
	if record_sound:
		sound_queue.append({
			"kind": "pocket", "strength": b.vel.length(),
			"pos": Vector3(pk.mouth.x, 0.0, pk.mouth.y),
		})


## Integrate balls that are inside a pocket. Called every frame regardless of
## whether the shot itself is still live, so a drop always finishes.
##
## While the centre is still above the cloth plane the ball is in free fall over
## the opening with nothing to touch; once it is fully below, the liner wall and
## the bottom of the channel come into play.
func advance_drops(dt: float) -> void:
	if falling.is_empty():
		return
	var rad := PoolPhys.BALL_R
	var floor_y := -PoolPhys.POCKET_DEPTH + rad
	var sub := 1.0 / 480.0
	var left := dt
	while left > 0.0:
		var h: float = minf(sub, left)
		left -= h
		for i in range(falling.size() - 1, -1, -1):
			var b: PoolBall = falling[i]
			b.vel.y -= PoolPhys.G * h
			b.pos += b.vel * h
			b.clamp_spin()
			var wl := b.avel.length()
			if wl > 1.0e-6 and is_finite(wl):
				b.orient = (Quaternion(b.avel / wl, wl * h) * b.orient).normalized()

			# Above the cloth the ball is not in free fall: it is tipping over the
			# straight lip of the opening, pivoting on the nearest point of that
			# edge. That contact is what makes a ball hesitate on the brink and
			# roll in, rather than dropping like a stone the instant its centre
			# crosses the line.
			if b.pos.y > -rad:
				var past := Vector2(b.pos.x, b.pos.z).distance_to(b.fall_mouth)
				if past < 0.5:
					var along := (Vector2(b.pos.x, b.pos.z) - b.fall_mouth).dot(b.fall_normal)
					var lip := Vector3(
						b.pos.x - b.fall_normal.x * along, 0.0,
						b.pos.z - b.fall_normal.y * along)
					var off := b.pos - lip
					var od := off.length()
					if od < rad and od > 1.0e-9:
						var support := off / od
						b.pos = lip + support * rad
						var vn := b.vel.dot(support)
						if vn < 0.0:
							b.vel -= support * vn      # felt lip: no bounce
							b.avel *= 0.97

			# Liner wall, active from the moment the ball drops in -- not only once
			# it is below the cloth. A ball entering at 3 m/s takes about 100 ms to
			# fall its own diameter, and covers 30 cm horizontally in that time: far
			# enough to sail straight out the back of the pocket and off the table
			# before anything stopped it. The back of the pocket is a wall the whole
			# way down.
			if true:
				var d := Vector2(b.pos.x - b.fall_center.x, b.pos.z - b.fall_center.y)
				var lim := b.fall_radius - rad
				var dl := d.length()
				if lim > 0.0 and dl > lim:
					var out := d / dl
					b.pos.x = b.fall_center.x + out.x * lim
					b.pos.z = b.fall_center.y + out.y * lim
					var vh := Vector2(b.vel.x, b.vel.z)
					var vn := vh.dot(out)
					if vn > 0.0:
						vh -= out * vn * (1.0 + PoolPhys.E_POCKET_WALL)
						vh *= 0.92
						b.vel.x = vh.x
						b.vel.z = vh.y
						b.avel *= 0.85
						if record_sound:
							sound_queue.append({
								"kind": "cushion", "strength": absf(vn) * 0.5,
								"pos": b.pos})

			# Bounced back out over the lip: it was never really potted. Put it
			# back in play and let the rules call it a foul.
			if b.pos.y > -rad * 0.5 and b.vel.y >= 0.0 \
					and (Vector2(b.pos.x, b.pos.z) - b.fall_mouth).dot(b.fall_normal) < 0.0:
				b.falling = false
				b.state = PoolBall.STATIONARY
				b.pocket_id = -1
				b.pos.y = rad
				b.vel = Vector3.ZERO
				b.avel = Vector3.ZERO
				b.begin_phase()
				falling.remove_at(i)
				shot_log.append({"type": "escaped_pocket", "t": shot_time, "a": b.number})
				if record_sound:
					sound_queue.append({"kind": "cloth", "strength": 0.6, "pos": b.pos})
				continue

			if b.pos.y <= floor_y:
				b.pos.y = floor_y
				if b.vel.y < 0.0:
					b.vel.y = -b.vel.y * PoolPhys.E_POCKET_FLOOR
				b.vel.x *= 0.80
				b.vel.z *= 0.80
				b.avel *= 0.80
				if b.vel.length() < 0.10:
					b.vel = Vector3.ZERO
					b.avel = Vector3.ZERO
					b.falling = false
					falling.remove_at(i)


func _check_off_table() -> void:
	# Measured from the outside of the woodwork, not the cushion line: a ball on
	# the rail is still on the table.
	var xl := table.rail_outer_x() + OFF_TABLE_MARGIN
	var zl := table.rail_outer_z() + OFF_TABLE_MARGIN
	for b in balls:
		if not b.is_active():
			continue
		if absf(b.pos.x) > xl or absf(b.pos.z) > zl or b.pos.y < -0.02:
			b.state = PoolBall.OFF_TABLE
			b.vel = Vector3.ZERO
			b.avel = Vector3.ZERO
			shot_log.append({"type": "off_table", "t": shot_time, "a": b.number})


# ---------------------------------------------------------------------------
# Cue strike
# ---------------------------------------------------------------------------

## Strike `b` with a cue of mass CUE_M travelling at `speed` along horizontal
## direction `aim`, elevated by `elev` radians, with the tip offset from centre
## by (side, vert) in units of the ball radius.
##
## Impulse magnitude follows from a 1-D collision against the ball's *effective*
## mass for an off-centre hit, 1/m_eff = 1/m + d^2/I with d the perpendicular
## distance from the centre to the cue axis:
##
##     J = (1 + e) M V / (1 + M/m_eff)  =  2 m V / (1 + m/M + 5 d^2 / 2R^2)
##
## which is why extreme english costs you speed. Angular velocity comes from the
## same impulse acting at the tip contact point.
## `p_rng` supplies the miscue scatter. Passing one makes the stroke reproducible
## from its arguments, which is what networked play and the replay tests need;
## omitting it falls back to the global generator.
static func cue_strike(b: PoolBall, aim: Vector3, speed: float, side: float, vert: float,
		elev: float, deterministic := false, jump_elev := -1.0,
		p_rng: RandomNumberGenerator = null) -> void:
	var rad := PoolPhys.BALL_R
	var m := PoolPhys.BALL_M

	# The tip can be placed out to MISCUE_LIMIT, but past MAX_TIP_OFFSET it starts
	# to slip off the ball: less of the stroke is delivered and the contact wanders
	# off line. That is what makes aiming very low to chip the ball possible, and
	# appropriately unreliable, instead of running into an invisible wall.
	var off := Vector2(side, vert)
	if off.length() > PoolPhys.MISCUE_LIMIT:
		off = off.normalized() * PoolPhys.MISCUE_LIMIT
	var miscue := 0.0
	if off.length() > PoolPhys.MAX_TIP_OFFSET:
		miscue = (off.length() - PoolPhys.MAX_TIP_OFFSET) \
			/ (PoolPhys.MISCUE_LIMIT - PoolPhys.MAX_TIP_OFFSET)

	var dir := Vector3(aim.x, 0.0, aim.z).normalized()
	# Squirt: side spin deflects the cue ball away from the english.
	if absf(off.x) > 1.0e-6:
		dir = dir.rotated(Vector3.UP, deg_to_rad(PoolPhys.SQUIRT_DEG) * off.x)
	if miscue > 0.0 and not deterministic:
		var scatter: float = p_rng.randf_range(-1.0, 1.0) if p_rng != null \
			else randf_range(-1.0, 1.0)
		dir = dir.rotated(Vector3.UP, deg_to_rad(
			scatter * PoolPhys.MISCUE_SCATTER_DEG * miscue))

	# Cue-aligned orthonormal frame: c = cue axis, r = right, p = up-in-plane.
	var right := dir.cross(Vector3.UP).normalized()
	var c_axis := (dir * cos(elev) - Vector3.UP * sin(elev)).normalized()
	var p_axis := right.cross(c_axis).normalized()

	var a_m := off.x * rad
	var b_m := off.y * rad
	var back := sqrt(maxf(rad * rad - a_m * a_m - b_m * b_m, 0.0))
	var rc := right * a_m + p_axis * b_m - c_axis * back   # centre -> tip contact

	var d2 := a_m * a_m + b_m * b_m                        # squared moment arm
	var denom := 1.0 + m / PoolPhys.CUE_M + 2.5 * d2 / (rad * rad)
	var j := (1.0 + PoolPhys.CUE_E) * m * speed / denom
	j *= lerpf(1.0, PoolPhys.MISCUE_POWER_FLOOR, miscue)

	# Which way the blow actually goes. A tip that has got under the ball slips
	# against the surface, so some of the impulse follows the contact normal -- up
	# and forward for a low hit -- rather than the line of the shaft. That is what
	# lets a level cue scoop the ball into the air, and it is why the scoop is a
	# foul stroke rather than an impossible one.
	var strike_dir := c_axis
	# Driven by how far *under* the ball the tip is, not by the total offset: a
	# side hit at the same distance from centre does not scoop, it squirts, and
	# keying this off the offset magnitude quietly tripled the squirt angle.
	var under: float = maxf(-off.y, 0.0)
	if under > PoolPhys.SCOOP_START:
		var scoop: float = PoolPhys.SCOOP_MAX * clampf(
			(under - PoolPhys.SCOOP_START)
			/ (PoolPhys.MISCUE_LIMIT - PoolPhys.SCOOP_START), 0.0, 1.0)
		strike_dir = c_axis.lerp(-rc.normalized(), scoop).normalized()

	b.vel += strike_dir * (j / m)
	b.avel += rc.cross(strike_dir * j) / PoolPhys.INERTIA

	# An elevated cue drives the ball downward into the slate, and the rebound is
	# what launches a jump. `jump_elev` is the elevation the player actually asked
	# for: the extra tilt the cue takes to clear a rail behind the shot does not
	# count, or a level cue would chip the ball just by standing near a cushion.
	var deliberate: float = elev if jump_elev < 0.0 else jump_elev
	if deliberate >= PoolPhys.JUMP_MIN_ELEV \
			and b.pos.y <= b.rest_y() + 1.0e-6 and b.vel.y < -PoolPhys.CUE_JUMP_MIN:
		b.vel.y = -b.vel.y * PoolPhys.CUE_JUMP_E

	b.begin_phase()


# ---------------------------------------------------------------------------
# Aiming support
# ---------------------------------------------------------------------------

## Snapshot of every ball, for running a throwaway copy of a shot.
##
## The default budget is the aim guide's, which is deliberately tiny -- it runs
## every frame and only cares about the first contact. The CPU player passes a
## full one, because it has to play the shot out to the last ball stopping to
## know whether it worked.
func clone_for_prediction(budget := PREDICT_EVENT_BUDGET) -> PoolSim:
	var copy := PoolSim.new(table)
	copy.max_events = budget
	copy.quiet = true
	copy.record_sound = false
	for b in balls:
		var c := PoolBall.new(b.id, b.number)
		c.pos = b.pos
		c.vel = b.vel
		c.avel = b.avel
		c.state = b.state
		c.pocket_id = b.pocket_id
		# Must be carried over: a ball resting on the rail that is cloned as though
		# it were on the cloth starts the trace airborne and falls.
		c.ground_y = b.ground_y
		c.begin_phase()
		copy.add_ball(c)
	copy.begin_shot()
	return copy


## Trace what the cue ball is *actually* going to do, by simulating the shot on a
## throwaway copy of the table and recording the path.
##
## This replaces drawing a straight line along the aim. A straight line is a lie
## whenever there is side spin on the ball: squirt launches the cue ball a few
## degrees off the cue's line, and an elevated cue makes it swerve as the spin
## bites into the cloth. The guide used to promise contacts that never happened
## for exactly that reason. Tracing the real thing costs a fraction of a
## millisecond, and it draws the curve too.
##
## Stops at the first ball the cue ball touches, or when `max_time` runs out.
func predict_cue_path(aim: Vector3, speed: float, side: float, vert: float,
		elev: float, max_time := 0.7, jump_elev := -1.0) -> Dictionary:
	var out := {
		"path": PackedVector3Array(),
		"hit_number": -1,
		"contact": Vector3.ZERO,
		"object_dir": Vector3.ZERO,
		"cue_dir_after": Vector3.ZERO,
		"object_at": Vector3.ZERO,
	}
	if cue == null:
		return out

	var scratch := clone_for_prediction()
	if scratch.cue == null:
		return out
	# Deterministic: a guide that jitters with the miscue dice is useless.
	cue_strike(scratch.cue, aim, speed, side, vert, elev, true, jump_elev)

	# The event solver is exact at any step size, so this only controls how finely
	# the path is sampled -- and how many advance() calls the trace costs, which is
	# what dominates its runtime. Each call sweeps every ball for candidate events,
	# so halving the step count roughly halves the cost of the guide.
	var step := 1.0 / 80.0
	var sample := 0.0
	var t := 0.0
	var travelled := 0.0
	var cushions := 0
	var last := scratch.cue.pos
	out["path"].append(scratch.cue.pos)
	while t < max_time and travelled < 2.4:
		var before := scratch.shot_log.size()
		scratch.advance(step)
		t += step
		sample += step

		for k in range(before, scratch.shot_log.size()):
			var e: Dictionary = scratch.shot_log[k]
			if e["type"] == "cushion":
				cushions += 1
			if e["type"] != "ball" or (e["a"] != 0 and e["b"] != 0):
				continue
			var cue_is_a: bool = e["a"] == 0
			out["hit_number"] = e["b"] if cue_is_a else e["a"]
			out["contact"] = e["pos_a"] if cue_is_a else e["pos_b"]
			out["object_at"] = e["pos_b"] if cue_is_a else e["pos_a"]
			out["path"].append(out["contact"])
			var cue_v: Vector3 = e["vel_a"] if cue_is_a else e["vel_b"]
			var obj_v: Vector3 = e["vel_b"] if cue_is_a else e["vel_a"]
			out["cue_dir_after"] = cue_v.normalized()
			out["object_dir"] = obj_v.normalized()
			return out

		travelled += scratch.cue.pos.distance_to(last)
		last = scratch.cue.pos
		if sample >= 0.020:
			sample = 0.0
			out["path"].append(scratch.cue.pos)
		# Out of budget, or far enough: draw what we have rather than keep grinding.
		if scratch.overflowed or scratch.event_count > PREDICT_TOTAL_EVENTS:
			break
		if cushions >= PREDICT_MAX_CUSHIONS:
			break
		if not scratch.cue.is_active() or scratch.settled():
			break
	out["path"].append(scratch.cue.pos)
	return out

## Trace a straight line from `from` along `dir` and report the first thing the
## cue ball would touch. Used to draw the ghost ball and tangent lines. This is
## a geometric query only -- it deliberately ignores spin curve and cushion
## angles, exactly like a real player's sight line.
func predict_first_hit(from: Vector3, dir: Vector3) -> Dictionary:
	var d := Vector3(dir.x, 0.0, dir.z).normalized()
	var origin := Vector3(from.x, PoolPhys.BALL_R, from.z)
	var best := INF
	var result := {"kind": "none", "distance": INF, "point": origin,
		"ball_ref": null, "normal": Vector3.ZERO}

	for b in balls:
		if b == cue or not b.is_active():
			continue
		var rel := Vector3(b.pos.x - origin.x, 0.0, b.pos.z - origin.z)
		var proj := rel.dot(d)
		if proj <= 0.0:
			continue
		var perp2 := rel.length_squared() - proj * proj
		var rr := PoolPhys.BALL_D
		if perp2 > rr * rr:
			continue
		var t := proj - sqrt(rr * rr - perp2)
		if t < 0.0 or t >= best:
			continue
		best = t
		result = {
			"kind": "ball", "distance": t, "point": origin + d * t, "ball_ref": b,
			"normal": (Vector3(b.pos.x, PoolPhys.BALL_R, b.pos.z)
				- (origin + d * t)).normalized(),
		}

	for c in table.cushions:
		var n3 := Vector3(c.normal.x, 0.0, c.normal.y)
		var denom := d.dot(n3)
		if denom >= -1.0e-9:
			continue
		var a3 := Vector3(c.a.x, PoolPhys.BALL_R, c.a.y)
		var t := ((a3 - origin).dot(n3) + PoolPhys.BALL_R) / denom
		if t < 0.0 or t >= best:
			continue
		var p := origin + d * t
		var s := (Vector2(p.x, p.z) - c.a).dot(c.tangent)
		if s < 0.0 or s > c.length:
			continue
		best = t
		result = {"kind": "cushion", "distance": t, "point": p, "ball_ref": null,
			"normal": n3}

	for pk in table.pockets:
		var n3 := Vector3(pk.normal.x, 0.0, pk.normal.y)
		var denom := d.dot(n3)
		if denom <= 1.0e-9:
			continue
		var m3 := Vector3(pk.mouth.x, PoolPhys.BALL_R, pk.mouth.y)
		var t := (m3 - origin).dot(n3) / denom
		if t < 0.0 or t >= best:
			continue
		best = t
		result = {"kind": "pocket", "distance": t, "point": origin + d * t,
			"ball_ref": null, "normal": n3}

	return result
