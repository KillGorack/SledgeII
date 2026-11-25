shader_type spatial;
// A craft's shield: a copy of its own meshes pushed out a little and drawn mostly see-through, so the tank (and
// its team color) stays visible underneath. Mostly a soft glow at the silhouette edge, with a slow energy band
// across it, and soft ripples spreading over the surface. Driven by shield_shell.gd (intensity from the shield amount, pulse when hit). Look is tuned in
// Materials/Shaders/shield_shell.tres.
render_mode blend_add, depth_draw_never, cull_back, unshaded, shadows_disabled;

uniform vec3 shield_color : source_color = vec3(0.82, 0.84, 0.86);
// Metres the shell sits out from the hull, along the (smoothed) surface normal.
uniform float inflate = 0.04;
// 0..1, set by the script from the shield amount. Everything scales with it.
uniform float intensity = 1.0;
// 0..1, set by the script: a brief brightening when the shield takes a hit.
uniform float pulse = 0.0;
// How much light the body of the shell adds (0 = nothing but the rim and ripples). The shell is ADDITIVE: it only
// adds light over the tank, never covers it, so the tank's own colors always show through.
uniform float base_alpha = 0.012;
// Extra opacity right at the silhouette edge.
uniform float rim_alpha = 0.26;
uniform float rim_power = 2.5;
// The slow band moving along the craft. 0 = none.
uniform float band_strength = 0.15;
uniform float band_scale = 2.0;
uniform float band_speed = 0.4;
// Ambient ripples: rings that spread out from a few points drifting over the hull, each fading as it travels.
// Nothing to do with hits. 0 = none.
uniform float ripple_strength = 0.9;
// Rings per metre.
uniform float ripple_scale = 4.5;
// How fast the rings travel (cycles per second).
uniform float ripple_speed = 0.35;
// How far a ring carries before it has faded out (metres).
uniform float ripple_reach = 1.2;
// A second, finer set of rings riding on the main ones (0 = none), and how much the rings wobble off perfect circles.
uniform float ripple_detail = 0.6;
uniform float ripple_wobble = 0.035;

varying vec3 local_pos;

void vertex() {
	VERTEX += NORMAL * inflate;
	local_pos = VERTEX;
}

// Expanding rings from `origin`: a thin crisp front, a faint tail behind it, and a finer set of rings on top, all
// fading with distance. The distance is wobbled a little so the rings are not perfect circles.
float ripple_from(vec3 p, vec3 origin, float phase) {
	vec3 q = p - origin;
	float len = length(q);
	float d = len + ripple_wobble * sin(q.x * 11.0 + TIME * 1.3) + ripple_wobble * 0.85 * sin(q.z * 9.0 - TIME * 1.1);
	float w = fract(d * ripple_scale - TIME * ripple_speed + phase);
	float front = smoothstep(0.0, 0.04, w) * (1.0 - smoothstep(0.04, 0.2, w));
	float tail = exp(-w * 5.0) * smoothstep(0.0, 0.04, w) * 0.22;
	float w2 = fract(d * ripple_scale * 3.3 - TIME * ripple_speed * 1.7 + phase * 2.0);
	float fine = smoothstep(0.0, 0.1, w2) * (1.0 - smoothstep(0.1, 0.35, w2));
	float reach = 1.0 - smoothstep(0.15, ripple_reach, len);
	return (front + tail + fine * ripple_detail * 0.35) * reach;
}

void fragment() {
	float facing = clamp(dot(normalize(NORMAL), normalize(VIEW)), 0.0, 1.0);
	float rim = pow(1.0 - facing, rim_power);
	float wave = 0.5 + 0.5 * sin((local_pos.z + local_pos.y * 0.5) * band_scale * 6.2831853 - TIME * band_speed * 6.2831853);
	float band = smoothstep(0.75, 1.0, wave);
	// Four slowly wandering sources so the rings never settle into a pattern.
	vec3 o1 = vec3(sin(TIME * 0.31) * 0.5, 0.15, cos(TIME * 0.27) * 0.8);
	vec3 o2 = vec3(cos(TIME * 0.23 + 2.0) * 0.5, 0.10, sin(TIME * 0.19 + 1.0) * 0.8);
	vec3 o3 = vec3(sin(TIME * 0.17 + 4.0) * 0.5, 0.20, cos(TIME * 0.21 + 3.0) * 0.8);
	vec3 o4 = vec3(cos(TIME * 0.13 + 5.0) * 0.5, 0.05, sin(TIME * 0.24 + 0.5) * 0.8);
	float ripples = ripple_from(local_pos, o1, 0.0) + ripple_from(local_pos, o2, 0.33) + ripple_from(local_pos, o3, 0.66) + ripple_from(local_pos, o4, 0.5);
	float alpha = base_alpha + rim * rim_alpha + band * band_strength * 0.2 + ripples * ripple_strength * 0.2;
	ALBEDO = shield_color * (1.0 + pulse * 0.8);
	ALPHA = clamp(alpha * intensity * (1.0 + pulse), 0.0, 1.0);
}
