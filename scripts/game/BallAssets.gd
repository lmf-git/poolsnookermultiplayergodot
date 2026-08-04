class_name BallAssets
extends RefCounted

## Procedurally generated ball textures and materials.
##
## There are no art assets in this project, so the balls are painted straight
## into an Image. Neither game played here uses numbered or striped balls -- UK
## pool is plain reds and yellows, snooker is plain colours -- so an object ball
## is a single flat colour, and the only thing with any marking on it is the cue
## ball.
##
## The layout assumes SphereMesh's UV convention (u = longitude, v = latitude
## from the top pole). At 2:1 texture aspect the pixel scale is isotropic at the
## equator, so the spots placed there come out round rather than smeared.

const TEX_W := 512
const TEX_H := 256

const WHITE := Color(0.965, 0.957, 0.925)


## Albedo texture for a ball. `number` 0 is the cue ball.
static func make_texture(number: int) -> ImageTexture:
	var img := Image.create_empty(TEX_W, TEX_H, true, Image.FORMAT_RGBA8)

	if number == 0:
		img.fill(WHITE)
		# The red-spot cue ball. It is a real thing on both tables, and it is the
		# only way to actually see the ball spinning -- a plain white sphere
		# under a plain white light gives away nothing about english at all.
		# Written as int() of an exact fraction rather than integer division,
		# which GDScript warns about (and rightly: it discards a remainder).
		var mid_y := int(TEX_H * 0.5)
		var quarter_x := int(TEX_W * 0.25)
		var spot := Color(0.78, 0.11, 0.10)
		for i in range(4):
			_disc(img, int(TEX_W * (0.125 + 0.25 * float(i))), mid_y, 9, spot)
		_disc(img, quarter_x, int(TEX_H * 0.12), 8, spot)
		_disc(img, quarter_x, int(TEX_H * 0.88), 8, spot)
	else:
		img.fill(PoolPhys.ball_color(number))

	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


## Filled circle with a one-pixel soft edge, wrapping horizontally.
static func _disc(img: Image, cx: int, cy: int, r: int, col: Color) -> void:
	for dy in range(-r - 1, r + 2):
		var y := cy + dy
		if y < 0 or y >= TEX_H:
			continue
		for dx in range(-r - 1, r + 2):
			var d := sqrt(float(dx * dx + dy * dy))
			if d > float(r) + 1.0:
				continue
			var x := wrapi(cx + dx, 0, TEX_W)
			var a: float = clampf(float(r) + 0.5 - d, 0.0, 1.0)
			img.set_pixel(x, y, img.get_pixel(x, y).lerp(col, a))


## Materials already built, keyed by what actually distinguishes one from
## another. Cleared when the game changes, because the colours do.
static var _cache := {}
static var _cache_mode := -1


## Phenolic resin is hard and very glossy, hence the low roughness. A touch of
## clearcoat-like specularity comes from keeping metallic at zero.
##
## Cached by colour rather than made per ball. Now that no ball carries a number,
## every red on the table is the same red: building one 512x256 texture each for
## fifteen snooker reds meant eleven megabytes of identical pixels, thrown away
## and built again on every rack. Keyed on the colour, a full snooker table needs
## seven textures and a UK pool table four.
static func make_material(number: int) -> StandardMaterial3D:
	if _cache_mode != PoolPhys.mode:
		_cache.clear()
		_cache_mode = PoolPhys.mode
	# Object balls are keyed by their colour, since that is now all there is to
	# tell them apart. The cue ball is the one that is not defined by its colour
	# -- it carries the red spots -- so it gets a key of its own. Written out
	# rather than as a ternary, whose two branches are different types.
	var key: Variant = PoolPhys.ball_color(number)
	if number == 0:
		key = "cue"
	if _cache.has(key):
		return _cache[key]

	var m := StandardMaterial3D.new()
	m.albedo_texture = make_texture(number)
	m.roughness = 0.08
	m.metallic = 0.0
	m.metallic_specular = 0.65
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	_cache[key] = m
	return m


static func make_mesh() -> SphereMesh:
	var s := SphereMesh.new()
	s.radius = PoolPhys.BALL_R
	s.height = PoolPhys.BALL_R * 2.0
	s.radial_segments = 48
	s.rings = 24
	return s
