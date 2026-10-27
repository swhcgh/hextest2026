class_name Traders
extends RefCounted
## Trading NPCs that shuttle goods between settlements. Each trader rests in a
## settlement, then travels (along roads where there are any) to one of the
## nearest other settlements on the same landmass. They cover a tile a day on
## roads and are much slower off road, depending on the terrain. On
## arrival it unloads its cargo into the town's stock and loads a few of the
## town's most plentiful goods to carry onward.
##
## A trader belongs to the faction that owns its home settlement; each trade it
## completes earns that faction one gold, paid into its capital's stock.
##
## trader: home (settlement index), trades (completed so far),
##   at (settlement index, -1 while travelling), last (previous stop),
##   dest (settlement index or -1), path (cells), segment, progress (0..1 along
##   the current segment), rest (hours left resting), cargo (resource -> int),
##   pos (world position)

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
const NEAREST_CANDIDATES := 3  # destinations are picked among this many nearest
const GOODS_PER_TRIP := 2  # different goods loaded at each stop
const LOAD_PER_GOOD := 3
const GOLD_PER_TRADE := 1
const NEUTRAL_COLOR := Color("9a9a9a")

var traders: Array[Dictionary] = []

var _map: VoronoiMap
var _settlements: Array[Dictionary]
var _factions: Array[Dictionary]
var _roads: RoadNetwork
var _rng := RandomNumberGenerator.new()


func spawn(map: VoronoiMap, settlements: Array[Dictionary], factions: Array[Dictionary], roads: RoadNetwork, map_seed: int) -> void:
	_map = map
	_settlements = settlements
	_factions = factions
	_roads = roads
	_rng.seed = map_seed + 19
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
			"last": -1,
			"dest": -1,
			"path": [] as Array[int],
			"segment": 0,
			"progress": 0.0,
			"rest": _rng.randf() * REST_HOURS,  # staggered departures
			"cargo": {},
			"pos": _site(home),
		}
		_load(t, home)
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
	var from_cell: int = _settlements[t.at].cell
	var here := _site(t.at)
	var options: Array[int] = []
	for i in _settlements.size():
		if i != t.at and _roads.landmass[_settlements[i].cell] == _roads.landmass[from_cell]:
			options.append(i)
	if options.is_empty():
		return
	options.sort_custom(func(a: int, b: int) -> bool: return here.distance_squared_to(_site(a)) < here.distance_squared_to(_site(b)))
	if options.size() > NEAREST_CANDIDATES:
		options.resize(NEAREST_CANDIDATES)
	if options.size() > 1:
		options.erase(t.last)  # don't just turn around
	var dest: int = options[_rng.randi() % options.size()]

	var path := _roads.find_path(from_cell, _settlements[dest].cell)
	if path.size() < 2:
		return
	t.last = t.at
	t.at = -1
	t.dest = dest
	t.path = path
	t.segment = 0
	t.progress = 0.0


func _arrive(t: Dictionary) -> void:
	t.at = t.dest
	t.dest = -1
	t.path = [] as Array[int]
	t.rest = REST_HOURS
	var stock: Dictionary = _settlements[t.at].stock
	for r: StringName in t.cargo:
		stock[r] += t.cargo[r]
	t.cargo = {}
	_load(t, t.at)
	t.trades += 1
	var f := faction_of(t)
	if f >= 0:
		_settlements[_factions[f].capital].stock[&"gold"] += GOLD_PER_TRADE


## Takes a few units of the town's most plentiful goods, leaving at least half.
func _load(t: Dictionary, settlement: int) -> void:
	var stock: Dictionary = _settlements[settlement].stock
	var goods: Array[StringName] = []
	for r in TownResources.RESOURCES:
		if stock[r] >= 2:
			goods.append(r)
	goods.sort_custom(func(a: StringName, b: StringName) -> bool: return stock[a] > stock[b])
	for r: StringName in goods.slice(0, GOODS_PER_TRIP):
		var amount := mini(LOAD_PER_GOOD, stock[r] / 2)
		stock[r] -= amount
		t.cargo[r] = t.cargo.get(r, 0) + amount


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
