class_name Locations
extends RefCounted
## Points of interest outside settlements: mines, caves, dungeons, ruins and
## shrines. Placed after factions so each knows whose territory it lies in.
##
## location: cell, kind, name, resource (&"" if none), faction (-1 = unclaimed)

const KINDS := {
	# land_per: roughly one location per this many land cells.
	# biomes: how suitable each biome is (missing = never).
	# high: prefers high ground. remote: prefers being far from settlements.
	&"mine": {"land_per": 35, "min_elev": 0.55, "high": true, "remote": false,
		"biomes": {&"mountain": 1.0, &"taiga": 0.6, &"snow": 0.3, &"grassland": 0.2}},
	&"cave": {"land_per": 45, "min_elev": 0.5, "high": true, "remote": false,
		"biomes": {&"mountain": 1.0, &"taiga": 0.7, &"grassland": 0.3, &"desert": 0.3, &"snow": 0.3}},
	&"dungeon": {"land_per": 60, "min_elev": 0.0, "high": false, "remote": true,
		"biomes": {&"grassland": 0.5, &"taiga": 0.6, &"desert": 0.5, &"mountain": 0.6}},
	&"ruins": {"land_per": 45, "min_elev": 0.0, "high": false, "remote": true,
		"biomes": {&"grassland": 1.0, &"desert": 1.0, &"taiga": 0.6, &"beach": 0.5}},
	&"shrine": {"land_per": 60, "min_elev": 0.0, "high": false, "remote": false,
		"biomes": {&"grassland": 0.6, &"taiga": 0.8, &"beach": 0.3}},
}

const MINE_RESOURCES: Array[StringName] = [&"iron", &"copper", &"silver", &"gold", &"coal"]
const NAME_WORDS := {
	&"cave": ["Whispering", "Echo", "Bat", "Crystal", "Hollow", "Dripping", "Blind"],
	&"dungeon": ["Dread", "Forgotten", "Black", "Sunken", "Weeping", "Iron"],
	&"ruins": ["Fallen", "Ancient", "Lost", "Broken", "Shattered", "Elder"],
	&"shrine": ["Quiet", "Hallowed", "Moss", "Pilgrim's", "Starlit", "Old"],
}
const NAME_SUFFIX := {
	&"cave": ["Cave", "Cavern", "Grotto"],
	&"dungeon": ["Dungeon", "Keep", "Crypt", "Vault"],
	&"ruins": ["Ruins", "Spire", "Citadel", "Fort"],
	&"shrine": ["Shrine", "Altar", "Stones"],
}

var locations: Array[Dictionary] = []


func generate(map: VoronoiMap, civ: Civilization, map_seed: int) -> void:
	locations.clear()
	var rng := RandomNumberGenerator.new()
	rng.seed = map_seed + 13
	var cells := map.cells

	var land_count := 0
	for c in cells:
		if c.is_land:
			land_count += 1
	var cell_size := sqrt(map.size.x * map.size.y / cells.size())
	var settlement_spacing := cell_size * 1.5
	var location_spacing := cell_size * 2.0

	var taken: Array[Vector2] = []  # sites of everything already placed
	var settlement_sites: Array[Vector2] = []
	for s in civ.settlements:
		settlement_sites.append(cells[s.cell].site)
		taken.append(cells[s.cell].site)

	for kind: StringName in KINDS:
		var spec: Dictionary = KINDS[kind]
		var candidates: Array[Dictionary] = []
		for i in cells.size():
			var cell := cells[i]
			if not cell.is_land or cell.elevation < spec.min_elev or not spec.biomes.has(cell.biome):
				continue
			var score: float = spec.biomes[cell.biome] + rng.randf() * 0.4
			if spec.high:
				score += cell.elevation * 0.5
			if spec.remote:
				var nearest := INF
				for p in settlement_sites:
					nearest = minf(nearest, cell.site.distance_to(p))
				score += minf(nearest / (cell_size * 5.0), 1.0)
			candidates.append({"cell": i, "score": score})
		candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return a.score > b.score)

		var wanted := maxi(land_count / spec.land_per, 1)
		var placed := 0
		for cand in candidates:
			if placed >= wanted:
				break
			var site: Vector2 = cells[cand.cell].site
			var ok := true
			for p in taken:
				var min_dist := settlement_spacing if p in settlement_sites else location_spacing
				if site.distance_to(p) < min_dist:
					ok = false
					break
			if not ok:
				continue
			taken.append(site)
			placed += 1
			var resource := &""
			if kind == &"mine":
				resource = MINE_RESOURCES[rng.randi() % MINE_RESOURCES.size()]
			if kind == &"mine":
				var produced := &"gold" if resource == &"gold" else &"ore"
				cells[cand.cell].production[produced] += Production.MINE_PRODUCTION
			locations.append({
				"cell": cand.cell,
				"kind": kind,
				"name": _make_name(kind, resource, rng),
				"resource": resource,
				"faction": civ.cell_faction[cand.cell],
			})


func _make_name(kind: StringName, resource: StringName, rng: RandomNumberGenerator) -> String:
	if kind == &"mine":
		return "%s Mine" % String(resource).capitalize()
	var words: Array = NAME_WORDS[kind]
	var suffixes: Array = NAME_SUFFIX[kind]
	return "%s %s" % [words[rng.randi() % words.size()], suffixes[rng.randi() % suffixes.size()]]
