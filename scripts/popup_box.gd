class_name PopupBox
extends RefCounted
## Draws the hover popups: a dark box of text lines with a colored border.

const FONT_SIZE := 14
const LINE_HEIGHT := 18


## Draws `lines` on `canvas` next to `anchor`, kept inside the area ending at
## `view_end`. If `swatch_line` is set, that line gets a color swatch in `color`.
static func draw(canvas: CanvasItem, lines: Array[String], anchor: Vector2, view_end: Vector2, color: Color, swatch_line := -1) -> void:
	var font := ThemeDB.fallback_font
	var width := 0.0
	for l in lines:
		width = maxf(width, font.get_string_size(l, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE).x)
	var box := Vector2(width + 32, lines.size() * LINE_HEIGHT + 12)
	var pos := anchor + Vector2(14, 14)
	pos.x = minf(pos.x, view_end.x - box.x - 4)
	pos.y = minf(pos.y, view_end.y - box.y - 4)

	canvas.draw_rect(Rect2(pos, box), Color(0.08, 0.08, 0.1, 0.92))
	canvas.draw_rect(Rect2(pos, box), color, false, 2.0)
	if swatch_line >= 0:
		canvas.draw_rect(Rect2(pos + Vector2(8, (swatch_line + 1) * LINE_HEIGHT - 6), Vector2(12, 12)), color)
	for i in lines.size():
		var x := 24.0 if i == swatch_line else 8.0
		var text_color := Color.WHITE if i == 0 else Color(0.8, 0.8, 0.85)
		canvas.draw_string(font, pos + Vector2(x, LINE_HEIGHT + i * LINE_HEIGHT), lines[i], HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE, text_color)
