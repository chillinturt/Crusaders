shader_type spatial;
render_mode unshaded, cull_disabled, fog_disabled, shadows_disabled;
// A portal's surface. Open: shows the other end's camera, mapped to the screen
// (not to the mesh), so it lines up exactly with the world around the doorway.
// Not open yet: a swirl in the portal's color.

uniform sampler2D view : filter_linear, repeat_disable;
uniform bool open = false;
uniform vec3 tint : source_color = vec3(0.2, 0.6, 1.0);

void fragment() {
	if (open) {
		ALBEDO = texture(view, SCREEN_UV).rgb;
	} else {
		vec2 p = UV - 0.5;
		float swirl = sin(length(p) * 28.0 - TIME * 4.0 + atan(p.y, p.x) * 3.0);
		ALBEDO = tint * (0.55 + 0.35 * swirl);
	}
}
