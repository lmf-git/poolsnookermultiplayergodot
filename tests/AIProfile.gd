extends Node

## Times one CPU turn, broken down, on both tables.

func _ready() -> void:
	for mode: int in [PoolPhys.POOL, PoolPhys.SNOOKER]:
		PoolPhys.configure(mode)
		var table := PoolTable.new()
		var sim := PoolSim.new(table)
		var rng := RandomNumberGenerator.new()
		rng.seed = 7
		var cue := PoolBall.new(0, 0)
		cue.place(Vector3(0.0, 0.0, PoolPhys.HEAD_STRING_Z))
		sim.add_ball(cue)
		if mode == PoolPhys.SNOOKER:
			var id := 1
			for p in PoolTable.snooker_red_positions():
				var b := PoolBall.new(id, 1)
				b.place(Vector3(p.x, 0.0, p.y))
				sim.add_ball(b)
				id += 1
			for v in range(2, 8):
				var s := PoolPhys.snooker_spot(v)
				var b2 := PoolBall.new(id, v)
				b2.place(Vector3(s.x, 0.0, s.y))
				sim.add_ball(b2)
				id += 1
		else:
			var pos := PoolTable.rack_positions(rng)
			var nums := PoolTable.rack_numbers(rng)
			for i in range(15):
				var b3 := PoolBall.new(i + 1, nums[i])
				b3.place(Vector3(pos[i].x, 0.0, pos[i].y))
				sim.add_ball(b3)

		# Break the rack open so the planner has a real table to look at.
		var rules = RulesSnooker.new() if mode == PoolPhys.SNOOKER else RulesUKPool.new()
		rules.reset()
		rules.begin_shot(sim)
		PoolSim.cue_strike(sim.cue, Vector3(0, 0, -1), 6.0, 0.05, 0.0, 0.0, true, 0.0)
		sim.simulate_to_rest()
		rules.end_shot(sim)

		for level in range(4):
			var ai := AIPlayer.new(level, 99)
			var t0 := Time.get_ticks_usec()
			ai.begin(sim, rules, mode, false)
			# Everything the level was prepared to look at, before any of it has
			# been played out.
			var considered: int = ai._queue.size()
			var t1 := Time.get_ticks_usec()
			# One unbounded slice: this measures the whole turn, where the game
			# hands it a few milliseconds a frame instead.
			while not ai.think(10000.0):
				pass
			var t2 := Time.get_ticks_usec()
			print("%s  %-7s  considered %3d  budget %2d  build %5.1f ms  search %6.1f ms  -> %s, %.2f m/s"
				% ["snooker" if mode == PoolPhys.SNOOKER else "pool   ",
				AIPlayer.LEVEL_NAMES[level], considered, ai.skill.max_sims,
				float(t1 - t0) / 1000.0, float(t2 - t1) / 1000.0,
				ai.shot.kind, ai.shot.speed])
	get_tree().quit()
