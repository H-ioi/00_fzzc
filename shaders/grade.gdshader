shader_type canvas_item;
render_mode unshaded;

// 最终调色：分离色调 + 对比 + 饱和 + 暗角 + 轻微颗粒
uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;

uniform float chromatic = 0.0016;
uniform vec3 shadow_tint : source_color = vec3(0.96, 0.97, 1.04);
uniform vec3 highlight_tint : source_color = vec3(1.05, 1.01, 0.93);
uniform float contrast = 1.02;
uniform float saturation = 1.0;
uniform float vignette_strength = 0.26;
uniform float vignette_inner = 0.68;
uniform float vignette_outer = 1.18;
uniform float grain = 0.006;

void fragment() {
	vec3 col = texture(screen_tex, SCREEN_UV).rgb;

	// 高光偏暖、阴影偏冷
	float lum = dot(col, vec3(0.299, 0.587, 0.114));
	col *= mix(shadow_tint, highlight_tint, smoothstep(0.12, 0.86, lum));

	// 对比与饱和
	col = (col - 0.5) * contrast + 0.5;
	float l2 = dot(col, vec3(0.299, 0.587, 0.114));
	col = mix(vec3(l2), col, saturation);
	col = clamp(col, 0.0, 1.0);

	// 暗角
	vec2 uv = SCREEN_UV - 0.5;
	uv.x *= 1.05;
	float d = length(uv) * 1.42;
	col *= 1.0 - smoothstep(vignette_inner, vignette_outer, d) * vignette_strength;

	// 颗粒（用屏幕坐标做静态噪点，避免闪烁）
	float n = fract(sin(dot(SCREEN_UV * 1024.0, vec2(12.9898, 78.233))) * 43758.5453);
	col += (n - 0.5) * grain;

	COLOR = vec4(clamp(col, 0.0, 1.0), 1.0);
}
