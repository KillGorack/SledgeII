shader_type sky;

uniform vec3 sky_top_color : source_color = vec3(0.385, 0.454, 0.55);
uniform vec3 sky_horizon_color : source_color = vec3(0.646, 0.655, 0.67);
uniform vec3 ground_color : source_color = vec3(0.2, 0.169, 0.133);
uniform float sun_angle : hint_range(0.0, 90.0) = 15.0;
uniform vec2 sun_azimuth_dir = vec2(1.0, 0.0);
uniform float cloud_density : hint_range(0.0, 1.0) = 0.5;
uniform float cloud_speed_1 : hint_range(0.0, 2.0) = 0.1;
uniform float cloud_speed_2 : hint_range(0.0, 2.0) = 0.07;
uniform vec2 cloud_dir_1 = vec2(1.0, 1.0);
uniform vec2 cloud_dir_2 = vec2(-1.0, 1.0);
uniform float cloud_aspect : hint_range(0.02, 2.0) = 1.0;
uniform vec3 cloud_color_1 : source_color = vec3(0.8, 0.9, 1.0);
uniform vec3 cloud_color_2 : source_color = vec3(1.0, 0.9, 0.8);
uniform sampler2D noise_texture;
uniform sampler2D sun_texture;
uniform sampler2D moon_texture;
uniform float moon_size : hint_range(0.005, 0.1) = 0.02;
uniform vec2 cloud_scale_1 = vec2(1.0, 1.0);
uniform vec2 cloud_scale_2 = vec2(1.0, 1.0);
uniform vec2 ground_texture_scale = vec2(0.3, 0.3);
uniform vec2 ground_texture_speed = vec2(0.0, 0.0);
uniform float ground_texture_strength : hint_range(0.0, 1.0) = 0.15;
uniform vec3 ground_texture_color : source_color = vec3(0.12, 0.1, 0.08);

// Starfield — independent of everything else above, toggle on/off freely.
uniform bool stars_enabled = false;
uniform float star_scale : hint_range(10.0, 200.0) = 200.0; // higher = smaller/denser star grid
uniform float star_density : hint_range(0.9, 0.999) = 0.98; // higher = fewer stars
uniform float star_brightness : hint_range(0.0, 3.0) = 1.2;
uniform vec3 star_color : source_color = vec3(1.0, 1.0, 1.0);


// Cheap 3D->1D hash — no texture needed, just deterministic noise per grid cell.
float hash13(vec3 p) {
    p = fract(p * 0.1031);
    p += dot(p, p.yzx + 33.33);
    return fract((p.x + p.y) * p.z);
}


vec3 get_stars(vec3 dir, float sky_visibility, float cloud_coverage) {
    vec3 grid = dir * star_scale;
    vec3 cell = floor(grid);
    vec3 local = fract(grid) - 0.08;
    float h = hash13(cell);
    if (h < star_density) {
        return vec3(0.0);
    }
    float dot_size = mix(0.05, 0.35, fract(h * 17.0)); // vary star size a bit so it doesn't look uniform
    float dot_mask = smoothstep(dot_size, 0.0, length(local));
    float twinkle = 0.7 + 0.3 * sin(TIME * (1.0 + h * 5.0) + h * 6.2831853);
    return star_color * dot_mask * twinkle * star_brightness * sky_visibility * (1.0 - cloud_coverage);
}


vec3 get_sky_color(vec3 dir) {
    float horizon_factor = clamp(dir.y, -1.0, 1.0);
    float blend = smoothstep(-0.1, 0.2, horizon_factor);
    vec3 base_color = mix(ground_color, mix(sky_horizon_color, sky_top_color, blend), blend);
    float sky_visibility = smoothstep(-0.05, 0.15, dir.y);
    float ground_visibility = 1.0 - sky_visibility;
    if (ground_visibility > 0.0) {
        float ground_safe_y = min(dir.y - 0.5, -0.01);
        vec2 ground_uv = dir.xz / ground_safe_y * ground_texture_scale + TIME * ground_texture_speed;
        float ground_noise = texture(noise_texture, ground_uv).r;
        base_color = mix(base_color, ground_texture_color, ground_noise * ground_texture_strength * ground_visibility);
    }
    float safe_y = max(dir.y + 0.5, 0.01);
    vec2 cloud_uv1 = dir.xz / safe_y * cloud_scale_1;
    cloud_uv1.x *= cloud_aspect;
    cloud_uv1 += TIME * cloud_speed_1 * cloud_dir_1;
    float noise1 = texture(noise_texture, cloud_uv1).r;
    float cloud_mask1 = smoothstep(1.0 - cloud_density, 1.0, noise1) * sky_visibility;
    vec2 cloud_uv2 = dir.xz / safe_y * cloud_scale_2;
    cloud_uv2.x *= cloud_aspect;
    cloud_uv2 += TIME * cloud_speed_2 * cloud_dir_2;
    float noise2 = texture(noise_texture, cloud_uv2).r;
    float cloud_mask2 = smoothstep(1.0 - cloud_density, 1.0, noise2) * sky_visibility;
    vec3 cloud_tint_1 = mix(base_color, cloud_color_1, cloud_mask1 * 0.6);
    vec3 cloud_tint_2 = mix(base_color, cloud_color_2, cloud_mask2 * 0.6);
    vec3 final_color = max(cloud_tint_1, cloud_tint_2);
    if (stars_enabled) {
        float cloud_coverage = max(cloud_mask1, cloud_mask2);
        final_color += get_stars(dir, sky_visibility, cloud_coverage);
    }
    float sun_el = radians(sun_angle);
    vec2 az = length(sun_azimuth_dir) > 0.0001 ? normalize(sun_azimuth_dir) : vec2(1.0, 0.0);
    vec3 sun_direction = normalize(vec3(az.x * cos(sun_el), sin(sun_el), az.y * cos(sun_el)));
    float sun_size = 0.025; // Controls sun size (try adjusting for your texture)
    float angle_to_sun = acos(dot(normalize(dir), sun_direction));
    // Smooth falloff over the outer ~12% of the disc radius, independent of
    // the raw texture's own alpha - avoids the hard-edged/blocky look two
    // overlapping binary cutoffs (circular angle check + square UV bounds)
    // would otherwise produce with no antialiasing.
    float sun_disc = 1.0 - smoothstep(sun_size * 0.88, sun_size, angle_to_sun);
    if (sun_disc > 0.0) {
        vec3 rel = dir - sun_direction;
        vec3 up = abs(sun_direction.y) < 0.99 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0);
        vec3 right = normalize(cross(up, sun_direction));
        vec3 sun_up = normalize(cross(sun_direction, right));
        float u = dot(rel, right) / sun_size * 0.5 + 0.5;
        float v = dot(rel, sun_up) / sun_size * 0.5 + 0.5;
        if (u >= 0.0 && u <= 1.0 && v >= 0.0 && v <= 1.0) {
            vec2 sun_uv = vec2(u, v);
            vec4 sun_tex_color = texture(sun_texture, sun_uv);
            // Blend sun texture over sky using its alpha, faded by the disc edge
            final_color = mix(final_color, sun_tex_color.rgb, sun_tex_color.a * sun_disc);
        }
    }
    // Moon sits directly opposite the sun in the sky (same fixed azimuth,
    // negated direction) - when the sun sets on one horizon, the moon rises
    // on the other, same as env.gd derives it for the actual light.
    vec3 moon_direction = -sun_direction;
    float angle_to_moon = acos(dot(normalize(dir), moon_direction));
    float moon_disc = 1.0 - smoothstep(moon_size * 0.88, moon_size, angle_to_moon);
    if (moon_disc > 0.0) {
        vec3 rel = dir - moon_direction;
        vec3 up = abs(moon_direction.y) < 0.99 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0);
        vec3 right = normalize(cross(up, moon_direction));
        vec3 moon_up = normalize(cross(moon_direction, right));
        float u = dot(rel, right) / moon_size * 0.5 + 0.5;
        float v = dot(rel, moon_up) / moon_size * 0.5 + 0.5;
        if (u >= 0.0 && u <= 1.0 && v >= 0.0 && v <= 1.0) {
            vec2 moon_uv = vec2(u, v);
            vec4 moon_tex_color = texture(moon_texture, moon_uv);
            final_color = mix(final_color, moon_tex_color.rgb, moon_tex_color.a * moon_disc);
        }
    }
    return final_color;
}

void sky() {
    vec3 dir = normalize(EYEDIR);
    COLOR = get_sky_color(dir);
}