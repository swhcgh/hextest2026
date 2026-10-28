class_name ArmyView
extends Node2D
## Draws armies in the field and the popup for the one under the mouse. Like
## TraderView, a separate node so it can redraw every frame as they march.

const HOVER_RADIUS := 11.0

var war: War
var civ: Civilization
var popups: PopupLayer
## Set by the map when a settlement or location is already being hovered.
var suppressed := false

var _hovered := -1

## Fires when the mouse starts or stops being over an army.
signal hover_changed(over_army: bool)


func _process(_delta: float) -> void:
	if not visible:
		popups.clear_popup(self)
		return
	var was_hovered := _hovered >= 0
	_hovered = -1
	if war != null and not suppressed and get_viewport().gui_get_hovered_control() == null:
		var mouse := get_global_mouse_position()
		var best := HOVER_RADIUS
		for i in war.armies.size():
			var d := mouse.distance_to(war.armies[i].pos)
			if d <= best:
				best = d
				_hovered = i
	if (_hovered >= 0) != was_hovered:
		hover_changed.emit(_hovered >= 0)
	queue_redraw()


func _draw() -> void:
	if war == null:
		return
	var font := ThemeDB.fallback_font
	for i in war.armies.size():
		var army := war.armies[i]
		var color: Color = civ.factions[army.faction].color
		var p: Vector2 = army.pos
		# Where it is headed, as a faint line along its path.
		var route := PackedVector2Array([p])
		for k in range(army.segment + 1, army.path.size()):
			route.append(war_site(army.path[k]))
		if route.size() >= 2:
			draw_polyline(route, Color(color, 0.5), 1.5)
		var r := 7.0 if i == _hovered else 6.0
		var shape := PackedVector2Array([p + Vector2(0, -r), p + Vector2(r, 0), p + Vector2(0, r), p + Vector2(-r, 0)])
		var outline := shape.duplicate()
		outline.append(shape[0])
		draw_colored_polygon(shape, color)
		draw_polyline(outline, Color.BLACK, 2.0)
		draw_string_outline(font, p + Vector2(8, 4), str(army.men), HORIZONTAL_ALIGNMENT_LEFT, -1, 10, 3, Color.BLACK)
		draw_string(font, p + Vector2(8, 4), str(army.men), HORIZONTAL_ALIGNMENT_LEFT, -1, 10, Color.WHITE)
	if _hovered >= 0 and _hovered < war.armies.size():
		_show_popup(war.armies[_hovered])
	else:
		popups.clear_popup(self)


func war_site(cell: int) -> Vector2:
	return war.cell_site(cell)


func _show_popup(army: Dictionary) -> void:
	var goal: Dictionary = army.goal
	var status := "Returning home" if army.phase == &"returning" else ("Marching to take land near %s" if goal.kind == &"capture" else "Marching to raid %s") % goal.name
	var lines: Array[String] = ["Army", civ.factions[army.faction].name, "At war with " + civ.factions[army.enemy].name, "Men: %d" % army.men, status]
	var loot := TownResources.stock_lines(army.plunder)
	if not loot.is_empty():
		lines.append("Loot:")
		lines.append_array(loot)
	popups.set_popup(self, lines, get_canvas_transform() * army.pos, civ.factions[army.faction].color, 1)
