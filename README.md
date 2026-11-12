# Godot FarmingGame Example

A small pixel-art farming game made with Godot: till the soil, plant seeds, water them and harvest.

![screenshot](docs/screenshot.jpg)

## Features

* Tile-based field: hoe a tile into soil, water it into wet soil (TileMapLayer terrains handle the autotiling)
* Three tools: hoe, watering can, and a seed panel listing every crop with its seed icon
* 11 spring crops with 7-frame growth animations: asparagus, broccoli, cabbage, carrot, cauliflower, onion, parsnip, potato, rice, spring onion, strawberry
* Day cycle: a planted crop grows one stage per game day and only if it was watered that day - rain or shine, the wet soil dries up every morning
* Harvest animation flies into the stock panel and raises that crop's counter
* Sound effects for tilling, watering, sowing and harvesting (`assets/audio/*.wav`), with a separate cue when a harvest drops a hidden crop, over a looping music track
* Crop data is Resource based (`data/crops/*.tres`): add a new crop by adding one resource file, and edit every crop in a single table with the bundled "Edit Resources as Table" editor plugin
* TODO:
  - More crops and seasons
  - Save and load

## How to play

Pick a tool at the bottom left, then left click a tile on the field:

1. **Hoe** a tile: grass turns into soil
2. pick a **seed** in the right hand column and plant it on a soil tile
3. **Water** it - and water it again every game day, otherwise it stops growing
4. once the crop reaches its last stage it is harvested automatically and its counter in the left hand column goes up

## Download

Builds for Windows (x64) are attached to the [releases page](../../releases).

## Running from source

Open `project.godot` with [Godot 4.7](https://godotengine.org) and press F5. Export presets for Web and Windows Desktop are included in `export_presets.cfg`.

## About

* **Director**: Snowy YANG
* **Programmer**: Kottalo
* **Artist**: 像素虚空
* **Editor addon**: "Edit Resources as Table" by Gennady "Don Tnowe" Krupenyov

## License

* **Project**: [GPL-3.0](LICENSE)
* **Assets**
  - **Art** (*.png*): [CC-BY-SA-4.0](LICENSE-assets.txt)
  - **Editor addon** (*addons/resources_spreadsheet_view/*): [MIT](addons/resources_spreadsheet_view/LICENSE.md), © 2022 Gennady "Don Tnowe" Krupenyov

## Acknowledgments

* [Godot Engine](https://godotengine.org)
