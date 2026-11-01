shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

uniform vec4 shallow_col : source_color = vec4(0.09, 0.40, 0.46, 1.0);
uniform vec4 deep_col : source_color = vec4(0.03, 0.13, 0.22, 1.0);
uniform vec4 foam_col : source_color = vec4(0.90, 0.94, 0.94, 1.0);
uniform vec4 sky_col : source_color = vec4(0.58, 0.70, 0.80, 1.0);
uniform sampler2D depth_mask : filter_linear, repeat_disable;
uniform sampler2D reflection_tex : filter_linear, repeat_disable;
uniform vec2 mask_origin = vec2(-24.0, -24.0);
uniform float mask_extent = 176.0;
uniform float wave_height = 0.16;

varying vec3 wpos;

// 三组方向波叠加；返回高度，同时输出解析法线
float wave_h(vec2 p, float t) {
	return wave_height * (
		sin(p.x * 0.55 + t * 1.10) * 0.55
		+ sin(p.y * 0.78 - t * 0.90) * 0.45
		+ sin((p.x + p.y) * 1.15 + t * 1.60) * 0.28);
}

vec2 wave_d(vec2 p, float t) {
	return wave_height * vec2(
		cos(p.x * 0.55 + t * 1.10) * 0.55 * 0.55
		+ cos((p.x + p.y) * 1.15 + t * 1.60) * 0.28 * 1.15,
		cos(p.y * 0.78 - t * 0.90) * 0.45 * 0.78
		+ cos((p.x + p.y) * 1.15 + t * 1.60) * 0.28 * 1.15);
}

void vertex() {
	vec3 wp = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	VERTEX.y += wave_h(wp.xz, TIME);
	wpos = wp;
}

void fragment() {
	float dep = texture(depth_mask, clamp((wpos.xz - mask_origin) / mask_extent, vec2(0.0), vec2(1.0))).r;
	vec2 ruv = (wpos.xz - mask_origin) / mask_extent;
	vec2 dd = max(abs(ruv - 0.5) - 0.5, vec2(0.0));
	float outside = clamp(max(dd.x, dd.y) * 30.0, 0.0, 1.0);
	dep = mix(dep, 1.0, outside);

	vec3 col = mix(shallow_col.rgb, deep_col.rgb, smoothstep(0.02, 0.55, dep));

	// 岸边泡沫
	float edge = (1.0 - smoothstep(0.0, 0.14, dep)) * (1.0 - outside);
	float pulse = 0.55 + 0.45 * sin(TIME * 1.6 + wpos.x * 0.85 + wpos.z * 0.65);
	col = mix(col, foam_col.rgb, clamp(edge * pulse, 0.0, 1.0) * 0.80);
	// 更宽的浅水提亮带，模拟浪花外缘
	float surf = (1.0 - smoothstep(0.02, 0.30, dep)) * (1.0 - outside);
	col = mix(col, shallow_col.rgb * 1.12, surf * 0.45);

	// 解析法线：让波浪真的反光
	vec2 grad = wave_d(wpos.xz, TIME);
	vec3 nrm = normalize(vec3(-grad.x, 1.0, -grad.y));
	NORMAL = nrm;

	// 菲涅尔反射天空
	vec3 view_dir = normalize(CAMERA_POSITION_WORLD - wpos);
	float ndv = clamp(dot(nrm, view_dir), 0.0, 1.0);
	float fres = pow(1.0 - ndv, 2.6);
	col = mix(col, sky_col.rgb, fres * 0.38);

	ALBEDO = col;
	ALPHA = mix(0.80, 0.99, smoothstep(0.02, 0.35, dep));
	ALPHA = max(ALPHA, clamp(edge * pulse, 0.0, 1.0) * 0.85);
	ALPHA = mix(ALPHA, 1.0, fres * 0.3);

	ROUGHNESS = 0.05;
	METALLIC = 0.10;
	SPECULAR = 0.7;
}
