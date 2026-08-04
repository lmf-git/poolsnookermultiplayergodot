shader_type spatial;
render_mode cull_back, diffuse_burley, specular_schlick_ggx;

// Painted plaster for the walls and ceiling of the room.
//
// A flat colour on a large wall is the single most obvious sign of a rendered
// room: real plaster has a slow, wide mottle from the float, a fine tooth that
// catches raking light, and it grows dirtier toward the corners. All three are
// here, and all three are cheap -- this is one of the largest surfaces on screen
// so it does the minimum that reads as a wall.
//
// UVs are in metres, as everywhere else in the room.

uniform vec3 wall_color : source_color = vec3(0.155, 0.150, 0.145);
uniform vec3 mottle_color : source_color = vec3(0.205, 0.196, 0.180);
uniform float tooth = 1.0;
uniform float base_roughness = 0.88;
// Height above the floor at which the wall is darkest, and how quickly it fades.
// A billiard room is lit from over the table, so the walls fall away upward.
uniform float shade_from = 0.4;
uniform float shade_to = 2.6;
uniform float shade_depth = 0.45;

float hash12(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453123);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash12(i), hash12(i + vec2(1.0, 0.0)), u.x),
		mix(hash12(i + vec2(0.0, 1.0)), hash12(i + vec2(1.0, 1.0)), u.x), u.y);
}

float fbm(vec2 p, int octaves) {
	float v = 0.0;
	float amp = 0.5;
	for (int i = 0; i < octaves; i++) {
		v += amp * vnoise(p);
		p *= 2.07;
		amp *= 0.5;
	}
	return v;
}

varying float height_above_floor;

void vertex() {
	height_above_floor = (MODEL_MATRIX * vec4(VERTEX, 1.0)).y;
}

void fragment() {
	// Two scales: the wide sweep of the float, and the tooth of the finish.
	float wide = fbm(UV * 0.7, 3);
	float fine = fbm(UV * 26.0, 2);

	vec3 col = mix(wall_color, mottle_color, clamp(wide * 1.25, 0.0, 1.0));
	col *= 0.94 + 0.12 * fine;
	col *= 1.0 - shade_depth * smoothstep(shade_from, shade_to, height_above_floor);

	ALBEDO = col;
	ROUGHNESS = clamp(base_roughness - 0.12 * fine, 0.5, 1.0);
	SPECULAR = 0.22;

	float e = 0.02;
	float hx = fbm((UV + vec2(e, 0.0)) * 26.0, 2) - fbm((UV - vec2(e, 0.0)) * 26.0, 2);
	float hy = fbm((UV + vec2(0.0, e)) * 26.0, 2) - fbm((UV - vec2(0.0, e)) * 26.0, 2);
	NORMAL_MAP = normalize(vec3(-hx * tooth * 2.0, -hy * tooth * 2.0, 1.0)) * 0.5 + 0.5;
}
