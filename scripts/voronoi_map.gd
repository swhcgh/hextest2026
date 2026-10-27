class_name VoronoiMap
extends RefCounted
## Procedural Voronoi overworld. Call generate() then read `cells`.
##
## Each cell is a Dictionary:
##   site: Vector2, polygon: PackedVector2Array, neighbors: Array[int],
##   elevation: float (0..1), moisture: float (0..1), is_land: bool, biome: StringName,
##   has_forest / dense_forest: bool (feature overlay on the biome),
##   river: bool, river_next: int (downstream cell, -1 if none), river_flow: int,
##   production: Dictionary of resource -> units per day (see Production)

## Share of the map's shorter side kept as open water along every edge.
const EDGE_PADDING := 0.06

var size := Vector2(1280, 720)
var cells: Array[Dictionary] = []
## River drawing data: pairs of points (a0, b0, a1, b1, ...) and one width per pair.
var river_points := PackedVector2Array()
var river_widths := PackedFloat32Array()
var sea_level := 0.38


func generate(map_seed: int, cell_count := 400, relax_iterations := 2) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = map_seed

	var sites := PackedVector2Array()
	for i in cell_count:
		sites.append(Vector2(rng.randf() * size.x, rng.randf() * size.y))

	for i in relax_iterations:
		var built := _build_cells(sites)
		for j in sites.size():
			sites[j] = _centroid(built[j].polygon, sites[j])

	cells = _build_cells(sites)
	river_points.clear()
	river_widths.clear()
	_assign_terrain(map_seed)
	_generate_rivers(map_seed)
	Production.assign(self)


## Voronoi diagram via Delaunay triangulation. Sites are mirrored across each
## map edge so border cells are closed and end on the border.
func _build_cells(sites: PackedVector2Array) -> Array[Dictionary]:
	var n := sites.size()
	var points := sites.duplicate()
	for s in sites:
		points.append(Vector2(-s.x, s.y))
		points.append(Vector2(2.0 * size.x - s.x, s.y))
		points.append(Vector2(s.x, -s.y))
		points.append(Vector2(s.x, 2.0 * size.y - s.y))

	var tris := Geometry2D.triangulate_delaunay(points)
	var corners: Array[PackedVector2Array] = []
	var neighbor_sets: Array[Dictionary] = []
	for i in n:
		corners.append(PackedVector2Array())
		neighbor_sets.append({})

	for t in range(0, tris.size(), 3):
		var ids := [tris[t], tris[t + 1], tris[t + 2]]
		var cc: Variant = _circumcenter(points[ids[0]], points[ids[1]], points[ids[2]])
		for k in 3:
			var a: int = ids[k]
			if a >= n:
				continue
			if cc != null:
				corners[a].append(cc)
			var b: int = ids[(k + 1) % 3]
			var c: int = ids[(k + 2) % 3]
			if b < n:
				neighbor_sets[a][b] = true
			if c < n:
				neighbor_sets[a][c] = true

	var border := PackedVector2Array([
		Vector2.ZERO, Vector2(size.x, 0), size, Vector2(0, size.y)])
	var result: Array[Dictionary] = []
	for i in n:
		var site := sites[i]
		var poly := corners[i]
		var sorted := Array(poly)
		sorted.sort_custom(func(p: Vector2, q: Vector2) -> bool:
			return (p - site).angle() < (q - site).angle())
		var clipped := Geometry2D.intersect_polygons(PackedVector2Array(sorted), border)
		var final_poly: PackedVector2Array = clipped[0] if clipped.size() > 0 else PackedVector2Array(sorted)
		var neighbors: Array[int] = []
		for k in neighbor_sets[i]:
			neighbors.append(k)
		result.append({
			"site": site,
			"polygon": final_poly,
			"neighbors": neighbors,
			"elevation": 0.0,
			"moisture": 0.0,
			"is_land": false,
			"biome": &"ocean",
			"has_forest": false,
			"dense_forest": false,
			"river": false,
			"river_next": -1,
			"river_flow": 0,
		})
	return result


func _circumcenter(a: Vector2, b: Vector2, c: Vector2) -> Variant:
	var d := 2.0 * (a.x * (b.y - c.y) + b.x * (c.y - a.y) + c.x * (a.y - b.y))
	if absf(d) < 0.000001:
		return null
	var a2 := a.length_squared()
	var b2 := b.length_squared()
	var c2 := c.length_squared()
	return Vector2(
		(a2 * (b.y - c.y) + b2 * (c.y - a.y) + c2 * (a.y - b.y)) / d,
		(a2 * (c.x - b.x) + b2 * (a.x - c.x) + c2 * (b.x - a.x)) / d)


func _centroid(poly: PackedVector2Array, fallback: Vector2) -> Vector2:
	var area := 0.0
	var c := Vector2.ZERO
	for i in poly.size():
		var p := poly[i]
		var q := poly[(i + 1) % poly.size()]
		var cross := p.cross(q)
		area += cross
		c += (p + q) * cross
	if absf(area) < 0.000001:
		return fallback
	return c / (3.0 * area)


func _assign_terrain(map_seed: int) -> void:
	var elev := FastNoiseLite.new()
	elev.seed = map_seed
	elev.frequency = 0.004
	elev.fractal_octaves = 4
	var wet := FastNoiseLite.new()
	wet.seed = map_seed + 1
	wet.frequency = 0.005
	wet.fractal_octaves = 3

	var forest := FastNoiseLite.new()
	forest.seed = map_seed + 3
	forest.frequency = 0.012
	forest.fractal_octaves = 3

	var half := size * 0.5
	var padding := minf(size.x, size.y) * EDGE_PADDING
	for cell in cells:
		var p: Vector2 = cell.site
		# Radial falloff keeps the continent away from the map edge; a small
		# lift toward the center makes inland water (lakes) less likely.
		var d := ((p - half) / half).length() / 1.2
		var e := elev.get_noise_2dv(p) * 0.5 + 0.5
		e = clampf(e * 1.1 + (1.0 - minf(d, 1.0)) * 0.06 - pow(d, 3.0) * 0.65, 0.0, 1.0)
		# Water padding: all ocean within EDGE_PADDING of any map edge, fading
		# back to normal terrain over the same distance again.
		var edge_dist := minf(minf(p.x, size.x - p.x), minf(p.y, size.y - p.y))
		e *= smoothstep(0.0, 1.0, clampf((edge_dist - padding) / padding, 0.0, 1.0))
		var m := wet.get_noise_2dv(p) * 0.5 + 0.5
		cell.elevation = e
		cell.moisture = m
		cell.is_land = e >= sea_level
		cell.biome = _biome(e, m)
		if cell.biome == &"grassland" or cell.biome == &"taiga":
			# Wetter ground and a patchy noise field decide where forests grow.
			var f := forest.get_noise_2dv(p) * 0.5 + 0.5 + (m - 0.5) * 0.8
			cell.has_forest = f > 0.62
			cell.dense_forest = f > 0.62 and m > 0.65


func _biome(e: float, m: float) -> StringName:
	if e < sea_level - 0.12:
		return &"deep_ocean"
	if e < sea_level:
		return &"ocean"
	if e < sea_level + 0.03:
		return &"beach"
	if e > 0.8:
		return &"snow" if m > 0.4 else &"mountain"
	if e > 0.65:
		return &"mountain" if m < 0.5 else &"taiga"
	if m < 0.3:
		return &"desert"
	return &"grassland"


## Rivers start in the highlands and run downhill (squeezing through pits) to
## the sea or into an existing river. Rivers that dead-end are discarded.
func _generate_rivers(map_seed: int) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = map_seed + 7

	var springs: Array[int] = []
	var land_count := 0
	for i in cells.size():
		if cells[i].is_land:
			land_count += 1
			if cells[i].elevation > 0.6:
				springs.append(i)
	var wanted := maxi(land_count / 25, 3)
	var made := 0
	while made < wanted and not springs.is_empty():
		var start: int = springs.pop_at(rng.randi() % springs.size())
		if cells[start].river:
			continue
		var path := _trace_river(start)
		if path.size() >= 4:
			_commit_river(path)
			made += 1

	for i in cells.size():
		var cell := cells[i]
		if not cell.river:
			continue
		var next: int = cell.river_next
		river_points.append(cell.site)
		river_points.append((cell.site + cells[next].site) * 0.5 if not cells[next].is_land else cells[next].site)
		river_widths.append(1.5 + minf(cell.river_flow, 5) * 0.7)


## Returns the cells from `start` to the sea (last cell is water) or to an
## existing river (last cell is a river cell), or [] if the river dead-ends.
func _trace_river(start: int) -> Array[int]:
	var path: Array[int] = [start]
	var visited := {start: true}
	var cur := start
	while path.size() < 300:
		var best := -1
		var best_elev := INF
		for nb in cells[cur].neighbors:
			if visited.has(nb):
				continue
			if not cells[nb].is_land:
				best = nb
				break
			if cells[nb].elevation < best_elev:
				best_elev = cells[nb].elevation
				best = nb
		if best < 0:
			return []
		path.append(best)
		if not cells[best].is_land or cells[best].river:
			return path
		visited[best] = true
		cur = best
	return []


func _commit_river(path: Array[int]) -> void:
	for i in path.size() - 1:
		var cell := cells[path[i]]
		cell.river_flow += 1
		if not cell.river:
			cell.river = true
			cell.river_next = path[i + 1]
	# A tributary adds its flow to every cell downstream of where it joins.
	var n: int = path[-1]
	while n >= 0 and cells[n].is_land:
		cells[n].river_flow += 1
		n = cells[n].river_next
