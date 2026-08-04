extends Node

## Measures how high the cue ball actually gets, across cue elevation and tip
## height, so jump-shot tuning is driven by numbers instead of guesswork.

func _ready() -> void:
	print("peak hop height (cm). rows = cue elevation, cols = tip offset (fraction of R)")
	var verts := [0.0, -0.2, -0.35, -0.5, -0.62]
	var head := "elev |"
	for v: float in verts:
		head += "  %+5.2f" % v
	print(head)
	for elev_deg: float in [20.0, 30.0, 40.0, 50.0, 60.0]:
		var row := "%4.0f |" % elev_deg
		for v: float in verts:
			row += "  %5.2f" % (_peak(deg_to_rad(elev_deg), v) * 100.0)
		print(row)
	print("")
	print("a ball is %.2f cm across; a jump must clear that to be worth anything"
		% (PoolPhys.BALL_D * 100.0))
	await get_tree().process_frame
	get_tree().quit()


## Peak height above resting centre, at full power for that elevation.
func _peak(elev: float, vert: float) -> float:
	var sim := PoolSim.new()
	var b := PoolBall.new(0, 0)
	b.place(Vector3(0.0, 0.0, 1.0))
	sim.add_ball(b)
	sim.begin_shot()
	# Same power model the game uses at full charge.
	var reach: float = lerpf(1.0, 0.55, clampf(elev / deg_to_rad(60.0), 0.0, 1.0))
	PoolSim.cue_strike(b, Vector3(0, 0, -1), 9.0 * reach, 0.0, vert, elev, true, elev)
	var peak := 0.0
	for _i in range(2000):
		sim.advance(1.0 / 480.0)
		peak = maxf(peak, b.pos.y - PoolPhys.BALL_R)
		if sim.settled():
			break
	return peak
