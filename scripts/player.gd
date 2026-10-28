class_name Player
extends RefCounted
## The player's unit: walks the map (along roads where there are any, at the
## same pace as traders) and buys and sells trade goods in settlements at the
## prices in Market. Carries up to CAPACITY goods; gold is counted apart and
## can be fractional.

const START_GOLD := 10.0
const CAPACITY := 10

var gold := START_GOLD
var cargo: Dictionary[StringName, int] = {}
var pos := Vector2.ZERO
## Cell the player stands on (the one it left last, while walking).
var cell := -1
var path: Array[int] = []  # cells of the current walk; empty when standing still
var segment := 0
var progress := 0.0  # 0..1 along the current segment

var _map: VoronoiMap
var _civ: Civilization
var _roads: RoadNetwork
var _traders: Traders


## Places the player on a random land cell on a landmass that has a
## settlement, with a little gold and nothing to carry.
func start(map: VoronoiMap, civ: Civilization, roads: RoadNetwork, traders: Traders, map_seed: int) -> void:
	_map = map
	_civ = civ
	_roads = roads
	_traders = traders
	gold = START_GOLD
	cargo.clear()
	path.clear()
	segment = 0
	progress = 0.0

	var inhabited: Dictionary[int, bool] = {}
	for s in civ.settlements:
		if not s.ruined:
			inhabited[roads.landmass[s.cell]] = true
	var options: Array[int] = []
	for i in map.cells.size():
		if map.cells[i].is_land and inhabited.has(roads.landmass[i]):
			options.append(i)
	var rng := RandomNumberGenerator.new()
	rng.seed = map_seed + 37
	cell = options[rng.randi() % options.size()] if not options.is_empty() else 0
	pos = map.cells[cell].site


func carried() -> int:
	var total := 0
	for r in cargo:
		total += cargo[r]
	return total


## The settlement the player is standing in, or -1 (also while walking).
func settlement_here() -> int:
	if not path.is_empty():
		return -1
	for i in _civ.settlements.size():
		if _civ.settlements[i].cell == cell and not _civ.settlements[i].ruined:
			return i
	return -1


func is_moving() -> bool:
	return not path.is_empty()


## Sets off for a land cell. Returns false if there's no way there. A walk in
## progress finishes its current step first.
func move_to(dest: int) -> bool:
	if not _map.cells[dest].is_land:
		return false
	var route: Array[int]
	if path.is_empty():
		route = _roads.find_path(cell, dest)
		if route.size() < 2:
			return false
		path = route
		segment = 0
		progress = 0.0
	else:
		var next: int = path[segment + 1]
		route = _roads.find_path(next, dest)
		if route.is_empty():
			return false
		var here: int = path[segment]
		path = [here] as Array[int]
		path.append_array(route)
	return true


## Walks forward by `delta_hours` of world time.
func update(delta_hours: float) -> void:
	var remaining := delta_hours
	while remaining > 0.0 and not path.is_empty():
		var hours := _traders.tile_hours(path[segment], path[segment + 1])
		var needed := (1.0 - progress) * hours
		if remaining < needed:
			progress += remaining / hours
			remaining = 0.0
		else:
			remaining -= needed
			progress = 0.0
			segment += 1
			cell = path[segment]
			if segment >= path.size() - 1:
				path.clear()
				segment = 0
	if path.is_empty():
		pos = _map.cells[cell].site
	else:
		pos = _map.cells[path[segment]].site.lerp(_map.cells[path[segment + 1]].site, progress)


func can_buy(settlement: int, r: StringName) -> bool:
	var s := _civ.settlements[settlement]
	return carried() < CAPACITY and s.stock[r] > 0 and gold >= Market.buy_price(s, r)


func can_sell(r: StringName) -> bool:
	return cargo.get(r, 0) > 0


## Buys one unit from the settlement.
func buy(settlement: int, r: StringName) -> bool:
	if not can_buy(settlement, r):
		return false
	var s := _civ.settlements[settlement]
	gold -= Market.buy_price(s, r)
	s.stock[r] -= 1
	cargo[r] = cargo.get(r, 0) + 1
	return true


## Sells one unit to the settlement.
func sell(settlement: int, r: StringName) -> bool:
	if not can_sell(r):
		return false
	var s := _civ.settlements[settlement]
	gold += Market.sell_price(s, r)
	s.stock[r] += 1
	cargo[r] -= 1
	return true
