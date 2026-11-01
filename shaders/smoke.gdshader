shader_type spatial;
render_mode unshaded, blend_mix, depth_draw_never, cull_disabled, shadows_disabled;

// 烟囱冒出的炊烟：软圆片 + 顶点色（粒子 color_ramp 控制淡出）
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
	float d = length(uv) * 2.0;
	float a = clamp(1.0 - d, 0.0, 1.0);
	a = a * a;
	ALBEDO = vec3(0.93, 0.93, 0.91);
	ALPHA = a * COLOR.a;
}
