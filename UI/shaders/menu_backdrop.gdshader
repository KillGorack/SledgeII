shader_type canvas_item;

// The menu's backdrop, drawn on one full-screen ColorRect: drifting nebula, two layers of stars, and a neon
// grid floor running off to a horizon. `intensity` is turned down by index.gd once panels cover the screen, so
// the grid never fights the text in front of it.

uniform sampler2D stars : repeat_enable, filter_linear_mipmap;
uniform vec3 color_deep : source_color = vec3(0.012, 0.016, 0.045);
uniform vec3 color_violet : source_color = vec3(0.42, 0.25, 1.0);
uniform vec3 color_pink : source_color = vec3(1.0, 0.2, 0.62);
uniform vec3 color_cyan : source_color = vec3(0.2, 0.85, 1.0);
uniform float horizon : hint_range(0.3, 0.9) = 0.6;
uniform float grid_speed = 0.35;
uniform float intensity : hint_range(0.0, 1.0) = 1.0;

float hash(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

float noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), f.x), mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), f.x), f.y);
}

float fbm(vec2 p) {
	float value = 0.0;
	float amp = 0.5;
	// Each layer is turned as well as scaled, so the noise's square cells never line up into visible blocks.
	mat2 turn = mat2(vec2(0.8, 0.6), vec2(-0.6, 0.8));
	for (int i = 0; i < 5; i++) {
		value += amp * noise(p);
		p = turn * p * 2.03 + vec2(17.1, 9.2);
		amp *= 0.5;
	}
	return value;
}

void fragment() {
	vec2 res = 1.0 / SCREEN_PIXEL_SIZE;
	float aspect = res.x / res.y;
	vec2 uv = UV;
	vec2 p = vec2((uv.x - 0.5) * aspect, uv.y);
	float t = TIME;

	// Sky: near-black at the top, a little indigo toward the horizon.
	vec3 col = mix(color_deep, color_deep + color_violet * 0.07, smoothstep(0.0, horizon, uv.y));

	// Nebula: two slow clouds, violet and pink, with a cyan rim where they overlap.
	float cloud_a = fbm(p * 1.6 + vec2(t * 0.012, -t * 0.008));
	float cloud_b = fbm(p * 2.3 + vec2(-t * 0.015, t * 0.006) + 7.3);
	float sky_mask = 1.0 - smoothstep(horizon - 0.35, horizon + 0.02, uv.y) * 0.55;
	col += color_violet * smoothstep(0.42, 0.85, cloud_a) * 0.22 * sky_mask;
	col += color_pink * smoothstep(0.5, 0.9, cloud_b) * 0.14 * sky_mask;
	col += color_cyan * smoothstep(0.55, 0.8, cloud_a * cloud_b * 2.2) * 0.1 * sky_mask;

	// Stars: two layers drifting at different speeds, the near one twinkling.
	float above = 1.0 - smoothstep(horizon - 0.04, horizon, uv.y);
	vec4 far_stars = texture(stars, p * 1.9 + vec2(t * 0.004, t * 0.002));
	vec4 near_stars = texture(stars, p * 1.15 + vec2(t * 0.009, -t * 0.003) + 0.37);
	float twinkle = 0.75 + 0.25 * sin(t * 1.7 + hash(floor(p * 40.0)) * 6.2831);
	col += far_stars.rgb * far_stars.a * 0.45 * above;
	col += near_stars.rgb * near_stars.a * 0.85 * twinkle * above;

	// The grid floor below the horizon.
	float below = uv.y - horizon;
	if (below > 0.0) {
		float depth = 0.11 / below;
		vec2 world = vec2((uv.x - 0.5) * aspect * depth * 2.4, depth + t * grid_speed);
		vec2 grid = world * 2.0;
		vec2 width = fwidth(grid);
		vec2 dist = abs(fract(grid - 0.5) - 0.5) / max(width, vec2(0.0001));
		float line = 1.0 - min(min(dist.x, dist.y), 1.0);
		// A soft halo around each line, and a fade where the lines get too dense to draw cleanly.
		vec2 halo_dist = abs(fract(grid - 0.5) - 0.5);
		float halo = exp(-min(halo_dist.x, halo_dist.y) * 14.0) * 0.35;
		float clean = 1.0 - smoothstep(0.25, 0.9, max(width.x, width.y));
		float near_fade = smoothstep(0.0, 0.1, below);
		vec3 grid_color = mix(color_pink, color_cyan, smoothstep(0.0, 0.45, below));
		// A band of light that rolls toward the viewer every few seconds.
		float pulse = exp(-abs(fract(world.y * 0.08 - t * 0.12) - 0.5) * 9.0);
		vec3 floor_col = color_deep * 0.6 + grid_color * (line + halo) * clean * near_fade * (0.55 + pulse * 0.9);
		col = mix(col, floor_col, smoothstep(0.0, 0.012, below));
	}

	// The glow sitting on the horizon line.
	float glow = exp(-abs(uv.y - horizon) * 26.0);
	float core = exp(-abs(uv.y - horizon) * 320.0);
	col += mix(color_pink, color_violet, 0.35) * glow * 0.42;
	col += vec3(1.0, 0.8, 0.95) * core * 0.75;

	// Turned down behind the working screens, then finished with scanlines and a vignette.
	col = mix(color_deep + (col - color_deep) * 0.34, col, intensity);
	col *= 0.965 + 0.035 * sin(FRAGCOORD.y * 3.14159);
	vec2 corner = (uv - 0.5) * vec2(1.1, 1.25);
	col *= 1.0 - smoothstep(0.35, 1.05, dot(corner, corner) * 2.0) * 0.75;

	COLOR = vec4(col, 1.0);
}
