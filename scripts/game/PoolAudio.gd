class_name PoolAudio
extends Node

## Procedurally synthesised impact sounds.
##
## No audio files ship with the project, so each impact type is additive
## synthesis baked once into an AudioStreamWAV at startup: a fast exponential
## envelope over a couple of partials plus shaped noise. Pitch and gain are
## jittered per hit from the actual impact speed, which is what stops a break
## from sounding like a machine gun playing one sample.

const SR := 44100
const VOICES := 12

var _streams := {}
var _players: Array[AudioStreamPlayer3D] = []
var _next := 0
var _rng := RandomNumberGenerator.new()


func _ready() -> void:
	_rng.randomize()
	_streams["ball"] = _synth(0.075, _shape_ball)
	_streams["cushion"] = _synth(0.140, _shape_cushion)
	_streams["pocket"] = _synth(0.420, _shape_pocket)
	_streams["cloth"] = _synth(0.090, _shape_cloth)
	_streams["cue"] = _synth(0.060, _shape_cue)

	for _i in range(VOICES):
		var p := AudioStreamPlayer3D.new()
		p.unit_size = 2.5
		p.max_db = 0.0
		p.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_SQUARE_DISTANCE
		add_child(p)
		_players.append(p)


# --- Waveform shapes. Each returns amplitude at time t; `r` supplies noise. ---

## Phenolic on phenolic: an almost instantaneous transient over bright partials.
func _shape_ball(t: float, r: RandomNumberGenerator) -> float:
	var env := exp(-t / 0.0075)
	var click := exp(-t / 0.0008) * r.randf_range(-1.0, 1.0) * 0.55
	var partials := 0.60 * sin(TAU * 2850.0 * t) + 0.28 * sin(TAU * 4310.0 * t) \
		+ 0.14 * sin(TAU * 6900.0 * t)
	return env * partials + click


## Rubber under cloth: much lower, and the cloth adds a scuff on contact.
func _shape_cushion(t: float, r: RandomNumberGenerator) -> float:
	var env := exp(-t / 0.022)
	var body := 0.55 * sin(TAU * 196.0 * t) + 0.30 * sin(TAU * 331.0 * t)
	var scuff := exp(-t / 0.006) * r.randf_range(-1.0, 1.0) * 0.35
	return env * body + scuff


## The drop, then the ball rolling away down the return track.
func _shape_pocket(t: float, r: RandomNumberGenerator) -> float:
	var thud := exp(-t / 0.045) * (0.7 * sin(TAU * 128.0 * t) + 0.3 * sin(TAU * 88.0 * t))
	var roll := (1.0 - exp(-t / 0.05)) * exp(-t / 0.16) * r.randf_range(-1.0, 1.0) * 0.30
	return thud + roll


## A ball landing back on the bed after a hop.
func _shape_cloth(t: float, r: RandomNumberGenerator) -> float:
	return exp(-t / 0.012) * (0.45 * sin(TAU * 240.0 * t) + r.randf_range(-1.0, 1.0) * 0.45)


## Leather tip on the cue ball.
func _shape_cue(t: float, r: RandomNumberGenerator) -> float:
	var env := exp(-t / 0.0055)
	return env * (0.5 * sin(TAU * 1180.0 * t) + 0.3 * sin(TAU * 1970.0 * t)
		+ r.randf_range(-1.0, 1.0) * 0.30)


## Bake one impact into a 16-bit mono stream. `shape` receives (t, rng).
func _synth(duration: float, shape: Callable) -> AudioStreamWAV:
	var count := int(duration * float(SR))
	var data := PackedByteArray()
	data.resize(count * 2)
	var rng := RandomNumberGenerator.new()
	rng.seed = 20240729
	var peak := 0.0
	var samples := PackedFloat32Array()
	samples.resize(count)
	for i in range(count):
		var v: float = shape.call(float(i) / float(SR), rng)
		samples[i] = v
		peak = maxf(peak, absf(v))
	var norm := 0.92 / maxf(peak, 1.0e-6)
	for i in range(count):
		data.encode_s16(i * 2, int(clampf(samples[i] * norm, -1.0, 1.0) * 32767.0))

	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = SR
	w.stereo = false
	w.data = data
	return w


## `strength` is the impact speed in m/s; `ref` is the speed that counts as loud.
func play(kind: String, pos: Vector3, strength: float, ref := 4.0) -> void:
	if not _streams.has(kind):
		return
	var loud: float = clampf(strength / ref, 0.0, 1.0)
	if loud < 0.012:
		return
	var p := _players[_next]
	_next = (_next + 1) % VOICES
	p.stream = _streams[kind]
	p.position = pos
	# Harder hits are brighter as well as louder.
	p.pitch_scale = _rng.randf_range(0.93, 1.08) * (0.92 + 0.20 * loud)
	p.volume_db = linear_to_db(0.12 + 0.88 * pow(loud, 0.6))
	p.play()


## Drain everything the simulator queued since the last frame.
func flush(sim: PoolSim) -> void:
	for e in sim.sound_queue:
		var kind: String = e["kind"]
		var ref := 4.0
		if kind == "cushion":
			ref = 3.0
		elif kind == "pocket":
			ref = 2.0
		elif kind == "cloth":
			ref = 1.5
		play(kind, e["pos"], e["strength"], ref)
	sim.sound_queue.clear()
