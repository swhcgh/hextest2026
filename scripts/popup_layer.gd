class_name PopupLayer
extends CanvasLayer
## Hover popups, drawn in screen space on a layer above every panel. Each
## source (the map, the traders) sets or clears its own popup; anchors are
## screen positions.

var _popups: Dictionary[Object, Dictionary] = {}
var _canvas := Control.new()


func _ready() -> void:
	layer = 10
	_canvas.set_anchors_preset(Control.PRESET_FULL_RECT)
	_canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_canvas.draw.connect(_draw_popups)
	add_child(_canvas)


func set_popup(source: Object, lines: Array[String], anchor: Vector2, color: Color, swatch_line := -1) -> void:
	_popups[source] = {"lines": lines, "anchor": anchor, "color": color, "swatch": swatch_line}
	_canvas.queue_redraw()


func clear_popup(source: Object) -> void:
	if _popups.erase(source):
		_canvas.queue_redraw()


func _draw_popups() -> void:
	for p: Dictionary in _popups.values():
		PopupBox.draw(_canvas, p.lines, p.anchor, _canvas.size, p.color, p.swatch)
