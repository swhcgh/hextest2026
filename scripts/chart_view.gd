class_name ChartView
extends Control
## Line chart of several series over time. Set `series` (dictionaries with
## name, color, start and values, as History produces), `days` (the x axis)
## and `title`, then call queue_redraw().

const FONT_SIZE := 11
const LEFT := 46.0
const TOP := 22.0
const RIGHT := 10.0
const X_LABEL_HEIGHT := 18.0
const LEGEND_ROW := 14.0
const GRID_LINES := 4
const X_TICKS := 5
const BACKGROUND := Color(0.08, 0.09, 0.11, 0.92)
const GRID_COLOR := Color(1, 1, 1, 0.12)
const TEXT_COLOR := Color(0.85, 0.87, 0.9)

var series: Array[Dictionary] = []
var days := PackedInt32Array()
var title := ""


func _init() -> void:
	custom_minimum_size = Vector2(360, 220)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), BACKGROUND)
	var font := ThemeDB.fallback_font
	draw_string(font, Vector2(8, 15), title, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE + 1, TEXT_COLOR)

	var legend := _legend_layout(font)
	var plot_bottom: float = size.y - X_LABEL_HEIGHT - legend.rows * LEGEND_ROW - 4.0
	var plot := Rect2(LEFT, TOP, size.x - LEFT - RIGHT, plot_bottom - TOP)
	if plot.size.x < 20.0 or plot.size.y < 20.0:
		return

	var top := _nice_ceiling(_max_value())
	for i in GRID_LINES + 1:
		var y := plot.end.y - plot.size.y * i / GRID_LINES
		draw_line(Vector2(plot.position.x, y), Vector2(plot.end.x, y), GRID_COLOR)
		var label := str(roundi(top * i / GRID_LINES))
		draw_string(font, Vector2(4, y + 4), label, HORIZONTAL_ALIGNMENT_LEFT, LEFT - 8, FONT_SIZE, TEXT_COLOR)

	var count := days.size()
	if count < 2:
		draw_string(font, plot.position + Vector2(8, 20), "Collecting data...", HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE, TEXT_COLOR)
	else:
		for i in X_TICKS + 1:
			var sample := roundi((count - 1) * float(i) / X_TICKS)
			var x := plot.position.x + plot.size.x * sample / (count - 1)
			draw_line(Vector2(x, plot.position.y), Vector2(x, plot.end.y), GRID_COLOR)
			draw_string(font, Vector2(x - 14, plot.end.y + 14), "D%d" % days[sample], HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE, TEXT_COLOR)
		for line in series:
			_draw_series(line, plot, top, count)

	for entry in legend.items:
		var line: Dictionary = series[entry.index]
		draw_rect(Rect2(entry.pos.x, entry.pos.y - 8, 8, 8), line.color)
		draw_string(font, entry.pos + Vector2(12, 0), line.name, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE, TEXT_COLOR)


func _draw_series(line: Dictionary, plot: Rect2, top: float, count: int) -> void:
	var values: PackedInt32Array = line.values
	if values.is_empty():
		return
	var step := maxi(ceili(float(values.size()) / plot.size.x), 1)  # a point per pixel at most
	var points := PackedVector2Array()
	var i := 0
	while i < values.size():
		points.append(_point(line.start + i, values[i], plot, top, count))
		i += step
	if (values.size() - 1) % step != 0:
		points.append(_point(line.start + values.size() - 1, values[-1], plot, top, count))
	if points.size() == 1:
		draw_circle(points[0], 2.0, line.color)
	else:
		draw_polyline(points, line.color, 1.5, true)


func _point(sample: int, value: int, plot: Rect2, top: float, count: int) -> Vector2:
	return Vector2(
		plot.position.x + plot.size.x * sample / maxf(count - 1, 1),
		plot.end.y - plot.size.y * clampf(value / top, 0.0, 1.0))


func _max_value() -> int:
	var best := 0
	for line in series:
		for v in line.values:
			best = maxi(best, v)
	return best


## Rounds up to 1, 2 or 5 times a power of ten, so axis labels stay tidy.
func _nice_ceiling(value: int) -> float:
	if value <= 4:
		return 4.0
	var magnitude := pow(10.0, floor(log(value) / log(10.0)))
	for m in [1.0, 2.0, 4.0, 5.0, 10.0]:
		if value <= m * magnitude:
			return m * magnitude
	return 10.0 * magnitude


## Wraps the legend entries along the bottom. Returns {rows, items: [{index, pos}]}.
func _legend_layout(font: Font) -> Dictionary:
	var rows_of: Array[int] = []
	var xs: Array[float] = []
	var x := 8.0
	var row := 0
	for i in series.size():
		var width := font.get_string_size(series[i].name, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE).x + 24.0
		if x + width > size.x and x > 8.0:
			x = 8.0
			row += 1
		rows_of.append(row)
		xs.append(x)
		x += width
	var rows := row + 1 if not series.is_empty() else 0
	var items: Array[Dictionary] = []
	for i in series.size():
		items.append({"index": i, "pos": Vector2(xs[i], size.y - 4.0 - (rows - 1 - rows_of[i]) * LEGEND_ROW)})
	return {"rows": rows, "items": items}
