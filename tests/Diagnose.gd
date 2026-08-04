extends Node

## Scratch diagnostic: run a break with tracing on and report where the event
## solver is burning its budget.

func _ready() -> void:
	var sim := PoolSim.new()
	var cb := PoolBall.new(0, 0)
	cb.place(Vector3(0.05, 0.0, PoolPhys.HEAD_STRING_Z + 0.1))
	sim.add_ball(cb)
	var rng := RandomNumberGenerator.new()
	rng.seed = 1
	var pos := PoolTable.rack_positions(rng)
	var nums := PoolTable.rack_numbers(rng)
	for i in range(15):
		var b := PoolBall.new(i + 1, nums[i])
		b.place(Vector3(pos[i].x, 0.0, pos[i].y))
		sim.add_ball(b)
	sim.begin_shot()
	sim.trace_events = true
	PoolSim.cue_strike(sim.cue, (Vector3(0.0, PoolPhys.BALL_R, PoolPhys.FOOT_SPOT_Z)
		- cb.pos).normalized(), 8.0, 0.0, 0.0, 0.0)

	var t := 0.0
	var steps := 0
	while not sim.settled() and t < 20.0 and not sim.overflowed:
		sim.advance(0.05)
		t += 0.05
		steps += 1

	print("table time: %.3f   events: %d   overflowed: %s" % [t, sim.event_count, sim.overflowed])

	var names := ["NONE", "PHASE", "BALL", "CUSHION", "JAW", "POCKET"]
	var hist := {}
	var zero_steps := 0
	for e in sim.trace:
		var k: String = names[e[2]]
		hist[k] = int(hist.get(k, 0)) + 1
		if e[1] < 1.0e-9:
			zero_steps += 1
	print("last-%d event mix: %s   zero-length steps: %d" % [sim.trace.size(), hist, zero_steps])

	print("tail of trace (shot_time, dt, type, a, b):")
	var start: int = maxi(0, sim.trace.size() - 30)
	for i in range(start, sim.trace.size()):
		var e: Array = sim.trace[i]
		print("  t=%.6f dt=%.9f %s a=%d b=%d" % [e[0], e[1], names[e[2]], e[3], e[4]])

	print("ball states:")
	for b in sim.balls:
		print("  #%d state=%d pos=(%.4f, %.4f, %.4f) v=%.4f w=%.2f" % [
			b.number, b.state, b.pos.x, b.pos.y, b.pos.z, b.vel.length(), b.avel.length()])

	await get_tree().process_frame
	get_tree().quit()
