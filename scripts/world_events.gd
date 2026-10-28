class_name WorldEvents
extends RefCounted
## Random events that strike an area of the map, hitting every settlement
## inside it (so one event can touch several cities, and several factions).
## Call setup() for a new world, then on_day() once per world day.
##
## So far these are natural disasters (see KINDS). An epicenter cell is picked
## and the hit falls off with distance in hexes from it. Earthquakes, floods
## and wildfires strike at once: they kill people, wipe out part of the stock,
## and can leave a town in ruins. Droughts last for weeks and cut the yield of
## farmed goods across their area. The seasons make some more likely: floods
## in spring, wildfires and droughts late in summer.
##
## To add an event, add an entry to KINDS and, if it needs more than the
## damage fields below, a case in _suits(), _exposure() or _weight().
##
## active: events whose area is still shown on the map. Each is
##   {kind, center (cell), cells (cell -> intensity 0..1), age, lifetime (days)}
## farm_mult: cell -> multiplier on grain and meat produced there (droughts)

signal changed
## A town was ruined, so settlement lists and territory need refreshing.
signal towns_lost
signal event_occurred(text: String)
## A disaster began; `entry` is its record in `active`.
signal started(entry: Dictionary)

const DAILY_CHANCE := 0.015  # per world day, for some disaster to strike
const FADE_DAYS := 8  # how long a sudden disaster stays marked on the map
const ATTEMPTS := 15  # epicenters tried per event before it fizzles out
const DAMAGE_JITTER := Vector2(0.7, 1.3)  # luck in how hard each settlement is hit

## radius: hexes from the epicenter the event reaches.
## pop_loss: share of a settlement's people lost at full intensity.
## stock_loss: share of each good lost at full intensity (other_loss for the rest).
## destroy: chance a town is ruined, at full intensity (cities are never ruined).
## yield_loss / duration: for lasting events, the cut to farmed goods and its length in days.
## color: how the area is tinted on the map.
const KINDS := {
	&"earthquake": {
		"label": "Earthquake", "radius": Vector2i(2, 4),
		"pop_loss": 0.30, "stock_loss": {&"ore": 0.2}, "other_loss": 0.4,
		"destroy": 0.5, "color": Color(0.55, 0.32, 0.12, 0.6),
	},
	&"flood": {
		"label": "Flood", "radius": Vector2i(2, 4),
		"pop_loss": 0.08, "stock_loss": {&"grain": 0.55, &"meat": 0.45, &"textiles": 0.4, &"ore": 0.05, &"gold": 0.05}, "other_loss": 0.2,
		"destroy": 0.12, "color": Color(0.15, 0.4, 1.0, 0.55),
	},
	&"wildfire": {
		"label": "Wildfire", "radius": Vector2i(2, 3),
		"pop_loss": 0.06, "stock_loss": {&"wood": 0.65, &"textiles": 0.45, &"grain": 0.3, &"ore": 0.0, &"gold": 0.0}, "other_loss": 0.15,
		"destroy": 0.2, "color": Color(1.0, 0.3, 0.05, 0.6),
	},
	&"drought": {
		"label": "Drought", "radius": Vector2i(4, 7),
		"yield_loss": 0.6, "duration": Vector2i(40, 90), "color": Color(0.9, 0.75, 0.2, 0.4),
	},
}

var active: Array[Dictionary] = []
var farm_mult: Dictionary[int, float] = {}

var _civ: Civilization
var _map: VoronoiMap
var _rng := RandomNumberGenerator.new()


func setup(civ: Civilization, map: VoronoiMap, map_seed: int) -> void:
	_civ = civ
	_map = map
	_rng.seed = map_seed + 29
	active.clear()
	farm_mult.clear()


func on_day(total_days: int) -> void:
	var was_active := not active.is_empty()
	var drought_ended := false
	for i in range(active.size() - 1, -1, -1):
		var e := active[i]
		e.age += 1
		if e.age >= e.lifetime:
			if e.kind == &"drought":
				drought_ended = true
				event_occurred.emit("The drought around %s has broken" % _nearest_name(e.center))
			active.remove_at(i)
	if drought_ended:
		_rebuild_farm_mult()

	if _rng.randf() < DAILY_CHANCE:
		_strike(_pick_kind(total_days))
		was_active = true
	if was_active:
		changed.emit()


## How visible an active event's tint is: 1 when fresh, 0 when it has passed.
## A drought stays at full strength until it begins to lift.
func fade(e: Dictionary) -> float:
	var left: float = 1.0 - float(e.age) / e.lifetime
	return minf(left / 0.2, 1.0) if e.kind == &"drought" else left


func _pick_kind(total_days: int) -> StringName:
	var phase := Upkeep.year_phase(total_days)
	var weights := {}
	var total := 0.0
	for kind: StringName in KINDS:
		weights[kind] = _weight(kind, phase)
		total += weights[kind]
	var roll := _rng.randf() * total
	for kind: StringName in weights:
		roll -= weights[kind]
		if roll <= 0.0:
			return kind
	return &"earthquake"


## Relative odds of a kind at a point in the year (0 = midwinter).
func _weight(kind: StringName, phase: float) -> float:
	match kind:
		&"flood":
			return 0.4 + 1.6 * _near(phase, 0.25)
		&"wildfire":
			return 0.3 + 1.7 * _near(phase, 0.6)
		&"drought":
			return 0.3 + 1.7 * _near(phase, 0.5)
	return 1.0


## 1 when `phase` is at `center` of the year, falling to 0 a fifth of a year away.
func _near(phase: float, center: float) -> float:
	var d := absf(phase - center)
	return maxf(1.0 - minf(d, 1.0 - d) / 0.2, 0.0)


## Whether a cell can be an epicenter of this kind.
func _suits(kind: StringName, cell: Dictionary) -> bool:
	if not cell.is_land:
		return false
	match kind:
		&"earthquake":
			return cell.elevation > 0.4
		&"flood":
			return cell.river or _is_coastal(cell)
		&"wildfire":
			return cell.has_forest
	return true


## How exposed a settlement's cell is to the kind, 0..1: floods favor rivers
## and coasts, fires favor woodland.
func _exposure(kind: StringName, cell: Dictionary) -> float:
	match kind:
		&"flood":
			return 1.0 if cell.river or _is_coastal(cell) else 0.5
		&"wildfire":
			if cell.has_forest:
				return 1.0
			for nb: int in cell.neighbors:
				if _map.cells[nb].has_forest:
					return 1.0
			return 0.4
	return 1.0


func _is_coastal(cell: Dictionary) -> bool:
	for nb: int in cell.neighbors:
		if not _map.cells[nb].is_land:
			return true
	return false


## Picks an epicenter that puts at least one settlement in harm's way and
## strikes. Does nothing if no such spot turns up.
func _strike(kind: StringName) -> void:
	var spec: Dictionary = KINDS[kind]
	var radius_range: Vector2i = spec.radius
	for attempt in ATTEMPTS:
		var center := _rng.randi() % _map.cells.size()
		if not _suits(kind, _map.cells[center]):
			continue
		var area := _area(center, _rng.randi_range(radius_range.x, radius_range.y), kind == &"wildfire")
		if _settlements_in(area).is_empty():
			continue
		if spec.has("duration"):
			_start_lasting(kind, spec, center, area)
		else:
			_hit(kind, spec, center, area)
		return


## Cells within `radius` hexes of `center` with their intensity: 1 at the
## center, less with distance. Fires only spread over land.
func _area(center: int, radius: int, land_only: bool) -> Dictionary[int, float]:
	var area: Dictionary[int, float] = {center: 1.0}
	var frontier: Array[int] = [center]
	for step in range(1, radius + 1):
		var next: Array[int] = []
		for u in frontier:
			for v: int in _map.cells[u].neighbors:
				if area.has(v) or (land_only and not _map.cells[v].is_land):
					continue
				area[v] = 1.0 - float(step) / (radius + 1)
				next.append(v)
		frontier = next
	return area


func _settlements_in(area: Dictionary[int, float]) -> Array[int]:
	var found: Array[int] = []
	for i in _civ.settlements.size():
		if not _civ.settlements[i].ruined and area.has(_civ.settlements[i].cell):
			found.append(i)
	return found


## A sudden disaster: hurts every settlement in the area by how close to the
## center and how exposed it is, then stays marked on the map for a while.
func _hit(kind: StringName, spec: Dictionary, center: int, area: Dictionary[int, float]) -> void:
	var hit := 0
	var dead := 0.0
	var worst := -1
	var worst_severity := -1.0
	var ruined: Array[int] = []
	for i in _settlements_in(area):
		var s := _civ.settlements[i]
		var severity := clampf(area[s.cell] * _exposure(kind, _map.cells[s.cell]) * _rng.randf_range(DAMAGE_JITTER.x, DAMAGE_JITTER.y), 0.0, 1.0)
		hit += 1
		if severity > worst_severity:
			worst_severity = severity
			worst = i

		var people: float = s.population
		s.population = maxf(people * (1.0 - spec.pop_loss * severity), 1.0)
		dead += people - s.population
		for r: StringName in s.stock:
			var share: float = spec.stock_loss.get(r, spec.other_loss) * severity
			s.stock[r] -= int(round(s.stock[r] * clampf(share, 0.0, 1.0)))
		if s.kind == &"town" and _rng.randf() < spec.destroy * severity * severity:
			ruined.append(i)

	event_occurred.emit("%s near %s hit %d %s, %d lives lost" % [
			spec.label, _civ.settlements[worst].name, hit, "settlement" if hit == 1 else "settlements", int(round(dead))])
	for i in ruined:
		event_occurred.emit("%s was destroyed" % _civ.settlements[i].name)
		_civ.ruin_settlement(i)
	if not ruined.is_empty():
		Production.assign_catchments(_map, _civ.settlements, _civ.cell_faction)
		towns_lost.emit()
	var entry := {"kind": kind, "center": center, "cells": area, "age": 0, "lifetime": FADE_DAYS}
	active.append(entry)
	started.emit(entry)


## A drought: no direct damage, but farmed goods yield less for weeks. Hunger
## does the rest through upkeep and the population ceiling.
func _start_lasting(kind: StringName, spec: Dictionary, center: int, area: Dictionary[int, float]) -> void:
	var days: Vector2i = spec.duration
	var entry := {"kind": kind, "center": center, "cells": area, "age": 0, "lifetime": _rng.randi_range(days.x, days.y)}
	active.append(entry)
	started.emit(entry)
	_rebuild_farm_mult()
	event_occurred.emit("Drought grips the land around %s" % _nearest_name(center))


func _rebuild_farm_mult() -> void:
	farm_mult.clear()
	for e in active:
		if e.kind != &"drought":
			continue
		var loss: float = KINDS[e.kind].yield_loss
		for i: int in e.cells:
			farm_mult[i] = minf(farm_mult.get(i, 1.0), 1.0 - loss * e.cells[i])


func _nearest_name(cell: int) -> String:
	var site: Vector2 = _map.cells[cell].site
	var best := ""
	var best_dist := INF
	for s in _civ.settlements:
		var d := site.distance_to(_map.cells[s.cell].site)
		if d < best_dist:
			best_dist = d
			best = s.name
	return best
