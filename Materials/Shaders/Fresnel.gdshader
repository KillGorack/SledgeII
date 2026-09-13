shader_type spatial;

vec3 fresnel_glow(float amount, float intensity, vec3 color, vec3 normal, vec3 view)
{
    return pow((1.0 - dot(normalize(normal), normalize(view))), amount) * color * intensity;
}

void fragment()
{
    vec3 base_color = vec3(0.0, 0.0, 0.0);
    vec3 fresnel_color = vec3(0.0, 0.7, 0.9);

    // Ripple effect applied to Fresnel glow
    float ripple = sin(TIME * 10.0 + UV.x * 50.0) * 3.0; // Adjust speed & strength
    vec3 fresnel = fresnel_glow(12.0 + ripple, 8.0 + ripple, fresnel_color, NORMAL, VIEW);

    ALBEDO = base_color + fresnel;
    ALPHA = 0.5;
    EMISSION = fresnel * (10.0 - ALPHA);
}
