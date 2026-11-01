shader_type canvas_item;

// 圆形小地图：裁成圆形并在边缘压暗，模拟概念图里的罗盘地图
uniform float edge = 0.48;
uniform vec4 ring_col : source_color = vec4(0.42, 0.33, 0.22, 1.0);

void fragment() {
	vec2 uv = UV - 0.5;
	float d = length(uv);
	if (d > edge) {
		discard;
	}
	vec4 base = texture(TEXTURE, UV);
	float vig = 1.0 - smoothstep(edge * 0.72, edge, d) * 0.55;
	base.rgb *= vig;
	COLOR = base * COLOR;
}
