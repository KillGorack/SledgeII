shader_type canvas_item;

uniform vec2 scroll_speed = vec2(0.1, 0.25); // Adjust speed (X, Y)

void fragment() {
    vec2 uv_offset = UV + TIME * scroll_speed;
    COLOR = texture(TEXTURE, uv_offset);
}
