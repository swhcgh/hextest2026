class_name Traders
extends RefCounted
## Trading NPCs that run errands for their home settlement. A trader rests at
## home, loads goods the town has in excess (stock well above what its people
## use in a month), and picks a destination on the same landmass where it can
## swap them for goods home is short of. It looks at several nearby towns and
## goes to the one with the best deal for the distance. There it sells its
## cargo, buys what home lacks (never draining the seller below what the seller
## itself needs), then carries it back and unloads it at home.
##
## Travel is along roads where there are any: a tile a day on roads and much
## slower off road, depending on the terrain.
##
## Gold is a good like any other: traders sell surplus gold, and spare gold
## also goes along as money to buy what home lacks. A trade earns no bonus.
##
## A trader belongs to the faction that owns its home settlement.
##
## trader: home (settlement index), trades (completed so far),
##   at (settlement index, -1 while travelling), dest (settlement index or -1),
##   returning (heading home with its purchases), path (cells), segment,
##   progress (0..1 along the current segment), rest (hours left resting),
##   cargo (resource -> int), pos (world position)

const HOURS_PER_TILE := 24.0  # on a road
## Travel time off road, as a multiple of HOURS_PER_TILE, by terrain.
const OFFROAD_MULTIPLIER := {
	&"grassland": 1.5, &"beach": 1.8, &"desert": 2.2,
	&"taiga": 2.0, &"mountain": 3.5, &"snow": 4.0,
}
const FOREST_MULTIPLIER := 1.5
const DENSE_FOREST_MULTIPLIER := 1.8
const RIVER_MULTIPLIER := 1.4  # fording without a bridge
const REST_HOURS := 6.0
const TRADERS_PER_SETTLEMENT := 0.35
const MIN_TRADERS := 2
const NEAREST_CANDIDATES := 8  # destinations are judged among this many nearest
const GOODS_PER_TRIP := 3  # different goods loaded per trip
const CAPACITY := 12  # units carried
const TARGET_DAYS := 30.0  # a town wants this many days of its needs in store
const SURPLUS_RATIO := 1.3  # stock above target x this is excess to sell
const SHORT_RATIO := 0.8  # stock below target x this is a shortage
const SPARE_RATIO := 1.0  # a seller only parts with stock above target x this
const MIN_TARGET := 5.0
const DISTANCE_PENALTY := 0.15  # per cell of distance, on a destination's value
const MIN_DEAL := 3.0  # worth-the-trip threshold
const NEUTRAL_COLOR := Color("9a9a9a")

var traders: Array[Dictionary] = []
## Whether two factions (indices) are at war; set by the map. Traders won't
## deal with the enemy's towns.
var at_war := Callable()

var _map: VoronoiMap
var _settlements: Array[Dictionary]
var _factions: Array[Dictionary]
var _roads: RoadNetwork
var _rng := RandomNumberGenerator.new()
var _cell_size := 1.0


func spawn(map: VoronoiMap, settlements: Array[Dictionary], factions: Array[Dictionary], roads: RoadNetwork, map_seed: int) -> void:
	_map = map
	_settlements = settlements
	_factions = factions
	_roads = roads
	_rng.seed = map_seed + 19
	_cell_size = sqrt(map.size.x * map.size.y / maxi(map.cells.size(), 1))
	traders.clear()
	if settlements.is_empty():
		return

	var count := maxi(int(settlements.size() * TRADERS_PER_SETTLEMENT), MIN_TRADERS)
	for i in count:
		var home := _rng.randi() % settlements.size()
		var t := {
			"home": home,
			"trades": 0,
			"at": home,
			"dest": -1,
			"returning": false,
			"path": [] as Array[int],
			"segment": 0,
			"progress": 0.0,
			"rest": _rng.randf() * REST_HOURS,  # staggered departures
			"cargo": {},
			"pos": _site(home),
		}
		traders.append(t)


## Moves every trader forward by `delta_hours` of world time.
func update(delta_hours: float) -> void:
	for t in traders:
		var remaining := delta_hours
		while remaining > 0.0:
			if t.dest < 0:
				var used := minf(remaining, t.rest)
				t.rest -= used
				remaining -= used
				if t.rest > 0.0:
					break
				_depart(t)
				if t.dest < 0:
					t.rest = REST_HOURS * 4.0  # nowhere to go; try again later
			else:
				var segment_hours := _segment_hours(t)
				var needed: float = (1.0 - t.progress) * segment_hours
				if remaining < needed:
					t.progress += remaining / segment_hours
					remaining = 0.0
				else:
					remaining -= needed
					t.progress = 0.0
					t.segment += 1
					if t.segment >= t.path.size() - 1:
						_arrive(t)
		_update_pos(t)


func _depart(t: Dictionary) -> void:
	var home: int = t.home
	if _settlements[home].ruined:
		_rehome(t)
		return
	var from_cell: int = _settlements[home].cell
	var cargo := _plan_cargo(home)
	if cargo.is_empty():
		return  # nothing to spare
	var options: Array[int] = []
	for i in _settlements.size():
		if i != home and not _settlements[i].ruined and not _hostile(home, i) and _roads.landmass[_settlements[i].cell] == _roads.landmass[from_cell]:
			options.append(i)
	var here := _site(home)
	options.sort_custom(func(a: int, b: int) -> bool: return here.distance_squared_to(_site(a)) < here.distance_squared_to(_site(b)))
	if options.size() > NEAREST_CANDIDATES:
		options.resize(NEAREST_CANDIDATES)

	var dest := -1
	var best := MIN_DEAL
	for c in options:
		var value := _deal_value(home, c, cargo)
		value /= 1.0 + here.distance_to(_site(c)) / _cell_size * DISTANCE_PENALTY
		value *= _rng.randf_range(0.9, 1.1)  # not everyone agrees on the best deal
		if value > best:
			best = value
			dest = c
	if dest < 0:
		return
	var path := _roads.find_path(from_cell, _settlements[dest].cell)
	if path.size() < 2:
		return
	_take_cargo(t, home, cargo)
	_start(t, dest, path, false)


## A trader whose home fell to ruin moves in with the nearest living town on
## its landmass, or stays put if there is none.
func _rehome(t: Dictionary) -> void:
	var here := _site(t.home)
	var landmass: int = _roads.landmass[_settlements[t.home].cell]
	var best := -1
	var best_dist := INF
	for i in _settlements.size():
		if _settlements[i].ruined or _roads.landmass[_settlements[i].cell] != landmass:
			continue
		var d := here.distance_squared_to(_site(i))
		if d < best_dist:
			best_dist = d
			best = i
	if best >= 0:
		t.home = best
		t.at = best
	t.rest = REST_HOURS * 4.0


func _start(t: Dictionary, dest: int, path: Array[int], returning: bool) -> void:
	t.at = -1
	t.dest = dest
	t.returning = returning
	t.path = path
	t.segment = 0
	t.progress = 0.0


func _arrive(t: Dictionary) -> void:
	var stop: int = t.dest
	t.dest = -1
	t.path = [] as Array[int]
	if t.returning:
		t.at = stop
		t.returning = false
		t.rest = REST_HOURS
		var stock: Dictionary = _settlements[stop].stock
		for r: StringName in t.cargo:
			stock[r] += t.cargo[r]
		t.cargo = {}
		return

	# At the far town: sell the cargo, buy what home is short of, head back.
	t.at = stop
	if not _hostile(t.home, stop):  # war broke out on the way: turn back with the cargo
		_trade(t, stop)
		t.trades += 1
	var path := _roads.find_path(_settlements[stop].cell, _settlements[t.home].cell)
	if path.size() < 2:
		t.home = stop  # cut off from home; settle here instead
		t.rest = REST_HOURS
		var stock: Dictionary = _settlements[stop].stock
		for r: StringName in t.cargo:
			stock[r] += t.cargo[r]
		t.cargo = {}
		return
	_start(t, t.home, path, true)


func _hostile(a: int, b: int) -> bool:
	return at_war.is_valid() and at_war.call(_settlements[a].faction, _settlements[b].faction)


## How much of a good a town keeps in store: about TARGET_DAYS of its needs.
func _target(s: Dictionary, r: StringName) -> float:
	return maxf(Upkeep.daily_need(s, r) * TARGET_DAYS, MIN_TARGET)


func _surplus(s: Dictionary, r: StringName, ratio: float) -> int:
	return maxi(int(s.stock[r] - _target(s, r) * ratio), 0)


func _shortage(s: Dictionary, r: StringName) -> int:
	var target := _target(s, r)
	if s.stock[r] >= target * SHORT_RATIO:
		return 0
	return int(ceil(target - s.stock[r]))


## What a trader would load at `settlement`: the biggest excesses, up to capacity.
func _plan_cargo(settlement: int) -> Dictionary:
	var s := _settlements[settlement]
	var goods: Array[StringName] = []
	for r in TownResources.RESOURCES:
		if _surplus(s, r, SURPLUS_RATIO) > 0:
			goods.append(r)
	goods.sort_custom(func(a: StringName, b: StringName) -> bool: return _surplus(s, a, SURPLUS_RATIO) > _surplus(s, b, SURPLUS_RATIO))
	var cargo := {}
	var room := CAPACITY
	for r: StringName in goods.slice(0, GOODS_PER_TRIP):
		var amount := mini(_surplus(s, r, SURPLUS_RATIO), room)
		cargo[r] = amount
		room -= amount
		if room <= 0:
			break
	# Spare gold goes along as payment even when other goods crowd it out.
	var gold := mini(_surplus(s, &"gold", SURPLUS_RATIO) - cargo.get(&"gold", 0), room)
	if gold > 0:
		cargo[&"gold"] = cargo.get(&"gold", 0) + gold
	return cargo


func _take_cargo(t: Dictionary, settlement: int, cargo: Dictionary) -> void:
	var stock: Dictionary = _settlements[settlement].stock
	for r: StringName in cargo:
		stock[r] -= cargo[r]
		t.cargo[r] = t.cargo.get(r, 0) + cargo[r]


## What a trip to `dest` is worth: goods home is short of that dest can spare,
## plus half the value of selling `cargo` to what dest needs.
func _deal_value(home: int, dest: int, cargo: Dictionary) -> float:
	var h := _settlements[home]
	var d := _settlements[dest]
	var buy := 0
	var sell := 0
	for r in TownResources.RESOURCES:
		buy += mini(_shortage(h, r), _surplus(d, r, SPARE_RATIO))
		sell += mini(cargo.get(r, 0), maxi(int(_target(d, r) - d.stock[r]), 0))
	return minf(buy, CAPACITY) + sell * 0.5


## Sells the cargo to `stop` and buys what home lacks, unit for unit, from what
## `stop` can spare. The purchases replace the cargo.
func _trade(t: Dictionary, stop: int) -> void:
	var seller: Dictionary = _settlements[stop]
	var stock: Dictionary = seller.stock
	var budget := 0
	for r: StringName in t.cargo:
		stock[r] += t.cargo[r]
		budget += t.cargo[r]
	t.cargo = {}
	var home: Dictionary = _settlements[t.home]
	var wants: Array[StringName] = []
	for r in TownResources.RESOURCES:
		if _shortage(home, r) > 0:
			wants.append(r)
	wants.sort_custom(func(a: StringName, b: StringName) -> bool:
		return _shortage(home, a) / _target(home, a) > _shortage(home, b) / _target(home, b))
	for r: StringName in wants:
		var amount := mini(mini(_shortage(home, r), _surplus(seller, r, SPARE_RATIO)), budget)
		if amount > 0:
			stock[r] -= amount
			t.cargo[r] = amount
			budget -= amount


## The faction the trader works for (its home settlement's owner), or -1.
func faction_of(t: Dictionary) -> int:
	return _settlements[t.home].faction


func color_of(t: Dictionary) -> Color:
	var f := faction_of(t)
	return _factions[f].color if f >= 0 else NEUTRAL_COLOR


func faction_name_of(t: Dictionary) -> String:
	var f := faction_of(t)
	return _factions[f].name if f >= 0 else "Independent"


## Hours to cross the trader's current segment: a day on a road, longer off
## road by the average difficulty of the two cells.
func _segment_hours(t: Dictionary) -> float:
	var a: int = t.path[t.segment]
	var b: int = t.path[t.segment + 1]
	if _roads.has_road(a, b):
		return HOURS_PER_TILE
	return HOURS_PER_TILE * (_terrain_multiplier(_map.cells[a]) + _terrain_multiplier(_map.cells[b])) * 0.5


func _terrain_multiplier(cell: Dictionary) -> float:
	var m: float = OFFROAD_MULTIPLIER.get(cell.biome, 2.0)
	if cell.has_forest:
		m *= DENSE_FOREST_MULTIPLIER if cell.dense_forest else FOREST_MULTIPLIER
	if cell.river:
		m *= RIVER_MULTIPLIER
	return m


func _update_pos(t: Dictionary) -> void:
	if t.dest < 0:
		t.pos = _site(t.at)
	else:
		var a: Vector2 = _map.cells[t.path[t.segment]].site
		var b: Vector2 = _map.cells[t.path[t.segment + 1]].site
		t.pos = a.lerp(b, t.progress)


func _site(settlement: int) -> Vector2:
	return _map.cells[_settlements[settlement].cell].site
