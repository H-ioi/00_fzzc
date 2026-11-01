# 放逐之城 · 复刻原型

Godot 4.7.2 + GDScript，美术用 Blender 5.0 程序化生成。

当前状态：**21 种建筑 + 17 种场景道具**全部有低模资产，经济链、施工、道路、灾害、贸易、升级、存档全部跑通；画面具备**等距视角、程序化材质、地形起伏、河湖水体、昼夜循环、四季、雨雪天气**的完整视觉状态。

![城镇全貌](shot_town.png)
![目标 vs 当前](shot_compare.png)
![冬季](shot_winter.png)
![黄昏](shot_dusk.png)
![农田与稻草人](shot_farm.png)
![全岛](shot_island.png)
![近景](shot_close.png)

## 运行

```powershell
& 'D:\04_Godot\Godot_v4.7.2-stable_win64.exe' --path 'D:\01_code\00_fzzc'
```

首次打开（或新增了 glb 资源）需要让 Godot 扫一遍，否则 `class_name` 和模型都找不到：

```powershell
& 'D:\04_Godot\Godot_v4.7.2-stable_win64_console.exe' --headless --path 'D:\01_code\00_fzzc' --import
```

## 操作

| 操作 | 键位 |
|---|---|
| 平移 | WASD / 方向键 / 鼠标贴边 |
| 缩放 | 鼠标滚轮 |
| 旋转视角 | Q / E，或**按住鼠标中键拖动** |
| 调整俯角 | 按住鼠标中键上下拖动 |
| 全屏切换 | F11 |
| 暂停 | 空格 |
| 快速建造 | 1–9（9 是道路） |
| 铺路 | 选「道路」后<b>按住左键拖动</b>连续铺，右键擦除 |
| 存档 / 读档 | F5 / F9 |
| 取消建造 / 取消选中 | 右键 或 Esc |
| 选中建筑 | 左键点击 |

道路可以穿过森林（自动清树）并能爬坡，陡处自动铺石阶。

## 画面构成

| 层 | 内容 |
|---|---|
| 相机 | 等距正交，俯角 44° |
| 地形 | 64×64 高度场（`ArrayMesh` 位移），中央平台 + 河谷下切 + 湖 + 海岸沙滩 |
| 地表 | fbm 草色 + 枯草斑块 + 细颗粒 + 道路遮罩 + 裸土遮罩 + 建造网格 |
| 水体 | 深度遮罩着色 + 菲涅尔天空反射 + 岸边透明 + 泡沫 + 波浪 + 小船 |
| 建筑材质 | 三平面程序化（木纹 / 瓦片 / 石砌 / 灰泥），每栋随机色差 |
| 植被 | 3 树种 × 双层树冠 × 每棵色差 + 灌木 + 岩石 + 4200 草簇 + 花丛 + 岸线芦苇 |
| 生命 | 居民（随机衣色/身高、Catmull-Rom 平滑寻路）+ 7 鸡 3 狗 |
| 光照 | 暖色主光 + 冷蓝环境光 + 4 级阴影 + SSAO，冬季增强环境光 |
| 后期 | ACES + 景深 + 辉光 + 雾 + 分离色调 + 暗角 + 颗粒（`shaders/grade.gdshader`） |
| 动态 | 昼夜循环（80 秒一周，黄昏窗户透光）+ 四季（作物/积雪/风车转速）+ 雨雪天气 |
| UI | 羊皮纸/木牌主题 + 建筑 3D 缩略图 + 可滚动菜单 + 跟随小地图 |

## 建筑（21 种）

| 类别 | 建筑 |
|---|---|
| 住宅 | 民居、石屋、大宅、联排民居 |
| 仓储 | 仓库（钟楼、阁楼货门、吊装梁） |
| 食物 | 采集小屋、猎人小屋、农田、渔码头、风车 |
| 原料 | 伐木场、采石场、柴火棚 |
| 加工 | 裁缝铺、铁匠铺、木工坊 |
| 服务 | 水井、医院、教堂、贸易站 |
| 交通 | 道路 |

数值表在 `data/buildings.json`（由 `tools/export_defs.gd` 从 `scripts/BuildingDefs.gd` 导出，**JSON 为运行时权威**）。

## 场景道具（17 种）

木桶、板条箱、干草堆、手推车、长椅、路灯、栅栏、小船、鸡、狗、晾衣绳、木料堆、干草车、饮水槽、路牌、菜园、稻草人。

按建筑类型规则化放置（`CTX_WANT`）：住宅配菜园/晾衣绳/木料堆，农田配稻草人/干草车，水井配水槽，仓库/贸易站配路牌。

## 测试与截图

```powershell
$e = 'D:\04_Godot\Godot_v4.7.2-stable_win64_console.exe'
& $e --headless --path . -- --autotest     # 跑 1.5 游戏年，检查经济与建造
& $e --headless --path . -- --savetest     # 存读档往返一致性
& $e --path . -- --shot --town             # 截图（见下表）
```

| 截图参数 | 效果 |
|---|---|
| `--shot --town` | 演示城镇 |
| `--shot --winter --town` | 冬季 |
| `--shot --town --dusk` | 黄昏（强制） |
| `--shot --town --rain` | 雨天 |
| `--shot --winter --town --rain` | 雪天 |
| `--shot --far --town` | 全岛 |
| `--shot --at 45 73 --size 24` | 指定相机中心与视野 |
| `--shot --cutshadow buildings` | 关闭某组投影（排查用） |

## 已知问题

- **建筑坡地贴合**：坡度上限 1.2 米，超过则拒绝建造；石基台基向下延伸 1.1 米盖住缝隙，但极端地形仍可能有轻微穿模。
- **水面无真实反射**：用深度色 + 菲涅尔近似，没有屏幕空间反射。
- **阴影柔边受限**：`shadow_blur` 必须保持很低（0.12），否则在正交大视锥下会产生条带。

## 自测基线

```
[8] 第2年 夏 第3天 | 人口=15 | 木≈89 石=112 食≈364 柴≈125 | 建筑=12 | 仓容=1100
SAVETEST before = after （存读档完全一致）
```

## 目录

```
scripts/     Main.gd（世界/建造/命令）、GameState.gd（资源/时间）、Building.gd、Citizen.gd、
             Critter.gd、GridSystem.gd、GameUI.gd、ModelPaint.gd、BuildingDefs.gd
shaders/     ground / water / surface / grade / smoke / rain
assets/models/  21 个建筑 glb + 17 个道具 glb + character.glb
data/        buildings.json
tools/       build_assets.py（Blender 生成）、export_defs.gd、concept_render.py 等
```
