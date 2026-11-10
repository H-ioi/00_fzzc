shader_type spatial;
render_mode diffuse_burley, specular_disabled;

// 树冠材质：吃 MultiMesh 实例色，再叠一层手绘笔触。tint 给没有实例色的草和灌木用。
uniform vec4 tint : source_color = vec4(1.0, 1.0, 1.0, 1.0);
varying vec3 wpos;

float hash2(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = hash2(i);
	float b = hash2(i + vec2(1.0, 0.0));
	float c = hash2(i + vec2(0.0, 1.0));
	float d = hash2(i + vec2(1.0, 1.0));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

float fbm(vec2 p) {
	float v = 0.0;
	float a = 0.5;
	for (int i = 0; i < 3; i++) {
		v += a * vnoise(p);
		p *= 2.11;
		a *= 0.5;
	}
	return v;
}

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec3 c = COLOR.rgb * tint.rgb;
	float s = fbm(vec2(wpos.x * 1.4 + wpos.z * 0.6, wpos.y * 2.6 + wpos.z * 1.2) * 1.1);
	c *= mix(0.82, 1.14, s);
	float d = vnoise(wpos.xz * 5.0 + wpos.y * 2.0);
	c *= mix(0.94, 1.06, d);
	vec3 world_n = normalize((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
	float up = clamp(world_n.y * 0.55 + 0.45, 0.0, 1.0);
	c *= mix(0.68, 1.10, up);
	float facing = clamp(dot(normalize(NORMAL), vec3(0.0, 0.0, 1.0)), 0.0, 1.0);
	c *= mix(0.94, 1.05, facing);
	c = mix(c, floor(c * 28.0) / 28.0, 0.32);
	ALBEDO = c;
	ROUGHNESS = 0.94;
}
