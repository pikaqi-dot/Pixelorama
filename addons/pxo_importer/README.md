# PXO Importer

把 Pixelorama 的 `.pxo` 工程当作普通美术资源来用：丢进 `res://`，Godot 自动导入成
`PxoProject`，里面有每一帧、每一层，还有一份可以直接喂给 `AnimatedSprite2D` 的
`SpriteFrames`；工程里画了 TileMap 图层的话，图块和摆放位置也能变成 Godot 的
`TileSet` 与 `TileMapLayer`。

不需要导出 PNG 序列，不需要安装 Pixelorama 就能在游戏里读。

## 安装到任意工程

这个插件**自包含**：所有代码都在 `addons/pxo_importer/` 里，不引用 Pixelorama 仓库里的
其他任何文件（没有 autoload、没有 `res://src/`、没有别的 addon），拷走就能用。

1. 把整个 `addons/pxo_importer/` 文件夹复制到目标工程的 `addons/` 下。
   保持文件夹名 `addons/pxo_importer`——插件内部用绝对路径互相引用，改名会找不到。
2. 项目 → 项目设置 → 插件，勾上 **PXO Importer**（等同于在 `project.godot` 的
   `[editor_plugins]` 里加上 `res://addons/pxo_importer/plugin.cfg`）。
3. 把 `.pxo` 拖进文件系统面板。
4. 在 Pixelorama 里改完再保存，切回 Godot 会自动重新导入，和 `.png` 一样。

插件注册了三个全局类名：`PxoProject`、`PxoFrame`、`PxoTileset`。同名冲突只会发生在
另一个插件也用了这三个名字的情况下。

不用编辑器插件、只想在运行时读 `.pxo` 的话，可以不启用插件，直接保留
`pxo_project.gd` / `pxo_frame.gd` / `pxo_reader.gd` / `pxo_tileset.gd` 四个脚本即可
（见文末的文件表）。

## 在编辑器里看

在文件系统面板里选中或双击 `.pxo`，Inspector 顶部会出现预览：

- 一行信息：画布尺寸、帧数、fps、层名；帧比画布大时还会写出帧尺寸与原点（如 `· 帧 16×19（原点 0,-3）`），有图块集时再列出图块数量、单块尺寸和图块层
- 「帧」条：每帧的合成图，点一下切换
- 「图层（当前帧）」条：当前帧每一层的图，带层名
- 「播放」按钮：按工程的 fps 轮播各帧
- 「图块集」「地图」按钮：见下文，工程里没有图块集时是灰的

下面依旧是属性列表。导入的资源在 Godot 里是**只读**的——它由 `.pxo` 生成，不能就地改；
要改就回 Pixelorama 编辑源文件，保存后切回 Godot 会自动重新导入。

## 导出成 Godot 自己的资源

`.pxo` 导入出来的是只读资源，Godot 的动画编辑器、切片工具都打不开它。预览面板上有两个按钮，
在 `.pxo` 旁边写出普通文件，之后就能用原生工具：

| 按钮 | 产出 | 用来做什么 |
|---|---|---|
| 帧资源 | `<名字>_spriteframes.tres` | 双击进 SpriteFrames 面板编辑；拖给 `AnimatedSprite2D` |
| 精灵表 | `<名字>_sheet.png` | `Sprite2D` 设 `hframes`/`vframes` 切片；`TileSet` 当图集 |
| 图块集 | `<名字>_tileset.tres` | 拖到 `TileMapLayer` 的 Tile Set 上；TileSet 面板里能改，地形已连好 |
| 地图 | `<名字>_tilemap.tscn` | 打开就是一个 `Node2D`，每层图块一个 `TileMapLayer`，格子已经摆好 |

- 帧资源内嵌图像，不依赖 `.pxo`，可以随便改；重新点按钮会覆盖它（它就是从 `.pxo` 派生的）。
- 精灵表按**帧尺寸**（不是画布尺寸）横向排一行，第 N 格就是第 N 帧。想换行数就在代码里调
  `PxoExport.export_sheet(project, path, columns)`。
- 地图导出的是**当前选中的那一帧**，`TileSet` 内嵌在 `.tscn` 里，所以那个场景是单文件、拖进哪个项目都能用。
  想多帧都成地图，就逐帧点一次（或按下面的 API 自己生成）。

```gdscript
# 生成精灵表后用 hframes 切片
$Sprite2D.texture = preload("res://art/player_sheet.png")
$Sprite2D.hframes = 4
$Sprite2D.vframes = 1
$Sprite2D.frame = 2
```

## 用

### 动画：给 AnimatedSprite2D

```gdscript
var project: PxoProject = load("res://art/player.pxo")

$AnimatedSprite2D.sprite_frames = project.sprite_frames
$AnimatedSprite2D.play()
```

`sprite_frames` 是导入时按帧合成好的，速度取自工程的 `fps`，每帧的停留时间也按
Pixelorama 里的设置保留。

### 单层：只要角色，不要背景

```gdscript
var project: PxoProject = load("res://art/player.pxo")

$Body.texture = project.get_layer_image(0, "character")
$Shadow.texture = project.get_layer_image(0, "shadow")
```

层名就是 Pixelorama 图层面板里的名字，顺序从下往上，和 `project.layer_names` 一致。

### 逐帧、按名字

```gdscript
for i in project.frame_count():
    var frame := project.get_frame(i)
    print(i, " 合成图=", frame.composite, " 停留=", frame.duration)

var idle: Dictionary = project.get_tag("idle")   # {name, from, to, color}
```

### 自己拼一份 SpriteFrames

当工程是运行时拼出来的、而不是导入的，`build_sprite_frames()` 会重新生成一份。

### 图块：当成 TileMap 用

Pixelorama 的图块储存在 `.pxo` 里是「一堆独立的单块图片 + 每格用了第几块」，Godot 要的是
「一张图集 + 图集坐标」，这里替你把两边的账算平：

```gdscript
var project: PxoProject = load("res://levels/level.pxo")

# 图块集：每块已切好，地形（自动图块）也已按 Pixelorama 的设置连好
$TileMapLayer.tile_set = project.build_tile_set()

# 或者整张地图：每层图块一个 TileMapLayer，格子都摆好了
add_child(project.build_tile_map(0))   # 参数是第几帧
```

- 想看单块图或自己排图集：`PxoTileset.load_from(project, 0)` 拿到 `tiles`（每块一个 `Image`）、
  `atlas_coords(块号)`、`build_atlas_image()`。
- 图集是方形网格，列数由 `columns()` 决定（`ceil(sqrt(块数))`），块号 → 坐标就是
  `Vector2i(块号 % 列数, 块号 / 列数)`。
- 自动图块：方形图块集会把 `terrain_center_bit` 与 `terrain_peering_bits`（前 8 个方向）搬到
  Godot 的 terrain 上，六边形 / 等距图块集只做图块，地形不猜。
- 每格翻转（`flip_h` / `flip_v` / `transpose`）会写进 `set_cell` 的 `alternative_tile`。
- 校验过：用「图块 + 格子」重画出来的图层，和 `.pxo` 里 Pixelorama 自己画的那张图层图**逐像素完全一致**
  （示例工程 13312 像素，差异 0）。

## 导入选项

在 `.pxo` 的「导入」面板里：

| 选项 | 默认 | 说明 |
| --- | --- | --- |
| `import_composite_only` | 关 | 只保留合成后的每帧图像，丢掉分层图，资源更小 |
| `layer_filter` | 空 | 逗号分隔的层名，只导入这些层；留空表示全部 |
| `import_shader_layers` | 关 | 让着色器图层参与帧合成。默认不参与，原因见下 |

改了选项后点「重新导入」。

## 着色器图层与「帧看起来不一样」

Shader Composer 的图层在 `.pxo` 里存的是**一张静态烘焙的图**，而 Pixelorama 编辑时是**实时**算的
（跟着时间、跟着画布状态变）。导入器没法跑那张图，所以：

- 默认把着色器图层排除在「帧合成图」之外，只保留它们的原样层图（`layer_images` 里照旧有一张，
  可以在「图层」里单独看）。
- 导入时会 `push_warning` 说明是哪几个图层被跳过了；检查器的信息里也会写一行。
- 勾上 `import_shader_layers` 可以把它们硬合成进去 —— 但那是**某一时刻的烘焙画面**，通常和编辑器对不上，
  所以默认关闭。
- 想要**逐像素完全一致**：在 Pixelorama 里保存时勾上「包含合成图」（导出面板的 `include_blended_images`），
  再重新导入。这时导入器直接用 `.pxo` 自带的 `image_data/final_images/<帧号>`，那是 Pixelorama
  自己算出来的最终画面，混合模式也一并正确。

另外，合成时会按每个 cel 的 `offset` 摆放（图层被移动 / 缩放过也能对上位置）。

**画布不等于帧**：画布只决定 Pixelorama 里「看得到哪一块」，cel 画到画布外面并不会消失。所以导入器取
**所有帧、所有参与合成的 cel 的并集，再并上画布**作为帧的矩形（`PxoProject.frame_rect`），这个矩形
**整个工程共用**——每帧尺寸一致，`AnimatedSprite2D` 播起来不会上下跳。结果是：

- 内容没超出画布时，帧就是画布，和以前一样；
- 有 cel 超出画布时（比如 16×16 画布上画了 12×17 的角色），帧会扩到 16×19，**完整保留**那 17 行，
  不会像以前那样把超出的部分裁掉、看起来「矮了一截、整体偏下」。

`PxoFrame.frame_origin` 是这个矩形左上角在画布坐标里的位置，`PxoFrame.layer_offsets` 是每层图像
相对帧左上角的位置——单独取某一层的图来用时，按它摆放才不会偏。用 `project.frame_size()` 拿到帧尺寸
（老资源没有这个字段时自动回退到画布尺寸）。

## 资源长什么样

```
PxoProject (Resource)
├── canvas_size : Vector2i               # Pixelorama 的画布（只是可见范围）
├── frame_rect : Rect2i                  # 整帧覆盖的范围：画布 ∪ 所有帧画到画布外的内容
├── fps : float
├── color_mode : int                     # 像素的 Image.Format，读图块时沿用
├── layer_names : PackedStringArray      # 从下到上
├── shader_layer_names : PackedStringArray  # 着色器图层，默认不参与帧合成
├── frames : Array[PxoFrame]
│   └── PxoFrame
│       ├── composite : Texture2D        # 该帧合成图，尺寸 = frame_size()
│       ├── frame_origin : Vector2i      # composite 左上角在画布坐标里的位置
│       ├── layer_images : Array[Texture2D]
│       ├── layer_offsets : Array[Vector2i]  # 每层图像相对 composite 左上角的位置
│       ├── tile_cells : Array[Dictionary]  # 每层的图块摆放：Vector2i → {index, flip_h, flip_v, transpose}
│       └── duration : float
├── tags : Array[Dictionary]             # {name, from, to, color}
├── tilesets : Array[Dictionary]         # 图块集元数据（不含图片，图片按需从 .pxo 读）
├── tile_layers : Array[Dictionary]      # {layer, tileset, tile_size, name}
└── sprite_frames : SpriteFrames         # 导入时构建好，纹理与 frames 共享
```

## 格式说明

`.pxo` 是一个 ZIP：

| 路径 | 内容 |
| --- | --- |
| `data.json` | 整个工程的 JSON（尺寸、图层、帧、标签、fps…） |
| `image_data/frames/<帧>/layer_<层>` | 原始像素，帧与层都从 1 开始 |
| `image_data/final_images/<帧>` | 已合成好的整帧（仅当工程里勾了「包含合成图」） |
| `preview.png` | 256px 缩略图 |
| `mimetype` | `application/x-pixelorama` |
| `tilesets/<i>/<j>` | 第 i 个图块集的第 j 块（`i`、`j` 都从 0 开始） |
| `image_data/frames/<帧>/indices_layer_<层>` | 图块层的逐格索引（真值在 `data.json` 的 `cell_data` 里） |

导入器的取舍：

- 合成帧优先用 `final_images`（那是 Pixelorama 自己画的，混合模式完全正确）；它是画布大小，
  放进帧矩形里时按 `frame_rect` 的位置对齐。没有 `final_images` 时按可见层的 alpha 叠加，
  并应用层的 `opacity`。非 NORMAL 的混合模式在这种回退路径下不参与计算——需要精确效果时，
  在 Pixelorama 里勾上「包含合成图」再保存。
- 组图层、3D 图层、音频图层不带像素，对应的 `layer_images` 位置是 `null`；TileMap 图层有像素
  （`.pxo` 存了它渲染后的样子），所以合成帧里图块也在，`tile_cells` 里则是它的每格索引。
- 图块集的名字、单块尺寸、地形颜色与自动图块位都记在 `project.tilesets` 里，单块图片**不**放进
  导入出来的资源——图块集可能很大，需要时由 `PxoTileset` 回到 `.pxo` 里读。
- 索引色工程的像素按 RGBA8 读入，调色板信息保留在 `data.json` 里但没有解析成资源。

## 文件

| 文件 | 作用 | 需要打包进游戏 |
| --- | --- | --- |
| `pxo_project.gd` | 资源类型 | 是 |
| `pxo_frame.gd` | 单帧资源类型 | 是 |
| `pxo_tileset.gd` | 图块集 → `TileSet` / `TileMapLayer`（运行时可调） | 是 |
| `pxo_reader.gd` | 解析器：导入时用；运行时想直接读 `.pxo` 也用它 | 否（运行时直读才需要） |
| `pxo_import_plugin.gd` | `EditorImportPlugin` | 否 |
| `pxo_inspector_plugin.gd` | 让 Inspector 显示预览 | 否 |
| `pxo_preview.gd` | 预览面板本身 | 否 |
| `pxo_export.gd` | 导出 SpriteFrames / 精灵表 / TileSet / TileMap 场景 | 否 |
| `plugin.gd` / `plugin.cfg` | 编辑器插件注册 | 否 |
