class_name Production
extends RefCounted
## What each hex produces (units per day, stored in cell.production) and how
## settlements collect it. Every land hex is collected by the nearest town of
## the faction that owns it (cell.town, reached through that faction's own
## land; unclaimed land goes to independent towns); the yield falls with
## distance in hexes from full at the town's own hex down to MIN_YIELD far away.
##
## cell.production: Dictionary of resource name (StringName) -> float
## cell.town: settlement index collecting from this hex (-1 if none)
## cell.town_steps: hexes between this hex and that town

const PRODUCTION_SCALE := 0.2  # terrain values below are x this per day
const CITY_MULTIPLIER := 1.5  # cities work their land harder
const BASE_GOLD := {&"city": 0.6, &"town": 0.2}  # daily taxes
const MINE_PRODUCTION := 0.5  # added to a mine's hex by Locations
const MIN_YIELD := 0.25  # share of production collected from the farthest hexes
const FALLOFF_STEPS := 5  # distance at which the yield bottoms out

## Population grows logistically toward what the town's food income supports.
const GROWTH_RATE := 0.002  # per day, when far below capacity
const BASE_CAPACITY := 40.0
const PEOPLE_PER_DAILY_FOOD := 120.0  # capacity added per unit of grain+meat per day


## Sets production on every cell from its terrain.
static func assign(map: VoronoiMap) -> void:
	for cell in map.cells:
		cell["production"] = _terrain_production(map.cells, cell)
		cell["town"] = -1
		cell["town_steps"] = 0


static func _terrain_production(cells: Array[Dictionary], cell: Dictionary) -> Dictionary:
	var p: Dictionary[StringName, float] = {}
	for r in TownResources.RESOURCES:
		p[r] = 0.0
	if not cell.is_land:
		return p

	match cell.biome:
		&"grassland":
			p[&"grain"] += 1.0
			p[&"meat"] += 0.5
			p[&"textiles"] += 0.4
		&"taiga":
			p[&"meat"] += 0.4
			p[&"wood"] += 0.4
		&"mountain":
			p[&"ore"] += 0.8
		&"desert":
			p[&"ore"] += 0.1
	if cell.has_forest:
		p[&"wood"] += 1.5 if cell.dense_forest else 1.0
		p[&"meat"] += 0.3
		p[&"grain"] -= 0.7  # forest displaces fields
	if cell.river:
		p[&"grain"] += 0.4
		p[&"textiles"] += 0.2
	for nb: int in cell.neighbors:
		if not cells[nb].is_land:
			p[&"meat"] += 0.3  # fishing
			break
	for r: StringName in p:
		p[r] = maxf(p[r], 0.0) * PRODUCTION_SCALE
	return p


## Production as popup lines, three goods per line, skipping zeros.
static func lines(production: Dictionary) -> Array[String]:
	var parts: Array[String] = []
	for r in TownResources.RESOURCES:
		if production.get(r, 0.0) > 0.0:
			parts.append("%s %.2f" % [String(r).capitalize(), production[r]])
	var result: Array[String] = []
	for i in range(0, parts.size(), 3):
		result.append("   ".join(PackedStringArray(parts.slice(i, i + 3))))
	return result


## Points every land hex at the nearest town of its own faction (multi-source
## breadth-first search that only spreads through hexes with the same owner,
## -1 meaning unclaimed). Call again whenever a settlement is added or
## territory changes hands.
static func assign_catchments(map: VoronoiMap, settlements: Array[Dictionary], cell_faction: PackedInt32Array) -> void:
	var cells := map.cells
	for cell in cells:
		cell.town = -1
		cell.town_steps = 0
	var frontier: Array[int] = []
	for i in settlements.size():
		var c: int = settlements[i].cell
		cells[c].town = i
		frontier.append(c)
	while not frontier.is_empty():
		var next: Array[int] = []
		for u in frontier:
			for v: int in cells[u].neighbors:
				if cells[v].is_land and cells[v].town < 0 and cell_faction[v] == cell_faction[u]:
					cells[v].town = cells[u].town
					cells[v].town_steps = cells[u].town_steps + 1
					next.append(v)
		frontier = next


## Share of a hex's production its town collects: 1 at the town, MIN_YIELD
## at FALLOFF_STEPS hexes or more.
static func yield_at(steps: int) -> float:
	return lerpf(1.0, MIN_YIELD, clampf(float(steps) / FALLOFF_STEPS, 0.0, 1.0))


## One day of collection: every town gets the yield of the hexes assigned to
## it (grain and meat scaled by the season), plus taxes. Fractions carry over between days in settlement.carry.
static func collect_daily(map: VoronoiMap, settlements: Array[Dictionary], total_days: int = 0) -> void:
	var harvest := Upkeep.harvest_factor(total_days)
	var income: Array[Dictionary] = []
	for s in settlements:
		var zero: Dictionary[StringName, float] = {}
		for r in TownResources.RESOURCES:
			zero[r] = 0.0
		income.append(zero)
	for cell in map.cells:
		if cell.town < 0:
			continue
		var share := yield_at(cell.town_steps)
		for r: StringName in cell.production:
			income[cell.town][r] += cell.production[r] * share

	for i in settlements.size():
		var s := settlements[i]
		var multiplier := CITY_MULTIPLIER if s.kind == &"city" else 1.0
		if not s.has("carry"):
			s["carry"] = {}
		var carry: Dictionary = s.carry
		for r in TownResources.RESOURCES:
			var amount: float = income[i][r] * multiplier
			if r == &"grain" or r == &"meat":
				amount *= harvest  # farmed goods follow the seasons
			if r == &"gold":
				amount += BASE_GOLD[s.kind]
			carry[r] = carry.get(r, 0.0) + amount
			var whole := int(carry[r])
			if whole > 0:
				s.stock[r] += whole
				carry[r] -= whole
		var food: float = (income[i][&"grain"] + income[i][&"meat"]) * multiplier
		var capacity := BASE_CAPACITY + food * PEOPLE_PER_DAILY_FOOD
		s.population = maxf(s.population + s.population * GROWTH_RATE * (1.0 - s.population / capacity), 1.0)
