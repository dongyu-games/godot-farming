extends Node

## 地形索引：0=Grass（图集里没给瓦片）、1=Soil、2=WetSoil。
## WetSoil 是叠在 Soil 之上的 autotile：图集右半带透明部分，正好露出下面的干土，
## 所以浇水时不要删掉 Soil 的格子。
const TERRAIN_SOIL := 1
const TERRAIN_WET := 2

## 空地老化：连续 2 天没操作，第 3 天结算时才长回草地（第 4 天早上看到草地）
## 计数在每次换天时 +1，所以阈值 3 = 锄地当天 + 之后 2 天没动它
const EMPTY_SOIL_LIMIT := 3

## 底部 HUD 栏高度（像素）。世界画面只画在栏的上方，所以栏目不会压住任何作物。
const HUD_HEIGHT := 56

## —— 音效 ——
## 素材在 assets/audio 下：16-bit / 48 kHz / 立体声 wav，都是单发短音效（不循环）
const SFX_FILES := {
	"till": "res://assets/audio/till.wav",
	"water": "res://assets/audio/water.wav",
	"sow": "res://assets/audio/sow.wav",
	"harvest": "res://assets/audio/harvest.wav",
	"harvest_hidden": "res://assets/audio/harvest_hidden.wav",
}
## 每个音效的基准音量（dB）。素材原始响度差挺多（浇水那声峰值比锄地低 7 dB），
## 这里按"听起来一样响"拉平；想整体调音只改这张表即可。
const SFX_DB := {
	"till": -7.0,
	"water": -2.0,
	"sow": -5.0,
	"harvest": -5.0,
	"harvest_hidden": -4.0,
}
## 每个音效同时能叠几个播放器（连点锄头时前后两声不会互相掐断）
const SFX_VOICES := 3

## 世界上方可视区（子视口）尺寸，由视口大小减掉栏目得出
var view_container: SubViewportContainer
var view: SubViewport
var world_root: Node2D
## 世界整体在子视口里的平移量（负数表示向左/上推）
var world_offset := Vector2.ZERO
var field_rect := Rect2()
var _panning := false
var day_label: Label
## 背景音乐播放器（game.tscn 里的 Bgm 节点）
var bgm: AudioStreamPlayer
## 音效播放器：名字 → AudioStreamPlayer 数组；_sfx_next 记下一次轮到第几个
var _sfx_players: Dictionary = {}
var _sfx_next: Dictionary = {}
## 隐藏作物：初始隐形的 UI 节点（crop_name → 节点数组），以及掉落保底计数
var _hidden_entries: Dictionary = {}
var _drop_pity: Dictionary = {}

signal tool_changed
signal day_changed

@export var map_grass: TileMapLayer
@export var map_soil: TileMapLayer
@export var map_wet_soil: TileMapLayer
@export var tool_selection_pool: Control
@export var seed_selection_pool: Control
@export var crop_pool: Node2D
@export var crop_datas: Array[CropData]
@export var progress_time: ProgressBar
@export var timer_time: Timer
@export var stock_pool: Control
@export var position_hint: Control

var crop_dict: Dictionary[Vector2i, Crop] = {}
## 每个土格"连续没有作物"的天数
var empty_soil_days: Dictionary[Vector2i, int] = {}
var stock: Dictionary[String, int] = {}

## 一天有多少个 tick。一天的真实时长 = max_time × Timer_Time.wait_time
## （Timer_Time 在 game.tscn 里，默认 1 秒一拍，所以 max_time = 30 就是 30 秒一天）
## 两个值都能在编辑器 Inspector 里直接改：Game 节点 → max_time；Timer_Time → wait_time
@export var max_time: int = 30
var day: int = 1
var time: int:
	set(value):
		time = value
		progress_time.value = time

var selected_tool: ToolSelection:
	set(value):
		selected_tool = value
		tool_changed.emit()


func _ready() -> void:
	# BGM：循环在 .ogg 的导入参数里已经勾了，这里再兜一层，免得以后换素材忘了勾
	bgm = get_node_or_null(^"Bgm") as AudioStreamPlayer
	if bgm != null and bgm.stream is AudioStreamOggVorbis:
		(bgm.stream as AudioStreamOggVorbis).loop = true

	_build_sfx()

	progress_time.max_value = max_time
	selected_tool = tool_selection_pool.get_child(0)

	for crop in crop_datas:
		stock[crop.name] = 0

		# 隐藏作物（plantable=false）不进种子栏，只能靠收获掉落拿到
		if crop.plantable:
			var seed_selection: ToolSelection = Prefabs.tool_selection.instantiate()
			seed_selection.rect_icon.texture = crop.icon
			seed_selection.tool_type = Enums.ToolType.SEED
			seed_selection.seed_data = crop
			seed_selection_pool.add_child(seed_selection)
			if crop.hidden_until_obtained:
				seed_selection.modulate.a = 0.0
				_register_hidden_entry(crop.name, seed_selection)

		var stock_label: StockLabel = Prefabs.stock_label.instantiate()
		stock_label.rect_icon.texture = crop.stages[crop.stages.size() - 1]
		stock_label.name = crop.name
		stock_pool.add_child(stock_label)
		if crop.hidden_until_obtained:
			stock_label.modulate.a = 0.0
			_register_hidden_entry(crop.name, stock_label)

	_build_view()
	_build_hud()

	# 调试：FARM_SHOT=/path.png 启动时自动截图并退出
	if OS.get_environment("FARM_SHOT") != "":
		_shot_and_quit()

	time = 0
	timer_time.timeout.connect(_on_tick)


## 音效播放器在运行时建，不写进 game.tscn：换素材只改 SFX_FILES 一处。
## 一个名字建 SFX_VOICES 个播放器轮着用，快速连点时前后两声能叠上。
func _build_sfx() -> void:
	var root := Node.new()
	root.name = "Sfx"
	add_child(root)
	for key in SFX_FILES:
		var stream := load(SFX_FILES[key]) as AudioStream
		if stream == null:
			push_warning("音效找不到：%s" % SFX_FILES[key])
			continue
		var players: Array[AudioStreamPlayer] = []
		for i in SFX_VOICES:
			var player := AudioStreamPlayer.new()
			player.name = "%s_%d" % [key, i]
			player.stream = stream
			player.volume_db = SFX_DB.get(key, 0.0)
			root.add_child(player)
			players.append(player)
		_sfx_players[key] = players
		_sfx_next[key] = 0


## 播一声音效（名字见 SFX_FILES）。素材缺失时静默跳过，不会打断玩法。
func play_sfx(key: String) -> void:
	var players: Array = _sfx_players.get(key, [])
	if players.is_empty():
		return
	var i: int = int(_sfx_next.get(key, 0)) % players.size()
	_sfx_next[key] = i + 1
	(players[i] as AudioStreamPlayer).play()


## set_cells_terrain_connect 只会重算"传入的这些格子"的边缘，邻居不会自动刷新，
## 所以单独锄一格时，它和旧土的接缝要等到换天整层重算才消失。
## 这里把"目标格 + 已经存在的八邻格"一起传进去，接缝当场就对齐。
func _neighbor_cells(layer: TileMapLayer, coord: Vector2i) -> Array[Vector2i]:
	var cells: Array[Vector2i] = []
	for dx in range(-1, 2):
		for dy in range(-1, 2):
			if dx == 0 and dy == 0:
				continue
			var n := coord + Vector2i(dx, dy)
			if layer.get_cell_source_id(n) != -1:
				cells.append(n)
	return cells


func _apply_terrain(layer: TileMapLayer, coord: Vector2i, terrain: int) -> void:
	var cells: Array[Vector2i] = [coord]
	cells.append_array(_neighbor_cells(layer, coord))
	layer.set_cells_terrain_connect(cells, 0, terrain)


## —— 擦除后的边缘重铺 ——
## set_cells_terrain_connect 推断边界时读的是"周围瓦片自己存的 peering 位"，
## 而不是"邻居到底还在不在"。一格土被擦掉后，邻格那一位仍然写着"有土"，
## 空位又只贡献一个 -1 一起投票，1:1 打平时旧值赢 → 洞边上留着整块土，
## 看上去就是 autotile 没按 peering 更新、拼错了。
## 所以擦除后不再让引擎猜：这里按"八邻还在不在"直接算掩码，查表盖瓦片。
const _TERRAIN_BITS := [
	TileSet.CELL_NEIGHBOR_TOP_SIDE, TileSet.CELL_NEIGHBOR_RIGHT_SIDE,
	TileSet.CELL_NEIGHBOR_BOTTOM_SIDE, TileSet.CELL_NEIGHBOR_LEFT_SIDE,
	TileSet.CELL_NEIGHBOR_TOP_RIGHT_CORNER, TileSet.CELL_NEIGHBOR_BOTTOM_RIGHT_CORNER,
	TileSet.CELL_NEIGHBOR_BOTTOM_LEFT_CORNER, TileSet.CELL_NEIGHBOR_TOP_LEFT_CORNER,
]
## 与 _TERRAIN_BITS 一一对应的邻居方向（y 轴向下，与 local_to_map 一致）
const _TERRAIN_DIRS := [
	Vector2i(0, -1), Vector2i(1, 0), Vector2i(0, 1), Vector2i(-1, 0),
	Vector2i(1, -1), Vector2i(1, 1), Vector2i(-1, 1), Vector2i(-1, -1),
]
## 角位索引 → 它两侧的边位索引。图集里只有"两边都通"的角瓦片，其余组合没有对应瓦片
const _CORNER_NEEDS := {4: [0, 1], 5: [2, 1], 6: [2, 3], 7: [0, 3]}
## terrain → { 八位掩码 : [source_id, atlas_coords] }
var _terrain_tiles: Dictionary = {}


## 从 TileSet 里扫出"掩码 → 瓦片"的对照表（不写死图集坐标，换美术也不用改代码）
func _build_terrain_tiles() -> void:
	if not _terrain_tiles.is_empty() or map_soil == null or map_soil.tile_set == null:
		return
	var ts := map_soil.tile_set
	for i in ts.get_source_count():
		var sid := ts.get_source_id(i)
		var atlas := ts.get_source(sid) as TileSetAtlasSource
		if atlas == null:
			continue
		for t in atlas.get_tiles_count():
			var coords := atlas.get_tile_id(t)
			var td := atlas.get_tile_data(coords, 0)
			if td == null or td.terrain_set != 0 or td.terrain <= 0:
				continue
			var mask := 0
			for k in _TERRAIN_BITS.size():
				var bit: int = _TERRAIN_BITS[k]
				if td.is_valid_terrain_peering_bit(bit) \
					and td.get_terrain_peering_bit(bit) == td.terrain:
					mask |= 1 << k
			if not _terrain_tiles.has(td.terrain):
				_terrain_tiles[td.terrain] = {}
			_terrain_tiles[td.terrain][mask] = [sid, coords]


func _canonical_mask(mask: int) -> int:
	for c in _CORNER_NEEDS:
		if mask & (1 << c) == 0:
			continue
		var sides: Array = _CORNER_NEEDS[c]
		if mask & (1 << sides[0]) == 0 or mask & (1 << sides[1]) == 0:
			mask &= ~(1 << c)
	return mask


## 按实际邻居重铺 coord 周围 3x3 里所有同地形的格子（擦除/新铺后用）
func _retile_around(layer: TileMapLayer, coord: Vector2i, terrain: int) -> void:
	_build_terrain_tiles()
	var table: Dictionary = _terrain_tiles.get(terrain, {})
	if table.is_empty():
		return
	for dx in range(-1, 2):
		for dy in range(-1, 2):
			var c := coord + Vector2i(dx, dy)
			var td := layer.get_cell_tile_data(c)
			if td == null or td.terrain != terrain:
				continue
			var mask := 0
			for k in _TERRAIN_DIRS.size():
				var ntd := layer.get_cell_tile_data(c + _TERRAIN_DIRS[k])
				if ntd != null and ntd.terrain == terrain:
					mask |= 1 << k
			mask = _canonical_mask(mask)
			if not table.has(mask):
				continue  # 图集没有这个组合，保持原样比乱换一块好
			var want: Array = table[mask]
			if layer.get_cell_source_id(c) == want[0] and layer.get_cell_atlas_coords(c) == want[1]:
				continue
			layer.set_cell(c, want[0], want[1], 0)


## 把一格土连同湿土叠加一起除掉，并让周围按 peering 重铺边缘（长回草地）
func erase_soil(coord: Vector2i) -> void:
	if map_wet_soil.get_cell_source_id(coord) != -1:
		map_wet_soil.erase_cell(coord)
		_retile_around(map_wet_soil, coord, TERRAIN_WET)
	if map_soil.get_cell_source_id(coord) != -1:
		map_soil.erase_cell(coord)
		_retile_around(map_soil, coord, TERRAIN_SOIL)
	empty_soil_days.erase(coord)


## 最外圈草地不能锄：只在草地范围向内缩一格的可耕区内允许
func is_tillable(coord: Vector2i) -> bool:
	return map_grass.get_used_rect().grow(-1).has_point(coord)


## 世界画面放进一个子视口：只占屏幕上方，底部留给栏目。
## 这样栏目永远不会压住作物，草地比屏幕大时用中键拖动看别处。
func _build_view() -> void:
	var screen := get_viewport().get_visible_rect().size
	var view_size := Vector2(screen.x, screen.y - HUD_HEIGHT)

	view_container = SubViewportContainer.new()
	view_container.name = "WorldView"
	view_container.stretch = false
	view_container.position = Vector2.ZERO
	view_container.size = view_size
	view_container.custom_minimum_size = view_size
	view_container.mouse_filter = Control.MOUSE_FILTER_IGNORE

	view = SubViewport.new()
	view.size = Vector2i(int(view_size.x), int(view_size.y))
	view.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	view_container.add_child(view)

	world_root = Node2D.new()
	world_root.name = "WorldRoot"
	view.add_child(world_root)

	for node in [map_grass, map_soil, map_wet_soil, crop_pool]:
		node.get_parent().remove_child(node)
		world_root.add_child(node)

	var cl := CanvasLayer.new()
	cl.name = "WorldLayer"
	cl.layer = -1
	add_child(cl)
	cl.add_child(view_container)

	var used := map_grass.get_used_rect()
	field_rect = Rect2(Vector2(used.position) * 16.0, Vector2(used.size) * 16.0)
	# 先把草地摆在中间，再夹进合法范围
	world_offset = view_size * 0.5 - field_rect.get_center()
	_clamp_offset()


func _clamp_offset() -> void:
	var v := Vector2(view.size)
	world_offset.x = clamp(world_offset.x, v.x - field_rect.end.x, -field_rect.position.x)
	world_offset.y = clamp(world_offset.y, v.y - field_rect.end.y, -field_rect.position.y)
	# 真正把平移量作用到世界上，否则输入按 world_offset 算、画面却没动，点击就会错位
	if world_root != null:
		world_root.position = world_offset


## 屏幕坐标 → 世界坐标（子视口 + 平移量）
func screen_to_world(pos: Vector2) -> Vector2:
	return pos - view_container.global_position - world_offset


## 世界坐标 → 屏幕坐标（测试与提示框用）
func world_to_screen(pos: Vector2) -> Vector2:
	return pos + world_offset + view_container.global_position


## 底部栏目：工具 / 种子 / 收成 + 时间轴，和土地完全分开
func _build_hud() -> void:
	var layer := CanvasLayer.new()
	layer.name = "HudLayer"
	layer.layer = 5
	add_child(layer)

	var panel := Panel.new()
	panel.name = "Hud"
	panel.anchor_left = 0.0
	panel.anchor_right = 1.0
	panel.anchor_top = 1.0
	panel.anchor_bottom = 1.0
	panel.offset_top = -HUD_HEIGHT
	panel.mouse_filter = Control.MOUSE_FILTER_STOP   # 吃掉点击，土地收不到
	layer.add_child(panel)

	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.145, 0.106, 0.086, 1.0)
	sb.border_width_top = 2
	sb.border_color = Color(0.44, 0.32, 0.22, 1.0)
	panel.add_theme_stylebox_override("panel", sb)

	var root := VBoxContainer.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	# 左右只留 3px：收成项加到 6 个后（含隐藏作物），6px 边距会让最后一个被切掉
	root.offset_left = 3
	root.offset_right = -3
	root.offset_top = 4
	root.offset_bottom = -4
	root.alignment = BoxContainer.ALIGNMENT_CENTER
	root.add_theme_constant_override("separation", 5)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(root)

	# —— 第一行：三栏 ——
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 3)
	bar.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(bar)

	_hud_section(bar, "工具", tool_selection_pool)
	_hud_separator(bar)
	_hud_section(bar, "种子", seed_selection_pool)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bar.add_child(spacer)

	_hud_separator(bar)
	_hud_section(bar, "收成", stock_pool)

	# —— 第二行：时间轴 ——
	var time_row := HBoxContainer.new()
	time_row.add_theme_constant_override("separation", 6)
	time_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(time_row)

	day_label = Label.new()
	day_label.text = "第 %d 天" % day
	day_label.add_theme_font_size_override("font_size", 8)
	day_label.add_theme_color_override("font_color", Color(0.85, 0.78, 0.66))
	day_label.custom_minimum_size = Vector2(34, 0)
	day_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	time_row.add_child(day_label)

	progress_time.get_parent().remove_child(progress_time)
	progress_time.custom_minimum_size = Vector2(0, 10)
	progress_time.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	progress_time.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	progress_time.show_percentage = false
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.30, 0.225, 0.16, 1.0)
	bg.border_width_left = 1
	bg.border_width_top = 1
	bg.border_width_right = 1
	bg.border_width_bottom = 1
	bg.border_color = Color(0.33, 0.24, 0.17, 1.0)
	progress_time.add_theme_stylebox_override("background", bg)
	var fill := StyleBoxFlat.new()
	fill.bg_color = Color(0.80, 0.50, 0.19, 1.0)
	progress_time.add_theme_stylebox_override("fill", fill)
	time_row.add_child(progress_time)


func _hud_section(parent: Control, title: String, pool: Control) -> void:
	# 一栏 = 标题在上、图标行在下
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 1)
	box.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	box.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(box)

	var label := Label.new()
	label.text = title
	label.add_theme_font_size_override("font_size", 8)
	label.add_theme_color_override("font_color", Color(0.72, 0.62, 0.50))
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(label)

	var items := HBoxContainer.new()
	items.add_theme_constant_override("separation", 2)
	items.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(items)

	pool.get_parent().remove_child(pool)
	pool.set_anchors_preset(Control.PRESET_TOP_LEFT)
	pool.position = Vector2.ZERO
	pool.custom_minimum_size = Vector2.ZERO
	pool.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	items.add_child(pool)
	if pool is BoxContainer:
		for child in pool.get_children():
			if child is Control:
				child.size_flags_vertical = Control.SIZE_SHRINK_CENTER
				child.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN


func _hud_separator(parent: Control) -> void:
	var line := ColorRect.new()
	line.color = Color(0.32, 0.23, 0.17, 1.0)
	line.custom_minimum_size = Vector2(1, 0)
	line.size_flags_vertical = Control.SIZE_FILL
	line.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(line)


func _shot_and_quit() -> void:
	await get_tree().create_timer(2.0).timeout
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png(OS.get_environment("FARM_SHOT"))
	get_tree().quit()


func add_stock(crop_name: String, amount: int = 1) -> void:
	var before: int = stock.get(crop_name, 0)
	stock[crop_name] = before + amount
	var label: StockLabel = stock_pool.get_node_or_null(NodePath(crop_name))
	if label:
		label.number = stock[crop_name]
	# 隐藏作物：第一次拿到时把隐形的那一项显出来
	if before == 0 and stock[crop_name] > 0:
		_reveal_hidden_entries(crop_name)


## 隐藏作物在 UI 里的节点（初始 alpha=0），拿到后一起淡入
func _register_hidden_entry(crop_name: String, node: CanvasItem) -> void:
	if not _hidden_entries.has(crop_name):
		_hidden_entries[crop_name] = []
	_hidden_entries[crop_name].append(node)


func _reveal_hidden_entries(crop_name: String) -> void:
	var nodes: Array = _hidden_entries.get(crop_name, [])
	for node in nodes:
		var item := node as CanvasItem
		if item == null or not is_instance_valid(item):
			continue
		var t := item.create_tween()
		t.tween_property(item, "modulate:a", 1.0, 0.45)
	_hidden_entries.erase(crop_name)


## 掉落隐藏作物，带假随机保底：概率 p 时每 ceil(1/p) 次必定爆一次
## （p=0.03 → 34 次内必出；p=0.01 → 100 次内必出）
## rng_value 用来在测试里注入确定值，<0 表示现掷
func roll_hidden_drop(crop_name: String, chance: float, rng_value: float = -1.0) -> bool:
	if crop_name == "" or chance <= 0.0:
		return false
	var pity_limit := maxi(1, ceili(1.0 / chance))
	var tries: int = _drop_pity.get(crop_name, 0) + 1
	var roll: float = randf() if rng_value < 0.0 else rng_value
	var hit: bool = roll < chance or tries >= pity_limit
	if hit:
		_drop_pity[crop_name] = 0
		add_stock(crop_name, 1)
	else:
		_drop_pity[crop_name] = tries
	return hit


func _on_tick() -> void:
	time += 1
	# >= 而不是 >：否则 max_time=30 实际要走 31 拍才换天，一天就不等于 30 秒了
	if time >= max_time:
		time = 0
		_end_day()


## 一天结束：推进所有作物，结算浇水/枯萎/收获，然后湿土变回干土
func _end_day() -> void:
	day += 1
	if day_label != null:
		day_label.text = "第 %d 天" % day
	var dead: Array[Vector2i] = []

	for coord in crop_dict.keys():
		var crop: Crop = crop_dict[coord]
		if not is_instance_valid(crop):
			dead.append(coord)
			continue

		crop.advance_day()

		if crop.gone:
			dead.append(coord)

	for coord in dead:
		crop_dict.erase(coord)

	# 换天：湿土叠加层整体清掉，干土保持（作物留在原地，只是不再算浇水）
	# 先记下浇过水的格子——湿土清掉后就查不到了，而"浇过水"属于当天操作过，
	# 不该算进空土老化
	var watered_cells := {}
	for c in map_wet_soil.get_used_cells():
		watered_cells[c] = true
	map_wet_soil.clear()

	# 空土老化：连续 EMPTY_SOIL_LIMIT 天没有作物 → 长回草地
	var to_clear: Array[Vector2i] = []
	for cell in map_soil.get_used_cells():
		if crop_dict.has(cell):
			empty_soil_days.erase(cell)
			continue
		if watered_cells.has(cell):
			empty_soil_days.erase(cell)   # 今天浇过水 = 操作过，重新计数
			continue
		var days: int = empty_soil_days.get(cell, 0) + 1
		if days >= EMPTY_SOIL_LIMIT:
			to_clear.append(cell)
		else:
			empty_soil_days[cell] = days
	# 擦除时 erase_soil 已经把每一格的八邻刷新过了，这里不要再整层重算：
	# set_cells_terrain_connect 在有多个等价瓦片时会随机挑一个，
	# 逐格刷新会让边缘瓦片天天换样（看着像 autotile 没更新）。
	for cell in to_clear:
		erase_soil(cell)

	day_changed.emit()


func _unhandled_input(event: InputEvent) -> void:
	# F11（或 Alt+Enter）全屏 / 窗口切换：默认全屏启动，小屏上想回窗口化时用这个
	if event is InputEventKey and event.pressed and not event.echo:
		# Ctrl+D：开关隐藏调试面板（测金花概率用）
		if event.keycode == KEY_D and event.ctrl_pressed:
			toggle_debug_panel()
			get_viewport().set_input_as_handled()
			return
		if event.keycode == KEY_F11 or (event.keycode == KEY_ENTER and event.alt_pressed):
			var window := get_window()
			window.mode = Window.MODE_WINDOWED if window.mode == Window.MODE_FULLSCREEN else Window.MODE_FULLSCREEN
			get_viewport().set_input_as_handled()
		return

	# 只处理鼠标事件：键盘/手柄事件没有 position，直接读会报
	# "Invalid access to property or key 'position' on InputEventKey"
	if not (event is InputEventMouse):
		return

	# 底部栏目与土地隔绝：栏内的点击不参与耕作/浇水/播种
	if event.position.y > get_viewport().get_visible_rect().size.y - HUD_HEIGHT:
		return

	# 中键拖动平移世界（草地比可视区大）
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_MIDDLE:
		_panning = event.pressed
		return
	if event is InputEventMouseMotion and _panning:
		world_offset += event.relative
		_clamp_offset()
		return

	var world_pos := screen_to_world(event.position)
	var coord: Vector2i = map_grass.local_to_map(world_pos)
	var has_grass := map_grass.get_cell_tile_data(coord) != null
	var has_soil := map_soil.get_cell_tile_data(coord) != null
	var has_wet := map_wet_soil.get_cell_tile_data(coord) != null

	if event is InputEventMouseMotion:
		position_hint.visible = has_grass
		position_hint.position = map_soil.map_to_local(coord) + world_offset - position_hint.pivot_offset

	if event is InputEventMouseButton:
		if event.pressed and event.button_index == MOUSE_BUTTON_LEFT:

			# 成熟作物：点一下收获（连种作物回到指定阶段，金花额外 +1）
			# 枯萎作物：点一下渐隐消失（没有产出）
			if crop_dict.has(coord):
				var planted: Crop = crop_dict[coord]
				if planted.is_mature():
					planted.harvest()
					return
				if planted.is_withered:
					planted.clear_withered()
					return

			match selected_tool.tool_type:
				Enums.ToolType.HOE:
					# 草地 → 干土（已经是土或湿土就不重复锄；最外圈草地不许锄）
					if has_grass and not has_soil and not has_wet and is_tillable(coord):
						_apply_terrain(map_soil, coord, TERRAIN_SOIL)
						empty_soil_days[coord] = 0
						play_sfx("till")
				Enums.ToolType.WATER_CAN:
					# 干土 → 湿土：Soil 保留，WetSoil 作为 autotile 叠加在上面
					if has_soil and not has_wet:
						_apply_terrain(map_wet_soil, coord, TERRAIN_WET)
						play_sfx("water")
				Enums.ToolType.SEED:
					# 干土或湿土都能种
					if (has_soil or has_wet) and not crop_dict.has(coord):
						var crop: Crop = Prefabs.crop.instantiate()
						crop_pool.add_child(crop)
						crop.setup(selected_tool.seed_data, coord)
						crop.position = map_soil.map_to_local(coord)
						crop_dict[coord] = crop
						empty_soil_days.erase(coord)
						play_sfx("sow")


## —— 隐藏调试面板（Ctrl+D）——
## 给测试用：把金花分母改成 1/N（填 100 = 1/100），并统计实测爆率。
var debug_panel: Control
var debug_denominator_edit: LineEdit
var debug_stats_label: Label
var dbg_rolls: int = 0
var dbg_goldens: int = 0
var debug_golden_denominator: int = 33
var _golden_defaults: Dictionary = {}


func toggle_debug_panel() -> void:
	if debug_panel == null:
		_build_debug_panel()
	debug_panel.visible = not debug_panel.visible
	if debug_panel.visible:
		_refresh_debug_stats()


func _build_debug_panel() -> void:
	if _golden_defaults.is_empty():
		for crop in crop_datas:
			if crop.golden_chance > 0.0:
				_golden_defaults[crop.name] = crop.golden_chance
				debug_golden_denominator = maxi(1, int(round(1.0 / crop.golden_chance)))

	var layer := CanvasLayer.new()
	layer.name = "DebugLayer"
	layer.layer = 9
	add_child(layer)

	var panel := Panel.new()
	panel.name = "DebugPanel"
	panel.position = Vector2(3, 3)
	panel.size = Vector2(212, 74)
	panel.visible = false
	layer.add_child(panel)
	debug_panel = panel

	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.08, 0.09, 0.08, 0.92)
	sb.border_width_left = 1
	sb.border_width_top = 1
	sb.border_width_right = 1
	sb.border_width_bottom = 1
	sb.border_color = Color(0.44, 0.32, 0.22, 1.0)
	panel.add_theme_stylebox_override("panel", sb)

	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_FULL_RECT)
	box.offset_left = 5
	box.offset_top = 4
	box.offset_right = -5
	box.offset_bottom = -4
	box.add_theme_constant_override("separation", 3)
	panel.add_child(box)

	var title := Label.new()
	title.text = "调试：金花概率（Ctrl+D 开关）"
	title.add_theme_font_size_override("font_size", 8)
	title.add_theme_color_override("font_color", Color(0.95, 0.78, 0.5))
	box.add_child(title)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 3)
	box.add_child(row)

	var label_a := Label.new()
	label_a.text = "1 /"
	label_a.add_theme_font_size_override("font_size", 8)
	row.add_child(label_a)

	debug_denominator_edit = LineEdit.new()
	debug_denominator_edit.text = str(debug_golden_denominator)
	debug_denominator_edit.custom_minimum_size = Vector2(44, 12)
	debug_denominator_edit.add_theme_font_size_override("font_size", 8)
	debug_denominator_edit.text_submitted.connect(func(_t: String) -> void: _apply_debug_denominator())
	debug_denominator_edit.focus_exited.connect(func() -> void: _apply_debug_denominator())
	row.add_child(debug_denominator_edit)

	var label_b := Label.new()
	label_b.text = "（填 100 = 1/100）"
	label_b.add_theme_font_size_override("font_size", 8)
	label_b.add_theme_color_override("font_color", Color(0.75, 0.72, 0.66))
	row.add_child(label_b)

	debug_stats_label = Label.new()
	debug_stats_label.add_theme_font_size_override("font_size", 8)
	box.add_child(debug_stats_label)

	var row2 := HBoxContainer.new()
	row2.add_theme_constant_override("separation", 4)
	box.add_child(row2)

	var reset := Button.new()
	reset.text = "重置统计"
	reset.add_theme_font_size_override("font_size", 8)
	reset.custom_minimum_size = Vector2(52, 14)
	reset.pressed.connect(func() -> void:
		dbg_rolls = 0
		dbg_goldens = 0
		_refresh_debug_stats())
	row2.add_child(reset)

	var restore := Button.new()
	restore.text = "恢复默认概率"
	restore.add_theme_font_size_override("font_size", 8)
	restore.custom_minimum_size = Vector2(66, 14)
	restore.pressed.connect(_restore_golden_defaults)
	row2.add_child(restore)

	_refresh_debug_stats()


func _apply_debug_denominator() -> void:
	if debug_denominator_edit == null:
		return
	var n := int(debug_denominator_edit.text.strip_edges().to_int())
	n = clampi(n, 1, 100000)
	debug_denominator_edit.text = str(n)
	debug_golden_denominator = n
	var chance := 1.0 / float(n)
	for crop in crop_datas:
		if crop.golden_chance > 0.0 or crop.name in _golden_defaults:
			crop.golden_chance = chance
	_refresh_debug_stats()


func _restore_golden_defaults() -> void:
	for crop in crop_datas:
		if _golden_defaults.has(crop.name):
			crop.golden_chance = _golden_defaults[crop.name]
			debug_golden_denominator = maxi(1, int(round(1.0 / crop.golden_chance)))
	if debug_denominator_edit != null:
		debug_denominator_edit.text = str(debug_golden_denominator)
	_refresh_debug_stats()


## 作物每次掷金花都会调这里，面板据此算实测概率
func debug_register_golden_roll(hit: bool) -> void:
	dbg_rolls += 1
	if hit:
		dbg_goldens += 1
	_refresh_debug_stats()


func _refresh_debug_stats() -> void:
	if debug_stats_label == null:
		return
	var rate := 0.0 if dbg_rolls == 0 else 100.0 * float(dbg_goldens) / float(dbg_rolls)
	var cur := 0.0
	for crop in crop_datas:
		if crop.golden_chance > 0.0:
			cur = crop.golden_chance
			break
	debug_stats_label.text = "掷 %d 次 · 金花 %d 株 · 实测 %.1f%%（当前 1/%d）" % [
		dbg_rolls, dbg_goldens, rate, maxi(1, int(round(1.0 / cur))) if cur > 0.0 else 0
	]
