extends Node

## How high does a level cue scoop the ball from various tip heights?

func _ready() -> void:
	PoolPhys.configure(PoolPhys.POOL)
	print("level cue (0 deg elevation), full power:")
	print("  tip      v0     peak hop")
	for tip: float in [0.0, -0.20, -0.35, -0.40, -0.46, -0.52, -0.58, -0.66]:
		var sim := PoolSim.new()
		var b := PoolBall.new(0, 0)
		b.place(Vector3(0.0, 0.0, 1.0))
		sim.add_ball(b)
		sim.begin_shot()
		PoolSim.cue_strike(b, Vector3(0, 0, -1), 9.0, 0.0, tip, 0.0, true, 0.0)
		var v0 := b.vel.length()
		var peak := 0.0
		for _i in range(1500):
			sim.advance(1.0 / 480.0)
			peak = maxf(peak, b.pos.y - PoolPhys.BALL_R)
			if sim.settled():
				break
		print("  %+5.2f   %5.2f    %5.2f cm%s%s" % [tip, v0, peak * 100.0,
			"   clears a ball" if peak > PoolPhys.BALL_D else "",
			"   (miscue)" if absf(tip) > PoolPhys.MAX_TIP_OFFSET else ""])
	print("ball diameter %.2f cm; scoop starts at tip %.2f"
		% [PoolPhys.BALL_D * 100.0, PoolPhys.SCOOP_START])
	get_tree().quit()
