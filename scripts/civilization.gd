class_name Civilization
extends RefCounted
## Settlements and factions layered on top of a VoronoiMap.
##
## A region is simply the land a faction controls. Land no faction reaches
## (faction -1) is independent and has no region.
##
## settlement: cell, name, kind (&"city"/&"town"), faction, is_capital,
##   stock (goods in store) and population, both added by TownResources
## faction: name, color, capital (settlement index), settlements (Array[int]),
##   border (flat point pairs outlining the faction's whole territory, inset into it)

const SYLLABLES_START := ["Ash", "Bran", "Cor", "Dun", "El", "Fen", "Gar", "Hol", "Iron", "Kel", "Lor", "Mar", "North", "Oak", "Pen", "Ravens", "Stone", "Thorn", "Val", "West", "Wyn"]
const SYLLABLES_END := ["ford", "mouth", "wick", "ton", "haven", "gate", "bridge", "hold", "stead", "port", "vale", "field", "crest", "burg", "moor", "dale"]
const FACTION_PREFIX := ["Kingdom of", "Duchy of", "Republic of", "Empire of", "Free League of", "Principality of", "Concord of"]

## Each world gets a random number of factions in this range.
const MIN_FACTIONS := 4
const MAX_FACTIONS := 7
const MIN_FACTION_CELLS := 4
## Share of the land each faction starts with, at most.
const INITIAL_FACTION_SHARE := 0.08
## Share of all land cells a single faction may grow to control.
const MAX_FACTION_SHARE := 0.25

const BIOME_SETTLE_SCORE := {
	&"grassland": 1.0, &"beach": 0.4, &"taiga": 0.3, &"desert": 0.1,
}

var settlements: Array[Dictionary] = []
var factions: Array[Dictionary] = []
var cell_faction := PackedInt32Array()

var _map: VoronoiMap
var _border_cache: Array[PackedVector2Array] = []
var _rng := RandomNumberGenerator.new()
var _used_names := {}


func generate(map: VoronoiMap, map_seed: int) -> void:
	_map = map
	_rng.seed = map_seed + 2
	_used_names.clear()
	settlements.clear()
	factions.clear()
	cell_faction.resize(map.cells.size())
	cell_faction.fill(-1)

	_place_settlements()
	_found_factions(_rng.randi_range(MIN_FACTIONS, MAX_FACTIONS))
	_assign_settlements()
	_ensure_towns()
	_find_borders()


func _place_settlements() -> void:
	var cells := _map.cells
	var candidates: Array[Dictionary] = []
	for i in cells.size():
		var score := settle_score(i)
		if score > 0.0:
			candidates.append({"cell": i, "score": score})
	candidates.sort_custom(func(a, b): return a.score > b.score)

	var spacing := cell_size() * 2.4
	var max_count := maxi(cells.size() / 12, 3)
	var picked: Array[Dictionary] = []
	for c in candidates:
		if picked.size() >= max_count:
			break
		var p: Vector2 = cells[c.cell].site
		var ok := true
		for q in picked:
			if p.distance_to(cells[q.cell].site) < spacing:
				ok = false
				break
		if ok:
			picked.append(c)

	var city_count := maxi(picked.size() / 4, 1)
	for i in picked.size():
		settlements.append({
			"cell": picked[i].cell,
			"name": _make_name(),
			"kind": &"city" if i < city_count else &"town",
			"faction": -1,
			"is_capital": false,
		})


## How good a spot a cell is for a settlement; -1 if it can't hold one.
func settle_score(i: int) -> float:
	var cells := _map.cells
	var cell := cells[i]
	if not cell.is_land:
		return -1.0
	var base: float = BIOME_SETTLE_SCORE.get(cell.biome, -1.0)
	if base <= 0.0:
		return -1.0
	var coastal := false
	for nb in cell.neighbors:
		if not cells[nb].is_land:
			coastal = true
			break
	# Rivers attract settlement; dense woodland is harder to build in.
	base += (0.5 if cell.river else 0.0) - (0.4 if cell.has_forest else 0.0)
	return base + (0.6 if coastal else 0.0) + (1.0 - cell.elevation) * 0.3 + _rng.randf() * 0.5


func cell_size() -> float:
	return sqrt(_map.size.x * _map.size.y / _map.cells.size())


func _found_factions(faction_count: int) -> void:
	# Any settlement can become a capital (and is promoted to a city). A
	# faction that can't reach the minimum size (e.g. its capital is on a tiny
	# island) is rejected and replaced by the next-best candidate.
	var capitals: Array[int] = []
	var rejected: Array[int] = []
	while true:
		while capitals.size() < faction_count:
			var next := _farthest_settlement(capitals, rejected)
			if next < 0:
				break
			capitals.append(next)
		if capitals.is_empty():
			break

		cell_faction = _claim(capitals)
		var counts: Array[int] = []
		counts.resize(capitals.size())
		counts.fill(0)
		for f in cell_faction:
			if f >= 0:
				counts[f] += 1
		var smallest := counts.find(counts.min())
		if counts[smallest] >= MIN_FACTION_CELLS:
			break
		rejected.append(capitals[smallest])
		capitals.remove_at(smallest)
	if capitals.is_empty():
		cell_faction.fill(-1)

	for c in capitals:
		settlements[c].kind = &"city"

	var hues: Array[float] = []
	for f in capitals.size():
		var s := settlements[capitals[f]]
		s.is_capital = true
		factions.append({
			"name": "%s %s" % [FACTION_PREFIX[_rng.randi() % FACTION_PREFIX.size()], s.name],
			"color": _random_faction_color(hues),
			"capital": capitals[f],
			"settlements": [] as Array[int],
			"border": PackedVector2Array(),
		})


## Farthest-point sampling spreads capitals across the map. Returns the
## settlement farthest from every chosen capital, or -1 if none are left.
func _farthest_settlement(capitals: Array[int], rejected: Array[int]) -> int:
	var best := -1
	var best_dist := -1.0
	for c in settlements.size():
		if c in capitals or c in rejected:
			continue
		var d := INF
		for k in capitals:
			d = minf(d, _site(c).distance_to(_site(k)))
		if d > best_dist:
			best_dist = d
			best = c
	return best


func _assign_settlements() -> void:
	for i in settlements.size():
		var f := cell_faction[settlements[i].cell]
		settlements[i].faction = f
		if f >= 0:
			factions[f].settlements.append(i)


## Every faction gets at least one town besides its capital: a faction left
## with only its capital founds one on the best spot in its territory, keeping
## a little distance from other settlements if it can.
func _ensure_towns() -> void:
	for f in factions.size():
		if factions[f].settlements.size() > 1:
			continue
		var taken := {}
		for s in settlements:
			taken[s.cell] = true
		for min_spacing in [cell_size() * 1.5, 0.0]:
			var best := -1
			var best_score := -INF
			for i in cell_faction.size():
				if cell_faction[i] != f or taken.has(i):
					continue
				var site: Vector2 = _map.cells[i].site
				var too_close := false
				for s in settlements:
					if site.distance_to(_map.cells[s.cell].site) < min_spacing:
						too_close = true
						break
				if too_close:
					continue
				var score := settle_score(i)
				if score > best_score:
					best_score = score
					best = i
			if best >= 0:
				settlements.append({
					"cell": best,
					"name": _make_name(),
					"kind": &"town",
					"faction": f,
					"is_capital": false,
				})
				factions[f].settlements.append(settlements.size() - 1)
				break


## Multi-source Dijkstra over land from each capital's cell. Each cell goes to
## the nearest faction by travel cost, but a faction stops expanding once it
## holds INITIAL_FACTION_SHARE of the land. Returns the faction (index into
## `capitals`) per cell, or -1 for unclaimed.
func _claim(capitals: Array[int]) -> PackedInt32Array:
	var cells := _map.cells
	var land_count := 0
	for c in cells:
		if c.is_land:
			land_count += 1
	var max_cells := maxi(int(land_count * INITIAL_FACTION_SHARE), MIN_FACTION_CELLS)

	var label := PackedInt32Array()
	label.resize(cells.size())
	label.fill(-1)
	var sizes: Array[int] = []
	sizes.resize(capitals.size())
	sizes.fill(0)

	var heap := []  # binary min-heap of [cost, cell, faction]
	for k in capitals.size():
		MinHeap.push(heap, [0.0, settlements[capitals[k]].cell, k])

	while not heap.is_empty():
		var top: Array = MinHeap.pop(heap)
		var u: int = top[1]
		var f: int = top[2]
		if label[u] >= 0 or sizes[f] >= max_cells:
			continue
		label[u] = f
		sizes[f] += 1
		for v in cells[u].neighbors:
			if label[v] >= 0 or not cells[v].is_land:
				continue
			var step: float = cells[u].site.distance_to(cells[v].site) * (1.0 + cells[v].elevation * 2.0)
			MinHeap.push(heap, [top[0] + step, v, f])
	return label


## Outlines each faction's territory. For every polygon edge of a claimed cell
## we find the neighbor across it (the point on a Voronoi edge is equally far
## from both sites), and keep the edge if that side is water, another
## faction, independent land, or off the map. Matching by distance rather than
## by shared vertices avoids gaps where nearly-coincident corners differ.
func _find_borders() -> void:
	_border_cache.clear()
	_border_cache.resize(_map.cells.size())
	for i in _border_cache.size():
		_border_cache[i] = _compute_cell_border(i)
	for f in factions.size():
		_assemble_border(f)


## A faction's outline is the sum of its cells' border segments.
func _assemble_border(f: int) -> void:
	var border := PackedVector2Array()
	for i in cell_faction.size():
		if cell_faction[i] == f:
			border.append_array(_border_cache[i])
	factions[f].border = border


## Border segments (point pairs) of one claimed cell: its polygon edges whose
## far side is water, another faction, independent land, or off the map. Each
## is nudged into the cell so two factions sharing a border each draw a line.
func _compute_cell_border(i: int) -> PackedVector2Array:
	var segments := PackedVector2Array()
	if cell_faction[i] < 0:
		return segments
	var cells := _map.cells
	var poly: PackedVector2Array = cells[i].polygon
	for k in poly.size():
		var a := poly[k]
		var b := poly[(k + 1) % poly.size()]
		if a.is_equal_approx(b):
			continue
		var mid := (a + b) * 0.5
		var own := mid.distance_to(cells[i].site)
		var across := -1
		var across_dist := own + 1.0
		for nb in cells[i].neighbors:
			var d := mid.distance_to(cells[nb].site)
			if d < across_dist:
				across_dist = d
				across = nb
		if across >= 0 and cell_faction[across] == cell_faction[i]:
			continue
		var normal := (b - a).orthogonal().normalized()
		if normal.dot(cells[i].site - mid) < 0.0:
			normal = -normal
		segments.append(a + normal * 1.5)
		segments.append(b + normal * 1.5)
	return segments


## Gives an unclaimed cell to a faction, refreshing the affected outlines. An
## independent settlement on it joins the faction.
func claim_cell(cell: int, faction: int) -> void:
	cell_faction[cell] = faction
	var touched := {faction: true}
	var cells := _map.cells
	for x in [cell] + cells[cell].neighbors:
		_border_cache[x] = _compute_cell_border(x)
		if cell_faction[x] >= 0:
			touched[cell_faction[x]] = true
	for f in touched:
		_assemble_border(f)
	for i in settlements.size():
		if settlements[i].cell == cell and settlements[i].faction < 0:
			settlements[i].faction = faction
			factions[faction].settlements.append(i)


## Founds a town for a faction on a cell it controls. Returns its index; the
## caller fills in the stock.
func add_settlement(cell: int, faction: int) -> int:
	settlements.append({
		"cell": cell,
		"name": _make_name(),
		"kind": &"town",
		"faction": faction,
		"is_capital": false,
	})
	factions[faction].settlements.append(settlements.size() - 1)
	return settlements.size() - 1


## Random color whose hue is not too close to an already used one.
func _random_faction_color(used_hues: Array[float]) -> Color:
	var hue := _rng.randf()
	for attempt in 30:
		var clear := true
		for h in used_hues:
			var d := absf(hue - h)
			if minf(d, 1.0 - d) < 0.06:
				clear = false
				break
		if clear:
			break
		hue = _rng.randf()
	used_hues.append(hue)
	return Color.from_hsv(hue, _rng.randf_range(0.55, 0.9), _rng.randf_range(0.75, 1.0))


func _site(settlement: int) -> Vector2:
	return _map.cells[settlements[settlement].cell].site


func _make_name() -> String:
	for attempt in 20:
		var n: String = SYLLABLES_START[_rng.randi() % SYLLABLES_START.size()] + SYLLABLES_END[_rng.randi() % SYLLABLES_END.size()]
		if not _used_names.has(n):
			_used_names[n] = true
			return n
	return "Nameless %d" % _used_names.size()
