class_name ChartPanel
extends PanelContainer
## Window with a line chart of stock over time. Pick a resource and whether to
## compare factions (their totals) or the towns of one faction. Call
## setup() once, update_scopes() when the world changes, and refresh() as new
## history comes in.

signal close_requested

const FONT_SIZE := 11

var chart := ChartView.new()

var _history: History
var _civ: Civilization
var _scope := OptionButton.new()
var _resource := OptionButton.new()


func setup(history: History, civ: Civilization) -> void:
	_history = history
	_civ = civ
	var box := VBoxContainer.new()
	add_child(box)

	var header := HBoxContainer.new()
	box.add_child(header)
	var title := Label.new()
	title.text = "Resources over time"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.add_theme_font_size_override("font_size", FONT_SIZE + 1)
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE  # so the panel can be dragged by it
	header.add_child(title)
	var close := Button.new()
	close.text = "✕"
	close.flat = true
	close.focus_mode = Control.FOCUS_NONE
	close.pressed.connect(func() -> void: close_requested.emit())
	header.add_child(close)

	var controls := HBoxContainer.new()
	box.add_child(controls)
	for r in TownResources.RESOURCES:
		_resource.add_item(String(r).capitalize())
	for option in [_scope, _resource]:
		option.focus_mode = Control.FOCUS_NONE
		option.add_theme_font_size_override("font_size", FONT_SIZE)
		option.get_popup().add_theme_font_size_override("font_size", FONT_SIZE)
		option.item_selected.connect(func(_i: int) -> void: refresh())
		controls.add_child(option)
	box.add_child(chart)
	update_scopes()


## Rebuilds the scope list (all factions, or one faction's towns) for the
## current world.
func update_scopes() -> void:
	var previous := _scope.selected
	_scope.clear()
	_scope.add_item("All factions")
	for f in _civ.factions:
		_scope.add_item("Towns: %s" % f.name)
	_scope.add_item("Towns: independent")
	_scope.select(previous if previous >= 0 and previous < _scope.item_count else 0)
	refresh()


func refresh() -> void:
	var resource := TownResources.RESOURCES[maxi(_resource.selected, 0)]
	var scope := maxi(_scope.selected, 0)
	chart.days = _history.days
	if scope == 0:
		chart.series = _history.faction_series(_civ, resource)
		chart.title = "%s: total stock per faction" % String(resource).capitalize()
	else:
		var faction := scope - 1 if scope <= _civ.factions.size() else -1
		chart.series = _history.town_series(_civ, faction, resource)
		chart.title = "%s: %s" % [String(resource).capitalize(), _scope.get_item_text(scope)]
	chart.queue_redraw()
