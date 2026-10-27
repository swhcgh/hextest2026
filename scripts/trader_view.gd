class_name TraderView
extends Node2D
## Draws the traders and the popup for the one under the mouse. A separate
## node so it can redraw every frame as they move without redrawing the map.

const HOVER_RADIUS := 10.0

var traders: Traders
var settlements: Array[Dictionary]
## Set by the map when a settlement or location is already being hovered, so
## traders don't compete with their popups.
var suppressed := false

var _hovered := -1

## Fires when the mouse starts or stops being over a trader.
signal hover_changed(over_trader: bool)


func _process(_delta: float) -> void:
	if not visible:
		return
	var was_hovered := _hovered >= 0
	_hovered = -1
	if traders != null and not suppressed and get_viewport().gui_get_hovered_control() == null:
		var mouse := get_global_mouse_position()
		var best := HOVER_RADIUS
		for i in traders.traders.size():
			var d := mouse.distance_to(traders.traders[i].pos)
			if d <= best:
				best = d
				_hovered = i
	if (_hovered >= 0) != was_hovered:
		hover_changed.emit(_hovered >= 0)
	queue_redraw()


func _draw() -> void:
	if traders == null:
		return
	for i in traders.traders.size():
		var t := traders.traders[i]
		var highlighted := i == _hovered
		draw_circle(t.pos, 6.0 if highlighted else 4.5, Color.WHITE if highlighted else Color.BLACK)
		draw_circle(t.pos, 3.2, traders.color_of(t))
	if _hovered >= 0:
		_draw_popup(traders.traders[_hovered])


func _draw_popup(t: Dictionary) -> void:
	var status := "Resting in %s" % settlements[t.at].name if t.dest < 0 else ("Returning to %s" if t.returning else "Heading to %s") % settlements[t.dest].name
	var lines: Array[String] = ["Trader", traders.faction_name_of(t), status, "Trades made: %d" % t.trades]
	var cargo := TownResources.stock_lines(t.cargo)
	if cargo.is_empty():
		lines.append("No cargo")
	else:
		lines.append("Carrying:")
		lines.append_array(cargo)
	var view_end := get_canvas_transform().affine_inverse() * get_viewport_rect().size
	PopupBox.draw(self, lines, t.pos, view_end, traders.color_of(t), 1)
