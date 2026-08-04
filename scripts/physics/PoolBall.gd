class_name PoolBall
extends RefCounted

## State of one billiard ball, plus the analytic solution of its current motion
## phase.
##
## The key insight that makes exact simulation possible: on the cloth a ball is
## always in one of four regimes, and in every one of them the linear and
## angular accelerations are *constant*. So within a phase,
##
##     p(t) = p0 + v0 t + 1/2 a t^2      v(t) = v0 + a t      w(t) = w0 + alpha t
##
## exactly -- no integration error, and positions are polynomials we can solve
## against each other for collision times.

enum {
	STATIONARY,
	SLIDING,   # contact point skids on the cloth
	ROLLING,   # rolls without slipping, losing speed to rolling resistance
	SPINNING,  # centre at rest, still spinning about the vertical axis
	AIRBORNE,  # free flight (hop off a cushion, or a jump shot)
	POCKETED,
	OFF_TABLE,
}

var id := 0
var number := 0                       # 0 = cue ball

var pos := Vector3.ZERO               # centre of mass, metres
var vel := Vector3.ZERO               # m/s
var avel := Vector3.ZERO              # rad/s
var orient := Quaternion.IDENTITY     # visual only

var state := STATIONARY
var pocket_id := -1

## Height of the surface this ball is supported by: 0 on the cloth, RAIL_TOP when
## it has landed on the rail. PoolSim keeps it up to date from the table; it stays
## 0 for a ball simulated on its own.
var ground_y := 0.0

## Set while the ball is physically falling through a pocket. It is already out
## of the game by then (is_active() is false), so this motion cannot affect the
## shot -- it just has to look right.
var fall_center := Vector2.ZERO
var fall_radius := 0.0
## The drop line the ball came in over, so it can tip on that edge as it falls.
var fall_mouth := Vector2.ZERO
var fall_normal := Vector2.ZERO
var falling := false

# Analytic solution of the current phase.
var acc := Vector3.ZERO
var aacc := Vector3.ZERO
var phase_left := INF


func _init(p_id: int = 0, p_number: int = 0) -> void:
	id = p_id
	number = p_number


func is_active() -> bool:
	return state != POCKETED and state != OFF_TABLE


func is_moving() -> bool:
	return state != STATIONARY and is_active()


## Height of the ball's centre when it is resting on whatever is under it.
func rest_y() -> float:
	return ground_y + PoolPhys.BALL_R


func place(p: Vector3) -> void:
	ground_y = 0.0
	pos = Vector3(p.x, PoolPhys.BALL_R, p.z)
	vel = Vector3.ZERO
	avel = Vector3.ZERO
	state = STATIONARY
	pocket_id = -1
	begin_phase()


## Velocity of the material point currently touching the cloth, horizontal part.
## u = v + w x (-R * y_hat)
func contact_slip() -> Vector3:
	return Vector3(
		vel.x + PoolPhys.BALL_R * avel.z,
		0.0,
		vel.z - PoolPhys.BALL_R * avel.x)


func speed_h() -> float:
	return sqrt(vel.x * vel.x + vel.z * vel.z)


## Classify the current instant and solve the phase that starts here.
##
## Sliding is the interesting case. With friction F = -mu m g u_hat acting at
## the contact point, the torque about the centre is R * mu m g (y_hat x u_hat),
## so
##     dv/dt = -mu g u_hat
##     dw/dt = (5 mu g / 2R) (y_hat x u_hat)
##     du/dt = dv/dt - R (dw/dt x y_hat) = -(7/2) mu g u_hat
##
## The slip *direction* is therefore invariant while sliding, which is what
## makes the phase closed-form, and slip dies after |u| / (7/2 mu g).
func begin_phase() -> void:
	if state == POCKETED or state == OFF_TABLE:
		acc = Vector3.ZERO
		aacc = Vector3.ZERO
		phase_left = INF
		return

	# Airborne: free flight until the centre falls back to resting height. The
	# LIFTOFF_EPS floor matters -- see the constant's comment.
	if pos.y > rest_y() + PoolPhys.AIR_EPS or vel.y > PoolPhys.LIFTOFF_EPS:
		state = AIRBORNE
		acc = Vector3(0.0, -PoolPhys.G, 0.0)
		aacc = Vector3.ZERO
		phase_left = _time_to_land()
		return

	pos.y = rest_y()
	vel.y = 0.0

	# Vertical-axis spin decays on its own timeline, independent of the regime.
	var spin_acc := 0.0
	var spin_t := INF
	if absf(avel.y) > PoolPhys.SPIN_EPS:
		spin_acc = -signf(avel.y) * PoolPhys.SPIN_DECEL
		spin_t = absf(avel.y) / PoolPhys.SPIN_DECEL
	else:
		avel.y = 0.0

	var u := contact_slip()
	var u_len := u.length()

	if u_len > PoolPhys.SLIP_EPS:
		state = SLIDING
		var uh := u / u_len
		acc = -PoolPhys.SLIDE_DECEL * uh
		aacc = PoolPhys.SLIDE_ANG_ACC * Vector3.UP.cross(uh) + Vector3(0.0, spin_acc, 0.0)
		phase_left = minf(u_len / PoolPhys.SLIP_DECAY, spin_t)
		return

	var sp := speed_h()
	if sp > PoolPhys.STOP_EPS:
		state = ROLLING
		var vh := Vector3(vel.x, 0.0, vel.z)
		acc = -PoolPhys.ROLL_DECEL * (vh / sp)
		# Rolling constraint w_h = (y_hat x v) / R; snap it exactly so slip
		# never re-accumulates from round-off, then differentiate it.
		var w := Vector3.UP.cross(vh) / PoolPhys.BALL_R
		avel = Vector3(w.x, avel.y, w.z)
		aacc = Vector3.UP.cross(acc) / PoolPhys.BALL_R + Vector3(0.0, spin_acc, 0.0)
		phase_left = minf(sp / PoolPhys.ROLL_DECEL, spin_t)
		return

	vel = Vector3.ZERO
	acc = Vector3.ZERO
	if absf(avel.y) > PoolPhys.SPIN_EPS:
		state = SPINNING
		avel = Vector3(0.0, avel.y, 0.0)
		aacc = Vector3(0.0, spin_acc, 0.0)
		phase_left = spin_t
		return

	state = STATIONARY
	avel = Vector3.ZERO
	aacc = Vector3.ZERO
	phase_left = INF


## Time to fall to the resting height of a candidate surface. A flying ball may
## pass over more than one -- the rail plateau and then the cloth -- so PoolSim
## asks about each and takes the first that actually has something underneath.
func time_to_height(target_y: float) -> float:
	var h := pos.y - target_y
	var disc := vel.y * vel.y + 2.0 * PoolPhys.G * h
	if disc < 0.0:
		return INF
	return (vel.y + sqrt(disc)) / PoolPhys.G


## Positive root of  rest_y = y + vy t - 1/2 g t^2  (the descending crossing).
func _time_to_land() -> float:
	var t := time_to_height(rest_y())
	return 0.0 if t == INF else t


## Advance exactly dt inside the current phase. Callers must never step past
## phase_left; PoolSim guarantees this by scheduling phase ends as events.
func integrate(dt: float) -> void:
	if state == POCKETED or state == OFF_TABLE or dt <= 0.0:
		return
	# Midpoint angular velocity keeps the visual spin accurate to O(dt^2).
	var w_mid := avel + aacc * (0.5 * dt)
	pos += vel * dt + acc * (0.5 * dt * dt)
	vel += acc * dt
	avel += aacc * dt
	phase_left -= dt
	clamp_spin()

	var wl := w_mid.length()
	if wl > 1.0e-9 and is_finite(wl):
		var ang := wl * dt
		if ang > 1.0e-9:
			orient = (Quaternion(w_mid / wl, ang) * orient).normalized()


## Keep the spin finite and inside PoolPhys.MAX_SPIN. Called after integrating,
## which is the one point every impulse eventually passes through; see MAX_SPIN
## for what an unbounded one costs.
func clamp_spin() -> void:
	if not (is_finite(avel.x) and is_finite(avel.y) and is_finite(avel.z)):
		avel = Vector3.ZERO
		return
	var wl := avel.length()
	if wl > PoolPhys.MAX_SPIN:
		avel *= PoolPhys.MAX_SPIN / wl


## Conservative bound on how far the centre can move over a window of length t.
func max_travel(t: float) -> float:
	return vel.length() * t + 0.5 * acc.length() * t * t
