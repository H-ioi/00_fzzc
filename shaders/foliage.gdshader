shader_type spatial;
render_mode diffuse_burley, specular_disabled;

// 树冠材质：吃 MultiMesh 实例色，再叠一层手绘笔触与色阶
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
	vec3 c = COLOR.rgb;
	// 叶簇笔触：沿树冠高度拉长的低频噪声
	float s = fbm(vec2(wpos.x * 1.4 + wpos.z * 0.6, wpos.y * 2.6 + wpos.z * 1.2) * 1.1);
	c *= mix(0.80, 1.16, s);
	// 少量高频斑点，像叶片的明暗碎块
	float d = vnoise(wpos.xz * 5.0 + wpos.y * 2.0);
	c *= mix(0.94, 1.07, d);
	// 色阶量化
	c = floor(c * 22.0) / 22.0;
	ALBEDO = c;
	ROUGHNESS = 0.96;
}
