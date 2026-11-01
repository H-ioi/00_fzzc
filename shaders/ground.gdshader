shader_type spatial;
render_mode specular_disabled, diffuse_burley;

uniform vec4 grass_a : source_color = vec4(0.31, 0.35, 0.21, 1.0);
uniform vec4 grass_b : source_color = vec4(0.38, 0.41, 0.26, 1.0);
uniform vec4 grass_c : source_color = vec4(0.25, 0.29, 0.17, 1.0);
uniform vec4 sand_col : source_color = vec4(0.74, 0.67, 0.49, 1.0);
uniform vec4 dirt_col : source_color = vec4(0.40, 0.31, 0.20, 1.0);
uniform vec4 line_col : source_color = vec4(0.13, 0.18, 0.10, 1.0);
uniform vec4 dry_col : source_color = vec4(0.44, 0.40, 0.24, 1.0);
uniform vec4 winter_col : source_color = vec4(0.82, 0.86, 0.92, 1.0);
uniform float cell_size = 2.0;
uniform float world_size = 128.0;
uniform float line_strength = 0.45;
uniform float grid_alpha = 0.22;
uniform float winter_mix = 0.0;
uniform float wet = 0.0;
uniform float water_level = 1.15;
uniform float cloud_time = 0.0;
uniform float snow_line = 33.0;
uniform sampler2D road_mask : filter_linear, repeat_disable;
uniform sampler2D dirt_mask : filter_linear, repeat_disable;
uniform sampler2D plaza_mask : filter_linear, repeat_disable;

varying vec3 wpos;

float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}

// 石板铺装：错缝方格 + 逐块色调差异
vec3 cobbles(vec2 p) {
	vec2 c = p * 2.2;
	vec2 cell = floor(c);
	vec2 f = fract(c);
	f.x = fract(f.x + mod(cell.y, 2.0) * 0.5);
	float edge = min(min(f.x, 1.0 - f.x), min(f.y, 1.0 - f.y));
	float tone = hash(cell);
	vec3 stone = mix(vec3(0.24, 0.21, 0.17), vec3(0.42, 0.37, 0.31), tone);
	float t = smoothstep(0.015, 0.10, edge);
	return mix(stone * 0.55, stone, t);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = hash(i);
	float b = hash(i + vec2(1.0, 0.0));
	float c = hash(i + vec2(0.0, 1.0));
	float d = hash(i + vec2(1.0, 1.0));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

float fbm(vec2 p) {
	float v = 0.0;
	float a = 0.5;
	for (int i = 0; i < 4; i++) {
		v += a * vnoise(p);
		p *= 2.03;
		a *= 0.5;
	}
	return v;
}

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	mat2 rot = mat2(vec2(0.80, 0.60), vec2(-0.60, 0.80));
	float f = fbm(rot * wpos.xz * 0.10);
	vec3 base = mix(grass_a.rgb, grass_b.rgb, smoothstep(0.20, 0.82, f));

	float big = vnoise(rot * wpos.xz * 0.012 + 7.0);
	base *= 0.90 + 0.20 * big;

	// 枯草斑块：让草地有明暗干湿的变化
	float dry = smoothstep(0.56, 0.88, vnoise(rot * wpos.xz * 0.21 + 17.0));
	base = mix(base, dry_col.rgb, dry * 0.30);

	// 细颗粒：消除"喷枪上色"的均匀感
	float fine = vnoise(rot * wpos.xz * 3.4);
	float micro = vnoise(wpos.xz * 9.0);
	base *= 0.95 + 0.10 * fine + 0.04 * micro;

	float grain = vnoise(wpos.xz * 1.7);
	base *= 0.96 + 0.08 * grain;

	// 道路：从遮罩采样，用噪声扰动边缘，融进草地
	vec2 ruv = wpos.xz / world_size;
	vec2 warp = vec2(vnoise(wpos.xz * 0.55), vnoise(wpos.xz * 0.55 + 31.0)) - 0.5;
	float m = texture(road_mask, ruv + warp * 0.008).r;
	float path = smoothstep(0.34, 0.62, m);
	vec3 dirt = dirt_col.rgb * (0.82 + 0.36 * vnoise(wpos.xz * 0.85));
	dirt *= 0.94 + 0.12 * grain;
	// 土路上的碎石子
	dirt = mix(dirt, dirt * 1.35, smoothstep(0.72, 0.95, micro) * 0.6);
	base = mix(base, dirt, path);
	// 路缘被踩秃的一圈，颜色更浅
	float worn = clamp(smoothstep(0.08, 0.34, m) - path, 0.0, 1.0);
	base = mix(base, base * 1.14, worn * 0.8);

	// 建筑周围被踩踏的裸土
	float dm = texture(dirt_mask, ruv + warp * 0.010).r;
	float worn2 = smoothstep(0.15, 0.75, dm) * 0.55;
	vec3 bare = dirt_col.rgb * 0.92 * (0.85 + 0.3 * vnoise(wpos.xz * 1.3));
	base = mix(base, bare, worn2);

	// 中央广场的石板铺装
	float pm = texture(plaza_mask, ruv + warp * 0.006).r;
	float pave = smoothstep(0.35, 0.62, pm);
	base = mix(base, cobbles(wpos.xz), pave);

	// 水线附近形成河岸沙滩（不再依赖地图边缘）
	float above = wpos.y - water_level;
	float wobble = (vnoise(wpos.xz * 0.09) - 0.5) * 0.55;
	float beach = 1.0 - smoothstep(0.03, 0.16 + wobble * 0.5, above);
	beach *= step(-0.45, above);
	// 沙滩分层：高处干沙更浅，靠近水线湿沙更深
	float sand_t = smoothstep(-0.30, 1.10, above);
	vec3 sand = sand_col.rgb * mix(0.80, 1.16, sand_t);
	base = mix(base, sand, beach * 0.72);
	// 河谷绿廊：贴着水面的低地更湿润、更深绿，让河道在远景也能被看出来
	float lush = (1.0 - smoothstep(0.15, 1.05, above)) * 0.55;
	base = mix(base, base * vec3(0.80, 0.98, 0.74), lush);
	// 沙滩上的贝壳与碎石
	float shell = smoothstep(0.88, 0.98, vnoise(wpos.xz * 4.5)) * beach;
	base = mix(base, vec3(0.88, 0.85, 0.78), shell * 0.50);

	// 云影：大尺度噪声缓慢掠过地面
	vec2 cp = wpos.xz * 0.018 + vec2(cloud_time * 0.013, cloud_time * 0.008);
	float cl = fbm(cp * 1.7);
	float cloud_shade = mix(0.74, 1.0, smoothstep(0.42, 0.68, cl));
	base *= cloud_shade;

	// 高山雪线：海拔越高越白
	float snow = smoothstep(snow_line - 2.0, snow_line + 3.0, wpos.y);
	base = mix(base, vec3(0.93, 0.95, 0.98), snow * 0.94);

	base = mix(base, winter_col.rgb, winter_mix);

	// 水线附近：湿沙、湿土，颜色更深更饱和
	float shore_wet = 1.0 - smoothstep(-0.35, 0.55, above);
	base = mix(base, base * vec3(0.66, 0.66, 0.60), shore_wet * 0.85);
	// 水下地面偏青
	float under = smoothstep(0.05, -0.45, above);
	base = mix(base, mix(base, vec3(0.20, 0.30, 0.28), 0.55), under);

	// 下雨时地面变深、变亮泽
	base *= mix(1.0, 0.80, wet);

	// 网格线：建造时高亮，平时几乎看不见
	vec2 c = wpos.xz / cell_size;
	vec2 g = abs(fract(c - 0.5) - 0.5) / max(fwidth(c), vec2(0.0001));
	float line = 1.0 - min(min(g.x, g.y), 1.0);

	ALBEDO = mix(base, line_col.rgb, line * line_strength * grid_alpha);
	ROUGHNESS = mix(0.96, 0.52, wet);
	SPECULAR = wet * 0.35;
	SPECULAR = 0.0;
}
