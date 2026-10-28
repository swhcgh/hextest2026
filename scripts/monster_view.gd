class_name MonsterView
extends Node2D
## Draws monsters and the popup for the one under the mouse. A horde is a
## cluster of small creatures, a giant one large spiked figure.

const HOVER_RADIUS := 13.0
const COLOR := Color(0.55, 0.12, 0.12)
const HORDE_DOTS := [Vector2(-5, -3), Vector2(4, -5), Vector2(6, 2), Vector2(-2, 5), Vector2(-7, 3), Vector2(0, 0)]

var monsters: Monsters
var popups: PopupLayer
## Set by the map when a settlement or location is already being hovered.
var suppressed := false

var _hovered := -1

## Fires when the mouse starts or stops being over a monster.
signal hover_changed(over_monster: bool)


func _process(_delta: float) -> void:
	if not visible:
		popups.clear_popup(self)
		return
	var was_hovered := _hovered >= 0
	_hovered = -1
	if monsters != null and not suppressed and get_viewport().gui_get_hovered_control() == null:
		var mouse := get_global_mouse_position()
		var best := HOVER_RADIUS
		for i in monsters.monsters.size():
			var d := mouse.distance_to(monsters.monsters[i].pos)
			if d <= best:
				best = d
				_hovered = i
	if (_hovered >= 0) != was_hovered:
		hover_changed.emit(_hovered >= 0)
	queue_redraw()


func _draw() -> void:
	if monsters == null:
		return
	var font := ThemeDB.fallback_font
	for i in monsters.monsters.size():
		var m := monsters.monsters[i]
		var p: Vector2 = m.pos
		var grow := 1.2 if i == _hovered else 1.0
		if m.kind == &"horde":
			for d: Vector2 in HORDE_DOTS:
				draw_circle(p + d * grow, 3.2 * grow, Color.BLACK)
				draw_circle(p + d * grow, 2.2 * grow, COLOR)
		else:
			var spikes := PackedVector2Array()
			for k in 16:
				var r := (11.0 if k % 2 == 0 else 7.0) * grow
				spikes.append(p + Vector2.from_angle(TAU * k / 16.0 - PI / 2) * r)
			draw_colored_polygon(spikes, COLOR)
			var outline := spikes.duplicate()
			outline.append(spikes[0])
			draw_polyline(outline, Color.BLACK, 1.5)
			draw_circle(p + Vector2(-2.5, -1), 1.3, Color(1.0, 0.85, 0.2))
			draw_circle(p + Vector2(2.5, -1), 1.3, Color(1.0, 0.85, 0.2))
		var label := str(m.strength)
		draw_string_outline(font, p + Vector2(10, 14), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 10, 3, Color.BLACK)
		draw_string(font, p + Vector2(10, 14), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color(1.0, 0.6, 0.5))
	if _hovered >= 0 and _hovered < monsters.monsters.size():
		_show_popup(monsters.monsters[_hovered])
	else:
		popups.clear_popup(self)


func _show_popup(m: Dictionary) -> void:
	var target: String = monsters.target_name(m)
	var status := "Rampaging in " + target if m.phase == &"ravaging" else "Heading for " + target
	var lines: Array[String] = [m.name, "Monster horde" if m.kind == &"horde" else "Giant monster", "Strength: %d" % m.strength, status]
	popups.set_popup(self, lines, get_canvas_transform() * m.pos, COLOR, 1)
