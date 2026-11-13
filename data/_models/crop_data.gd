class_name CropData
extends Resource

## 作物名 = 文件名（cabbage / mushroom / radish / potato / mint）
var name: String:
	get:
		return resource_path.get_file().split(".")[0]

@export var icon: AtlasTexture                      ## 种子袋图标（UI 里显示）
@export var stages: Array[AtlasTexture]             ## 生长阶段，索引 0 = 刚播种，最后一个 = 成熟
@export var withered: AtlasTexture                  ## 枯萎贴图
@export var repeat_harvest: bool = false            ## true = 连种：收完回到 reset_stage
@export var reset_stage: int = 0                    ## 连种作物收完后回到第几阶段
@export var golden_chance: float = 0.0              ## 成熟时变成金花的概率（薄荷 0.03）
@export var golden: Array[AtlasTexture]             ## 金花贴图（可为空）
@export var yield_amount: int = 1                   ## 每次收获数量
## —— 隐藏作物相关 ——
@export var plantable: bool = true                  ## false = 不进种子栏（只能靠掉落获得）
@export var hidden_until_obtained: bool = false     ## true = 收成栏里一开始完全隐形，拿到才显示
@export var hidden_drop: String = ""                ## 收获本作物时可能掉落的隐藏作物名
@export var hidden_drop_chance: float = 0.0         ## 掉落概率（带保底，见 Game.roll_hidden_drop）
