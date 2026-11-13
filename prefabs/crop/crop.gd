class_name Crop
extends AnimatedSprite2D

## 连续不浇水多少天死亡（种子消失 / 苗枯萎）：同样等 2 天没水，第 3 天结算才死
const DRY_DAYS_TO_DIE := 3

## 成熟后放着不收获，第 3 天结算就过熟枯萎（和"2 天不管 → 第 3 天"的其它规则一致）
const RIPE_DAYS_TO_WITHER := 3

## 枯萎后没人点，放 3 天也自己消失（和"点一下立刻渐隐"走同一段动画）
const WITHERED_DAYS_TO_GONE := 3

var coord: Vector2i
var data: CropData
var dry_days: int = 0
## 成熟后已经放了多少天没收获
var ripe_days: int = 0
var is_withered := false
## 枯萎之后又放了多少天（到 WITHERED_DAYS_TO_GONE 就自己消失）
var withered_days: int = 0
var is_golden := false
var gone := false

## 今天是否浇过水（湿土图层的瓦片就是浇水标记）
var watered: bool:
	get:
		return Game.map_wet_soil.get_cell_tile_data(coord) != null


## 素材里每个阶段的苗都画在 16x16 格的**下半部分**（底边贴 15/16 行），
## 所以瓦片对齐到格子里就是对的，不需要再整体上抬；上抬 -8 会让整排作物
## 浮在土块上方（客户反馈"种子、苗都偏上"）。
const GROWN_OFFSET_Y := 0.0


func _ready() -> void:
	frame_changed.connect(_update_offset)
	animation_changed.connect(_update_offset)
	_update_offset()


func _update_offset() -> void:
	var is_seed := data != null and animation == data.name and frame == 0
	offset.y = 0.0 if is_seed else GROWN_OFFSET_Y


## 由 Game 在种植时调用。各阶段的帧预置在 crop.tscn 的 SpriteFrames 里（编辑器可见），
## 这里只负责切到对应作物的动画。
func setup(crop_data: CropData, cell: Vector2i) -> void:
	data = crop_data
	coord = cell
	animation = data.name
	frame = 0
	z_index = 1
	_roll_golden()


func last_stage() -> int:
	return sprite_frames.get_frame_count(data.name) - 1


## 可收获的"成果状态" = 倒数第二帧。最后一帧是"收获瞬间"的样子：
## 点下去先切到最后一帧，再从这一帧吸进对应的收成库存。
func mature_stage() -> int:
	# 约定：最后一帧是成品（收获时的样子），田里始终停在它的前一帧
	return maxi(last_stage() - 1, 0)


func is_mature() -> bool:
	return not is_withered and not gone and frame >= mature_stage()


## 每天结束调用一次
func advance_day() -> void:
	if gone:
		return

	# 已经枯萎：没人点也会自己烂掉，第 3 天结算就消失
	if is_withered:
		withered_days += 1
		if withered_days >= WITHERED_DAYS_TO_GONE:
			clear_withered()
		return

	# 已经成熟：只看"放了几天没收获"，浇水不再延命
	if is_mature():
		ripe_days += 1
		if ripe_days >= RIPE_DAYS_TO_WITHER:
			_wither()
		return

	if watered:
		dry_days = 0
		if frame < mature_stage():
			frame += 1
	else:
		dry_days += 1
		if dry_days >= DRY_DAYS_TO_DIE:
			if frame == 0:
				_disappear()        # 种子：连续 2 天没浇水 → 消失
			else:
				_wither()           # 苗：连续 2 天没浇水 → 枯萎


func _roll_golden() -> void:
	if data.golden_chance <= 0.0 or data.golden.is_empty():
		return
	var hit: bool = Game.roll_golden_harvest(data.name, data.golden_chance)
	# 调试面板统计：每次真实掷骰都记一笔（分母可在 Ctrl+D 面板里改）
	Game.debug_register_golden_roll(hit)
	if not hit:
		return
	is_golden = true
	# 给这一株设置金花的茎和成熟外观，连种时沿用同一套生长帧。
	var mature := mature_stage()
	var own: SpriteFrames = sprite_frames.duplicate()
	if data.golden_stem != null and mature > 1:
		own.set_frame(data.name, mature - 1, data.golden_stem)
	own.set_frame(data.name, mature, data.golden[0])
	sprite_frames = own
	animation = data.name
	frame = 0


func _wither() -> void:
	is_withered = true
	animation = "withered"      # crop.tscn 里预置的枯萎动画
	frame = 0
	modulate = Color(0.75, 0.75, 0.7)


## 枯萎的作物：玩家点一下，就地渐变消失（没有产出，也不留残影）
func clear_withered() -> void:
	if gone or not is_withered:
		return
	gone = true
	Game.crop_dict.erase(coord)
	var t := create_tween()
	t.set_parallel(true)
	t.tween_property(self, "modulate:a", 0.0, 0.55)
	t.tween_property(self, "scale", Vector2(0.85, 0.85), 0.55)
	t.chain().tween_callback(queue_free)


func _disappear() -> void:
	gone = true
	Game.crop_dict.erase(coord)
	var tween := create_tween()
	tween.tween_property(self, "modulate:a", 0.0, 0.25)
	tween.tween_callback(queue_free)


## 收获时，成品飞向对应库存；连种作物回到重置阶段继续长。
func harvest() -> void:
	if gone or is_withered:
		return

	var hidden_harvest := is_golden and not data.golden_harvest.is_empty()
	var stock_name := data.golden_harvest if hidden_harvest else data.name
	var amount := 1 if hidden_harvest else data.yield_amount * (2 if is_golden else 1)
	Game.add_stock(stock_name, amount)
	Game.play_sfx("harvest_hidden" if hidden_harvest else "harvest")

	# 本体留在成果形态（成品只在飞行残影里出现，不落在土里）
	ripe_days = 0
	animation = data.name
	_update_offset()
	var product := sprite_frames.get_frame_texture(animation, last_stage())
	if is_golden and not data.golden.is_empty():
		product = data.golden[data.golden.size() - 1]
	_spawn_absorb_ghost(Game.stock_pool.get_node_or_null(NodePath(stock_name)), product)

	if data.repeat_harvest:
		# 连种：残影负责飞，本体立刻回到重置阶段（否则下一个生长日会从"收获帧"继续）
		frame = clampi(data.reset_stage, 0, maxi(mature_stage() - 1, 0))
		_update_offset()
		var pop := create_tween()
		pop.tween_property(self, "scale", Vector2(1.15, 0.85), 0.08)
		pop.tween_property(self, "scale", Vector2.ONE, 0.12)
		return

	gone = true
	Game.crop_dict.erase(coord)
	# 立刻从土里拿掉：成品已经飞走了，土里不该留任何成品形态
	visible = false
	queue_free()


## 生成一个残影，从作物原位飞向对应的库存图标。
## 世界画在 SubViewport 里、库存栏在 HUD 的 CanvasLayer 里，所以残影挂到 HUD
## 层上并用画布坐标飞，否则会被子视口裁掉、飞不到栏目上。
func _spawn_absorb_ghost(target: StockLabel, texture: Texture2D) -> void:
	if target == null or texture == null:
		return

	var hud: Node = Game.get_node_or_null(^"HudLayer")
	var ghost := Sprite2D.new()
	ghost.texture = texture
	ghost.offset = Vector2(0, offset.y)
	ghost.z_index = z_index + 1
	if hud != null:
		# 世界在 SubViewport 里，其全局坐标与画布坐标系一一对应（world_root 的
		# 平移已经算在里面了），所以直接用 global_position，别再叠一次 world_offset
		ghost.global_position = global_position
		hud.add_child(ghost)
	else:
		ghost.global_position = global_position
		Game.crop_pool.add_child(ghost)

	var start := ghost.global_position
	# 飞行途中保持不透明，**到达库存项之后**才淡出——半路淡掉玩家就看不出飞去哪了
	var fly := ghost.create_tween()
	# EASE_OUT：起步就窜出去，再缓入停在库存图标上
	# 库存数字变化时会重新布局，每帧取图标位置，确保飞到更新后的位置。
	fly.tween_method(func(weight: float) -> void:
		ghost.global_position = start.lerp(target.rect_icon.get_global_rect().get_center(), weight),
		0.0, 1.0, 0.5).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	fly.parallel().tween_property(ghost, "scale", Vector2(0.8, 0.8), 0.5)
	fly.tween_property(ghost, "modulate:a", 0.0, 0.12)
	fly.tween_callback(ghost.queue_free)
