shader_type spatial;
render_mode diffuse_burley, specular_schlick_ggx;

// 用世界坐标做三平面程序化纹理，不需要 UV。
// pattern: 0 灰泥/布 1 木纹 2 瓦片 3 石砌 4 纯色

uniform vec4 base_color : source_color = vec4(0.8, 0.7, 0.5, 1.0);
uniform int pattern = 0;
uniform float detail_scale = 1.0;
uniform float detail_strength = 0.16;
uniform float surface_roughness = 0.88;
uniform vec4 emission_color : source_color = vec4(1.0, 0.78, 0.42, 1.0);
uniform float emission_strength = 0.0;

varying vec3 wpos;
varying vec3 wnormal;

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
		p *= 2.07;
		a *= 0.5;
	}
	return v;
}

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	wnormal = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

// 三平面采样：按法线权重混合三个投影面
float triplanar(vec3 p, vec3 n, float s) {
	vec3 a = abs(n);
	float wx = pow(a.x, 4.0);
	float wy = pow(a.y, 4.0);
	float wz = pow(a.z, 4.0);
	float sum = max(wx + wy + wz, 0.0001);
	float vx = fbm(p.zy * s);
	float vy = fbm(p.xz * s);
	float vz = fbm(p.xy * s);
	return (vx * wx + vy * wy + vz * wz) / sum;
}

// 木纹：沿一个方向拉长
float wood_grain(vec3 p, vec3 n, float s) {
	vec3 a = abs(n);
	vec2 uv;
	if (a.y > 0.6) {
		uv = p.xz * vec2(s * 0.35, s * 5.0);
	} else if (a.x > a.z) {
		uv = p.zy * vec2(s * 0.35, s * 5.0);
	} else {
		uv = p.xy * vec2(s * 0.35, s * 5.0);
	}
	float g = fbm(uv);
	// 板缝
	float seam = smoothstep(0.02, 0.10, abs(fract(uv.y * 0.18) - 0.5));
	return mix(g, g * 0.80, 1.0 - seam);
}

// 瓦片：横向条 + 竖向错缝
float roof_tiles(vec3 p, vec3 n, float s) {
	vec3 a = abs(n);
	vec2 uv = a.x > a.z ? p.zy : p.xy;
	uv *= s * 0.75;
	float row = fract(uv.y);
	float off = step(0.5, fract(uv.y)) * 0.5;
	float col = fract(uv.x + off);
	float r = smoothstep(0.0, 0.22, row) * smoothstep(1.0, 0.78, row);
	float c = smoothstep(0.0, 0.14, col) * smoothstep(1.0, 0.86, col);
	return clamp(0.72 + r * c * 0.42, 0.0, 1.2);
}

// 石砌：块状分格
float stone_blocks(vec3 p, vec3 n, float s) {
	vec3 a = abs(n);
	vec2 uv = a.x > a.z ? p.zy : p.xy;
	uv *= s;
	float row = floor(uv.y);
	uv.x += mod(row, 2.0) * 0.5;
	vec2 cell = fract(uv);
	float edge = min(min(cell.x, 1.0 - cell.x), min(cell.y, 1.0 - cell.y));
	float block = smoothstep(0.02, 0.12, edge);
	float tone = hash2(floor(uv));
	return mix(0.80 + tone * 0.12, 0.98 + tone * 0.14, block);
}

void fragment() {
	vec3 n = normalize(wnormal);
	float s = detail_scale;
	float v = 0.5;

	if (pattern == 1) {
		v = wood_grain(wpos, n, s);
	} else if (pattern == 2) {
		v = roof_tiles(wpos, n, s);
	} else if (pattern == 3) {
		v = stone_blocks(wpos, n, s);
	} else if (pattern == 4) {
		v = 1.0;
	} else {
		v = triplanar(wpos, n, s * 2.5);
	}

	vec3 col = base_color.rgb;
	col *= mix(1.0 - detail_strength * 1.35, 1.0 + detail_strength * 0.85, clamp(v, 0.0, 1.0));

	// 轻微的色相偏移，避免整片死板
	col *= vec3(1.0 + (v - 0.5) * 0.06, 1.0, 1.0 - (v - 0.5) * 0.05);

	// 手绘笔触：低频拉长的噪声做色块起伏
	vec2 stroke_uv = vec2(wpos.x * 0.9 + wpos.z * 0.35, wpos.y * 2.2 + wpos.z * 0.8) * 0.55;
	float stroke = fbm(stroke_uv);
	col *= mix(0.90, 1.10, stroke);
	// 轻微色阶，保留颜料块但不要把墙面切成硬色带
	col = mix(col, floor(col * 32.0) / 32.0, 0.38);

	ALBEDO = col;
	EMISSION = emission_color.rgb * emission_strength;
	ROUGHNESS = surface_roughness;
	SPECULAR = 0.25;

	// 用噪声梯度做一点点法线扰动，制造表面颗粒感
	float e = 0.06;
	float gx = triplanar(wpos + vec3(e, 0.0, 0.0), n, s * 2.5) - v;
	float gz = triplanar(wpos + vec3(0.0, 0.0, e), n, s * 2.5) - v;
	NORMAL = normalize(NORMAL + vec3(gx, 0.0, gz) * 0.22);
}
