shader_type canvas_item;

// A band of light that crosses the title every few seconds, only where the artwork is opaque.

uniform float period = 5.0;
uniform float band_width : hint_range(0.01, 0.5) = 0.09;
uniform float strength : hint_range(0.0, 2.0) = 0.85;
// The artwork is dark neon on black; this lifts it so it reads against the backdrop.
uniform float lift : hint_range(1.0, 3.0) = 1.5;

void fragment() {
	vec4 base = texture(TEXTURE, UV);
	float sweep = fract(TIME / period) * 2.6 - 0.8;
	float band = smoothstep(band_width, 0.0, abs(UV.x + (UV.y - 0.5) * 0.35 - sweep));
	float breathe = 0.92 + 0.08 * sin(TIME * 1.3);
	base.rgb = base.rgb * lift * breathe + vec3(1.0, 0.92, 1.0) * band * strength * base.a;
	COLOR = base * COLOR;
}
