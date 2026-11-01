shader_type spatial;
render_mode blend_mix, depth_draw_never, cull_disabled, unshaded, shadows_disabled;

// 建筑底部的接触阴影：中心实、边缘软，用来把建筑"压"在地面上
uniform float strength = 0.55;
uniform float falloff_start = 0.22;

void fragment() {
	vec2 uv = UV * 2.0 - 1.0;
	float d = length(uv);
	float a = (1.0 - smoothstep(falloff_start, 1.0, d)) * strength;
	ALBEDO = vec3(0.0);
	ALPHA = clamp(a, 0.0, 1.0);
}
