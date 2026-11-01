# PXO Importer

把 Pixelorama 的 `.pxo` 工程当作普通美术资源来用：丢进 `res://`，Godot 自动导入成
`PxoProject`，里面有每一帧、每一层，还有一份可以直接喂给 `AnimatedSprite2D` 的
`SpriteFrames`。

不需要导出 PNG 序列，不需要安装 Pixelorama 就能在游戏里读。

## 启用

1. 项目 → 项目设置 → 插件，勾上 **PXO Importer**（或确认 `project.godot` 的
   `[editor_plugins]` 里已有 `res://addons/pxo_importer/plugin.cfg`）。
2. 把 `.pxo` 拖进文件系统面板。
3. 在 Pixelorama 里改完再保存，切回 Godot 会自动重新导入，和 `.png` 一样。

## 在编辑器里看

在文件系统面板里选中或双击 `.pxo`，Inspector 顶部会出现预览：

- 一行信息：画布尺寸、帧数、fps、层名
- 「帧」条：每帧的合成图，点一下切换
- 「图层（当前帧）」条：当前帧每一层的图，带层名
- 「播放」按钮：按工程的 fps 轮播各帧

下面依旧是属性列表。导入的资源在 Godot 里是**只读**的——它由 `.pxo` 生成，不能就地改；
要改就回 Pixelorama 编辑源文件，保存后切回 Godot 会自动重新导入。

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

## 导入选项

在 `.pxo` 的「导入」面板里：

| 选项 | 默认 | 说明 |
| --- | --- | --- |
| `import_composite_only` | 关 | 只保留合成后的每帧图像，丢掉分层图，资源更小 |
| `layer_filter` | 空 | 逗号分隔的层名，只导入这些层；留空表示全部 |

改了选项后点「重新导入」。

## 资源长什么样

```
PxoProject (Resource)
├── canvas_size : Vector2i
├── fps : float
├── layer_names : PackedStringArray      # 从下到上
├── frames : Array[PxoFrame]
│   └── PxoFrame
│       ├── composite : Texture2D        # 该帧合成图
│       ├── layer_images : Array[Texture2D]
│       └── duration : float
├── tags : Array[Dictionary]             # {name, from, to, color}
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
| `tilesets/<i>/<j>` | TileMap 图层的单块图 |

导入器的取舍：

- 合成帧优先用 `final_images`（那是 Pixelorama 自己画的，混合模式完全正确）；
  没有时按可见层的 alpha 叠加，并应用层的 `opacity`。
  非 NORMAL 的混合模式在这种回退路径下不参与计算——需要精确效果时，在 Pixelorama
  里勾上「包含合成图」再保存。
- 组图层、TileMap 图层、3D 图层、音频图层不带像素，对应的 `layer_images` 位置是 `null`。
- 索引色工程的像素按 RGBA8 读入，调色板信息保留在 `data.json` 里但没有解析成资源。

## 文件

| 文件 | 作用 | 需要打包进游戏 |
| --- | --- | --- |
| `pxo_project.gd` | 资源类型 | 是 |
| `pxo_frame.gd` | 单帧资源类型 | 是 |
| `pxo_reader.gd` | 解析器（导入时用） | 否 |
| `pxo_import_plugin.gd` | `EditorImportPlugin` | 否 |
| `pxo_inspector_plugin.gd` | 让 Inspector 显示预览 | 否 |
| `pxo_preview.gd` | 预览面板本身 | 否 |
| `plugin.gd` / `plugin.cfg` | 编辑器插件注册 | 否 |
