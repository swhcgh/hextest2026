class_name DisasterView
extends Node2D
## Draws a badge with an animated icon over the epicenter of each disaster:
## shock rings and a crack for an earthquake, waves for a flood, a flickering
## flame for a wildfire, a sun for a drought. It pops in, holds for a few
## real seconds, then drifts up and fades. A drought's badge stays for as long
## as the drought lasts. Redraws every frame while any badge is up, so it keeps
## moving whatever the game speed. Hovering a badge lights up and outlines the
## area that disaster affected.

const ONE_OFF_SECONDS := 6.0
const FADE_SECONDS := 1.5
const POP_SECONDS := 0.35
const BADGE_RADIUS := 15.0
const LIFT := 24.0  # how far above the epicenter the badge floats, in screen pixels

var events: WorldEvents
var map: VoronoiMap

## Fires when the mouse starts or stops being over a badge.
signal hover_changed(over_badge: bool)

var _hovered := {}  # the active event whose badge is under the mouse, or empty
var _flashes: Array[Dictionary] = []  # {entry (an active event), born (seconds)}
var _time := 0.0


func clear() -> void:
	_flashes.clear()


## Starts a badge for an event just added to WorldEvents.active.
func add_flash(entry: Dictionary) -> void:
	_flashes.append({"entry": entry, "born": _time})


func _process(delta: float) -> void:
	_time += delta
	for i in range(_flashes.size() - 1, -1, -1):
		var f := _flashes[i]
		if _alpha(f) <= 0.0:
			_flashes.remove_at(i)
	_update_hover()
	if visible and not _flashes.is_empty():
		queue_redraw()


func _update_hover() -> void:
	var was_hovered := not _hovered.is_empty()
	_hovered = {}
	if visible and not _flashes.is_empty() and get_viewport().gui_get_hovered_control() == null:
		var zoom := get_canvas_transform().get_scale().x
		var mouse := get_global_mouse_position()
		var best := (BADGE_RADIUS + 3.0) / zoom
		for f in _flashes:
			var d := mouse.distance_to(map.cells[f.entry.center].site + _badge_offset(f) / zoom)
			if d <= best:
				best = d
				_hovered = f.entry
	if was_hovered != not _hovered.is_empty():
		hover_changed.emit(not _hovered.is_empty())


## Where the badge floats relative to the epicenter, in screen pixels.
func _badge_offset(f: Dictionary) -> Vector2:
	var rise := 0.0
	var age: float = _time - f.born
	if f.entry.kind != &"drought" and age > ONE_OFF_SECONDS - FADE_SECONDS:
		rise = (age - (ONE_OFF_SECONDS - FADE_SECONDS)) * 10.0  # drifts up as it fades
	return Vector2(0.0, -LIFT - rise + sin(_time * 3.0) * 1.5)


## 1 while a badge is up, ramping to 0 as it goes away.
func _alpha(f: Dictionary) -> float:
	var entry: Dictionary = f.entry
	if entry.kind == &"drought":
		return events.fade(entry) if events.active.has(entry) else 0.0
	var left: float = ONE_OFF_SECONDS - (_time - f.born)
	return clampf(left / FADE_SECONDS, 0.0, 1.0)


func _draw() -> void:
	if events == null:
		return
	var zoom := get_canvas_transform().get_scale().x
	var font := ThemeDB.fallback_font
	if not _hovered.is_empty():
		_draw_area(_hovered)
	for f in _flashes:
		var entry: Dictionary = f.entry
		var kind: StringName = entry.kind
		var color: Color = WorldEvents.KINDS[kind].color
		color.a = 1.0
		var age: float = _time - f.born
		var alpha := _alpha(f)
		var site: Vector2 = map.cells[entry.center].site

		# Everything below is drawn in screen pixels, whatever the map zoom.
		draw_set_transform(site, 0.0, Vector2.ONE / zoom)
		_draw_waves(kind, color, age, alpha)

		var center := _badge_offset(f)
		var pop := _pop(age)
		draw_set_transform(site + center / zoom, 0.0, Vector2.ONE * pop / zoom)
		draw_circle(Vector2.ZERO, BADGE_RADIUS + 2.0, Color(0, 0, 0, 0.85 * alpha))
		draw_circle(Vector2.ZERO, BADGE_RADIUS, Color(0.1, 0.1, 0.12, 0.92 * alpha))
		draw_arc(Vector2.ZERO, BADGE_RADIUS - 1.0, 0.0, TAU, 32, Color(color, alpha), 2.0)
		_draw_icon(kind, color, alpha)

		# The name, for the first moments of a one-off or the start of a drought.
		if age < ONE_OFF_SECONDS * 0.7 or kind != &"drought":
			draw_set_transform(site + center / zoom, 0.0, Vector2.ONE / zoom)
			var label: String = WorldEvents.KINDS[kind].label
			var width := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, 11).x
			var at := Vector2(-width * 0.5, BADGE_RADIUS + 14.0)
			draw_string_outline(font, at, label, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, 3, Color(0, 0, 0, alpha))
			draw_string(font, at, label, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color(1, 1, 1, alpha))
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


## Lights up the cells the event reached (stronger near the center) and
## outlines the whole area, in world coordinates.
func _draw_area(entry: Dictionary) -> void:
	var color: Color = WorldEvents.KINDS[entry.kind].color
	color.a = 1.0
	var pulse := 0.85 + 0.15 * sin(_time * 6.0)
	var cells: Dictionary = entry.cells
	for i: int in cells:
		var poly: PackedVector2Array = map.cells[i].polygon
		if map.cells[i].is_land and poly.size() >= 3:
			draw_colored_polygon(poly, Color(color, (0.3 + 0.3 * cells[i]) * pulse))
	var outline := _outline(entry)
	draw_multiline(outline, Color(0, 0, 0, 0.9), 5.0)
	draw_multiline(outline, Color(1, 1, 1, 0.95 * pulse), 2.5)


## Border segments (point pairs) of the land the event covers, worked out once.
## An edge counts if the cell across it is outside the area or is water.
func _outline(entry: Dictionary) -> PackedVector2Array:
	if entry.has("outline"):
		return entry.outline
	var segments := PackedVector2Array()
	var cells: Dictionary = entry.cells
	for i: int in cells:
		var cell := map.cells[i]
		if not cell.is_land:
			continue
		var poly: PackedVector2Array = cell.polygon
		for k in poly.size():
			var a := poly[k]
			var b := poly[(k + 1) % poly.size()]
			if a.is_equal_approx(b):
				continue
			# The neighbor across an edge is the one whose site is nearest its midpoint.
			var mid := (a + b) * 0.5
			var across := -1
			var across_dist := mid.distance_to(cell.site) + 1.0
			for nb: int in cell.neighbors:
				var d := mid.distance_to(map.cells[nb].site)
				if d < across_dist:
					across_dist = d
					across = nb
			if across >= 0 and cells.has(across) and map.cells[across].is_land:
				continue
			segments.append(a)
			segments.append(b)
	entry["outline"] = segments
	return segments


## Overshoots a little as the badge appears: 0 -> 1.15 -> 1.
func _pop(age: float) -> float:
	if age >= POP_SECONDS:
		return 1.0
	var t := age / POP_SECONDS
	return sin(t * PI * 0.5) * 1.15 if t < 0.7 else lerpf(1.15, 1.0, (t - 0.7) / 0.3)


## Rings or ripples spreading from the epicenter itself (screen pixels).
func _draw_waves(kind: StringName, color: Color, age: float, alpha: float) -> void:
	if kind == &"drought":
		return
	var rings := 3 if kind == &"earthquake" else 2
	for k in rings:
		var t := fmod(age * 0.7 + k / float(rings), 1.0)
		var wave_alpha := (1.0 - t) * 0.8 * alpha
		if age * 0.7 > 3.0:
			wave_alpha *= 0.0  # a few pulses, then calm
		draw_arc(Vector2.ZERO, 6.0 + t * 38.0, 0.0, TAU, 32, Color(color, wave_alpha), 2.5 - t * 1.5)
	draw_circle(Vector2.ZERO, 3.5, Color.BLACK)
	draw_circle(Vector2.ZERO, 2.2, Color(color, alpha))


## The glyph inside the badge, about 9px from its center (badge-local pixels).
func _draw_icon(kind: StringName, color: Color, alpha: float) -> void:
	var white := Color(1, 1, 1, alpha)
	var tint := Color(color, alpha)
	match kind:
		&"earthquake":  # a crack through the ground
			var crack := PackedVector2Array([Vector2(-1, -10), Vector2(3, -4), Vector2(-3, 0), Vector2(3, 4), Vector2(-1, 10)])
			var shake := Vector2(sin(_time * 40.0) * 0.8, 0.0)
			for i in crack.size():
				crack[i] += shake
			draw_polyline(crack, Color(0, 0, 0, alpha), 4.5)
			draw_polyline(crack, white, 2.0)
			draw_line(Vector2(-9, 9), Vector2(9, 9), tint, 2.0)
		&"flood":  # two rows of waves
			for row in [-4.0, 3.0]:
				var wave := PackedVector2Array()
				for i in 13:
					var x := -9.0 + i * 1.5
					wave.append(Vector2(x, row + sin(x * 0.9 + _time * 5.0) * 1.8))
				draw_polyline(wave, white if row < 0.0 else tint, 2.0)
		&"wildfire":  # a flickering flame, with a bright core
			var flicker := 1.0 + sin(_time * 14.0) * 0.07
			var flame := PackedVector2Array([Vector2(1, -11), Vector2(6, -2), Vector2(7, 4), Vector2(3, 9), Vector2(-3, 9), Vector2(-7, 4), Vector2(-5, -3), Vector2(-2, -1), Vector2(-1, -6)])
			for i in flame.size():
				flame[i] = Vector2(flame[i].x, flame[i].y * flicker)
			draw_colored_polygon(flame, tint)
			var core := PackedVector2Array([Vector2(0, -2), Vector2(3, 3), Vector2(2, 7), Vector2(-2, 7), Vector2(-3, 3)])
			draw_colored_polygon(core, Color(1.0, 0.9, 0.35, alpha))
		_:  # drought: a sun
			draw_circle(Vector2.ZERO, 4.5, tint)
			for k in 8:
				var dir := Vector2.from_angle(k * TAU / 8.0 + _time * 0.6)
				draw_line(dir * 6.5, dir * 10.0, tint, 2.0)
