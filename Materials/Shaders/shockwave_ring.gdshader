shader_type spatial;
render_mode unshaded, blend_mix, cull_disabled, depth_draw_never;

uniform vec4 ring_color : source_color = vec4(1.0, 0.85, 0.4, 1.0);
uniform float progress : hint_range(0.0, 1.0) = 0.0;
uniform float ring_thickness : hint_range(0.01, 0.3) = 0.06;
uniform float edge_softness : hint_range(0.001, 0.1) = 0.02;
uniform float fade_alpha : hint_range(0.0, 1.0) = 1.0;

void fragment() {
	vec2 centered_uv = UV - vec2(0.5);
	float dist = length(centered_uv);

	float current_radius = progress * 0.5;
	float inner_edge = current_radius - ring_thickness * 0.5;
	float outer_edge = current_radius + ring_thickness * 0.5;
	float band = smoothstep(inner_edge - edge_softness, inner_edge, dist)
		- smoothstep(outer_edge, outer_edge + edge_softness, dist);

	ALBEDO = ring_color.rgb;
	ALPHA = band * fade_alpha * ring_color.a;
}
