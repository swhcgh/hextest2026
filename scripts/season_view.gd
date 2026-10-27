class_name SeasonView
extends Control
## Screen-space seasonal color wash over the map that blends from season to
## season. Set `total_days` from outside.

const TINTS: Array[Color] = [  # at the peak of winter, spring, summer, autumn
	Color(0.65, 0.78, 1.0, 0.16),
	Color(0.55, 0.95, 0.65, 0.06),
	Color(1.0, 0.92, 0.55, 0.08),
	Color(1.0, 0.55, 0.2, 0.13),
]

var total_days := 0:
	set(value):
		total_days = value
		queue_redraw()


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


## The wash color for the current day, blended between neighboring seasons.
func tint() -> Color:
	var x := Upkeep.year_phase(total_days) * 4.0
	var a := int(floor(x)) % 4
	return TINTS[a].lerp(TINTS[(a + 1) % 4], x - floor(x))


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), tint())
