extends Node

## The aim guide re-traces the shot every frame while aiming. It must be cheap and
## it must never spend the simulator's full event budget doing it.

func _ready() -> void:
	PoolPhys.configure(PoolPhys.POOL)
	var rng := RandomNumberGenerator.new()
	rng.seed = 4242
	var worst_ms := 0.0
	var overflows := 0
	var refreshes := 0
	var samples := 0

	# Settle a real break first: a scattered table with balls resting in contact
	# is the situation the guide struggles with.
	for trial in range(6):
		var sim := PoolSim.new()
		var cb := PoolBall.new(0, 0)
		cb.place(Vector3(0.05, 0.0, PoolPhys.HEAD_STRING_Z))
		sim.add_ball(cb)
		var pos := PoolTable.rack_positions(rng)
		var nums := PoolTable.rack_numbers(rng)
		for i in range(15):
			var b := PoolBall.new(i + 1, nums[i])
			b.place(Vector3(pos[i].x, 0.0, pos[i].y))
			sim.add_ball(b)
		sim.begin_shot()
		PoolSim.cue_strike(sim.cue, Vector3(0, 0, -1), 8.0, 0.0, 0.0, 0.0, true, 0.0)
		var t := 0.0
		while t < 40.0 and not (sim.settled() and sim.falling.is_empty()):
			sim.advance(1.0 / 240.0)
			sim.advance_drops(1.0 / 240.0)
			t += 1.0 / 240.0

		# Now sweep the aim the way a player does, refreshing every step.
		for k in range(90):
			var ang := TAU * float(k) / 90.0
			var t0 := Time.get_ticks_usec()
			var pred := sim.predict_cue_path(
				Vector3(cos(ang), 0.0, sin(ang)), 6.0,
				rng.randf_range(-0.4, 0.4), rng.randf_range(-0.5, 0.3), 0.0, PoolSim.PREDICT_SECONDS, 0.0)
			var ms := float(Time.get_ticks_usec() - t0) / 1000.0
			worst_ms = maxf(worst_ms, ms)
			refreshes += 1
			# Deterministic measure of the same work, for comparing one build
			# against another. Milliseconds here are at the mercy of whatever
			# else the machine is doing -- the same build has been seen at 16 ms
			# and at 44 ms -- so the wall clock says whether the guide is fast
			# enough today, and the sample count says whether a change made it do
			# more. The path carries a sample every 20 ms of traced shot, so this
			# is the length of shot traced, in fortieths of a second.
			samples += pred.get("path", PackedVector3Array()).size()
			if pred.get("overflowed", false):
				overflows += 1
	print("%d guide refreshes on settled tables: worst %.2f ms" % [refreshes, worst_ms])
	print("work: %d path samples total, %.1f per refresh" % [
		samples, float(samples) / float(maxi(refreshes, 1))])
	print("budget: guide %d events, real sim %d" % [
		PoolSim.PREDICT_EVENT_BUDGET, PoolSim.MAX_EVENTS_PER_STEP])
	get_tree().quit()
