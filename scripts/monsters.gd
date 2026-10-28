class_name Monsters
extends RefCounted
## Monsters that wander in from the wilds: a horde of many small creatures, or
## one giant. Call setup() for a new world, on_day() once per world day and
## update() every frame with the world hours that passed.
##
## They come at most once or twice a year, and only one is loose at a time. A
## monster appears on the most remote land it can find and sets out along
## the roads for the nearest one. Like an army it fights by die roll (see
## War.roll_battle) against the town's militia. When it wins it ravages the
## town (people killed, goods carried off, sometimes the town is destroyed),
## lingers a few days, then moves on to the nearest settlement it has not yet
## hit. When it loses it is driven off. After RAMPAGE_TARGETS attacks, or
## MAX_DAYS, it wanders back into the wilds.
##
## Whenever a monster attacks a settlement, that faction sends an army to meet
## it (see War.raise_defense). A monster fights any army that comes near, and
## a beaten army retreats. A giant takes only GIANT_TOUGHNESS of the usual
## losses, so it takes a stronger army to bring one down.
##
## monster: kind (&"horde"/&"giant"), name, strength, targets_left, age (days),
##   target (settlement), phase (&"marching"/&"ravaging"), rest (hours left
##   ravaging), hit (settlements already attacked), path (cells), segment,
##   progress (0..1), pos, no_clash (hours)

signal event_occurred(text: String)
## A town was ruined, so settlement lists and territory need refreshing.
signal towns_lost

const PER_YEAR := 1.5  # monsters per year, on average
const STRENGTH := {&"horde": Vector2i(45, 90), &"giant": Vector2i(70, 120)}
const NAMES := {
	&"horde": ["Goblin horde", "Orc horde", "Gnoll horde", "Ghoul horde"],
	&"giant": ["Stone giant", "Troll", "Ogre", "Great wyrm"],
}
const GIANT_TOUGHNESS := 0.5
const SPAWN_TRIES := 30  # land cells sampled; it appears at the most remote
const RAMPAGE_TARGETS := Vector2i(2, 4)
const MAX_DAYS := 80
const REST_HOURS := Vector2(72.0, 144.0)  # how long it ravages a town
const HOURS_PER_TILE := 30.0
const POP_LOSS := Vector2(0.10, 0.25)  # share of a town's people killed when it wins
const STOCK_LOSS := 0.35
const DESTROY_CHANCE := 0.2  # a town, not a city, falls
const CLASH_DISTANCE := 0.8  # in hex widths
const CLASH_IMMUNITY := 24.0  # hours a monster and an army leave each other alone after fighting

var monsters: Array[Dictionary] = []

var _civ: Civilization
var _map: VoronoiMap
var _roads: RoadNetwork
var _war: War
var _rng := RandomNumberGenerator.new()
var _cell_size := 1.0


func setup(civ: Civilization, map: VoronoiMap, roads: RoadNetwork, war: War, map_seed: int) -> void:
	_civ = civ
	_map = map
	_roads = roads
	_war = war
	_rng.seed = map_seed + 41
	_cell_size = civ.cell_size()
	monsters.clear()


func on_day(_total_days: int) -> void:
	for m in monsters.duplicate():
		m.age += 1
		if m.age >= MAX_DAYS:
			_leave(m, "%s wandered back into the wilds" % m.name)
	if monsters.is_empty() and _rng.randf() < PER_YEAR / (WorldClock.DAYS_PER_MONTH * WorldClock.MONTHS_PER_YEAR):
		_spawn()


func update(delta_hours: float) -> void:
	if monsters.is_empty() or delta_hours <= 0.0:
		return
	for m in monsters.duplicate():
		m.no_clash = maxf(m.no_clash - delta_hours, 0.0)
		if m.phase == &"ravaging":
			m.rest -= delta_hours
			if m.rest <= 0.0:
				_move_on(m)
		else:
			_march(m, delta_hours)
		if monsters.has(m):
			_check_clash(m)


# --- appearing and moving ------------------------------------------------

func _spawn() -> void:
	var wild := -1
	var best_gap := 0.0
	for attempt in SPAWN_TRIES:
		var c := _rng.randi() % _map.cells.size()
		if not _map.cells[c].is_land:
			continue
		var close := _nearest(c, [])
		if close < 0:
			continue
		var gap: float = _map.cells[c].site.distance_to(_map.cells[_civ.settlements[close].cell].site)
		if gap > best_gap:
			best_gap = gap
			wild = c
	if wild < 0:
		return
	var kind: StringName = &"horde" if _rng.randf() < 0.5 else &"giant"
	var range_: Vector2i = STRENGTH[kind]
	var m := {
		"kind": kind, "name": NAMES[kind][_rng.randi() % NAMES[kind].size()],
		"strength": _rng.randi_range(range_.x, range_.y), "targets_left": _rng.randi_range(RAMPAGE_TARGETS.x, RAMPAGE_TARGETS.y),
		"age": 0, "target": -1, "phase": &"marching", "rest": 0.0, "hit": [], "path": [wild, wild],
		"segment": 0, "progress": 0.0, "pos": _map.cells[wild].site, "no_clash": 0.0,
	}
	if not _set_course(m, wild):
		return
	monsters.append(m)
	var near := _nearest(wild, [])
	event_occurred.emit("%s sighted in the wilds near %s" % [m.name, _civ.settlements[near].name])


## Heads for the nearest settlement not yet attacked. False if none is reachable.
func _set_course(m: Dictionary, from: int) -> bool:
	var target := _nearest(from, m.hit)
	while target >= 0:
		var path := _roads.find_path(from, _civ.settlements[target].cell)
		if path.size() >= 2:
			m.target = target
			m.path = path
			m.segment = 0
			m.progress = 0.0
			m.phase = &"marching"
			return true
		m.hit.append(target)  # unreachable; try the next
		target = _nearest(from, m.hit)
	return false


## The living settlement nearest `cell` that isn't in `skip`, or -1. Only those
## on the same landmass count.
func _nearest(cell: int, skip: Array) -> int:
	var site: Vector2 = _map.cells[cell].site
	var best := -1
	var best_dist := INF
	for i in _civ.settlements.size():
		var s := _civ.settlements[i]
		if s.ruined or skip.has(i) or _roads.landmass[s.cell] != _roads.landmass[cell]:
			continue
		var d := site.distance_to(_map.cells[s.cell].site)
		if d < best_dist:
			best_dist = d
			best = i
	return best


func _march(m: Dictionary, delta_hours: float) -> void:
	var remaining := delta_hours
	while remaining > 0.0 and monsters.has(m):
		var needed: float = (1.0 - m.progress) * HOURS_PER_TILE
		if remaining < needed:
			m.progress += remaining / HOURS_PER_TILE
			remaining = 0.0
		else:
			remaining -= needed
			m.progress = 0.0
			m.segment += 1
			if m.segment >= m.path.size() - 1:
				m.pos = _map.cells[m.path[-1]].site
				_arrive(m)
				return
	if monsters.has(m):
		var a: Vector2 = _map.cells[m.path[m.segment]].site
		var b: Vector2 = _map.cells[m.path[m.segment + 1]].site
		m.pos = a.lerp(b, m.progress)


func _move_on(m: Dictionary) -> void:
	if m.targets_left <= 0 or not _set_course(m, m.path[-1]):
		_leave(m, "%s wandered back into the wilds" % m.name)


func _leave(m: Dictionary, text: String) -> void:
	monsters.erase(m)
	event_occurred.emit(text)


# --- fighting ------------------------------------------------------------

## The monster reaches its target and attacks it.
func _arrive(m: Dictionary) -> void:
	var t: int = m.target
	var s := _civ.settlements[t]
	m.hit.append(t)
	if s.ruined:
		_move_on(m)
		return
	m.targets_left -= 1
	var result := _war.roll_battle(m.strength, _war.militia(s.cell, s.faction))
	m.strength -= _monster_loss(m, result.attacker_loss)
	s.population = maxf(s.population - result.defender_loss, 1.0)
	if result.attacker_won:
		_ravage(m, t)
	else:
		_leave(m, "%s was beaten back from %s" % [m.name, s.name])
		return
	if m.strength <= 0:
		_slain(m)
		return
	m.phase = &"ravaging"
	m.rest = _rng.randf_range(REST_HOURS.x, REST_HOURS.y)
	# The owner calls out its army, which finds the monster still at the gates.
	if s.faction >= 0 and not s.ruined:
		_war.raise_defense(s.faction, s.cell, s.name)


func _ravage(m: Dictionary, t: int) -> void:
	var s := _civ.settlements[t]
	var killed := 0.0
	var before: float = s.population
	s.population = maxf(before * (1.0 - _rng.randf_range(POP_LOSS.x, POP_LOSS.y)), 1.0)
	killed = before - s.population
	var taken := 0
	for r: StringName in s.stock:
		var take := int(s.stock[r] * STOCK_LOSS)
		s.stock[r] -= take
		taken += take
	var text := "%s ravaged %s, killing %d and destroying %d goods" % [m.name, s.name, int(round(killed)), taken]
	if s.kind == &"town" and _rng.randf() < DESTROY_CHANCE:
		text += "; the town was destroyed"
		_civ.ruin_settlement(t)
		Production.assign_catchments(_map, _civ.settlements, _civ.cell_faction)
		towns_lost.emit()
	event_occurred.emit(text)


func _check_clash(m: Dictionary) -> void:
	if m.no_clash > 0.0:
		return
	for army in _war.armies.duplicate():
		if army.no_clash > 0.0 or army.routed or army.pos.distance_to(m.pos) > _cell_size * CLASH_DISTANCE:
			continue
		var result := _war.roll_battle(army.men, m.strength)
		army.men -= result.attacker_loss
		m.strength -= _monster_loss(m, result.defender_loss)
		army.no_clash = CLASH_IMMUNITY
		m.no_clash = CLASH_IMMUNITY
		var f: String = _civ.factions[army.faction].name
		if result.attacker_won:
			event_occurred.emit("The army of %s fought %s (%d men lost)" % [f, m.name, maxi(result.attacker_loss, 0)])
		else:
			event_occurred.emit("%s crushed the army of %s (%d men lost)" % [m.name, f, maxi(result.attacker_loss, 0)])
			army.routed = true
		if army.men <= 0:
			_war.disband(army)
		else:
			_war.retreat(army)
		if m.strength <= 0:
			_slain(m)
		elif result.attacker_won:
			_driven_off(m)
		return


func _monster_loss(m: Dictionary, loss: int) -> int:
	return int(round(loss * GIANT_TOUGHNESS)) if m.kind == &"giant" else loss


func _slain(m: Dictionary) -> void:
	_leave(m, "%s was slain" % m.name)


func _driven_off(m: Dictionary) -> void:
	if monsters.has(m):
		_leave(m, "%s was driven off" % m.name)


## Name of the settlement a monster is heading for or ravaging.
func target_name(m: Dictionary) -> String:
	return _civ.settlements[m.target].name
