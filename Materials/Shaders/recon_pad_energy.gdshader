shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never;

// Layered on TOP of the pad's own neutral PBR material (see recon_station.tscn) -
// additive and mostly-transparent where there's no energy, so the solid metal
// plate underneath still reads as a real surface and this is just the
// glow/spark dressing sitting just above it.

// Swap per team/captured state later (see recon_station.gd) the same way
// projectile_color already tints weapons - nothing wired to that yet, this
// is just the neutral default.
uniform vec4 pad_color : source_color = vec4(0.25, 0.85, 1.0, 1.0);

uniform float ring_speed : hint_range(0.05, 2.0) = 0.4;
uniform float ring_count : hint_range(1.0, 8.0) = 3.0;
uniform float ring_sharpness : hint_range(1.0, 40.0) = 12.0;

uniform float spark_density : hint_range(0.9, 0.999) = 0.96;
uniform float spark_speed : hint_range(0.5, 5.0) = 2.0;

uniform float edge_glow_power : hint_range(0.5, 8.0) = 3.0;
uniform float brightness : hint_range(0.2, 5.0) = 1.6;

// Cheap 2D hash - same trick sky.gdshader's starfield uses, no texture
// needed, just deterministic per-cell noise.
float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

void fragment() {
	vec2 centered = UV - vec2(0.5);
	float dist = length(centered) * 2.0; // 0 at center, 1 at the pad's rim

	// Concentric rings scrolling outward forever - fract() on a growing phase
	// loops seamlessly with no visible reset pop, same trick the sky
	// shader's scrolling cloud UVs use.
	float phase = fract(dist * ring_count - TIME * ring_speed);
	float ring = pow(abs(sin(phase * PI)), ring_sharpness);

	// Sparse flickering specks - a coarse grid of cells, most dark, a few lit
	// and flickering independently of each other so they don't blink in
	// lockstep, same per-cell-hash approach as the sky shader's stars.
	vec2 spark_cell = floor(UV * 18.0);
	float spark_h = hash12(spark_cell);
	float spark_on = step(spark_density, spark_h);
	float spark_flicker = 0.5 + 0.5 * sin(TIME * spark_speed * (1.0 + spark_h * 4.0) + spark_h * 20.0);
	float sparks = spark_on * spark_flicker;

	// Brightens toward the rim - there's no usable surface normal to fresnel
	// against on a flat overlay quad, so this fakes the same "glowing edge"
	// look directly off distance-from-center instead.
	float edge_glow = pow(clamp(dist, 0.0, 1.0), edge_glow_power);

	float energy = ring + sparks + edge_glow * 0.5;
	ALBEDO = pad_color.rgb * brightness * energy;
	ALPHA = clamp(energy, 0.0, 1.0) * pad_color.a;
}
