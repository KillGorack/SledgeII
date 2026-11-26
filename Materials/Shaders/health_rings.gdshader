shader_type canvas_item;

// The HUD's health rings (see Crafts/_scripts/health_rings.gd): up to three concentric depletion rings sharing one
// band, life innermost. Drawn here instead of with draw_arc so each ring can carry a faint animated texture.
// GDScript decides which pools exist, their warning colors and the hit flash; this only draws them.

uniform vec2 rect_size = vec2(500.0, 179.0);
uniform float vertical_stretch = 1.09;
uniform float band_inner = 41.0;
uniform float band_outer = 61.0;
uniform int ring_count = 1;
uniform vec4 track_color : source_color = vec4(0.0, 0.0, 0.0, 0.5);
// Per ring, innermost first.
uniform float ratios[3];
uniform vec4 colors[3];
uniform int kinds[3]; // 0 life, 1 armor, 2 shields
uniform float flashes[3];
// How strong the texture is (0 = flat color).
uniform float texture_strength = 1.0;
// Fill for the hole inside the innermost ring (alpha 0 = nothing, the default).
uniform vec4 center_fill : source_color = vec4(0.0);
// Edge detail: dark outline + bevel highlight on each ring, and a bright cap on the arc's leading end.
uniform float rim_width = 1.6;
uniform float rim_darkness = 0.55;
uniform float bevel_light = 0.18;
uniform float cap_light = 0.35;

void fragment() {
	COLOR = vec4(0.0);
	vec2 p = (UV - 0.5) * rect_size;
	p.y /= vertical_stretch;
	float r = length(p);
	float pitch = (band_outer - band_inner) / float(ring_count);
	float idx = floor((r - band_inner) / pitch);
	// Outside the band nothing is drawn (Godot doesn't allow an early return in fragment()).
	if (idx >= 0.0 && idx < float(ring_count)) {
		int i = int(idx);
		float lo = band_inner + pitch * idx;
		// Distance to the nearer edge of this ring. Neighbouring rings touch (no gap); the outline drawn below is
		// what separates them. Only the outer edge of the whole band is anti-aliased against transparency.
		float edge = min(r - lo, lo + pitch - r);
		float aa = max(fwidth(r), 0.5);
		float band_edge = min(r - band_inner, band_outer - r);
		float cover = smoothstep(-aa * 0.5, aa * 0.5, band_edge);

		// 0..1 clockwise from the top.
		float a = fract(atan(p.x, -p.y) / TAU);
		float ratio = ratios[i];
		float fill = ratio >= 0.999 ? 1.0 : smoothstep(-0.5, 0.5, (ratio - a) * TAU * r);
		if (ratio <= 0.0) {
			fill = 0.0;
		}

		float tex = 0.0;
		int kind = kinds[i];
		if (kind == 0) {
			// Life: a slow pulse travelling round the ring.
			tex = 0.14 * sin(a * TAU * 2.0 - TIME * 2.5);
		} else if (kind == 1) {
			// Armor: static brushed diagonal lines.
			tex = 0.08 * sin((p.x + p.y) * 1.7);
		} else {
			// Shields: a faster, finer shimmer.
			tex = 0.16 * sin(a * TAU * 8.0 - TIME * 1.8) * sin(a * TAU * 3.0 + TIME * 0.7);
		}
		vec3 c = colors[i].rgb * (1.0 + tex * texture_strength);

		// Outline: darkest right at the ring's edges. Bevel: a light line just inside the outer edge.
		float e_out = lo + pitch - r;
		float rim = 1.0 - smoothstep(0.0, rim_width, edge);
		float bevel = (1.0 - smoothstep(rim_width * 0.5, rim_width * 1.8, e_out)) * smoothstep(0.0, rim_width * 0.5, e_out);
		// Cap: bright line at the leading end of the filled arc.
		float cap = (1.0 - smoothstep(0.0, 2.0, (ratio - a) * TAU * r)) * step(0.0, ratio - a) * step(0.001, ratio) * step(ratio, 0.999);

		c += vec3(bevel * bevel_light + cap * cap_light);
		c = mix(c, c * (1.0 - rim_darkness), rim);
		c = mix(c, vec3(1.0), flashes[i] * 0.6);

		// Empty track keeps the outline too, as a faint light edge, so the ring's full extent still reads.
		vec4 empty = track_color;
		empty.rgb += vec3(0.6) * rim;
		empty.a = clamp(empty.a + rim * 0.3 + bevel * 0.08, 0.0, 1.0);
		COLOR = mix(empty, vec4(c, 1.0), fill);
		COLOR.a *= cover;
	} else if (r < band_inner) {
		// The hole inside the rings (the innermost ring's outline covers the seam).
		COLOR = center_fill;
	}
}
