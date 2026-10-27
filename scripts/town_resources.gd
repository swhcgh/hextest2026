class_name TownResources
extends RefCounted
## Gives every settlement a small store of goods (settlement.stock), set by the
## land around it. These are starting stockpiles for trading later.
##
## stock: Dictionary of resource name (StringName) -> int
## population: float, starting size set here and grown by Production

const RESOURCES: Array[StringName] = [&"wood", &"ore", &"textiles", &"grain", &"meat", &"gold"]
const RING_DEPTH := 2  # how many cells out a settlement draws from
const STOCK_SCALE := 15.0  # days of the surrounding land's production
const CITY_MULTIPLIER := 2.0
const BASE_GOLD := {&"city": 30, &"town": 10}
const START_POPULATION := {&"city": Vector2(200.0, 350.0), &"town": Vector2(60.0, 140.0)}


static func generate(map: VoronoiMap, settlements: Array[Dictionary], map_seed: int) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = map_seed + 17
	for s in settlements:
		generate_one(map, s, rng)


## Fills in one settlement's starting stock: a few weeks of what the land
## around it produces (see Production).
static func generate_one(map: VoronoiMap, s: Dictionary, rng: RandomNumberGenerator) -> void:
	var total := {}
	for r in RESOURCES:
		total[r] = 0.0
	for i in _surroundings(map.cells, s.cell):
		for r in RESOURCES:
			total[r] += map.cells[i].production[r]

	var size_mult := CITY_MULTIPLIER if s.kind == &"city" else 1.0
	var stock := {}
	for r in RESOURCES:
		stock[r] = int(round(total[r] * STOCK_SCALE * size_mult * rng.randf_range(0.7, 1.3)))
	# Gold is coin as much as ore: every settlement holds some.
	stock[&"gold"] += BASE_GOLD[s.kind]
	s["stock"] = stock
	var pop_range: Vector2 = START_POPULATION[s.kind]
	s["population"] = rng.randf_range(pop_range.x, pop_range.y)


## The cell and everything within RING_DEPTH neighbor-steps of it.
static func _surroundings(cells: Array[Dictionary], start: int) -> Array[int]:
	var seen := {start: true}
	var frontier: Array[int] = [start]
	for depth in RING_DEPTH:
		var next: Array[int] = []
		for u in frontier:
			for v in cells[u].neighbors:
				if not seen.has(v):
					seen[v] = true
					next.append(v)
		frontier = next
	var result: Array[int] = []
	result.assign(seen.keys())
	return result


## Goods in a stock/cargo dictionary as text lines, three per line, skipping
## empty ones.
static func stock_lines(stock: Dictionary) -> Array[String]:
	var parts: Array[String] = []
	for r in RESOURCES:
		if stock.get(r, 0) > 0:
			parts.append("%s %d" % [String(r).capitalize(), stock[r]])
	var lines: Array[String] = []
	for i in range(0, parts.size(), 3):
		lines.append("   ".join(PackedStringArray(parts.slice(i, i + 3))))
	return lines
