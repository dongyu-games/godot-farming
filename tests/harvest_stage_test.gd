extends Node

## 回归：成果状态 = 倒数第二帧；收获瞬间切到最后一帧，再从那一帧吸进库存
## 运行: godot --headless --path . tests/harvest_stage_test.tscn

var pass_count := 0
var fail_count := 0


func _ready() -> void:
	await get_tree().process_frame
	await get_tree().process_frame

	print("[A] 各作物的成果状态 = 倒数第二帧")
	for data in Game.crop_datas:
		if not data.plantable:
			# 隐藏作物不可种植，crop.tscn 里本来就没有它的动画
			var crop: Crop = Prefabs.crop.instantiate()
			_check("%s: 不可种植、没有生长动画" % data.name,
				not crop.sprite_frames.has_animation(data.name))
			crop.free()
			continue
		var crop := _spawn_prefab(data)
		var last := crop.last_stage()
		var mature := crop.mature_stage()
		_check("%s: 成果帧 = %d（最后一帧 %d 是成品）" % [data.name, mature, last],
			mature == last - 1 and last >= 1)
		crop.free()

	# 土豆：田里停在成品的前一帧（192,112）；成品 = 最后一帧土豆堆 (224,112)
	for data in Game.crop_datas:
		if data.name != "potato":
			continue
		var pcrop := _spawn_prefab(data)
		var field_tex: AtlasTexture = pcrop.sprite_frames.get_frame_texture(data.name, pcrop.mature_stage())
		var product_tex: AtlasTexture = pcrop.sprite_frames.get_frame_texture(data.name, pcrop.last_stage())
		_check("potato: 田里停在成品的前一帧 (192,112)",
			field_tex != null and field_tex.region == Rect2(192, 112, 16, 16),
			"田里 region=%s" % (field_tex.region if field_tex != null else "null"))
		_check("potato: 成品帧是土豆堆 (224,112)",
			product_tex != null and product_tex.region == Rect2(224, 112, 16, 16),
			"成品 region=%s" % (product_tex.region if product_tex != null else "null"))
		_check("potato: 收成栏图标是土豆堆",
			data.stages[data.stages.size() - 1].region == Rect2(224, 112, 16, 16),
			"icon=%s" % data.stages[data.stages.size() - 1].region)
		pcrop.free()

	print("\n[B] 一天一浇水，长到成果状态就停住")
	var data0: CropData = Game.crop_datas[0]          # cabbage，一次性收获
	var coord := Vector2i(10, 2)
	var crop := _plant(data0, coord)
	var mature0 := crop.mature_stage()
	var days := 0
	var seen: Array[int] = []
	for i in range(8):
		_water(coord)
		Game._end_day()
		days += 1
		seen.append(crop.frame)
		if days > mature0 + 1:
			break
	print("   逐天帧: ", seen, "  成果帧=", mature0, " 最后一帧=", crop.last_stage())
	_check("帧序列单调到成果帧后停住", seen[-1] == mature0, "最后 frame=%d" % crop.frame)
	_check("成果状态可收获", crop.is_mature(), "frame=%d" % crop.frame)

	print("\n[C] 一次性作物：土里不出现成品，成品直接飞走")
	var ghosts_before := _ghost_count()
	var field_frame_before := crop.frame
	crop.harvest()
	_check("土里没切到成品帧", crop.frame == field_frame_before and crop.frame == crop.mature_stage(),
		"frame=%d 成果帧=%d 成品帧=%d" % [crop.frame, crop.mature_stage(), crop.last_stage()])
	_check("本体立刻从土里消失", not crop.visible, "visible=%s" % crop.visible)
	_check("已从 crop_dict 移除", not Game.crop_dict.has(coord))
	_check("生成吸收残影", _ghost_count() == ghosts_before + 1,
		"残影 %d → %d" % [ghosts_before, _ghost_count()])
	var ghost: Node = _last_ghost()
	if ghost != null:
		var gtex: Texture2D = ghost.texture
		_check("残影用的是最后一帧贴图", gtex == crop.sprite_frames.get_frame_texture(data0.name, crop.last_stage()))
		var d: float = (ghost.global_position - crop.global_position).length()
		_check("残影从作物所在格起飞", d < 2.0, "偏移 %.1f px" % d)
	_check("库存 +1", Game.stock.get(data0.name, 0) >= 1, "库存 %d" % Game.stock.get(data0.name, 0))

	# 吸收动画必须一路飞到库存图标上才消失，玩家才知道飞去哪儿了
	var icon_center := _stock_icon_center(data0.name)
	var g: Sprite2D = ghost as Sprite2D
	if g == null:
		_check("拿到残影节点", false)
	else:
		var d0: float = (g.global_position - icon_center).length()
		await get_tree().create_timer(0.25).timeout
		var d1: float = (g.global_position - icon_center).length() if is_instance_valid(g) else -1.0
		_check("飞行途中还在、且在靠近库存项", is_instance_valid(g) and d1 < d0,
			"距离 %.1f → %.1f" % [d0, d1])
		if is_instance_valid(g):
			_check("飞行途中没有提前淡出", g.modulate.a > 0.9, "alpha=%.2f" % g.modulate.a)
		await get_tree().create_timer(0.3).timeout
		var arrived: bool = is_instance_valid(g)
		var d2: float = (g.global_position - icon_center).length() if arrived else -1.0
		_check("到达库存图标位置（距离 < 2px）", arrived and d2 < 2.0, "距离 %.1f" % d2)
		if arrived:
			_check("到达后才开始淡出", g.modulate.a <= 1.0)
	await get_tree().create_timer(0.3).timeout
	_check("落地淡出后销毁", _ghost_count() == 0, "剩余 %d" % _ghost_count())

	print("\n[D] 连种作物：收获瞬间切最后一帧，本体回到重置阶段")
	var data_repeat: CropData = Game.crop_datas[1]    # mushroom，连种
	var coord2 := Vector2i(11, 2)
	var crop2 := _plant(data_repeat, coord2)
	for i in range(crop2.mature_stage()):
		_water(coord2)
		Game._end_day()
	_check("蘑菇长到成果帧", crop2.frame == crop2.mature_stage(), "frame=%d" % crop2.frame)
	crop2.harvest()
	_check("本体回到 reset_stage", crop2.frame == data_repeat.reset_stage,
		"frame=%d reset=%d" % [crop2.frame, data_repeat.reset_stage])
	_check("仍在地块上", Game.crop_dict.has(coord2) and not crop2.gone)

	print("\n[D2] 薄荷收获后回到小花骨朵（f3）")
	var mint_data: CropData = Game.crop_datas[4]
	var coord3 := Vector2i(9, 2)
	var crop3 := _plant(mint_data, coord3)
	for i in range(7):
		_water(coord3)
		Game._end_day()
	_check("薄荷成熟在成果帧 %d" % crop3.mature_stage(), crop3.frame == crop3.mature_stage(),
		"frame=%d" % crop3.frame)
	crop3.harvest()
	_check("收获后回到 reset_stage", crop3.frame == mint_data.reset_stage,
		"frame=%d reset=%d" % [crop3.frame, mint_data.reset_stage])
	_check("reset_stage 是小花骨朵 f3", mint_data.reset_stage == 3, "reset=%d" % mint_data.reset_stage)
	var tex := crop3.sprite_frames.get_frame_texture(mint_data.name, crop3.frame)
	_check("回到的那一帧就是贴图里的 f3", (tex as AtlasTexture) != null and (mint_data.stages[mint_data.reset_stage] as AtlasTexture) != null and (tex as AtlasTexture).region == (mint_data.stages[mint_data.reset_stage] as AtlasTexture).region)
	Game.crop_dict.erase(coord3)
	await get_tree().create_timer(0.7).timeout

	print("\n[E] 金花只改本株，不影响同种其它作物")
	var mint: CropData = Game.crop_datas[4]
	var saved := mint.golden_chance
	mint.golden_chance = 0.0
	var cb := _plant(mint, Vector2i(13, 2))
	mint.golden_chance = 1.0
	var ca := _plant(mint, Vector2i(12, 2))
	mint.golden_chance = saved
	for i in range(7):
		_water(Vector2i(12, 2))
		_water(Vector2i(13, 2))
		Game._end_day()
	print("   a: golden=", ca.is_golden, " frames_same_resource=", ca.sprite_frames == cb.sprite_frames)
	_check("两株都到成果帧/或成熟", ca.is_mature() and cb.is_mature())
	_check("金花株拥有独立 SpriteFrames", ca.is_golden and not cb.is_golden
		and ca.sprite_frames != cb.sprite_frames)
	Game.crop_dict.erase(Vector2i(12, 2))
	Game.crop_dict.erase(Vector2i(13, 2))

	print("\n=== 结果: %d 通过, %d 失败 ===" % [pass_count, fail_count])
	get_tree().quit(0 if fail_count == 0 else 1)


func _spawn_prefab(data: CropData) -> Crop:
	var crop: Crop = Prefabs.crop.instantiate()
	add_child(crop)
	crop.setup(data, Vector2i(0, 0))
	return crop


func _plant(data: CropData, coord: Vector2i) -> Crop:
	Game._apply_terrain(Game.map_soil, coord, Game.TERRAIN_SOIL)
	var crop: Crop = Prefabs.crop.instantiate()
	Game.crop_pool.add_child(crop)
	crop.setup(data, coord)
	crop.position = Game.map_soil.map_to_local(coord)
	Game.crop_dict[coord] = crop
	return crop


func _water(coord: Vector2i) -> void:
	Game._apply_terrain(Game.map_wet_soil, coord, Game.TERRAIN_WET)


func _stock_icon_center(crop_name: String) -> Vector2:
	var label: Node = Game.stock_pool.get_node_or_null(NodePath(crop_name))
	if label == null:
		return Vector2.ZERO
	var icon := label.get_node_or_null(^"Icon") as Control
	if icon == null:
		return (label as Control).global_position
	return icon.global_position + icon.size * 0.5


func _ghost_count() -> int:
	var hud: Node = Game.get_node_or_null(^"HudLayer")
	if hud == null:
		return 0
	var n := 0
	for child in hud.get_children():
		if child is Sprite2D and is_instance_valid(child):
			n += 1
	return n


func _last_ghost() -> Node:
	var hud: Node = Game.get_node_or_null(^"HudLayer")
	if hud == null:
		return null
	for child in hud.get_children():
		if child is Sprite2D and is_instance_valid(child):
			return child
	return null


func _check(label: String, condition: bool, detail: String = "") -> void:
	if condition:
		pass_count += 1
		print("  ✓ ", label, ("  " + detail) if detail else "")
	else:
		fail_count += 1
		print("  ✗ ", label, "  ", detail)
