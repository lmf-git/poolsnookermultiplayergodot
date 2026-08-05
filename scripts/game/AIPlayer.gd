class_name AIPlayer
extends RefCounted

## The computer player, for both games.
##
## It plays the same game the human does: it can only see where the balls are,
## it strokes the cue through PoolSim.cue_strike like everything else, and it
## misses. Nothing is nudged in its favour and nothing is nudged against it --
## the difficulty levels differ in how *well* it aims and how much of the table
## it bothers to look at, never in the physics.
##
## How a turn is planned:
##
##   1. **Geometry.** For every ball it is allowed to hit and every pocket, work
##      out the ghost-ball line, throw away anything blocked or cut too fine, and
##      score what is left with a cheap prior -- cut angle, distance, and how
##      much angular room the pocket actually leaves at that range.
##   2. **Simulation.** Take the best few of those, plus safety candidates when
##      nothing is on, and *play each one out* on a throwaway copy of the table
##      until every ball has stopped. This is the expensive part, so it is
##      spread across frames with a millisecond budget (see `think`).
##   3. **Judgement.** Score the finished table the way the game would: balls
##      down, fouls, and -- for the stronger levels -- what the shot left, for
##      itself if it keeps the table and for the opponent if it does not.
##   4. **Execution.** Aim and power are then perturbed by the level's error.
##      The shot it *chooses* is the shot it wanted; the shot it *plays* is the
##      one its hands were up to.
##
## The two games are genuinely different opponents, not one opponent with the
## numbers changed -- see `_score_pool` and `_score_snooker`. Pool is a
## territorial game about clearing your seven and not handing over two visits;
## snooker is an economic one about the value of the ball you go for and where
## the cue ball has to be for the next one.

enum { EASY, MEDIUM, HARD, PRO }

const LEVEL_NAMES := ["Easy", "Medium", "Hard", "Pro"]

## Table time a candidate shot is played out for before it is abandoned, and the
## slice it is advanced in. The solver is exact at any step size; this only sets
## how often the loop checks whether everything has stopped.
const SIM_MAX_TIME := 18.0
const SIM_STEP := 0.05

## What one candidate is allowed to cost, and it is allowed nothing like a real
## shot's budget.
##
## This is the single most important number in the planner. A shot played out
## with the simulator's full per-call budget can resolve millions of events
## before it gives up -- a hard stroke into a tight cluster generates events by
## the thousand, and the two are multiplied by the six hundred slices a thirty
## second playout takes. One such candidate locks the process solid for minutes,
## which is not a slow frame: it is an application that has stopped responding
## and gets killed where it stands, leaving no error behind to explain itself.
##
## A candidate that cannot be settled inside this is not a shot worth playing
## anyway, so it is scored on what happened before the budget ran out.
const SIM_EVENTS_PER_SLICE := 900
const SIM_EVENTS_TOTAL := 9000
## Wall-clock ceiling for a single candidate, as a last line of defence for
## anything the event count does not catch.
const SIM_MSEC_MAX := 12.0

## A ball this close to the line of a shot is in the way of it.
const BLOCK_CLEARANCE := 0.0015
## How far past the lip of a pocket the CPU aims. Aiming at the drop line itself
## leaves no room for the ball to be a millimetre off and still fall.
const POCKET_AIM_DEPTH := 0.020
## Speed the object ball should still be carrying when it arrives at the pocket.
## Not the least that would drop: a ball creeping in on its last centimetre of
## roll is robbed by the jaws whenever the aim is a millimetre out, and the CPU's
## aim is always a little out. This is the margin that makes its pots stand up.
const POT_ARRIVAL_SPEED := 0.55
## Reference distance the aiming error is quoted at.
const AIM_ERROR_REFERENCE := 1.0
## What still being at the table is worth, on top of the balls a shot pots.
const KEEPS_TABLE := 55.0
## How far either side of the ghost ball the stronger levels try a pot, looking
## for the aim that beats collision throw. About a quarter of a degree.
const THROW_TRIAL := 0.0045
## Angular error at the object ball that a pocket forgives, used to normalise the
## pot prior. Roughly the tolerance of a comfortable mid-range pot: a corner from
## three-quarters of a metre, arrived at square.
const TOLERANCE_REF := 0.020
## Clear gap between the jaws, in metres, that a pot has to leave to be worth
## attempting. Zero is the bare geometric limit -- the ball fits through and not
## a millimetre more -- and a pot that only drops when struck perfectly is not a
## pot, because the CPU's aim is never perfect. See `_finalise`.
const POT_CLEARANCE := 0.005
## How many balls to consider hiding behind, and how many to consider hitting to
## get there. Every blocker against every target is hundreds of candidates and
## the budget is forty, so both ends are cut to the ones nearest the cue ball --
## which are the ones a stroke can realistically be built to.
const SNOOKER_BLOCKERS := 4
const SNOOKER_TARGETS := 3
## What a shot that simply misses is worth. Neither good nor bad: the table goes
## to the opponent, which the safety scoring already prices, and this is only the
## baseline an uncertain pot is discounted towards.
const MISS_VALUE := 0.0


## What one difficulty level is actually made of.
class Skill extends RefCounted:
	## Standard deviation of the aiming error, in radians, before it is scaled by
	## how long and how hard the shot is.
	var aim_error := 0.010
	## Standard deviation of the stroke speed, as a fraction.
	var power_error := 0.15
	## How many shots it is willing to play out before deciding. This is the
	## single biggest lever: a player who only looks at six shots misses the good
	## one, whatever their cue action.
	var max_sims := 14
	## Cuts finer than this are not attempted at all.
	var cut_limit := 1.13                 # 65 degrees
	## Whether it strokes anything but centre ball at one fixed pace -- follow,
	## draw, and a firmer stroke when the position wants one. Without this a
	## player can only ever roll the ball in at the minimum speed that reaches
	## the pocket, which is why a centre-ball-only opponent looks like it is not
	## trying: it is not choosing a weak stroke, it has no other one.
	var uses_spin := false
	## Whether it hunts for the aim that beats collision throw.
	var refines_aim := false
	## How much it cares where the cue ball finishes, against simply potting.
	var position := 0.35
	## Whether it will deliberately play a safety instead of a hopeless pot.
	var plays_safe := true
	## Snooker: how far it chases the value of a colour over the ease of one.
	var ambition := 0.35


static func skill_for(p_level: int) -> Skill:
	var s := Skill.new()
	match p_level:
		EASY:
			# Sees the obvious pot and not much else, and hits it about a third
			# of a ball out at a metre. Will not play safe: if there is nothing
			# on, it hits its own ball and hopes.
			s.aim_error = 0.0230
			s.power_error = 0.22
			s.max_sims = 6
			s.cut_limit = 0.96            # 55 degrees
			s.uses_spin = false
			s.refines_aim = false
			s.position = 0.0
			s.plays_safe = false
			s.ambition = 0.0
		MEDIUM:
			# A club player: strikes the ball properly, thinks about where the
			# cue ball is going, and does not always find the best line.
			s.aim_error = 0.0085
			s.power_error = 0.105
			s.max_sims = 14
			s.cut_limit = 1.13            # 65 degrees
			s.uses_spin = true
			s.refines_aim = false
			s.position = 0.55
			s.plays_safe = true
			s.ambition = 0.35
		HARD:
			s.aim_error = 0.0032
			s.power_error = 0.075
			s.max_sims = 26
			s.cut_limit = 1.31            # 75 degrees
			s.uses_spin = true
			s.refines_aim = true
			s.position = 0.85
			s.plays_safe = true
			s.ambition = 0.75
		_:
			# Pro: a hair over a millimetre of error at a metre, looks at
			# everything, and plays for the next ball as hard as for this one.
			s.aim_error = 0.0012
			s.power_error = 0.030
			s.max_sims = 40
			s.cut_limit = 1.43            # 82 degrees
			s.uses_spin = true
			s.refines_aim = true
			s.position = 1.30
			s.plays_safe = true
			s.ambition = 1.0
	return s


## One stroke under consideration.
class Candidate extends RefCounted:
	var aim := Vector3(0, 0, -1)
	var speed := 2.0                      # cue speed at the tip, m/s
	var spin := Vector2.ZERO
	var prior := 0.0                      # cheap ranking, before simulation
	## Cue-side aiming error, in radians, that this shot survives -- how far out
	## the aim can be and still have the ball drop. INF for anything that is not
	## a pot, which has nothing to be precise about.
	var aim_allow := INF
	## Distance the cue ball travels to reach the object ball, which is what
	## scales both the aiming error and its leverage on the object ball.
	var cue_dist := 1.0
	var score := -INF                     # what the played-out shot was worth
	var kind := "pot"
	var target := -1


## Plain int, not the enum type: it is clamped into range with clampi, and
## GDScript rightly objects to assigning a bare integer where an enum value is
## expected. The same reasoning as Main's camera mode.
var level: int = MEDIUM
var skill: Skill

## The chosen stroke, once `think` reports it is done.
var shot: Candidate = null
## Set while planning, purely so the HUD can say what it is up to.
var status := ""

var _rng := RandomNumberGenerator.new()
var _sim: PoolSim
var _rules
## The table being played on, POOL or SNOOKER, which is what the shot-making
## geometry cares about.
var _mode: int = PoolPhys.POOL
## The game being played, which is what the *scoring* cares about. Killer runs on
## the pool table but wants nothing else the eight-ball scorer does.
var _game: int = PoolPhys.GAME_EIGHT_BALL
var _queue: Array = []
var _best: Candidate = null
var _sims_left := 0


func _init(p_level := MEDIUM, seed_value := -1) -> void:
	set_level(p_level)
	if seed_value >= 0:
		_rng.seed = seed_value
	else:
		_rng.randomize()


func set_level(p_level: int) -> void:
	level = clampi(p_level, EASY, PRO)
	skill = skill_for(level)


func level_name() -> String:
	return LEVEL_NAMES[level]


# ---------------------------------------------------------------------------
# planning a turn
# ---------------------------------------------------------------------------

## Start planning. `is_break` short-circuits the search: everyone breaks the same
## way and playing out forty candidate smashes tells you nothing.
func begin(p_sim: PoolSim, p_rules, p_game: int, is_break: bool) -> void:
	_sim = p_sim
	_rules = p_rules
	_game = p_game
	_mode = PoolPhys.table_for(p_game)
	_best = null
	shot = null
	_queue.clear()
	_sims_left = skill.max_sims
	status = "planning"

	if is_break:
		_best = _break_shot()
		shot = _finalise(_best)
		status = ""
		return

	_queue = _pot_candidates()
	if _queue.is_empty() or (skill.plays_safe and _queue[0].prior < 0.22):
		# Nothing worth having, or nothing at all: look for a way to leave the
		# opponent with as little as possible instead -- and, in snooker, for a
		# way to leave them unable to hit anything at all, which is a shot that
		# has to be aimed for rather than stumbled into.
		_queue.append_array(_safety_candidates())
		if skill.plays_safe and _mode == PoolPhys.SNOOKER:
			_queue.append_array(_snooker_candidates(_their_targets()))
	_queue.sort_custom(func(a: Candidate, b: Candidate) -> bool: return a.prior > b.prior)
	_queue = _one_playout_each(_queue)
	if _queue.size() > skill.max_sims * 2:
		_queue.resize(skill.max_sims * 2)


## What the opponent will be on when the table goes back to them: a red while any
## remain, otherwise the colour that is next in order.
##
## The generator that lays snookers and the scoring that judges them both have to
## mean the same thing by "what they can hit", or the CPU plays for snookers its
## own scoring cannot see and scores them off tables it never plays for.
func _their_targets() -> Callable:
	if _rules.reds_left(_sim) > 0:
		return func(v: int) -> bool: return v == 1
	if _rules.reds_done:
		var order: int = _rules.colour_order
		return func(v: int) -> bool: return v == order
	return func(v: int) -> bool: return v >= 2


## Move the best candidate for each distinct ball to the front of the queue.
##
## The queue is sorted by a prior that only knows how easy a shot *looks*, and
## the spin and aiming variants of a good-looking one sit immediately behind it.
## On a table with an easy yellow and a slightly longer black that is enough to
## spend the whole simulation budget on the yellow and never play the black out
## at all -- so the shot that was never looked at cannot be chosen, whatever it
## was worth. One playout each, best first, then the rest of the list as it
## stood: every ball gets its chance, and what it is worth is settled by the
## scoring like everything else.
func _one_playout_each(queue: Array) -> Array:
	var seen := {}
	var first: Array = []
	var rest: Array = []
	for c: Candidate in queue:
		if c.target >= 0 and not seen.has(c.target):
			seen[c.target] = true
			first.append(c)
		else:
			rest.append(c)
	first.append_array(rest)
	return first


## Play out candidates until the millisecond budget for this frame is gone.
## Returns true once a stroke has been settled on.
func think(budget_msec: float) -> bool:
	if shot != null:
		return true
	var until := Time.get_ticks_usec() + int(budget_msec * 1000.0)
	while not _queue.is_empty() and _sims_left > 0:
		var cand: Candidate = _queue.pop_front()
		cand.score = _evaluate(cand)
		_sims_left -= 1
		if _best == null or cand.score > _best.score:
			_best = cand
		if Time.get_ticks_usec() >= until:
			return false

	if _best == null:
		_best = _fallback_shot()
	shot = _finalise(_best)
	status = ""
	return true


## Turn the chosen stroke into the one that actually gets played, by adding the
## error this level shoots with. Long shots and hard strokes are missed by more,
## which is true of people and is what stops a weak CPU from being uncannily good
## at soft close-range pots.
func _finalise(cand: Candidate) -> Candidate:
	var out := Candidate.new()
	out.kind = cand.kind
	out.target = cand.target
	out.spin = cand.spin
	var travel := 1.0
	if _sim != null and _sim.cue != null:
		travel = _cue_travel(cand)
	var err := aim_sigma(travel, cand.speed)
	out.aim = cand.aim.rotated(Vector3.UP, _rng.randfn(0.0, err)).normalized()
	out.speed = _stroke(cand.speed * (1.0 + _rng.randfn(0.0, skill.power_error)))
	return out


## The aiming error this level will actually shoot a shot of this length and pace
## with, as a standard deviation in radians.
##
## Factored out of `_finalise` so the planner can ask the same question *before*
## choosing: how far out is this stroke likely to be? Judging a shot without
## knowing that is the whole problem it exists to solve.
func aim_sigma(travel: float, speed: float) -> float:
	var reach: float = clampf(travel / AIM_ERROR_REFERENCE, 0.35, 2.2)
	var effort: float = clampf(speed / 4.0, 0.4, 1.8)
	return skill.aim_error * (0.55 + 0.45 * reach) * (0.7 + 0.3 * effort)


## How far the cue ball has to go to reach whatever this shot is aimed at, for
## scaling the aiming error. Falls back to a table-length guess.
func _cue_travel(cand: Candidate) -> float:
	if cand.target < 0 or _sim == null or _sim.cue == null:
		return 1.0
	var best := 1.0
	var found := false
	for b in _sim.balls:
		if b.number != cand.target or not b.is_active():
			continue
		var d := _flat(b.pos).distance_to(_flat(_sim.cue.pos))
		if not found or d < best:
			best = d
			found = true
	return best


# ---------------------------------------------------------------------------
# candidate generation
# ---------------------------------------------------------------------------

## Every pot the CPU can see: each legal ball into each pocket, ghost-balled,
## filtered for blocked lines and impossible cuts, and priced by a prior that
## costs nothing to compute.
func _pot_candidates() -> Array:
	var out: Array = []
	var cue2 := _flat(_sim.cue.pos)
	for b in _sim.balls:
		if not b.is_active() or b.number == 0 or not _legal_now(b.number):
			continue
		var ball2 := _flat(b.pos)
		for pk in _sim.table.pockets:
			var aim_pt: Vector2 = pk.mouth + pk.normal * POCKET_AIM_DEPTH
			var to_pocket := aim_pt - ball2
			var d_obj := to_pocket.length()
			if d_obj < 1.0e-4:
				continue
			var u := to_pocket / d_obj
			# What the jaws actually leave for a ball arriving along this line.
			# The gap closes as the arrival steepens, and a middle pocket's shuts
			# long before a corner's -- which is what rules out sending a ball
			# across the mouth of one from down by the baulk cushion.
			var opening := pk.opening_along(u)
			if opening <= POT_CLEARANCE:
				continue
			var ghost := ball2 - u * PoolPhys.BALL_D
			var to_ghost := ghost - cue2
			var d_cue := to_ghost.length()
			if d_cue < PoolPhys.BALL_R:
				continue
			var c := to_ghost / d_cue
			var cos_cut := c.dot(u)
			if cos_cut <= cos(skill.cut_limit):
				continue
			if not _line_clear(cue2, ghost, b, _sim.cue, _sim):
				continue
			if not _line_clear(ball2, aim_pt, b, null, _sim):
				continue

			var cand := Candidate.new()
			cand.target = b.number
			cand.aim = Vector3(c.x, 0.0, c.y)
			cand.speed = _speed_for_pot(d_cue, d_obj, cos_cut)
			cand.prior = _pot_prior(d_cue, d_obj, cos_cut, opening)
			cand.cue_dist = d_cue
			cand.aim_allow = _aim_allowance(d_cue, d_obj, opening)
			# Snooker: a colour is worth going out of your way for, and how far
			# out of your way is exactly what separates a cautious player from an
			# ambitious one.
			if _mode == PoolPhys.SNOOKER:
				cand.prior *= lerpf(1.0, 0.45 + 0.16 * float(b.number),
					skill.ambition)
			out.append(cand)
	out.sort_custom(func(a: Candidate, bb: Candidate) -> bool: return a.prior > bb.prior)

	# Spin and a firmer stroke are only worth simulating on the shots that were
	# worth playing in the first place.
	if skill.uses_spin and not out.is_empty():
		var variants: Array = []
		# A fifth of the budget, rounded down on purpose: these are the shots
		# worth trying variations of, and a fraction of a shot is not one.
		var top: int = mini(out.size(), maxi(2, int(float(skill.max_sims) / 5.0)))
		for i in range(top):
			var base: Candidate = out[i]
			for tip: float in [0.32, -0.32]:
				var v := Candidate.new()
				v.target = base.target
				v.aim = base.aim
				v.aim_allow = base.aim_allow
				v.cue_dist = base.cue_dist
				v.speed = _stroke(base.speed * 1.12)
				v.spin = Vector2(0.0, tip)
				v.prior = base.prior * 0.94
				variants.append(v)
			var firm := Candidate.new()
			firm.target = base.target
			firm.aim = base.aim
			firm.aim_allow = base.aim_allow
			firm.cue_dist = base.cue_dist
			firm.speed = _stroke(base.speed * 1.45)
			firm.prior = base.prior * 0.92
			variants.append(firm)

		# Aiming off. The ghost ball is where the object ball would go if the
		# contact were frictionless, and it is not: friction across the line of
		# centres throws the ball a little off the cut, so the ghost is a small
		# lie on anything but a straight pot. Rather than model the correction,
		# the stronger levels try the shot a fraction either side and keep
		# whichever one the simulation actually pots -- which is what a player
		# does when they learn to aim thicker on a cut without being able to say
		# by how much.
		if not skill.refines_aim:
			out.append_array(variants)
			return out
		for i in range(mini(out.size(), 3)):
			var base2: Candidate = out[i]
			for off: float in [THROW_TRIAL, -THROW_TRIAL]:
				var v2 := Candidate.new()
				v2.target = base2.target
				v2.aim = base2.aim.rotated(Vector3.UP, off)
				v2.speed = base2.speed
				v2.prior = base2.prior * 0.97
				variants.append(v2)
		out.append_array(variants)
	return out


## Shots played for position rather than for a ball: contact something legal,
## and leave the cue ball where the opponent can do nothing with it.
##
## The candidates are contacts at a spread of cut angles and speeds, which is how
## a real safety is chosen -- thick or thin off which ball, and how hard. Which
## of them is actually any good is not guessed at here; it comes out of playing
## them and looking at the table afterwards.
func _safety_candidates() -> Array:
	var out: Array = []
	var cue2 := _flat(_sim.cue.pos)
	var reachable: Array = []
	for b in _sim.balls:
		if not b.is_active() or b.number == 0 or not _legal_now(b.number):
			continue
		if _line_clear(cue2, _flat(b.pos), b, _sim.cue, _sim):
			reachable.append(b)

	if reachable.is_empty():
		return _escape_candidates()

	# Nearest and farthest first: those are the two that make a safety, either
	# rolling up tight behind something or nicking the far side of the pack.
	reachable.sort_custom(func(a: PoolBall, b: PoolBall) -> bool:
		return _flat(a.pos).distance_to(cue2) < _flat(b.pos).distance_to(cue2))
	var picks: Array = []
	picks.append(reachable[0])
	if reachable.size() > 1:
		picks.append(reachable[reachable.size() - 1])
	while picks.size() < 4 and reachable.size() > picks.size():
		var b: PoolBall = reachable[_rng.randi_range(0, reachable.size() - 1)]
		if not picks.has(b):
			picks.append(b)

	for b: PoolBall in picks:
		var ball2 := _flat(b.pos)
		var to_ball := ball2 - cue2
		var d := to_ball.length()
		if d < 1.0e-4:
			continue
		var dir := to_ball / d
		var side := Vector2(-dir.y, dir.x)
		for cut: float in [0.0, 0.55, -0.55, 0.88, -0.88]:
			# Move the ghost ball sideways to take the contact thinner. At 1.0 it
			# misses altogether, so 0.88 is about as fine as is worth playing.
			var ghost := ball2 - dir * PoolPhys.BALL_D * sqrt(maxf(1.0 - cut * cut, 0.0)) \
				+ side * (cut * PoolPhys.BALL_D)
			var c := (ghost - cue2)
			if c.length() < 1.0e-4:
				continue
			c = c.normalized()
			for pace: float in [0.55, 1.0, 1.7]:
				var cand := Candidate.new()
				cand.kind = "safety"
				cand.target = b.number
				cand.aim = Vector3(c.x, 0.0, c.y)
				cand.speed = _cue_speed_for_ball_speed(_ball_speed_for_distance(
					d * pace + 0.25))
				# Safeties are ranked below any real pot, and among themselves by
				# nothing much -- the simulation decides.
				cand.prior = 0.20 - 0.02 * absf(cut)
				out.append(cand)
	return out


## Shots played to leave the opponent with nothing to hit at all.
##
## A safety is chosen by playing contacts and looking at what they left. A
## *snooker* almost never turns up that way: the cue ball has to finish in one
## particular small place -- behind a ball, on the far side of it from everything
## the opponent is on -- and the odds of a thin cut at a guessed pace landing
## there are tiny. So the CPU never played one, which is most of what was missing
## from it as a snooker opponent: a professional who cannot lay a snooker cannot
## win a frame from behind.
##
## Here it is aimed for directly. Pick something to hide behind, work out where
## the cue ball would have to stop, and build the stroke backwards from the
## 90-degree rule: a cue ball stunning off an object ball leaves along the
## tangent, square to the line of centres, so asking for a departure direction
## fixes where the contact has to be and therefore where to aim.
##
## Everything after that is the same as any other candidate -- the simulation says
## where the cue ball really finished, and `_snookered` says whether it was worth
## anything. This only makes sure the shot is in the list to be tried.
func _snooker_candidates(their_want: Callable) -> Array:
	var out: Array = []
	if _sim.cue == null or not _sim.cue.is_active():
		return out
	var cue2 := _flat(_sim.cue.pos)

	# Where the opponent's balls are, as one point. "Behind" a blocker only means
	# anything relative to what they have to hit.
	var theirs := Vector2.ZERO
	var n := 0
	for b in _sim.balls:
		if b.is_active() and b.number != 0 and their_want.call(b.number):
			theirs += _flat(b.pos)
			n += 1
	if n == 0:
		return out
	theirs /= float(n)

	# Both lists are cut down before they are crossed: every blocker against every
	# target is hundreds of candidates, and the budget is forty.
	#
	# A blocker has to be a ball the opponent is *not* on -- hiding behind a ball
	# they are allowed to hit is not a snooker, it is a ball sitting in front of
	# them. A target has to be one this player is allowed to hit first, or the
	# snooker is laid and the foul is ours.
	var blockers := _nearest_active(cue2, SNOOKER_BLOCKERS,
		func(v: int) -> bool: return not their_want.call(v))
	var targets := _nearest_active(cue2, SNOOKER_TARGETS,
		func(v: int) -> bool: return _legal_now(v))

	for blocker: PoolBall in blockers:
		var b2 := _flat(blocker.pos)
		var away := b2 - theirs
		if away.length() < 1.0e-4:
			continue
		away = away.normalized()
		# Tucked in behind it -- close enough that the blocker really does cover
		# the cue ball, and clear of everything else on the table.
		var spot := b2 + away * (PoolPhys.BALL_D * 1.2)
		if not _sim.table.is_legal_center(spot, 0.006):
			continue
		if not _clear_of_balls(spot, _sim.cue):
			continue
		for t: PoolBall in targets:
			if t == blocker:
				continue
			var t2 := _flat(t.pos)
			var run := spot - t2
			if run.length() < PoolPhys.BALL_D:
				continue
			var d := run.normalized()
			var perp := Vector2(-d.y, d.x)
			for side: float in [1.0, -1.0]:
				var ghost := t2 + perp * (side * PoolPhys.BALL_D)
				var to_ghost := ghost - cue2
				var d_cue := to_ghost.length()
				if d_cue < PoolPhys.BALL_R:
					continue
				var c := to_ghost / d_cue
				# The contact has to be on the near side of the object ball: the
				# other ghost is one the cue ball could only reach by passing
				# through the ball it is supposed to be hitting.
				if c.dot(t2 - cue2) <= 0.0:
					continue
				# ...and the cue ball has to come off it *towards* the hiding
				# place. The tangent is a line, not a direction: half of these
				# would send it away from the spot at the same speed.
				if c.dot(d) <= 0.0:
					continue
				if not _line_clear(cue2, ghost, t, _sim.cue, _sim):
					continue
				var cand := Candidate.new()
				cand.kind = "snooker"
				cand.target = t.number
				cand.aim = Vector3(c.x, 0.0, c.y)
				cand.cue_dist = d_cue
				# Enough to reach the contact and carry on to the hiding place,
				# arriving with almost nothing left so it stays there.
				cand.speed = _cue_speed_for_ball_speed(_ball_speed_for_distance(
					d_cue + ghost.distance_to(spot) * 1.15, 0.30))
				# A thin contact is the whole trick here, and one missed
				# altogether is a foul worth four. What the aim can be out by and
				# still touch the ball is about the angle its edge subtends from
				# here, halved because one side of that is a miss rather than a
				# fuller contact -- which is what lets the certainty weighting
				# discount these for the levels whose aim is not up to them.
				cand.aim_allow = 0.5 * atan(PoolPhys.BALL_R / d_cue)
				# Above a plain safety, below any real pot: worth trying first
				# among the shots that are not going to pot anything.
				cand.prior = 0.24
				out.append(cand)
	return out


## The `count` nearest active object balls to `from`, optionally only those
## matching `want`. An empty Callable means any ball at all.
func _nearest_active(from: Vector2, count: int, want: Callable) -> Array:
	var balls: Array = []
	for b in _sim.balls:
		if not b.is_active() or b.number == 0:
			continue
		if want.is_valid() and not want.call(b.number):
			continue
		balls.append(b)
	balls.sort_custom(func(a: PoolBall, bb: PoolBall) -> bool:
		return _flat(a.pos).distance_to(from) < _flat(bb.pos).distance_to(from))
	if balls.size() > count:
		balls.resize(count)
	return balls


## Snookered: no legal ball can be hit in a straight line. Bank off a cushion by
## mirroring the cue ball through it and aiming at where that line crosses.
func _escape_candidates() -> Array:
	var out: Array = []
	var cue2 := _flat(_sim.cue.pos)
	# Each entry is an inward normal and the value of n . p on the plane the cue
	# ball's *centre* can reach, which is the cushion set in by a ball radius.
	var wall_z := -PoolPhys.HALF_L + PoolPhys.BALL_R
	var wall_x := -PoolPhys.HALF_W + PoolPhys.BALL_R
	var walls := [
		[Vector2(0, 1), wall_z], [Vector2(0, -1), wall_z],
		[Vector2(1, 0), wall_x], [Vector2(-1, 0), wall_x],
	]
	for b in _sim.balls:
		if not b.is_active() or b.number == 0 or not _legal_now(b.number):
			continue
		var ball2 := _flat(b.pos)
		for w in walls:
			var n: Vector2 = w[0]
			var offset: float = w[1]
			# Reflect the target through the cushion plane n . p = -offset, set in
			# by a ball radius because the cue ball's centre never reaches the
			# cloth's edge.
			var plane_d: float = -offset - PoolPhys.BALL_R
			var dist := ball2.dot(n) - plane_d
			if dist <= PoolPhys.BALL_R:
				continue                  # already against that cushion
			# Aiming at the target's reflection sends the cue ball off the cushion
			# straight at it -- geometrically. A real cushion is not a mirror, so
			# this is only a candidate: the simulation says whether it worked.
			var mirrored := ball2 - n * (2.0 * dist)
			var dir := mirrored - cue2
			if dir.length() < 1.0e-4:
				continue
			dir = dir.normalized()
			for pace: float in [1.2, 2.0]:
				var cand := Candidate.new()
				cand.kind = "escape"
				cand.target = b.number
				cand.aim = Vector3(dir.x, 0.0, dir.y)
				cand.speed = _cue_speed_for_ball_speed(_ball_speed_for_distance(
					cue2.distance_to(mirrored) * pace))
				cand.prior = 0.10
				out.append(cand)
	if out.is_empty():
		out.append(_fallback_shot())
	return out


## Something legal to do when every search came up empty: hit the nearest ball
## that is on, as squarely as possible. It may well foul, but the game moves on.
##
## Failing *that*, the nearest ball of any colour. There are positions where
## nothing is legal to hit -- an open table settled the wrong way, a rules state
## that says the striker is on a colour with none left -- and the candidate's own
## default aim points down the table at whatever happens to be there. That is the
## computer visibly aiming at nothing, and then fouling on whatever it ran into,
## which is a far worse way to be wrong than a foul the player can see coming.
func _fallback_shot() -> Candidate:
	var cand := Candidate.new()
	cand.kind = "fallback"
	cand.speed = _stroke(1.6)
	if _sim == null or _sim.cue == null:
		return cand
	var cue2 := _flat(_sim.cue.pos)
	var best := INF
	var any_best := INF
	var any_aim := Vector3.ZERO
	for b in _sim.balls:
		if not b.is_active() or b.number == 0:
			continue
		var d := _flat(b.pos).distance_to(cue2)
		var dir := (_flat(b.pos) - cue2).normalized()
		if d < any_best:
			any_best = d
			any_aim = Vector3(dir.x, 0.0, dir.y)
		if not _legal_now(b.number):
			continue
		if d < best:
			best = d
			cand.aim = Vector3(dir.x, 0.0, dir.y)
			cand.target = b.number
	if best == INF and any_aim != Vector3.ZERO:
		cand.kind = "fallback-illegal"
		cand.aim = any_aim
	return cand


## The break. There is nothing to search: the balls are in a triangle and the
## job is to spread them, so both games get the shot everyone actually plays.
func _break_shot() -> Candidate:
	var cand := Candidate.new()
	cand.kind = "break"
	var cue2 := _flat(_sim.cue.pos)

	if _mode == PoolPhys.SNOOKER:
		# Thin off the outside of the widest red on the cue ball's own side, with
		# a touch of check side: that is the shot that sends the cue ball round
		# the cushions back to baulk while barely disturbing the pack. Anything
		# fuller opens the reds up for the opponent.
		var away: float = signf(cue2.x)
		if away == 0.0:
			away = 1.0
		var target := _outermost_red(away)
		var to_ball := target - cue2
		var dir := to_ball.normalized()
		var side := Vector2(-dir.y, dir.x)
		# Which way round the perpendicular points depends on the heading, so the
		# offset is taken toward the cushion rather than by a fixed sign.
		if side.x * away < 0.0:
			side = -side
		var ghost := target + side * (PoolPhys.BALL_D * 0.92) \
			- dir * PoolPhys.BALL_D * 0.39
		var c := (ghost - cue2).normalized()
		cand.aim = Vector3(c.x, 0.0, c.y)
		cand.speed = _stroke(2.6)
		cand.spin = Vector2(-away * 0.30, 0.0)
		cand.target = 1
		return cand

	# Pool: straight into the apex ball, hard, with a little topspin so the cue
	# ball carries on into the pack rather than sitting on the break line.
	var apex := Vector2(0.0, PoolPhys.rack_apex_z())
	var to_apex := (apex - cue2).normalized()
	cand.aim = Vector3(to_apex.x, 0.0, to_apex.y)
	cand.speed = _stroke(7.4)
	cand.spin = Vector2(0.0, 0.14)
	cand.target = -1
	return cand


## The red furthest out on `side` of the pack, which is the one a snooker break
## is played off. Taking it from the same side as the cue ball is what makes the
## contact a thin one rather than a cut across the front of the triangle.
func _outermost_red(side: float) -> Vector2:
	var best := Vector2(0.0, PoolPhys.rack_apex_z())
	var widest := -INF
	for b in _sim.balls:
		if not b.is_active() or b.number != 1:
			continue
		var p := _flat(b.pos)
		if p.x * side > widest:
			widest = p.x * side
			best = p
	return best


# ---------------------------------------------------------------------------
# playing a candidate out
# ---------------------------------------------------------------------------

## Play the stroke on a throwaway copy of the table, then judge where it left
## everything. This is the only place a candidate's real worth is decided --
## everything before it is a guess used to choose what is worth playing out.
func _evaluate(cand: Candidate) -> float:
	var state := _sim.clone_for_prediction(SIM_EVENTS_PER_SLICE)
	if state.cue == null:
		return -INF
	# The same automatic tilt the player's cue gets when a rail -- or a ball --
	# is behind the shot, so the simulated stroke is the stroke that will be
	# played. A candidate the CPU can only reach over an intervening ball is
	# therefore scored as the weakened stroke it really is.
	var elev := state.clearance_elevation(cand.aim)
	PoolSim.cue_strike(state.cue, cand.aim, cand.speed, cand.spin.x, cand.spin.y,
		elev, true, 0.0)
	var t := 0.0
	var deadline := Time.get_ticks_usec() + int(SIM_MSEC_MAX * 1000.0)
	while t < SIM_MAX_TIME and not state.is_shot_over():
		state.advance(SIM_STEP)
		state.advance_drops(SIM_STEP)
		t += SIM_STEP
		# Three ways out, all of them saying the same thing: this shot is costing
		# more than it can possibly be worth. Whatever has happened by now is
		# what it gets scored on.
		if state.event_count > SIM_EVENTS_TOTAL or state.overflowed:
			break
		if Time.get_ticks_usec() > deadline:
			break

	var out := _outcome(state)
	var score := 0.0
	if _game == PoolPhys.GAME_SNOOKER:
		_restore_respots(state, out)
		score = _score_snooker(state, out)
	elif _game == PoolPhys.GAME_KILLER:
		score = _score_killer(out)
	else:
		_restore_pool_respots(state, out)
		score = _score_pool(state, out)
	return _weigh_by_certainty(cand, score)


## Discount what a shot is worth by how likely it is to come off.
##
## The playout above is noiseless -- it is the shot the CPU *means* to play --
## and the error only arrives afterwards, in `_finalise`. So without this a pot
## that goes in exactly once, struck perfectly, is scored the same as one with a
## ball's width to spare, and the planner will happily take the first. That is
## the difference between an opponent that plays percentages and one that keeps
## rattling the ball it was always going to rattle.
##
## Only the upside is discounted. A shot already worth less than missing -- a
## foul, a ball off the table -- is not made better by being unlikely; you would
## simply have found a different way to give the table away.
func _weigh_by_certainty(cand: Candidate, score: float) -> float:
	if score <= MISS_VALUE:
		return score
	return MISS_VALUE + (score - MISS_VALUE) * _robustness(cand)


## Killer, which is the simplest table there is to judge: pot a ball and you are
## still in the game, fail and you are out of it.
##
## There is no position to play for -- the table passes after every shot however
## well it goes -- so the whole of the CPU's judgement is how sure the pot is.
## Which ball, and where the cue ball finishes, are worth nothing at all, and
## pretending otherwise would have it playing for a leave it will never get.
func _score_killer(out: Dictionary) -> float:
	var potted: Array[int] = out["potted"]
	var off: Array[int] = out["off_table"]

	# Every one of these ends the striker's frame, so they are all equally fatal
	# and there is nothing to weigh against them.
	if out["cue_potted"] or not off.is_empty():
		return -1.0e5
	if out["first_hit"] < 0:
		return -1.0e5
	if potted.is_empty():
		return -1.0e5 if out["rail_after"] else -2.0e5

	# Survived. More balls down is not better -- one is all it takes -- but a shot
	# that leaves fewer on the table brings the re-rack closer, and a re-rack is
	# a fresh full table for whoever is unlucky enough to be next.
	return 1000.0 + float(potted.size())


## The eight-ball equivalent, and much smaller: potting is permanent, so the only
## balls that come back are the ones driven off the table. Rare -- but when it
## happens the ball reappears on the black spot, in the middle of the table and
## squarely in the way, which is exactly the sort of thing the planner should not
## be blind to.
func _restore_pool_respots(state: PoolSim, out: Dictionary) -> void:
	for v in out["off_table"] as Array[int]:
		if v == 8:
			continue                      # the black off the table loses the frame
		for b in state.balls:
			if b.number != v or b.is_active():
				continue
			var p := state.free_spot(Vector2(0.0, PoolPhys.FOOT_SPOT_Z), b)
			state.return_to_table(b, Vector3(p.x, 0.0, p.y))
			break


## Put the colours back before the position is judged.
##
## A potted colour is off the table only until the end of the shot, and what the
## planner cares about -- what is on next, whether the line to it is clear,
## whether the opponent is snookered -- is all read off the table *after* the
## respot. Scoring the raw simulated table instead means judging a position
## against balls that are not where they are about to be: the planner cannot see
## a colour blocking the shot it is playing for, because on its copy of the table
## that colour does not exist.
func _restore_respots(state: PoolSim, out: Dictionary) -> void:
	var back: Array[int] = []
	for v in out["potted"] as Array[int]:
		if v != RulesSnooker.RED:
			back.append(v)
	for v in out["off_table"] as Array[int]:
		if v != RulesSnooker.RED:
			back.append(v)
	for v in back:
		# During the clearance the colour that was on is potted for keeps. Any
		# other colour off the table is a foul, and fouls always spot back.
		if _rules.reds_done and v == _rules.colour_order:
			continue
		for b in state.balls:
			if b.number != v or b.is_active():
				continue
			var p := RulesSnooker.respot_position(state, v, b)
			state.return_to_table(b, Vector3(p.x, 0.0, p.y))
			break


## What happened, read out of the shot log exactly as the rules engines read it.
func _outcome(state: PoolSim) -> Dictionary:
	var potted: Array[int] = []
	var off_table: Array[int] = []
	var first_hit := -1
	var cue_potted := false
	var rail_after := false
	for e in state.shot_log:
		match e["type"]:
			"ball":
				if first_hit < 0 and (e["a"] == 0 or e["b"] == 0):
					first_hit = e["b"] if e["a"] == 0 else e["a"]
			"cushion":
				if first_hit >= 0:
					rail_after = true
			"pocket":
				if e["a"] == 0:
					cue_potted = true
				else:
					potted.append(e["a"])
			"off_table":
				if e["a"] == 0:
					cue_potted = true
				else:
					off_table.append(e["a"])
			"escaped_pocket":
				if e["a"] == 0:
					cue_potted = false
				else:
					potted.erase(e["a"])
	return {
		"potted": potted, "off_table": off_table, "first_hit": first_hit,
		"cue_potted": cue_potted, "rail_after": rail_after,
	}


# ---------------------------------------------------------------------------
# judging a finished table: pool
# ---------------------------------------------------------------------------

## UK pool is a territorial game. Two things dominate everything else: never
## give up the black, and never give up a foul -- a foul here is two visits, which
## against anyone decent is most of a frame. Two visits and not the cue ball: it
## is played from where it lies unless it went down, so the price of a foul is
## paid in shots rather than in position, and a safety that leaves them nothing is
## still worth playing after one.
func _score_pool(state: PoolSim, out: Dictionary) -> float:
	var potted: Array[int] = out["potted"]
	var off: Array[int] = out["off_table"]
	var mine: int = _rules.groups[_rules.player]
	var open: bool = _rules.table_open
	var on_black: bool = _rules.on_black(_sim)

	var foul := false
	if out["cue_potted"] or not off.is_empty():
		foul = true
	elif out["first_hit"] < 0 or not _rules.is_legal_first_hit(_sim, out["first_hit"]):
		foul = true
	elif not open:
		for n in potted:
			if n != 8 and RulesUKPool.group_of(n) != mine:
				foul = true

	# The black settles the game outright, either way.
	if potted.has(8) or off.has(8):
		if on_black and not foul and not off.has(8):
			return 1.0e6
		return -1.0e6

	# On an open table the colours are settled by the first ball down, so which
	# group this shot won is part of what the shot is worth.
	var my_group := mine
	if (open or mine == RulesUKPool.OPEN) and not potted.is_empty():
		my_group = RulesUKPool.group_of(potted[0])
	var own := 0
	for n in potted:
		if my_group == RulesUKPool.OPEN or RulesUKPool.group_of(n) == my_group:
			own += 1

	var their_group: int = _rules.groups[_rules.opponent()]
	if my_group != RulesUKPool.OPEN:
		their_group = RulesUKPool.YELLOWS if my_group == RulesUKPool.REDS \
			else RulesUKPool.REDS
	var mine_left := _count_group(state, my_group)
	var my_leave := _best_prior(state, _group_filter(my_group, mine_left == 0))
	var their_leave := _best_prior(state,
		_group_filter(their_group, _count_group(state, their_group) == 0))

	if foul:
		# Priced by what they can do with it, because that is what a foul costs.
		return -420.0 - 240.0 * their_leave

	if own > 0:
		return 200.0 * float(own) + 150.0 * skill.position * my_leave

	if not skill.plays_safe:
		# A weak player does not value a safety, so a shot that pots nothing is
		# worth nothing much whatever it left.
		return 5.0

	# A safety: everything is in what the opponent has been left with.
	var snookered := 40.0 if _snookered(state, _group_filter(their_group,
		_count_group(state, their_group) == 0)) else 0.0
	return 70.0 * (1.0 - their_leave) + snookered + 25.0 * skill.position * my_leave


func _count_group(state: PoolSim, g: int) -> int:
	if g == RulesUKPool.OPEN:
		return 99
	var n := 0
	for b in state.balls:
		if b.is_active() and RulesUKPool.group_of(b.number) == g:
			n += 1
	return n


## Which balls count as "on" for a player of group `g`, once their colour is
## cleared and only the black is left.
func _group_filter(g: int, cleared: bool) -> Callable:
	if cleared:
		return func(n: int) -> bool: return n == 8
	if g == RulesUKPool.OPEN:
		return func(n: int) -> bool: return n != 8
	return func(n: int) -> bool: return RulesUKPool.group_of(n) == g


# ---------------------------------------------------------------------------
# judging a finished table: snooker
# ---------------------------------------------------------------------------

## Snooker is an economic game, and the CPU plays it as one: a ball is worth its
## value times the chance of getting it, and a shot is worth the ball plus what
## it leaves. The red/colour alternation makes position everything -- potting a
## red and finishing on nothing is most of a wasted visit.
func _score_snooker(state: PoolSim, out: Dictionary) -> float:
	var potted: Array[int] = out["potted"]
	var first_hit: int = out["first_hit"]
	var foul := false
	var penalty := 4

	if first_hit < 0 or not _rules.is_legal_target(_sim, first_hit):
		foul = true
		penalty = maxi(4, maxi(first_hit, _rules.required_value(_sim)))
	if out["cue_potted"]:
		foul = true
		penalty = maxi(penalty, maxi(4, _rules.required_value(_sim)))
	# Driving a ball off the table costs the same as the rules engine says it
	# does. Without this the planner sees no downside to a shot that loses a ball
	# off the table, which is exactly the shot it should be avoiding.
	for v in out["off_table"] as Array[int]:
		foul = true
		penalty = maxi(penalty, maxi(4, maxi(v, _rules.required_value(_sim))))
	for v in potted:
		if not _legal_pot_snooker(v, potted):
			foul = true
			penalty = maxi(penalty, maxi(4, v))

	var points := 0
	if not foul:
		for v in potted:
			points += v

	# What is on for the next stroke -- which is what the cue ball had to finish
	# on. Getting this right is most of what makes the CPU build a break instead
	# of potting one ball and stopping: red, colour, red, colour.
	var want: Callable
	if _rules.reds_done:
		# Clearing up: the colours in order, one further along if this shot took
		# the one that was on.
		var order: int = _rules.colour_order
		if potted.has(order):
			order += 1
		want = func(n: int) -> bool: return n == order
	elif potted.is_empty():
		want = (func(n: int) -> bool: return n == 1) if _rules.on_red \
			else (func(n: int) -> bool: return n >= 2)
	elif _rules.on_red:
		want = func(n: int) -> bool: return n >= 2       # red down, colour next
	else:
		want = func(n: int) -> bool: return n == 1       # colour down, red next
	var leave := _best_prior(state, want)

	# Whatever the opponent will be on if they get the table: a red while any
	# remain, a colour otherwise.
	var their_want: Callable
	if _rules.reds_left(state) > 0:
		their_want = func(n: int) -> bool: return n == 1
	elif _rules.reds_done:
		# Clearing the colours: whoever plays next is on the same one this player
		# would have been. Saying "any colour" there costs the snooker scoring
		# everything -- with the pink still on the table it would never call a
		# snooker behind it, however tight.
		their_want = want
	else:
		their_want = func(n: int) -> bool: return n >= 2

	if foul:
		return -40.0 * float(penalty) - 200.0 * _best_prior(state, their_want)

	if points > 0:
		# Clearing the last colour wins the frame outright.
		if _rules.reds_done and _rules.colour_order >= 7 and potted.has(7):
			return 1.0e6
		# KEEPS_TABLE is what stops two cautious computers from trading safeties
		# at each other until the reds rot. A pot is not only worth its points:
		# it is worth still being the one holding the cue afterwards, and that is
		# most of why a snooker player takes on a half-chance at all.
		#
		# What a point is worth against where the cue ball finishes is the whole
		# of the colour choice, and it was badly out. At a flat 26 a point the
		# five points between a yellow and a black came to 130, which a perfect
		# leave (130 * position, up to 169 for a professional) simply outbid --
		# so the CPU took the easy yellow off a good angle every time, which is
		# not how anybody plays this game. Weighted by ambition, so a club player
		# still takes the safe two points and a professional goes to the black.
		return KEEPS_TABLE + lerpf(26.0, 58.0, skill.ambition) * float(points) \
			+ 130.0 * skill.position * leave

	if not skill.plays_safe:
		return 3.0

	# A safety. Baulk is worth having: everything is a long way from everything
	# there, and the reds are at the other end of the table.
	var baulk := 0.0
	if state.cue != null and state.cue.is_active() \
			and state.cue.pos.z > PoolPhys.baulk_z() - PoolPhys.BALL_D:
		baulk = 22.0
	# A snooker is not a better safety, it is a different shot: it is how a frame
	# is won from behind, by making the opponent give the table back with points
	# on it. Scaled by ambition, so a club player still mostly rolls up behind
	# something and hopes while a professional plays for it.
	var snookered := lerpf(45.0, 120.0, skill.ambition) \
		if _snookered(state, their_want) else 0.0
	# Of two safeties that leave the opponent equally nothing, the one that
	# nudged the pack is the better shot -- it is the one that makes a frame
	# happen. Without this the two players trade untouched safeties off the same
	# solid triangle until somebody's hand slips, which is not snooker.
	var development := 18.0 * clampf(_reds_disturbed(state) / 0.35, 0.0, 1.0)
	return 45.0 * (1.0 - _best_prior(state, their_want)) + baulk + snookered \
		+ development


## Total distance the reds were moved by this shot. The clone keeps the balls in
## the order they were cloned from, so this is an index-for-index comparison.
func _reds_disturbed(state: PoolSim) -> float:
	var moved := 0.0
	for i in range(mini(state.balls.size(), _sim.balls.size())):
		var after := state.balls[i]
		var before := _sim.balls[i]
		if after.number != 1 or not after.is_active() or not before.is_active():
			continue
		moved += _flat(after.pos).distance_to(_flat(before.pos))
	return moved


func _legal_pot_snooker(value: int, potted: Array[int]) -> bool:
	if _rules.reds_left(_sim) > 0 or not _rules.reds_done:
		if _rules.on_red:
			return value == 1
		return value >= 2 and potted.size() == 1
	return value == _rules.colour_order


# ---------------------------------------------------------------------------
# ball in hand
# ---------------------------------------------------------------------------

## Where to put the cue ball down. Every pot line the CPU can see is walked back
## from the ghost ball at a few comfortable distances, and the position that
## leaves the easiest shot wins.
##
## `in_d` restricts it to the D, which is where the break is played from and
## where snooker's in-hand always is.
func plan_placement(p_sim: PoolSim, p_rules, p_game: int, in_d: bool,
		is_break: bool) -> Vector2:
	_sim = p_sim
	_rules = p_rules
	_game = p_game
	_mode = PoolPhys.table_for(p_game)

	if is_break:
		return _break_placement()

	var best := Vector2.INF
	var best_score := -1.0
	for b in _sim.balls:
		if not b.is_active() or b.number == 0 or not _legal_now(b.number):
			continue
		var ball2 := _flat(b.pos)
		for pk in _sim.table.pockets:
			var aim_pt: Vector2 = pk.mouth + pk.normal * POCKET_AIM_DEPTH
			var to_pocket := aim_pt - ball2
			var d_obj := to_pocket.length()
			if d_obj < 1.0e-4:
				continue
			var u := to_pocket / d_obj
			# Placing the cue ball is the one time the CPU can choose its angle
			# into the pocket, so it asks for more than the bare minimum gap.
			if pk.opening_along(u) <= POT_CLEARANCE * 2.0:
				continue
			if not _line_clear(ball2, aim_pt, b, null, _sim):
				continue
			var ghost := ball2 - u * PoolPhys.BALL_D
			for back: float in [0.22, 0.40, 0.65]:
				var p := ghost - u * back
				if in_d and not _inside_d(p):
					continue
				if not _sim.table.is_legal_center(p):
					continue
				if not _clear_of_balls(p, null):
					continue
				if not _line_clear(p, ghost, b, _sim.cue, _sim):
					continue
				# Dead straight is the easiest pot there is, and this is the one
				# moment the CPU gets to choose it.
				var s := _pot_prior(back, d_obj, 1.0, pk.opening_along(u))
				if s > best_score:
					best_score = s
					best = p
	if best != Vector2.INF:
		return best

	# Nothing on from anywhere: stand off in a corner of the zone rather than
	# leaving the cue ball in the middle of the table for the opponent.
	if in_d:
		return _break_placement()
	return Vector2(PoolPhys.HALF_W * 0.55, PoolPhys.baulk_z())


## Where the cue ball goes for a break, inside the D in both games.
func _break_placement() -> Vector2:
	var r := PoolPhys.d_radius()
	if _mode == PoolPhys.SNOOKER:
		# Out toward the green or the yellow, which is where a break is played
		# from: it gives the cue ball a cushion to come back off.
		var side: float = 1.0 if _rng.randf() < 0.5 else -1.0
		return Vector2(side * r * 0.72, PoolPhys.baulk_z() + r * 0.30)
	# Pool: just off centre, so the cue ball has somewhere to go after the apex.
	var off: float = _rng.randf_range(0.15, 0.45) * r
	if _rng.randf() < 0.5:
		off = -off
	return Vector2(off, PoolPhys.baulk_z() + r * 0.25)


func _inside_d(p: Vector2) -> bool:
	if p.y < PoolPhys.baulk_z():
		return false
	var rel := p - Vector2(0.0, PoolPhys.baulk_z())
	return rel.length() <= PoolPhys.d_radius() - PoolPhys.BALL_R


# ---------------------------------------------------------------------------
# geometry the whole planner runs on
# ---------------------------------------------------------------------------

## How far the *cue* aim can be out and still have the ball drop, in radians.
##
## The pocket forgives `opening / 2` metres of sideways error at the object
## ball's range, which is `tolerance` radians of object-ball direction. An aiming
## error at the cue does not arrive there one-for-one: it shifts the contact
## point on the object ball by `d_cue * error`, and a shift of a whole ball
## diameter swings the object ball through a right angle. So the cue-side error
## is levered up by `d_cue / BALL_D` -- a metre of cue travel multiplies it about
## seventeen times -- and what survives is `tolerance * BALL_D / d_cue`.
##
## This is the number the planner had no notion of. It is why a thin cut from
## distance is hard even when the pocket is wide open, and why the same pocket
## from six inches is not.
func _aim_allowance(d_cue: float, d_obj: float, opening: float) -> float:
	var tolerance := maxf(opening, 0.0) / (2.0 * maxf(d_obj, 0.05))
	return tolerance * PoolPhys.BALL_D / maxf(d_cue, PoolPhys.BALL_D)


## The chance a shot survives the error this level shoots with: the probability
## that a normal deviate of that width lands inside what the pot allows.
func _robustness(cand: Candidate) -> float:
	if not is_finite(cand.aim_allow):
		return 1.0
	var sigma := aim_sigma(cand.cue_dist, cand.speed)
	if sigma <= 1.0e-9:
		return 1.0
	return _erf(cand.aim_allow / (sigma * sqrt(2.0)))


## Abramowitz & Stegun 7.1.26. Accurate to about 1.5e-7, which is far more than
## a shot-choosing heuristic needs, and it avoids a table lookup.
static func _erf(x: float) -> float:
	var ax := absf(x)
	var t := 1.0 / (1.0 + 0.3275911 * ax)
	var y := 1.0 - (((((1.061405429 * t - 1.453152027) * t) + 1.421413741) * t
		- 0.284496736) * t + 0.254829592) * t * exp(-ax * ax)
	return signf(x) * y


## How good a pot looks before anything is simulated: 0 is hopeless, 1 is a
## sitter. The terms are what actually makes a pot hard -- how fine the cut is,
## and how much angular room is left at the object ball's distance.
##
## `opening` is the gap the jaws leave along the line the ball will arrive on,
## so how squarely the pocket is being approached is already in it rather than
## being a separate guess at the same thing. That matters most at the middle
## pockets, whose mouths are wider than a corner's measured across but which
## give that width up fastest as the arrival steepens.
func _pot_prior(d_cue: float, d_obj: float, cos_cut: float,
		opening: float) -> float:
	var tolerance := maxf(opening, 0.0) / (2.0 * maxf(d_obj, 0.05))
	var room: float = clampf(tolerance / TOLERANCE_REF, 0.0, 1.0)
	var reach := 1.0 / (1.0 + d_cue * 0.55)
	return pow(maxf(cos_cut, 0.0), 1.5) * room * reach


## The best pot available to whoever is at the table next, over a whole table.
## Used to price what a shot leaves -- for the CPU if it keeps the table, and for
## the opponent if it does not.
func _best_prior(state: PoolSim, is_target: Callable) -> float:
	if state.cue == null or not state.cue.is_active():
		return 0.0
	var cue2 := _flat(state.cue.pos)
	var best := 0.0
	for b in state.balls:
		if not b.is_active() or b.number == 0 or not is_target.call(b.number):
			continue
		var ball2 := _flat(b.pos)
		for pk in state.table.pockets:
			var aim_pt: Vector2 = pk.mouth + pk.normal * POCKET_AIM_DEPTH
			var to_pocket := aim_pt - ball2
			var d_obj := to_pocket.length()
			if d_obj < 1.0e-4:
				continue
			var u := to_pocket / d_obj
			var opening := pk.opening_along(u)
			if opening <= POT_CLEARANCE:
				continue
			var ghost := ball2 - u * PoolPhys.BALL_D
			var to_ghost := ghost - cue2
			var d_cue := to_ghost.length()
			if d_cue < PoolPhys.BALL_R:
				continue
			var cos_cut := (to_ghost / d_cue).dot(u)
			if cos_cut <= 0.15:
				continue
			if not _line_clear(cue2, ghost, b, state.cue, state):
				continue
			if not _line_clear(ball2, aim_pt, b, null, state):
				continue
			best = maxf(best, _pot_prior(d_cue, d_obj, cos_cut, opening))
			if best > 0.92:
				return best
	return best


## True when nothing that is on can be hit in a straight line -- which is what
## makes a safety a snooker rather than just a bad leave.
func _snookered(state: PoolSim, is_target: Callable) -> bool:
	if state.cue == null or not state.cue.is_active():
		return false
	var cue2 := _flat(state.cue.pos)
	for b in state.balls:
		if not b.is_active() or b.number == 0 or not is_target.call(b.number):
			continue
		if _line_clear(cue2, _flat(b.pos), b, state.cue, state):
			return false
	return true


## Is the path from a to b free of every ball except the two named?
func _line_clear(a: Vector2, b: Vector2, ignore_a: PoolBall, ignore_b: PoolBall,
		state: PoolSim) -> bool:
	var limit := PoolPhys.BALL_D - BLOCK_CLEARANCE
	for ball in state.balls:
		if ball == ignore_a or ball == ignore_b or not ball.is_active():
			continue
		if _point_segment_distance(_flat(ball.pos), a, b) < limit:
			return false
	return true


func _clear_of_balls(p: Vector2, ignore: PoolBall) -> bool:
	for b in _sim.balls:
		if b == ignore or not b.is_active():
			continue
		if p.distance_to(_flat(b.pos)) < PoolPhys.BALL_D + 0.001:
			return false
	return true


static func _point_segment_distance(p: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var l2 := ab.length_squared()
	if l2 < 1.0e-12:
		return p.distance_to(a)
	var t: float = clampf((p - a).dot(ab) / l2, 0.0, 1.0)
	return p.distance_to(a + ab * t)


static func _flat(p: Vector3) -> Vector2:
	return Vector2(p.x, p.z)


func _legal_now(number: int) -> bool:
	if _mode == PoolPhys.SNOOKER:
		return _rules.is_legal_target(_sim, number)
	return _rules.is_legal_first_hit(_sim, number)


# ---------------------------------------------------------------------------
# speed
# ---------------------------------------------------------------------------

## Speed a ball struck without spin still has after `d` metres.
##
## It leaves the tip sliding and stays that way until the contact point stops
## skidding, which happens at 5/7 of the launch speed after 12 v^2 / 49 mu g --
## and sliding costs fifteen times what rolling does on this cloth, so guessing
## with rolling resistance alone under-powers every shot badly.
static func speed_after(v0: float, d: float) -> float:
	var mu_g := PoolPhys.MU_SLIDE * PoolPhys.G
	var d_slide := 12.0 * v0 * v0 / (49.0 * mu_g)
	if d <= d_slide:
		return sqrt(maxf(v0 * v0 - 2.0 * mu_g * d, 0.0))
	var v_roll := v0 * 5.0 / 7.0
	return sqrt(maxf(v_roll * v_roll - 2.0 * PoolPhys.ROLL_DECEL * (d - d_slide), 0.0))


## Launch speed a ball needs to still be moving usefully `d` metres later.
## Inverted by bisection because `speed_after` has a kink in it where the ball
## stops sliding, and one clean monotonic function beats two cases.
static func _ball_speed_for_distance(d: float, arrive := POT_ARRIVAL_SPEED) -> float:
	var lo := 0.05
	var hi := 12.0
	for _i in range(28):
		var mid := 0.5 * (lo + hi)
		if speed_after(mid, d) < arrive:
			lo = mid
		else:
			hi = mid
	return hi


## Tip speed that gives the cue ball `v` on a centre-ball hit, from the same
## impulse the simulator uses: J = (1 + e) m V / (1 + m/M).
##
## Held to the stroke range the player's power meter spans. The computer cannot
## feather the ball more delicately than a person is allowed to, and cannot hit
## it harder either -- if it could, the games would not be the same game.
static func _cue_speed_for_ball_speed(v: float) -> float:
	return _stroke(v * (1.0 + PoolPhys.BALL_M / PoolPhys.CUE_M)
		/ (1.0 + PoolPhys.CUE_E))


## Any stroke the CPU plays, held to the range the player's power meter spans.
static func _stroke(speed: float) -> float:
	return clampf(speed, PoolPhys.CUE_SPEED_MIN, PoolPhys.CUE_SPEED_MAX)


## Tip speed for a pot: enough on the object ball to drop, allowing for what the
## cut angle keeps back and for what the cue ball loses on the way in.
func _speed_for_pot(d_cue: float, d_obj: float, cos_cut: float) -> float:
	var v_obj := _ball_speed_for_distance(d_obj)
	var v_contact := v_obj / maxf(cos_cut, 0.30)
	var v0 := _ball_speed_for_distance(d_cue, v_contact)
	return _cue_speed_for_ball_speed(v0)
