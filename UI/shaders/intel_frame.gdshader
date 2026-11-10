shader_type canvas_item;

// Laid over a map's picture to make it read as a feed on a screen: faint scanlines, a band of light drifting
// down, darkened edges and a bracket in each corner. It only ever adds light or shade; the picture is the
// node underneath.

uniform vec4 tint : source_color = vec4(0.27, 0.88, 1.0, 1.0);
uniform float bracket_inset = 10.0;
uniform float bracket_length = 28.0;

void fragment() {
	vec2 pixel = fwidth(UV);
	vec2 edge = min(UV, 1.0 - UV);
	vec2 edge_px = edge / max(pixel, vec2(0.00001));

	float along_x = step(bracket_inset, edge_px.x) * step(edge_px.x, bracket_inset + bracket_length);
	float along_y = step(bracket_inset, edge_px.y) * step(edge_px.y, bracket_inset + bracket_length);
	float thin_x = step(bracket_inset, edge_px.x) * step(edge_px.x, bracket_inset + 2.0);
	float thin_y = step(bracket_inset, edge_px.y) * step(edge_px.y, bracket_inset + 2.0);
	float bracket = max(thin_x * along_y, thin_y * along_x);

	float band = smoothstep(0.1, 0.0, abs(UV.y - (fract(TIME * 0.11) * 1.4 - 0.2)));
	float light = clamp(bracket * 0.9 + band * 0.07, 0.0, 1.0);

	float scanline = step(0.5, fract(FRAGCOORD.y * 0.5)) * 0.1;
	float corner_shade = (1.0 - smoothstep(0.0, 0.16, min(edge.x * 1.78, edge.y))) * 0.4;
	float shade = clamp(scanline + corner_shade, 0.0, 1.0);

	float alpha = light + shade * (1.0 - light);
	COLOR = vec4(tint.rgb * light / max(alpha, 0.0001), alpha);
}
