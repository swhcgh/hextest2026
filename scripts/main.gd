extends Node2D
## Draws a generated VoronoiMap with its Civilization.
## Space: pause/resume time. Enter/R: new world. Up/Down: cell count.
## Hover a settlement for details, or a faction's region to highlight it.
## The left panel toggles each visual layer.
## Camera: drag with left/middle mouse or WASD/arrows to pan, mouse wheel or +/- to zoom.

const BIOME_COLORS := {
	&"deep_ocean": Color("1f3b63"),
	&"ocean": Color("2d5f93"),
	&"beach": Color("d9c98f"),
	&"desert": Color("d6b86a"),
	&"grassland": Color("8bb35a"),
	&"taiga": Color("5f8a78"),
	&"mountain": Color("8a8580"),
	&"snow": Color("f0f3f5"),
}
const FOREST_COLOR := Color("3d7a3a")
const TREE_COLOR := Color("1f4d28")
const ROAD_COLOR := Color("d9b77a")
const RIVER_COLOR := Color("4f90cc")
const LOCATION_COLORS := {
	&"mine": Color("e0a43a"),
	&"cave": Color("9b8f84"),
	&"dungeon": Color("b0453f"),
	&"ruins": Color("c9c4b0"),
	&"shrine": Color("5fc4c0"),
}
const NEUTRAL_COLOR := Color("9a9a9a")
const HOVER_RADIUS := 12.0

var map := VoronoiMap.new()
var civ := Civilization.new()
var roads := RoadNetwork.new()
var places := Locations.new()
var map_seed := 0
var cell_count := 400

## Toggleable visual layers: [key, label]. All start enabled.
const LAYERS := [
	[&"grid", "Cell outlines"],
	[&"forests", "Forests"],
	[&"rivers", "Rivers"],
	[&"roads", "Roads"],
	[&"faction_colors", "Faction colors"],
	[&"faction_borders", "Faction borders"],
	[&"highlight", "Hover highlight"],
	[&"hex_info", "Hex info popup"],
	[&"settlements", "Settlements"],
	[&"locations", "Locations"],
	[&"traders", "Traders"],
	[&"armies", "Armies"],
	[&"disasters", "Disasters"],
	[&"labels", "Settlement names"],
	[&"places_list", "Location list"],
	[&"legend", "Legend"],
	[&"log", "Event log"],
]
const PANEL_FONT_SIZE := 11
const MAX_LOG_LINES := 500
const LOG_SIZE := Vector2(380, 120)  # default size of the scrolling log
const PLACES_SIZE := Vector2(210, 170)  # default size of the location list
const HIGHLIGHT_COLOR := Color("ffe14a")
const RUIN_COLOR := Color("b08a68")
const ZOOM_MIN := 1.0
const ZOOM_MAX := 4.0
const ZOOM_STEP := 1.15
const DRAG_THRESHOLD := 4.0  # pixels of mouse travel before a panel drag starts
const GRIP_SIZE := 14.0
const PAN_SPEED := 600.0  # screen pixels per second

var layers: Dictionary[StringName, bool] = {}
var camera := Camera2D.new()
var overlay := Control.new()  # holds the screen-space panels, unaffected by the camera
var legend_panel := PanelContainer.new()
var clock := WorldClock.new()
var log_panel := PanelContainer.new()
var log_list: VBoxContainer
var log_scroll: ScrollContainer
var places_panel := PanelContainer.new()
var places_list: VBoxContainer
var list_hover := {}  # {name, cell} of the location list row under the mouse, or empty
var traders := Traders.new()
var actions := FactionActions.new()
var events := WorldEvents.new()
var war := War.new()
var army_view := ArmyView.new()
var trader_view := TraderView.new()
var popups := PopupLayer.new()  # hover popups, above every panel
var clock_panel := PanelContainer.new()
var layers_panel := PanelContainer.new()
var panel_homes: Dictionary[PanelContainer, Callable] = {}  # PanelContainer -> Callable returning its default position
var panel_offsets: Dictionary[PanelContainer, Vector2] = {}  # PanelContainer -> Vector2 the user dragged it away from home
var panel_grips: Dictionary[PanelContainer, Control] = {}  # PanelContainer -> its resize grip
var resize_mouse := Vector2.ZERO  # mouse position when a grip was pressed
var resize_size := Vector2.ZERO  # panel size when a grip was pressed
var drag_distance := 0.0  # mouse travel since the last press on a panel
var history := History.new()
var chart_panel := ChartPanel.new()
var season_view := SeasonView.new()
var date_label := Label.new()
var pause_button := Button.new()
var legend_list: VBoxContainer
var tree_points := PackedVector2Array()  # centers of tree glyphs
var hovered := -1  # settlement index under the mouse, or -1
var hovered_location := -1  # location index under the mouse, or -1
var hovered_cell := -1  # land hex under the mouse (for its production popup), or -1
var trader_hovered := false  # a trader's popup is showing instead
var army_hovered := false  # an army's popup is showing instead
var hovered_faction := -1  # faction whose region is under the mouse, or -1


func _ready() -> void:
	map.size = get_viewport_rect().size
	camera.position = map.size * 0.5
	add_child(camera)
	add_child(popups)
	trader_view.popups = popups
	trader_view.traders = traders
	trader_view.hover_changed.connect(func(over: bool) -> void:
		trader_hovered = over
		queue_redraw())
	trader_view.settlements = civ.settlements
	add_child(trader_view)
	army_view.war = war
	army_view.civ = civ
	army_view.popups = popups
	army_view.hover_changed.connect(func(over: bool) -> void:
		army_hovered = over
		queue_redraw())
	add_child(army_view)
	traders.at_war = war.at_war
	clock.hour_passed.connect(_on_hour_passed)
	clock.day_passed.connect(actions.on_day)
	clock.day_passed.connect(func() -> void:
		events.on_day(clock.total_days)
		war.on_day(clock.total_days))
	clock.day_passed.connect(func() -> void:
		Production.collect_daily(map, civ.settlements, clock.total_days, events.farm_mult)
		for line in Upkeep.apply_daily(civ.settlements, clock.total_days):
			_log(line)
		history.record(civ, clock.total_days)
		if chart_panel.visible:
			chart_panel.refresh())
	actions.changed.connect(_on_world_changed)
	actions.action_taken.connect(_log)
	events.event_occurred.connect(_log)
	war.event_occurred.connect(_log)
	war.status_changed.connect(_on_world_changed)
	events.towns_lost.connect(_on_world_changed)
	events.changed.connect(queue_redraw)
	_build_ui()
	_regenerate(randi())


func _build_ui() -> void:
	var ui := CanvasLayer.new()
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	ui.add_child(season_view)  # under the panels
	ui.add_child(overlay)
	add_child(ui)

	# Layer toggles, top-left.
	_make_draggable(layers_panel, func() -> Vector2: return Vector2(8, 8))
	var layer_list := _make_collapsible(layers_panel, "Layers")
	# Tight padding so the checkboxes pack closely.
	var tight := StyleBoxEmpty.new()
	tight.content_margin_left = 2
	tight.content_margin_right = 2
	tight.content_margin_top = 1
	tight.content_margin_bottom = 1
	for layer: Array in LAYERS:
		layers[layer[0]] = true
		var check := CheckBox.new()
		check.text = layer[1]
		check.button_pressed = true
		check.focus_mode = Control.FOCUS_NONE  # keep Space/Enter for "new world"
		_set_font(check)
		for state: String in ["normal", "pressed", "hover", "hover_pressed", "focus"]:
			check.add_theme_stylebox_override(state, tight)
		check.toggled.connect(_on_layer_toggled.bind(layer[0]))
		layer_list.add_child(check)
	overlay.add_child(layers_panel)
	_place_panel(layers_panel)

	_build_clock_panel()
	overlay.add_child(clock_panel)

	# Event log, bottom-left.
	_make_draggable(log_panel, func() -> Vector2: return Vector2(8.0, overlay.size.y - log_panel.size.y - 8.0))
	log_panel.resized.connect(_place_log)
	overlay.resized.connect(_place_log)
	log_list = _make_collapsible(log_panel, "Event log", LOG_SIZE)
	log_scroll = log_list.get_parent()
	overlay.add_child(log_panel)

	# Every settlement and location by name, bottom-right. Mousing over a row
	# marks that place on the map.
	_make_draggable(places_panel, func() -> Vector2: return overlay.size - places_panel.size - Vector2(8.0, 8.0))
	places_panel.resized.connect(_place_places)
	overlay.resized.connect(_place_places)
	places_list = _make_collapsible(places_panel, "Locations", PLACES_SIZE)
	overlay.add_child(places_panel)

	# Faction summary, top-right; re-pinned to the right edge whenever its size
	# (or the window's) changes.
	_make_draggable(legend_panel, func() -> Vector2: return Vector2(overlay.size.x - legend_panel.size.x - 8.0, 8.0))
	legend_panel.resized.connect(_place_legend)
	overlay.resized.connect(_place_legend)
	legend_list = _make_collapsible(legend_panel, "Factions")
	overlay.add_child(legend_panel)

	# Chart of resources over time, hidden until the Chart button is pressed.
	chart_panel.setup(history, civ)
	chart_panel.close_requested.connect(_toggle_chart)
	_make_draggable(chart_panel, func() -> Vector2: return (overlay.size - chart_panel.size) * 0.5)
	chart_panel.mouse_entered.connect(_clear_hover)
	chart_panel.visible = false
	panel_grips[chart_panel].visible = false
	overlay.add_child(chart_panel)

	# Grips must come after their panels in the tree, or the panels get the click.
	for grip: Control in panel_grips.values():
		overlay.move_child(grip, -1)


## Date, pause button and speed slider, bottom-center.
func _build_clock_panel() -> void:
	clock_panel.mouse_entered.connect(_clear_hover)
	_make_draggable(clock_panel, func() -> Vector2: return Vector2((overlay.size.x - clock_panel.size.x) * 0.5, overlay.size.y - clock_panel.size.y - 8.0))
	clock_panel.resized.connect(_place_clock)
	overlay.resized.connect(_place_clock)
	var box := VBoxContainer.new()
	clock_panel.add_child(box)

	_set_font(date_label, 2)
	date_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(date_label)

	var row := HBoxContainer.new()
	box.add_child(row)
	pause_button.focus_mode = Control.FOCUS_NONE  # Space is the pause hotkey
	_set_min_size(pause_button, Vector2(60, 0))
	_set_font(pause_button)
	pause_button.pressed.connect(func() -> void: _set_paused(not clock.paused))
	row.add_child(pause_button)

	var slider := HSlider.new()
	slider.min_value = 1
	slider.max_value = WorldClock.HOURS_PER_DAY * 7  # top speed: one week per second
	slider.step = 1
	slider.value = clock.hours_per_second
	slider.focus_mode = Control.FOCUS_NONE
	_set_min_size(slider, Vector2(140, 0))
	slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL  # takes up extra width
	slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(slider)

	var chart_button := Button.new()
	chart_button.text = "Chart"
	chart_button.focus_mode = Control.FOCUS_NONE
	_set_font(chart_button)
	chart_button.pressed.connect(_toggle_chart)
	row.add_child(chart_button)

	var speed_label := Label.new()
	_set_min_size(speed_label, Vector2(76, 0))
	_set_font(speed_label)
	row.add_child(speed_label)
	var update_speed := func(v: float) -> void:
		clock.hours_per_second = v
		if v >= WorldClock.HOURS_PER_DAY * 7:
			speed_label.text = "1 week/s"
		elif v >= WorldClock.HOURS_PER_DAY:
			speed_label.text = "%s days/s" % String.num(snappedf(v / WorldClock.HOURS_PER_DAY, 0.01)).trim_suffix(".0")
		else:
			speed_label.text = "%d h/s" % v
	slider.value_changed.connect(update_speed)
	update_speed.call(slider.value)

	clock.hour_passed.connect(_update_date_label)
	_update_date_label()
	_set_paused(false)
	_place_clock.call_deferred()


func _toggle_chart() -> void:
	chart_panel.visible = not chart_panel.visible
	if chart_panel.visible:
		chart_panel.refresh()
		_place_panel.call_deferred(chart_panel)


func _set_paused(paused: bool) -> void:
	clock.paused = paused
	pause_button.text = "Play" if paused else "Pause"


func _update_date_label() -> void:
	date_label.text = "%s  ·  %s" % [clock.date_text(), Upkeep.season_name(clock.total_days)]
	season_view.total_days = clock.total_days


func _place_clock() -> void:
	_place_panel(clock_panel)


func _place_log() -> void:
	_place_panel(log_panel)


## Appends a dated line to the event log, dropping the oldest beyond the limit.
func _log(text: String) -> void:
	var bar := log_scroll.get_v_scroll_bar()
	var following := bar.value + bar.page >= bar.max_value - 4.0  # don't yank a reader who scrolled up
	var label := Label.new()
	label.text = "%s  %s" % [clock.short_text(), text]
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_set_font(label)
	log_list.add_child(label)
	while log_list.get_child_count() > MAX_LOG_LINES:
		var oldest := log_list.get_child(0)
		log_list.remove_child(oldest)
		oldest.queue_free()
	_apply_font_delta(log_panel)
	if following:
		_scroll_log_to_end.call_deferred()


## Waits a frame for the new line to be laid out, then shows the newest lines.
func _scroll_log_to_end() -> void:
	await get_tree().process_frame
	log_scroll.scroll_vertical = int(log_scroll.get_v_scroll_bar().max_value)


func _place_places() -> void:
	_place_panel(places_panel)


## Rebuilds the location list: living settlements and locations, A to Z.
func _rebuild_places() -> void:
	list_hover = {}
	for row in places_list.get_children():
		places_list.remove_child(row)
		row.queue_free()
	var entries: Array[Dictionary] = []
	for s in civ.settlements:
		if not s.ruined:
			entries.append({"name": s.name, "kind": "Capital" if s.is_capital else String(s.kind).capitalize(), "cell": s.cell})
	for loc in places.locations:
		entries.append({"name": loc.name, "kind": String(loc.kind).capitalize(), "cell": loc.cell})
	entries.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.name.naturalnocasecmp_to(b.name) < 0)

	var idle := StyleBoxEmpty.new()
	var over := StyleBoxFlat.new()
	over.bg_color = Color(1, 1, 1, 0.18)
	for box: StyleBox in [idle, over]:
		box.content_margin_left = 3
		box.content_margin_right = 3
		box.content_margin_top = 1
		box.content_margin_bottom = 1
	for e in entries:
		var row := Button.new()
		row.text = "%s  ·  %s" % [e.name, e.kind]
		row.alignment = HORIZONTAL_ALIGNMENT_LEFT
		row.focus_mode = Control.FOCUS_NONE
		row.clip_text = true
		for state: String in ["normal", "pressed", "focus"]:
			row.add_theme_stylebox_override(state, idle)
		row.add_theme_stylebox_override("hover", over)
		row.add_theme_stylebox_override("hover_pressed", over)
		_set_font(row)
		row.mouse_entered.connect(func() -> void:
			list_hover = e
			queue_redraw())
		row.mouse_exited.connect(func() -> void:
			if list_hover == e:
				list_hover = {}
				queue_redraw())
		places_list.add_child(row)
	_apply_font_delta(places_panel)
	queue_redraw()


func _place_legend() -> void:
	_place_panel(legend_panel)


## Lets `panel` be dragged by its background. `home` gives the panel's default
## position; dragging stores an offset from it, so the panel keeps tracking its
## edge as it resizes.
func _make_draggable(panel: PanelContainer, home: Callable) -> void:
	panel_homes[panel] = home
	panel.gui_input.connect(_on_panel_gui_input.bind(panel))
	panel.resized.connect(_place_panel.bind(panel))  # keep it on screen as it grows

	# Resize grip in the bottom-right corner. It lives in the overlay, above the
	# panel, because the panel's own children would swallow clicks there.
	var grip := Control.new()
	grip.custom_minimum_size = Vector2.ONE * GRIP_SIZE
	grip.size = grip.custom_minimum_size
	grip.z_index = 1
	grip.mouse_default_cursor_shape = Control.CURSOR_FDIAGSIZE
	grip.mouse_entered.connect(_clear_hover)
	grip.gui_input.connect(_on_grip_gui_input.bind(panel))
	grip.draw.connect(func() -> void:
		var c := Color(1, 1, 1, 0.5)
		for i: float in [4.0, 8.0, 12.0]:
			grip.draw_line(Vector2(GRIP_SIZE - 1, GRIP_SIZE - i), Vector2(GRIP_SIZE - i, GRIP_SIZE - 1), c))
	# Hidden while the panel is hidden or collapsed: over a collapsed panel the
	# grip would cover its heading button and swallow the click that expands it.
	panel.visibility_changed.connect(func() -> void: grip.visible = panel.visible and not panel.get_meta(&"collapsed", false))
	panel_grips[panel] = grip
	overlay.add_child(grip)


func _on_panel_gui_input(event: InputEvent, panel: PanelContainer) -> void:
	var click := event as InputEventMouseButton
	var motion := event as InputEventMouseMotion
	if click and click.button_index == MOUSE_BUTTON_LEFT and click.pressed:
		drag_distance = 0.0
	elif motion and motion.button_mask & MOUSE_BUTTON_MASK_LEFT:
		drag_distance += motion.relative.length()
		if drag_distance >= DRAG_THRESHOLD:
			var home: Vector2 = panel_homes[panel].call()
			panel_offsets[panel] = _clamp_to_overlay(panel, panel.position + motion.relative) - home
			_place_panel(panel)


## Puts `panel` at its home position plus any drag offset, kept on screen.
func _place_panel(panel: PanelContainer) -> void:
	var home: Vector2 = panel_homes[panel].call()
	panel.position = _clamp_to_overlay(panel, home + panel_offsets.get(panel, Vector2.ZERO))
	panel_grips[panel].position = panel.position + panel.size - Vector2.ONE * GRIP_SIZE


## Resizes `panel` as its grip is dragged. It can't get smaller than its
## contents need, nor extend past the window. The top-left corner stays put.
func _on_grip_gui_input(event: InputEvent, panel: PanelContainer) -> void:
	var click := event as InputEventMouseButton
	var motion := event as InputEventMouseMotion
	if click and click.button_index == MOUSE_BUTTON_LEFT and click.pressed:
		resize_mouse = click.global_position
		resize_size = panel.size
	elif motion and motion.button_mask & MOUSE_BUTTON_MASK_LEFT:
		var corner := panel.position
		var wanted := resize_size + motion.global_position - resize_mouse
		wanted = wanted.min(overlay.size - corner)
		# Shrink the text a couple of points before the panel hits its minimum.
		for delta: int in [0, -1, -2, -3, -4, -5]:
			_set_font_delta(panel, delta)
			panel.custom_minimum_size = Vector2.ZERO  # so the contents' own minimum shows
			if panel.get_combined_minimum_size().x <= wanted.x and panel.get_combined_minimum_size().y <= wanted.y:
				break
		wanted = wanted.max(panel.get_combined_minimum_size())
		panel.custom_minimum_size = wanted
		panel.size = wanted
		panel_offsets[panel] = corner - (panel_homes[panel].call() as Vector2)  # undo the edge pinning
		_place_panel(panel)


func _clamp_to_overlay(panel: PanelContainer, pos: Vector2) -> Vector2:
	var max_pos := (overlay.size - panel.size).max(Vector2.ZERO)
	return pos.clamp(Vector2.ZERO, max_pos)


## Sets a panel text size and remembers it, so `_apply_font_delta` can shrink it.
func _set_font(control: Control, extra := 0) -> void:
	control.set_meta(&"font_extra", extra)
	control.add_theme_font_size_override("font_size", PANEL_FONT_SIZE + extra)


## Sets a minimum size that shrinks along with the panel's text.
func _set_min_size(control: Control, base: Vector2) -> void:
	control.set_meta(&"base_min_size", base)
	control.custom_minimum_size = base


## Text in `panel` is drawn `delta` points smaller (0 or negative).
func _set_font_delta(panel: PanelContainer, delta: int) -> void:
	panel.set_meta(&"font_delta", delta)
	_apply_font_delta(panel)


## Applies the panel's text shrink to its text, and the same proportion to
## its tagged minimum sizes and spacing.
func _apply_font_delta(panel: PanelContainer) -> void:
	var delta: int = panel.get_meta(&"font_delta", 0)
	var scale := float(PANEL_FONT_SIZE + delta) / PANEL_FONT_SIZE
	var pending: Array[Node] = [panel]
	while not pending.is_empty():
		var node: Node = pending.pop_back()
		pending.append_array(node.get_children())
		if node is Control and node.has_meta(&"base_min_size"):
			node.custom_minimum_size = (node.get_meta(&"base_min_size") as Vector2) * scale
		if node is Control and node.has_meta(&"base_separation"):
			node.add_theme_constant_override("separation", roundi(node.get_meta(&"base_separation") * scale))
		if node is Control and node.has_meta(&"font_extra"):
			node.add_theme_font_size_override("font_size", PANEL_FONT_SIZE + node.get_meta(&"font_extra") + delta)


## Fills `panel` with a heading button that shows/hides a list. Returns the
## list container to add rows to. With `scroll_size`, the list sits in a
## scroll window of that size (its parent) instead of growing the panel.
func _make_collapsible(panel: PanelContainer, title_text: String, scroll_size := Vector2.ZERO) -> VBoxContainer:
	panel.mouse_entered.connect(_clear_hover)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 0)
	panel.add_child(box)
	var title := Button.new()
	title.flat = true
	title.alignment = HORIZONTAL_ALIGNMENT_LEFT
	title.focus_mode = Control.FOCUS_NONE
	_set_font(title)
	box.add_child(title)
	title.gui_input.connect(_on_panel_gui_input.bind(panel))  # drag by the heading too
	var list := VBoxContainer.new()
	list.add_theme_constant_override("separation", 0)
	var body: Control = list
	if scroll_size != Vector2.ZERO:
		var scroll := ScrollContainer.new()
		scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
		_set_min_size(scroll, scroll_size)
		list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		scroll.add_child(list)
		body = scroll
	box.add_child(body)
	var set_open := func(open: bool) -> void:
		body.visible = open
		panel.set_meta(&"collapsed", not open)
		if panel_grips.has(panel):
			panel_grips[panel].visible = panel.visible and open
		panel.custom_minimum_size = Vector2.ZERO  # forget a user-set size
		_set_font_delta(panel, 0)
		title.text = ("▼ " if open else "▶ ") + title_text
		panel.reset_size.call_deferred()  # shrink the panel to fit
	title.pressed.connect(func() -> void:
		if drag_distance < DRAG_THRESHOLD:  # a drag, not a click
			set_open.call(not body.visible))
	set_open.call(true)
	return list


## Rebuilds the faction rows for the current world.
func _rebuild_legend() -> void:
	for row in legend_list.get_children():
		row.queue_free()
	for fi in civ.factions.size():
		var f := civ.factions[fi]
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 4)
		row.set_meta(&"base_separation", 4)
		var swatch := ColorRect.new()
		swatch.color = f.color
		_set_min_size(swatch, Vector2(10, 10))
		swatch.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(swatch)
		var label := Label.new()
		label.text = "%s (%d settlements)" % [f.name, f.settlements.size()]
		var enemy := war.enemy_of(fi)
		if enemy >= 0:
			label.text += " - at war with " + civ.factions[enemy].name
		_set_font(label)
		row.add_child(label)
		legend_list.add_child(row)
	_apply_font_delta(legend_panel)
	legend_panel.reset_size.call_deferred()
	_place_legend.call_deferred()


## A faction expanded or founded a town: territory, roads and counts changed.
func _on_world_changed() -> void:
	_rebuild_legend()
	_rebuild_places()
	queue_redraw()


## A hovered settlement's popup shows its stock, which traders change.
func _on_hour_passed() -> void:
	if hovered >= 0:
		queue_redraw()


func _on_layer_toggled(pressed: bool, key: StringName) -> void:
	layers[key] = pressed
	if not layers.highlight:
		hovered_faction = -1
	if not layers.settlements:
		hovered = -1
	if not layers.locations:
		hovered_location = -1
	if not layers.hex_info:
		hovered_cell = -1
	legend_panel.visible = layers.legend
	log_panel.visible = layers.log
	places_panel.visible = layers.places_list
	if not layers.places_list:
		list_hover = {}
	trader_view.visible = layers.traders
	army_view.visible = layers.armies
	_sync_trader_view()
	queue_redraw()


func _clear_hover() -> void:
	if hovered != -1 or hovered_location != -1 or hovered_faction != -1 or hovered_cell != -1:
		hovered = -1
		hovered_location = -1
		hovered_faction = -1
		hovered_cell = -1
		queue_redraw()
	_sync_trader_view()


## Traders defer to a hovered settlement or location.
func _sync_trader_view() -> void:
	trader_view.suppressed = hovered >= 0 or hovered_location >= 0
	army_view.suppressed = hovered >= 0 or hovered_location >= 0


func _regenerate(new_seed: int) -> void:
	map_seed = new_seed
	hovered = -1
	hovered_location = -1
	_sync_trader_view()
	hovered_faction = -1
	hovered_cell = -1
	map.generate(map_seed, cell_count)
	civ.generate(map, map_seed)
	roads.generate(map, civ.settlements, map_seed)
	places.generate(map, civ, map_seed)
	Production.assign_catchments(map, civ.settlements, civ.cell_faction)
	TownResources.generate(map, civ.settlements, map_seed)
	traders.spawn(map, civ.settlements, civ.factions, roads, map_seed)
	actions.setup(civ, map, roads, places.locations, map_seed)
	events.setup(civ, map, map_seed)
	war.setup(civ, map, roads, places.locations, map_seed)
	for line in log_list.get_children():
		log_list.remove_child(line)
		line.queue_free()
	_rebuild_legend()
	_rebuild_places()
	clock.reset()
	history.reset()
	history.record(civ, 0)
	chart_panel.update_scopes()
	_update_date_label()
	_scatter_trees()
	get_window().title = "Hex Test 2026 - seed %d, %d cells" % [map_seed, cell_count]
	queue_redraw()


## Scatters a few tree glyphs around the site of each forest cell.
func _scatter_trees() -> void:
	tree_points.clear()
	var rng := RandomNumberGenerator.new()
	rng.seed = map_seed
	var reach := sqrt(map.size.x * map.size.y / map.cells.size()) * 0.3
	for cell in map.cells:
		if not cell.has_forest:
			continue
		for t in 5 if cell.dense_forest else 3:
			var offset := Vector2.from_angle(rng.randf() * TAU) * rng.randf() * reach
			tree_points.append(cell.site + offset)


func _process(delta: float) -> void:
	clock.advance(delta)
	traders.update(clock.elapsed_hours)
	war.update(clock.elapsed_hours)
	var dir := Vector2(
		Input.get_axis(&"ui_left", &"ui_right") + float(Input.is_key_pressed(KEY_D)) - float(Input.is_key_pressed(KEY_A)),
		float(Input.is_key_pressed(KEY_S)) - float(Input.is_key_pressed(KEY_W)))
	if dir != Vector2.ZERO:
		camera.position += dir.limit_length(1.0) * PAN_SPEED * delta / camera.zoom.x
		_clamp_camera()
		_update_hover()


func _unhandled_input(event: InputEvent) -> void:
	var motion := event as InputEventMouseMotion
	var click := event as InputEventMouseButton
	if motion:
		if Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT) or Input.is_mouse_button_pressed(MOUSE_BUTTON_MIDDLE):
			camera.position -= motion.relative / camera.zoom.x
			_clamp_camera()
		_update_hover()
	elif click and click.pressed:
		if click.button_index == MOUSE_BUTTON_WHEEL_UP:
			_zoom_at(click.position, ZOOM_STEP)
		elif click.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_zoom_at(click.position, 1.0 / ZOOM_STEP)


## Zooms by `factor`, keeping the world point under `screen_pos` fixed.
func _zoom_at(screen_pos: Vector2, factor: float) -> void:
	var center := get_viewport_rect().size * 0.5
	var old_zoom := camera.zoom.x
	var new_zoom := clampf(old_zoom * factor, ZOOM_MIN, ZOOM_MAX)
	var world := camera.position + (screen_pos - center) / old_zoom
	camera.zoom = Vector2.ONE * new_zoom
	camera.position = world - (screen_pos - center) / new_zoom
	_clamp_camera()
	_update_hover()
	queue_redraw()


## Keeps the view inside the map (centered when the whole map fits).
func _clamp_camera() -> void:
	var half := get_viewport_rect().size * 0.5 / camera.zoom.x
	var pos := camera.position
	for axis in 2:
		if half[axis] * 2.0 >= map.size[axis]:
			pos[axis] = map.size[axis] * 0.5
		else:
			pos[axis] = clampf(pos[axis], half[axis], map.size[axis] - half[axis])
	camera.position = pos
	if hovered >= 0 or hovered_location >= 0 or hovered_cell >= 0:
		queue_redraw()


func _to_screen(world: Vector2) -> Vector2:
	return (world - camera.position) * camera.zoom.x + get_viewport_rect().size * 0.5


func _world_mouse() -> Vector2:
	var center := get_viewport_rect().size * 0.5
	return camera.position + (get_viewport().get_mouse_position() - center) / camera.zoom.x


func _update_hover() -> void:
	if get_viewport().gui_get_hovered_control() != null:
		_clear_hover()
		return
	var pos := _world_mouse()
	var h := _settlement_at(pos) if layers.settlements else -1
	var l := _location_at(pos) if layers.locations and h < 0 else -1
	var cell := _cell_at(pos)
	var r: int = civ.cell_faction[cell] if layers.highlight and cell >= 0 else -1
	var hc := cell if layers.hex_info and cell >= 0 and map.cells[cell].is_land else -1
	if h != hovered or l != hovered_location or r != hovered_faction or hc != hovered_cell:
		hovered = h
		hovered_location = l
		hovered_faction = r
		hovered_cell = hc
		queue_redraw()
	_sync_trader_view()


func _settlement_at(pos: Vector2) -> int:
	var best := -1
	var best_dist := HOVER_RADIUS
	for i in civ.settlements.size():
		if civ.settlements[i].ruined:
			continue
		var d := pos.distance_to(map.cells[civ.settlements[i].cell].site)
		if d <= best_dist:
			best_dist = d
			best = i
	return best


func _location_at(pos: Vector2) -> int:
	var best := -1
	var best_dist := HOVER_RADIUS
	for i in places.locations.size():
		var d := pos.distance_to(map.cells[places.locations[i].cell].site)
		if d <= best_dist:
			best_dist = d
			best = i
	return best


## A Voronoi cell contains the points nearest its site, so the closest site
## identifies the cell under the mouse.
func _cell_at(pos: Vector2) -> int:
	if map.cells.is_empty():
		return -1
	var best := 0
	var best_dist := INF
	for i in map.cells.size():
		var d := pos.distance_squared_to(map.cells[i].site)
		if d < best_dist:
			best_dist = d
			best = i
	return best


func _unhandled_key_input(event: InputEvent) -> void:
	var key := event as InputEventKey
	if key == null or not key.pressed or key.echo:
		return
	match key.keycode:
		KEY_SPACE:
			_set_paused(not clock.paused)
		KEY_ENTER, KEY_R:
			_regenerate(randi())
		KEY_EQUAL, KEY_KP_ADD:
			_zoom_at(get_viewport_rect().size * 0.5, ZOOM_STEP)
		KEY_MINUS, KEY_KP_SUBTRACT:
			_zoom_at(get_viewport_rect().size * 0.5, 1.0 / ZOOM_STEP)
		KEY_UP:
			cell_count = mini(cell_count + 100, 3000)
			_regenerate(map_seed)
		KEY_DOWN:
			cell_count = maxi(cell_count - 100, 50)
			_regenerate(map_seed)


func _draw() -> void:
	_draw_cells()
	if layers.forests:
		_draw_trees()
	if layers.rivers:
		_draw_rivers()
	if layers.roads:
		_draw_roads()
	if layers.disasters:
		_draw_disasters()
	if layers.faction_borders:
		for f in civ.factions:
			draw_multiline(f.border, f.color, 3.0)
	if hovered_faction >= 0:
		_draw_region_highlight(hovered_faction)
	if layers.settlements:
		_draw_settlements()
	if layers.locations:
		_draw_locations()
	popups.clear_popup(self)
	if not list_hover.is_empty():
		_draw_list_highlight()
	if hovered >= 0:
		var s := civ.settlements[hovered]
		_draw_popup(s.name, "Capital city" if s.is_capital else String(s.kind).capitalize(), s.cell, s.faction, "Independent", _settlement_lines(s))
	elif hovered_location >= 0:
		var loc := places.locations[hovered_location]
		var kind := String(loc.kind).capitalize()
		if loc.resource != &"":
			kind = "%s %s" % [String(loc.resource).capitalize(), loc.kind]
		_draw_popup(loc.name, kind, loc.cell, loc.faction, "Unclaimed", [] as Array[String])
	elif hovered_cell >= 0 and not trader_hovered and not army_hovered:
		_draw_hex_popup(hovered_cell)


## Rings the place under the mouse in the location list, with its name.
func _draw_list_highlight() -> void:
	var p: Vector2 = map.cells[list_hover.cell].site
	var font := ThemeDB.fallback_font
	draw_arc(p, 13.0, 0.0, TAU, 32, Color.BLACK, 5.0)
	draw_arc(p, 13.0, 0.0, TAU, 32, HIGHLIGHT_COLOR, 3.0)
	var label_pos := p + Vector2(16, -10)
	draw_string_outline(font, label_pos, list_hover.name, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, 4, Color.BLACK)
	draw_string(font, label_pos, list_hover.name, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, HIGHLIGHT_COLOR)


func _draw_cells() -> void:
	for i in map.cells.size():
		var cell := map.cells[i]
		var poly: PackedVector2Array = cell.polygon
		if poly.size() < 3:
			continue
		var color: Color = BIOME_COLORS[cell.biome]
		if layers.forests and cell.has_forest:
			color = color.lerp(FOREST_COLOR, 0.75 if cell.dense_forest else 0.55)
		if layers.faction_colors and cell.is_land:
			var f := civ.cell_faction[i]
			var tint: Color = civ.factions[f].color if f >= 0 else NEUTRAL_COLOR
			color = color.lerp(tint, 0.5)
		draw_colored_polygon(poly, color)
		if layers.grid:
			var outline := poly.duplicate()
			outline.append(poly[0])
			draw_polyline(outline, color.darkened(0.15), 1.0)


func _draw_trees() -> void:
	for p in tree_points:
		draw_colored_polygon(PackedVector2Array([p + Vector2(0, -4), p + Vector2(3, 2), p + Vector2(-3, 2)]), TREE_COLOR)


func _draw_rivers() -> void:
	for i in map.river_widths.size():
		draw_line(map.river_points[i * 2], map.river_points[i * 2 + 1], RIVER_COLOR, map.river_widths[i], true)


func _draw_roads() -> void:
	draw_multiline(roads.points, Color(0.2, 0.12, 0.05, 0.6), 3.5)
	draw_multiline(roads.points, ROAD_COLOR, 2.0)


## Tints the cells each recent disaster reached, strongest near its epicenter,
## fading as it passes.
func _draw_disasters() -> void:
	for e in events.active:
		var color: Color = WorldEvents.KINDS[e.kind].color
		var fade := events.fade(e)
		for i: int in e.cells:
			var poly: PackedVector2Array = map.cells[i].polygon
			if not map.cells[i].is_land or poly.size() < 3:
				continue
			draw_colored_polygon(poly, Color(color, color.a * e.cells[i] * fade))
		var ring := Color(color, fade)
		draw_arc(map.cells[e.center].site, 10.0, 0.0, TAU, 24, Color.BLACK, 4.0)
		draw_arc(map.cells[e.center].site, 10.0, 0.0, TAU, 24, ring, 2.0)


func _draw_region_highlight(faction: int) -> void:
	var glow := Color(1, 1, 1, 0.18)
	for i in map.cells.size():
		if civ.cell_faction[i] == faction:
			draw_colored_polygon(map.cells[i].polygon, glow)
	var outline: PackedVector2Array = civ.factions[faction].border
	draw_multiline(outline, Color(0, 0, 0, 0.85), 6.0)
	draw_multiline(outline, Color.WHITE, 3.0)


func _draw_settlements() -> void:
	var font := ThemeDB.fallback_font
	for s in civ.settlements:
		var p: Vector2 = map.cells[s.cell].site
		if s.ruined:  # a hollow ring the size of the old marker, crossed out, named
			var is_city: bool = s.kind == &"city"
			var r := 6.0 if is_city else 3.5
			var k := r * 0.6
			for pass_color: Array in [[Color.BLACK, 3.0], [RUIN_COLOR, 1.5]]:
				draw_arc(p, r, 0.0, TAU, 16, pass_color[0], pass_color[1])
				draw_line(p + Vector2(-k, -k), p + Vector2(k, k), pass_color[0], pass_color[1])
				draw_line(p + Vector2(-k, k), p + Vector2(k, -k), pass_color[0], pass_color[1])
			if layers.labels:
				var label_pos := p + (Vector2(9, 4) if is_city else Vector2(6, 3))
				var label_size := 13 if is_city else 9
				var label_text: String = "%s (ruins)" % s.name
				draw_string_outline(font, label_pos, label_text, HORIZONTAL_ALIGNMENT_LEFT, -1, label_size, 3, Color.BLACK)
				draw_string(font, label_pos, label_text, HORIZONTAL_ALIGNMENT_LEFT, -1, label_size, RUIN_COLOR)
			continue
		if s.kind == &"city":
			if s.is_capital:
				draw_circle(p, 9.0, Color.BLACK)
				draw_circle(p, 7.5, Color("ffd24a"))
			draw_circle(p, 6.0, Color.BLACK)
			draw_circle(p, 4.5, Color.WHITE)
			if layers.labels:
				var label_pos := p + Vector2(9, 4)
				draw_string_outline(font, label_pos, s.name, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, 4, Color.BLACK)
				draw_string(font, label_pos, s.name, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color.WHITE)
		else:
			draw_circle(p, 3.5, Color.BLACK)
			draw_circle(p, 2.5, Color("dddddd"))
			if layers.labels:
				var label_pos := p + Vector2(6, 3)
				draw_string_outline(font, label_pos, s.name, HORIZONTAL_ALIGNMENT_LEFT, -1, 9, 3, Color.BLACK)
				draw_string(font, label_pos, s.name, HORIZONTAL_ALIGNMENT_LEFT, -1, 9, Color("e6e6e6"))


func _draw_locations() -> void:
	var font := ThemeDB.fallback_font
	for loc in places.locations:
		var p: Vector2 = map.cells[loc.cell].site
		var r := 6.0
		var shape: PackedVector2Array
		match loc.kind:
			&"mine":  # diamond
				shape = PackedVector2Array([p + Vector2(0, -r - 1), p + Vector2(r + 1, 0), p + Vector2(0, r + 1), p + Vector2(-r - 1, 0)])
			&"cave":  # triangle
				shape = PackedVector2Array([p + Vector2(0, -r - 1), p + Vector2(r + 1, r), p + Vector2(-r - 1, r)])
			&"dungeon":  # square
				shape = PackedVector2Array([p + Vector2(-r, -r), p + Vector2(r, -r), p + Vector2(r, r), p + Vector2(-r, r)])
			&"ruins":  # hexagon
				shape = PackedVector2Array()
				for k in 6:
					shape.append(p + Vector2.from_angle(k * TAU / 6.0) * (r + 1))
			_:  # shrine: circle
				shape = PackedVector2Array()
				for k in 12:
					shape.append(p + Vector2.from_angle(k * TAU / 12.0) * r)
		var closed := shape.duplicate()
		closed.append(shape[0])
		draw_colored_polygon(shape, LOCATION_COLORS[loc.kind])
		draw_polyline(closed, Color.BLACK, 1.5)
		var letter: String = String(loc.kind)[0].to_upper()
		draw_string(font, p + Vector2(-4, 4), letter, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, Color.BLACK)


## Population and goods in stock, for a settlement popup.
func _settlement_lines(s: Dictionary) -> Array[String]:
	var lines: Array[String] = ["Population: %d" % int(s.population)]
	lines.append_array(TownResources.stock_lines(s.stock))
	lines.append("Labor:")
	lines.append_array(Labor.lines(s.labor))
	return lines


## Terrain, owner, collecting town and daily production of a hex.
func _draw_hex_popup(i: int) -> void:
	var cell := map.cells[i]
	var title := String(cell.biome).capitalize()
	if cell.has_forest:
		title += " forest"
	if cell.river:
		title += " (river)"
	var faction: int = civ.cell_faction[i]
	var owner_name := "Unclaimed"
	var color := NEUTRAL_COLOR
	if faction >= 0:
		owner_name = civ.factions[faction].name
		color = civ.factions[faction].color
	var lines: Array[String] = [title, owner_name]
	if cell.town >= 0:
		lines.append("Collected by %s (%d%%)" % [civ.settlements[cell.town].name, Production.yield_at(cell.town_steps) * 100.0])
	var produced := Production.lines(cell.production)
	if produced.is_empty():
		lines.append("Produces nothing")
	else:
		lines.append("Produces per day:")
		lines.append_array(produced)
	popups.set_popup(self, lines, _to_screen(cell.site), color, 1)


func _draw_popup(title: String, kind: String, cell: int, faction: int, no_faction_text: String, extra_lines: Array[String]) -> void:
	var faction_name := no_faction_text
	var faction_color := NEUTRAL_COLOR
	if faction >= 0:
		faction_name = civ.factions[faction].name
		faction_color = civ.factions[faction].color
	var lines: Array[String] = [title, kind, faction_name]
	lines.append_array(extra_lines)
	popups.set_popup(self, lines, _to_screen(map.cells[cell].site), faction_color, 2)
