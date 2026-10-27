class_name RoadNetwork
extends RefCounted
## Sparse roads between settlements. Each faction's capital is linked to
## every other settlement in its territory. Roads between factions
## are rarer: at most one per pair of factions, and only sometimes. Independent
## settlements link to their nearest neighbor now and then. Roads are routed
## over land (avoiding mountains, forest and river crossings) and are cheaper
## to travel along existing roads, so routes merge instead of running side by
## side.

const BORDER_ROAD_CHANCE := 0.35
const INDEPENDENT_LINK_CHANCE := 0.6
## Factions farther apart than this (as a share of map width) never get a road.
const MAX_BORDER_ROAD_SHARE := 0.3
const ROAD_DISCOUNT := 0.3
const FOREST_PENALTY := 1.4
const RIVER_CROSSING_COST := 20.0

## Flat pairs of points (a0, b0, a1, b1, ...), each road segment drawn once.
var points := PackedVector2Array()
## Cells that carry a road.
var road_cells := {}
## Landmass id per cell (-1 for water); settlements share an id if connected by land.
var landmass := PackedInt32Array()

var _map: VoronoiMap
var _drawn_edges := {}


func generate(map: VoronoiMap, settlements: Array[Dictionary], map_seed: int) -> void:
	_map = map
	points.clear()
	road_cells.clear()
	_drawn_edges.clear()
	var rng := RandomNumberGenerator.new()
	rng.seed = map_seed + 11
	landmass = _label_landmasses()

	# 1. Capitals to the other settlements in their territory.
	for cap in settlements.size():
		if not settlements[cap].is_capital:
			continue
		for other in settlements.size():
			if other != cap and settlements[other].faction == settlements[cap].faction \
					and landmass[settlements[other].cell] == landmass[settlements[cap].cell]:
				link(settlements[cap].cell, settlements[other].cell)

	# 2. Between factions: the closest pair of settlements per pair of
	# factions, and only sometimes.
	var best_pair := {}  # faction pair key -> {"i", "j", "d"}
	for i in settlements.size():
		for j in range(i + 1, settlements.size()):
			var fi: int = settlements[i].faction
			var fj: int = settlements[j].faction
			if fi < 0 or fj < 0 or fi == fj:
				continue
			if landmass[settlements[i].cell] != landmass[settlements[j].cell]:
				continue
			var d := _site(settlements, i).distance_to(_site(settlements, j))
			var key := _key(fi, fj)
			if not best_pair.has(key) or d < best_pair[key].d:
				best_pair[key] = {"i": i, "j": j, "d": d}
	for key in best_pair:
		var p: Dictionary = best_pair[key]
		if p.d <= map.size.x * MAX_BORDER_ROAD_SHARE and rng.randf() < BORDER_ROAD_CHANCE:
			link(settlements[p.i].cell, settlements[p.j].cell)

	# 3. Independent settlements to their nearest neighbor on the same landmass.
	for i in settlements.size():
		if settlements[i].faction >= 0 or rng.randf() >= INDEPENDENT_LINK_CHANCE:
			continue
		var nearest := -1
		var nearest_dist := INF
		for j in settlements.size():
			if j == i or landmass[settlements[j].cell] != landmass[settlements[i].cell]:
				continue
			var d := _site(settlements, i).distance_to(_site(settlements, j))
			if d < nearest_dist:
				nearest_dist = d
				nearest = j
		if nearest >= 0:
			link(settlements[i].cell, settlements[nearest].cell)


## Cheapest land route between two cells, following roads where they exist.
## Returns [] if unreachable.
func find_path(from: int, to: int) -> Array[int]:
	return _route(from, to)


## Whether a road runs directly between two neighboring cells.
func has_road(a: int, b: int) -> bool:
	return _drawn_edges.has(_key(a, b))


## Builds a road between two cells, merging into existing roads.
func link(from: int, to: int) -> void:
	var path := _route(from, to)
	if not path.is_empty():
		_commit(path)


func _site(settlements: Array[Dictionary], i: int) -> Vector2:
	return _map.cells[settlements[i].cell].site


## Connected land cells share a label; water is -1.
func _label_landmasses() -> PackedInt32Array:
	var cells := _map.cells
	var label := PackedInt32Array()
	label.resize(cells.size())
	label.fill(-1)
	var next_label := 0
	for start in cells.size():
		if not cells[start].is_land or label[start] >= 0:
			continue
		var stack: Array[int] = [start]
		label[start] = next_label
		while not stack.is_empty():
			var u: int = stack.pop_back()
			for v in cells[u].neighbors:
				if cells[v].is_land and label[v] < 0:
					label[v] = next_label
					stack.append(v)
		next_label += 1
	return label


func _key(a: int, b: int) -> int:
	return mini(a, b) * 100000 + maxi(a, b)


## Cheapest land route between two cells (Dijkstra), or [] if unreachable.
func _route(from: int, to: int) -> Array[int]:
	var cells := _map.cells
	var dist := PackedFloat64Array()
	dist.resize(cells.size())
	dist.fill(INF)
	var prev := PackedInt32Array()
	prev.resize(cells.size())
	prev.fill(-1)

	var heap := []
	dist[from] = 0.0
	MinHeap.push(heap, [0.0, from])
	while not heap.is_empty():
		var top: Array = MinHeap.pop(heap)
		var u: int = top[1]
		if u == to:
			break
		if top[0] > dist[u]:
			continue
		for v in cells[u].neighbors:
			if not cells[v].is_land:
				continue
			var nd: float = dist[u] + _step_cost(u, v)
			if nd < dist[v]:
				dist[v] = nd
				prev[v] = u
				MinHeap.push(heap, [nd, v])

	var path: Array[int] = []
	if prev[to] < 0 and from != to:
		return path
	var c := to
	while c >= 0:
		path.append(c)
		c = prev[c]
	path.reverse()
	return path


func _step_cost(u: int, v: int) -> float:
	var cells := _map.cells
	var cost: float = cells[u].site.distance_to(cells[v].site) * (1.0 + cells[v].elevation * 3.0)
	if road_cells.has(v) and road_cells.has(u):
		return cost * ROAD_DISCOUNT
	if cells[v].has_forest:
		cost *= FOREST_PENALTY
	if cells[v].river and not road_cells.has(v):
		cost += RIVER_CROSSING_COST
	return cost


func _commit(path: Array[int]) -> void:
	for c in path:
		road_cells[c] = true
	for k in path.size() - 1:
		var key := _key(path[k], path[k + 1])
		if _drawn_edges.has(key):
			continue
		_drawn_edges[key] = true
		points.append(_map.cells[path[k]].site)
		points.append(_map.cells[path[k + 1]].site)
