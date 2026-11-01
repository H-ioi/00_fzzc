shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled, shadows_disabled;

// 雨丝：面向相机的细长条，两端淡出
void vertex() {
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(
		INV_VIEW_MATRIX[0], INV_VIEW_MATRIX[1], INV_VIEW_MATRIX[2], MODEL_MATRIX[3]);
	MODELVIEW_MATRIX = MODELVIEW_MATRIX * mat4(
		vec4(length(MODEL_MATRIX[0].xyz), 0.0, 0.0, 0.0),
		vec4(0.0, length(MODEL_MATRIX[1].xyz), 0.0, 0.0),
		vec4(0.0, 0.0, length(MODEL_MATRIX[2].xyz), 0.0),
		vec4(0.0, 0.0, 0.0, 1.0));
}

void fragment() {
	vec2 uv = UV - 0.5;
	float ax = pow(1.0 - clamp(abs(uv.x) * 2.0, 0.0, 1.0), 1.8);
	float ay = 1.0 - clamp(abs(uv.y) * 2.0, 0.0, 1.0);
	ALBEDO = vec3(0.56, 0.62, 0.74);
	ALPHA = ax * ay * 0.22;
}
