shader_type spatial;

uniform sampler2D noise_texture;    // Noise texture
uniform float noise_intensity = 1.0;  // Strength of the noise effect
uniform float noise_speed_x = 2.0;    // Animation speed along X-axis
uniform float noise_speed_y = 1.5;    // Animation speed along Y-axis
uniform float noise_scale = 0.25;     // Scaling factor for the noise
uniform float noise_alpha = 1.0;      // Overall transparency adjustment

uniform vec3 emission_color = vec3(1.0, 1.0, 1.0); // Emission color (glow effect)
uniform float emission_intensity = 1.0;            // Emission brightness

void fragment() {
    vec2 uv = UV;

    // Step 1: Animate UV coordinates along two axes
    float time_factor_x = TIME * noise_speed_x; // Animation along X-axis
    float time_factor_y = TIME * noise_speed_y; // Animation along Y-axis

    vec2 noise_uv_x = (uv + vec2(time_factor_x, 0.0)) * noise_scale; // Horizontal movement
    vec2 noise_uv_y = (uv + vec2(0.0, time_factor_y)) * noise_scale; // Vertical movement

    // Step 2: Sample the noise texture for both axes
    float noise_value_x = texture(noise_texture, noise_uv_x).r; // Noise for X-axis
    float noise_value_y = texture(noise_texture, noise_uv_y).r; // Noise for Y-axis

    // Step 3: Blend the two noise values
    float blended_noise_value = (noise_value_x + noise_value_y) * 0.5; // Average the two

    // Step 4: Apply noise intensity
    vec3 noise_effect = vec3(blended_noise_value) * noise_intensity;

    // Step 5: Calculate emission from bright areas of the noise
    float emission_factor = max(0.0, blended_noise_value - 0.5) * 2.0; // Focus on brighter noise areas
    vec3 emission = emission_color * emission_factor * emission_intensity;

    // Step 6: Adjust alpha based on brightness
    float brightness_alpha = blended_noise_value; // Alpha is stronger for brighter noise
    float final_alpha = brightness_alpha * noise_alpha; // Scale alpha with overall adjustment

    // Outputs
    ALBEDO = noise_effect;   // Output blended noise as the RGB
    ALPHA = final_alpha;     // Apply dynamic alpha scaling
    EMISSION = emission;     // Apply emission based on bright noise areas
}
