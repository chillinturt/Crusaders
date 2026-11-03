// World-space checkerboard so you can actually see how fast you're moving.
shader_type spatial;

uniform vec3 color_a : source_color = vec3(0.42, 0.44, 0.47);
uniform vec3 color_b : source_color = vec3(0.32, 0.34, 0.37);
uniform float cell_size = 2.0;

varying vec3 world_pos;
varying vec3 world_normal;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	world_normal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

void fragment() {
	// Nudge inward so faces sitting exactly on a cell boundary don't flicker.
	vec3 cell = floor((world_pos - world_normal * 0.01) / cell_size);
	float checker = mod(cell.x + cell.y + cell.z, 2.0);
	ALBEDO = mix(color_a, color_b, checker);
	ROUGHNESS = 0.9;
}
