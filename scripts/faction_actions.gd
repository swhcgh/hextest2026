class_name FactionActions
extends RefCounted
## Things factions do as world days pass. Call setup() for a new world, then
## on_day() once per world day; `changed` fires when anything on the map did.
##
## Each action costs goods, paid from the stock of the faction's settlements
## (see EXPAND_COST / FOUND_COST). A faction that can't afford an action tries
## again the next day, so its pace is set by its income as much as its timers.
##
## Each faction acts on its own timers:
##  - expand: claims an unclaimed land cell next to its territory, preferring
##    good settling ground close to its settlements (until it hits the size cap)
##  - found a town: settles a free spot in its territory, far enough from other
##    settlements, and builds a road to its capital

signal changed
## One line of text per action, for the event log.
signal action_taken(text: String)

const EXPAND_DAYS := Vector2i(5, 10)
const FOUND_DAYS := Vector2i(8, 16)
## Base expansion cost; it grows with territory: x (1 + cells / COST_GROWTH_CELLS).
const EXPAND_COST := {&"grain": 6, &"wood": 3, &"gold": 2}
const COST_GROWTH_CELLS := 10.0
## A faction can hold at most this many cells per settlement, so growing
## further means founding towns.
const MAX_CELLS_PER_SETTLEMENT := 5
const FOUND_COST := {&"wood": 10, &"grain": 8, &"gold": 12}
const TOWN_SPACING_CELLS := 1.6  # min distance to any settlement
const LOCATION_SPACING_CELLS := 1.2  # min distance to any mine, cave, etc.
const TERRITORY_PER_SETTLEMENT := 4  # at most one settlement per this many cells

enum Result { DONE, NOTHING_TO_DO, TOO_POOR }

var _civ: Civilization
var _map: VoronoiMap
var _roads: RoadNetwork
var _locations: Array[Dictionary]
var _rng := RandomNumberGenerator.new()
var _max_cells := 0
var _cell_size := 1.0
var _expand_timer: Array[int] = []
var _found_timer: Array[int] = []


func setup(civ: Civilization, map: VoronoiMap, roads: RoadNetwork, locations: Array[Dictionary], map_seed: int) -> void:
	_civ = civ
	_map = map
	_roads = roads
	_locations = locations
	_rng.seed = map_seed + 23
	_cell_size = civ.cell_size()

	var land_count := 0
	for c in map.cells:
		if c.is_land:
			land_count += 1
	_max_cells = maxi(int(land_count * Civilization.MAX_FACTION_SHARE), Civilization.MIN_FACTION_CELLS)

	_expand_timer.clear()
	_found_timer.clear()
	for f in civ.factions.size():
		_expand_timer.append(_rng.randi_range(EXPAND_DAYS.x, EXPAND_DAYS.y))
		_found_timer.append(_rng.randi_range(FOUND_DAYS.x, FOUND_DAYS.y))


func on_day() -> void:
	var did_something := false
	for f in _civ.factions.size():
		_expand_timer[f] -= 1
		if _expand_timer[f] <= 0:
			var result := _expand(f)
			_expand_timer[f] = 1 if result == Result.TOO_POOR else _rng.randi_range(EXPAND_DAYS.x, EXPAND_DAYS.y)
			did_something = did_something or result == Result.DONE
		_found_timer[f] -= 1
		if _found_timer[f] <= 0:
			var result := _found_town(f)
			_found_timer[f] = 1 if result == Result.TOO_POOR else _rng.randi_range(FOUND_DAYS.x, FOUND_DAYS.y)
			did_something = did_something or result == Result.DONE
	if did_something:
		changed.emit()


## Claims the most attractive unclaimed cell bordering the faction.
func _expand(f: int) -> Result:
	var cells := _map.cells
	var own := 0
	var frontier: Dictionary[int, bool] = {}
	for i in cells.size():
		if _civ.cell_faction[i] != f:
			continue
		own += 1
		for nb: int in cells[i].neighbors:
			if cells[nb].is_land and _civ.cell_faction[nb] < 0:
				frontier[nb] = true
	if own >= _max_cells or frontier.is_empty():
		return Result.NOTHING_TO_DO
	if own >= _civ.factions[f].settlements.size() * MAX_CELLS_PER_SETTLEMENT:
		return Result.NOTHING_TO_DO

	var best := -1
	var best_score := -INF
	for i in frontier:
		var cell := cells[i]
		var nearest := INF
		for s: int in _civ.factions[f].settlements:
			nearest = minf(nearest, cell.site.distance_to(cells[_civ.settlements[s].cell].site))
		var score: float = Civilization.BIOME_SETTLE_SCORE.get(cell.biome, 0.1) \
				+ (0.3 if cell.river else 0.0) - nearest / (_cell_size * 6.0) + _rng.randf() * 0.3
		if score > best_score:
			best_score = score
			best = i

	var cost := _scaled_cost(EXPAND_COST, 1.0 + own / COST_GROWTH_CELLS)
	if not _can_afford(f, cost):
		return Result.TOO_POOR
	_pay(f, cost)

	var annexed := ""
	for s in _civ.settlements:
		if s.cell == best and s.faction < 0:
			annexed = s.name
	var near := _nearest_own_settlement(f, best)
	_civ.claim_cell(best, f)
	Production.assign_catchments(_map, _civ.settlements, _civ.cell_faction)
	var faction_name: String = _civ.factions[f].name
	if annexed != "":
		action_taken.emit("%s annexed %s" % [faction_name, annexed])
	else:
		action_taken.emit("%s expanded near %s" % [faction_name, near])
	for loc in _locations:
		if loc.cell == best:
			loc.faction = f
	return Result.DONE


## Founds a town on the best free spot in the faction's territory.
func _found_town(f: int) -> Result:
	var cells := _map.cells
	var own := 0
	for i in cells.size():
		if _civ.cell_faction[i] == f:
			own += 1
	if _civ.factions[f].settlements.size() >= own / TERRITORY_PER_SETTLEMENT:
		return Result.NOTHING_TO_DO

	var best := -1
	var best_score := 0.0
	for i in cells.size():
		if _civ.cell_faction[i] != f:
			continue
		var score := _civ.settle_score(i)
		if score <= best_score or not _is_free_spot(i):
			continue
		best_score = score
		best = i
	if best < 0:
		return Result.NOTHING_TO_DO
	if not _can_afford(f, FOUND_COST):
		return Result.TOO_POOR
	_pay(f, FOUND_COST)

	var index := _civ.add_settlement(best, f)
	Production.assign_catchments(_map, _civ.settlements, _civ.cell_faction)
	TownResources.generate_one(_map, _civ.settlements[index], _rng)
	_roads.link(_civ.settlements[_civ.factions[f].capital].cell, best)
	action_taken.emit("%s founded %s" % [_civ.factions[f].name, _civ.settlements[index].name])
	return Result.DONE


func _scaled_cost(cost: Dictionary, factor: float) -> Dictionary:
	var scaled: Dictionary[StringName, int] = {}
	for r: StringName in cost:
		scaled[r] = ceili(cost[r] * factor)
	return scaled


## Whether the faction's settlements together hold the whole cost.
func _can_afford(f: int, cost: Dictionary) -> bool:
	for r: StringName in cost:
		var held := 0
		for s: int in _civ.factions[f].settlements:
			held += _civ.settlements[s].stock[r]
		if held < cost[r]:
			return false
	return true


## Takes the cost from the faction's settlements, richest first per good.
func _pay(f: int, cost: Dictionary) -> void:
	for r: StringName in cost:
		var owners: Array[int] = []
		owners.assign(_civ.factions[f].settlements)
		owners.sort_custom(func(a: int, b: int) -> bool: return _civ.settlements[a].stock[r] > _civ.settlements[b].stock[r])
		var left: int = cost[r]
		for s: int in owners:
			var stock: Dictionary = _civ.settlements[s].stock
			var take := mini(left, stock[r])
			stock[r] -= take
			left -= take
			if left <= 0:
				break


func _nearest_own_settlement(f: int, cell: int) -> String:
	var site: Vector2 = _map.cells[cell].site
	var best_name := ""
	var best_dist := INF
	for s: int in _civ.factions[f].settlements:
		var d := site.distance_to(_map.cells[_civ.settlements[s].cell].site)
		if d < best_dist:
			best_dist = d
			best_name = _civ.settlements[s].name
	return best_name


func _is_free_spot(cell: int) -> bool:
	var site: Vector2 = _map.cells[cell].site
	for s in _civ.settlements:
		if site.distance_to(_map.cells[s.cell].site) < _cell_size * TOWN_SPACING_CELLS:
			return false
	for loc in _locations:
		if site.distance_to(_map.cells[loc.cell].site) < _cell_size * LOCATION_SPACING_CELLS:
			return false
	return true
