shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

// Procedural boarded timber: floorboards, wall panelling and trim all come out
// of this one shader at different scales.
//
// Nothing is sampled from an image. UVs arrive in *metres* -- the meshes are
// built with world-sized UVs -- so a board is the width it says it is however
// large the surface is, and the two tables' rooms are covered by the same
// material without either of them tiling visibly.
//
// The bump is taken from the same height field the colour is, sampled four more
// times around each pixel. That costs a handful of noise evaluations and means
// the grooves between boards catch the table lights properly instead of being
// painted-on lines.

uniform vec3 base_color : source_color = vec3(0.130, 0.072, 0.038);
uniform vec3 grain_color : source_color = vec3(0.260, 0.148, 0.074);
uniform float board_width = 0.155;
uniform float board_length = 1.250;
uniform float groove = 0.0045;
uniform float grain_scale = 1.0;
uniform float base_roughness = 0.42;
uniform float bump = 1.0;
// Turns the boards through a right angle, for surfaces whose grain should run
// the other way (the trim around a room runs along the wall, not across it).
uniform bool across = false;

float hash12(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453123);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	float a = hash12(i);
	float b = hash12(i + vec2(1.0, 0.0));
	float c = hash12(i + vec2(0.0, 1.0));
	float d = hash12(i + vec2(1.0, 1.0));
	return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

// Grain is noise stretched hard along the board: wood is fibrous, and isotropic
// noise reads as stone.
float grain(vec2 p) {
	float v = 0.0;
	float amp = 0.5;
	vec2 q = vec2(p.x * 0.9, p.y * 17.0) * grain_scale;
	for (int i = 0; i < 4; i++) {
		v += amp * vnoise(q);
		q *= 2.03;
		amp *= 0.5;
	}
	return v;
}

// Board index and the position within it, given a point in metres.
void board_at(vec2 p, out vec2 id, out vec2 local) {
	float row = floor(p.y / board_width);
	// Stagger the butt joints row by row, or every board ends on the same line
	// and the floor reads as a grid.
	float along = p.x + hash12(vec2(row, 7.3)) * board_length;
	float col = floor(along / board_length);
	id = vec2(col, row);
	local = vec2(fract(along / board_length), fract(p.y / board_width));
}

float height_at(vec2 p) {
	vec2 id;
	vec2 local;
	board_at(p, id, local);
	float gw = clamp(groove / board_width, 0.001, 0.4);
	float gl = clamp(groove / board_length, 0.0005, 0.4);
	float seam = smoothstep(0.0, gw, local.y) * smoothstep(0.0, gw, 1.0 - local.y)
		* smoothstep(0.0, gl, local.x) * smoothstep(0.0, gl, 1.0 - local.x);
	float g = grain(p + id * 13.0);
	// Boards are not perfectly flat, and the grooves between them are real.
	return seam * 0.85 + g * 0.15 + hash12(id) * 0.04;
}

void fragment() {
	vec2 p = across ? UV.yx : UV;

	vec2 id;
	vec2 local;
	board_at(p, id, local);

	float g = grain(p + id * 13.0);
	// Cathedral figure: the arcs across a plain-sawn board.
	float figure = 0.5 + 0.5 * sin((p.x * 5.5 + g * 6.0) * 3.14159265);

	vec3 col = mix(base_color, grain_color, clamp(0.25 + 0.75 * g, 0.0, 1.0));
	col *= 0.84 + 0.34 * hash12(id + 0.37);            // each board its own tone
	col *= 0.93 + 0.10 * figure;

	float gw = clamp(groove / board_width, 0.001, 0.4);
	float gl = clamp(groove / board_length, 0.0005, 0.4);
	float seam = smoothstep(0.0, gw, local.y) * smoothstep(0.0, gw, 1.0 - local.y)
		* smoothstep(0.0, gl, local.x) * smoothstep(0.0, gl, 1.0 - local.x);
	col *= mix(0.30, 1.0, seam);

	ALBEDO = col;
	// Wax pools in the grain and the joints, so they stay matt while the face of
	// the board polishes up.
	ROUGHNESS = clamp(base_roughness + 0.30 * (1.0 - g) + 0.25 * (1.0 - seam),
		0.18, 1.0);
	SPECULAR = 0.45;

	float e = 0.0035;
	float hx = height_at(p + vec2(e, 0.0)) - height_at(p - vec2(e, 0.0));
	float hy = height_at(p + vec2(0.0, e)) - height_at(p - vec2(0.0, e));
	vec3 n = normalize(vec3(-hx * bump * 24.0, -hy * bump * 24.0, 1.0));
	if (across) {
		n.xy = n.yx;
	}
	NORMAL_MAP = n * 0.5 + 0.5;
}
