class_name War
extends RefCounted
## Wars between factions. Call setup() for a new world, on_day() once per world
## day and update() every frame with the world hours that passed.
##
## A faction that isn't at war may declare one on a neighbor it can reach by
## land, favoring weaker ones. A faction is in at most one war at a time, and
## at war it fields at most one army at a time. Each campaign, the army is
## raised from the towns nearest the enemy (each gives up to LEVY_MAX of its
## people, never dropping below KEEP_POPULATION), picks a target and marches
## there:
##  - capture: take an enemy hex bordering its own land (and any town on it)
##  - raid: loot an enemy settlement of part of its stock
## The target's defenders are a militia drawn from the nearest town's people.
## Armies of enemies that meet in the field fight too, and a beaten army
## retreats home. Survivors rejoin the towns that sent them, with any loot. Food
## for armies in the field is ignored for now.
##
## Equipping an army costs goods from the faction's towns, per man (see
## COST_PER_MAN), heavy on gold and ore. A faction that can't pay for the
## levy raises a smaller army, or none until it can.
##
## A battle is a die roll weighted by numbers: each side's men are scaled by a
## d6 (see BATTLE_SWING) and the higher total wins. The loser loses most of its
## men; the winner loses men in proportion to how close it was.
##
## Once a war has seen a few aggressive actions (battles), each day brings a
## chance of peace. If one side is clearly stronger (by population) the other
## pays tribute and may cede some hexes, otherwise it is a white peace. Wars
## also end after MAX_WAR_DAYS. Factions at war don't trade (see Traders).
##
## war: a, b (factions), start (day), actions (battles so far), limit (battles
##   before peace becomes likely)
## army: faction, enemy, men, levy (settlement -> men it gave), plunder
##   (resource -> int), goal {kind, cell, name}, phase (&"marching"/&"returning"),
##   path (cells), segment, progress (0..1), pos, no_clash (hours), routed
##   (fled a lost clash, so it avoids further fights on the way home)

signal status_changed  # a war began or ended, or territory changed hands
signal event_occurred(text: String)

const DECLARE_CHANCE := 0.004  # per day, scaled by the faction's aggression
const MAX_REACH_CELLS := 9.0  # nearest settlements must be within this many hex widths
const DECLARE_PAUSE := Vector2i(2, 5)  # days before the first army is raised
const CAMPAIGN_PAUSE := Vector2i(6, 14)  # days between an army coming home and the next
const LEVY_TOWNS := 3
const LEVY_MIN := 0.10
const LEVY_MAX := 0.20  # share of a town's people it may send
const KEEP_POPULATION := 30.0  # a town never levies below this
const MIN_ARMY := 15
## Goods to arm and equip one man, paid by the faction's towns, richest first.
const COST_PER_MAN := {
	&"gold": 0.3, &"ore": 0.25, &"wood": 0.1, &"textiles": 0.1, &"grain": 0.08, &"meat": 0.06,
}
const HOURS_PER_TILE := 30.0
const MILITIA_SHARE := {&"town": 0.12, &"city": 0.18}
const CAPITAL_BONUS := 1.5
const OPEN_FIELD_MILITIA := 0.05  # share of the nearest town's people defending bare land
const PLUNDER_SHARE := 0.25
const RAID_POP_LOSS := 0.04
const BATTLE_SWING := 0.15  # each point of the d6 above/below 3.5 changes a side's strength by this
const CLASH_DISTANCE := 0.8  # in hex widths
const CLASH_IMMUNITY := 24.0  # hours two armies leave each other alone after fighting
const BATTLES_BEFORE_PEACE := Vector2i(2, 4)
const PEACE_CHANCE := 0.15  # per day, once the battles are fought
const MAX_WAR_DAYS := 150
const TRUCE_DAYS := 120
const STRONG_RATIO := 1.25  # population ratio at which a winner can dictate terms
const TRIBUTE_SHARE := 0.25
const MAX_CEDED_CELLS := 3

var wars: Array[Dictionary] = []
var armies: Array[Dictionary] = []

var _civ: Civilization
var _map: VoronoiMap
var _roads: RoadNetwork
var _locations: Array[Dictionary]
var _rng := RandomNumberGenerator.new()
var _cell_size := 1.0
var _day := 0
var _aggression: Array[float] = []
var _pause: Array[int] = []  # day each faction may next raise an army
var _truce: Dictionary[int, int] = {}  # faction pair -> day its truce ends


func setup(civ: Civilization, map: VoronoiMap, roads: RoadNetwork, locations: Array[Dictionary], map_seed: int) -> void:
	_civ = civ
	_map = map
	_roads = roads
	_locations = locations
	_rng.seed = map_seed + 31
	_cell_size = civ.cell_size()
	_day = 0
	wars.clear()
	armies.clear()
	_truce.clear()
	_aggression.clear()
	_pause.clear()
	for f in civ.factions.size():
		_aggression.append(_rng.randf_range(0.5, 1.5))
		_pause.append(0)


func at_war(a: int, b: int) -> bool:
	if a < 0 or b < 0 or a == b:
		return false
	for w in wars:
		if (w.a == a and w.b == b) or (w.a == b and w.b == a):
			return true
	return false


## The faction `f` is fighting, or -1.
func enemy_of(f: int) -> int:
	for w in wars:
		if w.a == f:
			return w.b
		if w.b == f:
			return w.a
	return -1


func on_day(total_days: int) -> void:
	_day = total_days
	for i in range(wars.size() - 1, -1, -1):
		var w := wars[i]
		var done: bool = w.actions >= w.limit and _rng.randf() < PEACE_CHANCE
		if done or _day - w.start >= MAX_WAR_DAYS:
			_make_peace(i)
	for f in _civ.factions.size():
		var enemy := enemy_of(f)
		if enemy < 0:
			if _rng.randf() < DECLARE_CHANCE * _aggression[f]:
				_declare(f)
		elif _army_index(f) < 0 and _day >= _pause[f]:
			_raise_army(f, enemy)


## Moves every army forward by `delta_hours` of world time.
func update(delta_hours: float) -> void:
	if armies.is_empty() or delta_hours <= 0.0:
		return
	for army in armies.duplicate():
		army.no_clash = maxf(army.no_clash - delta_hours, 0.0)
		var remaining := delta_hours
		while remaining > 0.0 and armies.has(army):
			var needed: float = (1.0 - army.progress) * HOURS_PER_TILE
			if remaining < needed:
				army.progress += remaining / HOURS_PER_TILE
				remaining = 0.0
			else:
				remaining -= needed
				army.progress = 0.0
				army.segment += 1
				if army.segment >= army.path.size() - 1:
					_arrive(army)
					break
		if armies.has(army):
			_update_pos(army)
	_check_clashes()


# --- declaring and ending wars -------------------------------------------

func _declare(f: int) -> void:
	var options: Array[int] = []
	var weights: Array[float] = []
	var mine := _power(f)
	for g in _civ.factions.size():
		if g == f or enemy_of(g) >= 0 or _truce.get(_key(f, g), 0) > _day or not _within_reach(f, g):
			continue
		options.append(g)
		weights.append(clampf(mine / maxf(_power(g), 1.0), 0.3, 3.0))
	if options.is_empty():
		return
	var total := 0.0
	for w in weights:
		total += w
	var roll := _rng.randf() * total
	var target := options[-1]
	for k in options.size():
		roll -= weights[k]
		if roll <= 0.0:
			target = options[k]
			break
	wars.append({"a": f, "b": target, "start": _day, "actions": 0,
			"limit": _rng.randi_range(BATTLES_BEFORE_PEACE.x, BATTLES_BEFORE_PEACE.y)})
	_pause[f] = _day + _rng.randi_range(DECLARE_PAUSE.x, DECLARE_PAUSE.y)
	_pause[target] = _day + _rng.randi_range(DECLARE_PAUSE.x, DECLARE_PAUSE.y)
	event_occurred.emit("%s declared war on %s" % [_civ.factions[f].name, _civ.factions[target].name])
	status_changed.emit()


## Ends war number `index`. A clearly stronger side gets tribute and land.
func _make_peace(index: int) -> void:
	var w := wars[index]
	wars.remove_at(index)
	_truce[_key(w.a, w.b)] = _day + TRUCE_DAYS
	for army in armies.duplicate():
		if army.faction == w.a or army.faction == w.b:
			_recall(army)

	var pa := _power(w.a)
	var pb := _power(w.b)
	var a_name: String = _civ.factions[w.a].name
	var b_name: String = _civ.factions[w.b].name
	var winner: int = -1
	if pa >= pb * STRONG_RATIO:
		winner = w.a
	elif pb >= pa * STRONG_RATIO:
		winner = w.b
	if winner < 0:
		event_occurred.emit("%s and %s made peace" % [a_name, b_name])
	else:
		var loser: int = w.b if winner == w.a else w.a
		var ceded := _take_tribute_and_land(winner, loser)
		var text := "%s made peace with %s, which pays tribute" % [_civ.factions[winner].name, _civ.factions[loser].name]
		if ceded > 0:
			text += " and cedes %d %s" % [ceded, "hex" if ceded == 1 else "hexes"]
		event_occurred.emit(text)
	status_changed.emit()


## The loser hands a share of every town's stock to the winner's capital and
## gives up a few hexes bordering the winner. Returns the number of hexes.
func _take_tribute_and_land(winner: int, loser: int) -> int:
	var capital: Dictionary = _civ.settlements[_civ.factions[winner].capital]
	for i: int in _civ.factions[loser].settlements:
		var stock: Dictionary = _civ.settlements[i].stock
		for r: StringName in stock:
			var take := int(stock[r] * TRIBUTE_SHARE)
			stock[r] -= take
			capital.stock[r] += take

	var loser_capital_cell: int = _civ.settlements[_civ.factions[loser].capital].cell
	var options: Array[int] = []
	for i in _civ.cell_faction.size():
		if _civ.cell_faction[i] == loser and i != loser_capital_cell and _borders(i, winner):
			options.append(i)
	var home: Vector2 = _map.cells[capital.cell].site
	options.sort_custom(func(a: int, b: int) -> bool:
		return _map.cells[a].site.distance_squared_to(home) < _map.cells[b].site.distance_squared_to(home))
	var count := mini(_rng.randi_range(1, MAX_CEDED_CELLS), options.size())
	for k in count:
		_transfer(options[k], winner)
	if count > 0:
		Production.assign_catchments(_map, _civ.settlements, _civ.cell_faction)
	return count


# --- raising armies and choosing targets ---------------------------------

func _raise_army(f: int, enemy: int) -> void:
	_pause[f] = _day + 5  # if nothing comes of it, look again soon
	var enemy_towns: Array[int] = _civ.factions[enemy].settlements
	if enemy_towns.is_empty():
		return
	var towns: Array[int] = []
	towns.assign(_civ.factions[f].settlements)
	towns.sort_custom(func(a: int, b: int) -> bool: return _gap_to(a, enemy_towns) < _gap_to(b, enemy_towns))

	var levy: Dictionary[int, int] = {}
	var men := 0
	for s in towns.slice(0, LEVY_TOWNS):
		var pop: float = _civ.settlements[s].population
		var take := mini(int(pop * _rng.randf_range(LEVY_MIN, LEVY_MAX)), int(pop - KEEP_POPULATION))
		if take > 0:
			levy[s] = take
			men += take
	# Shrink the levy to what the faction can pay to equip.
	var affordable := _affordable_men(f)
	if men > affordable:
		for s in levy:
			levy[s] = int(levy[s] * float(affordable) / men)
		men = 0
		for s in levy:
			men += levy[s]
	if men < MIN_ARMY:
		return

	var start_cell: int = _civ.settlements[levy.keys()[0]].cell
	var goal := _pick_goal(f, enemy, men, start_cell)
	if goal.is_empty():
		return
	var path := _roads.find_path(start_cell, goal.cell)
	if path.size() < 2:
		return

	for s in levy:
		_civ.settlements[s].population -= levy[s]
	_pay(f, _equipment_cost(men))
	armies.append({
		"faction": f, "enemy": enemy, "men": men, "levy": levy, "plunder": {},
		"goal": goal, "phase": &"marching", "path": path, "segment": 0, "progress": 0.0,
		"pos": _map.cells[start_cell].site, "no_clash": 0.0, "routed": false,
	})
	var verb := "to take land near" if goal.kind == &"capture" else "to raid"
	event_occurred.emit("%s sent %d men %s %s" % [_civ.factions[f].name, men, verb, goal.name])


## The goods it takes to equip `men`.
func _equipment_cost(men: int) -> Dictionary[StringName, int]:
	var cost: Dictionary[StringName, int] = {}
	for r: StringName in COST_PER_MAN:
		cost[r] = ceili(COST_PER_MAN[r] * men)
	return cost


## The most men the faction's towns together could equip right now.
func _affordable_men(f: int) -> int:
	var most := 1000000
	for r: StringName in COST_PER_MAN:
		var held := 0
		for s: int in _civ.factions[f].settlements:
			held += _civ.settlements[s].stock[r]
		most = mini(most, int((held - 1) / COST_PER_MAN[r]))  # -1 leaves room for rounding up
	return maxi(most, 0)


## Takes the cost from the faction's towns, richest first per good.
func _pay(f: int, cost: Dictionary) -> void:
	for r: StringName in cost:
		var owners: Array[int] = []
		owners.assign(_civ.factions[f].settlements)
		owners.sort_custom(func(a: int, b: int) -> bool: return _civ.settlements[a].stock[r] > _civ.settlements[b].stock[r])
		var left: int = cost[r]
		for s in owners:
			var stock: Dictionary = _civ.settlements[s].stock
			var take := mini(left, stock[r])
			stock[r] -= take
			left -= take
			if left <= 0:
				break


## A capture target (an enemy hex bordering `f`) or a raid target (an enemy
## settlement), preferring valuable, lightly defended ones. Returns {} if the
## army can't reach any.
func _pick_goal(f: int, enemy: int, men: int, start_cell: int) -> Dictionary:
	var land: int = _roads.landmass[start_cell]
	var captures: Array[Dictionary] = []
	var raids: Array[Dictionary] = []
	var enemy_capital_cell: int = _civ.settlements[_civ.factions[enemy].capital].cell
	for i in _civ.cell_faction.size():
		if _civ.cell_faction[i] != enemy or _roads.landmass[i] != land or i == enemy_capital_cell:
			continue
		if _borders(i, f):
			var town := _settlement_at(i)
			captures.append(_goal(&"capture", i, men, 2.5 if town >= 0 else 1.0))
	for s: int in _civ.factions[enemy].settlements:
		var cell: int = _civ.settlements[s].cell
		if _roads.landmass[cell] != land:
			continue
		var wealth := 0
		for r: StringName in _civ.settlements[s].stock:
			wealth += _civ.settlements[s].stock[r]
		raids.append(_goal(&"raid", cell, men, 1.0 + minf(wealth / 300.0, 3.0)))

	var pool := captures
	if captures.is_empty() or (not raids.is_empty() and _rng.randf() < 0.5):
		pool = raids
	var best := {}
	var best_score := -INF
	for g in pool:
		if g.score > best_score:
			best_score = g.score
			best = g
	return best


func _goal(kind: StringName, cell: int, men: int, value: float) -> Dictionary:
	var owner := _civ.cell_faction[cell]
	var town := _settlement_at(cell)
	var label := "the border"
	if town >= 0:
		label = _civ.settlements[town].name
	else:
		var near := _nearest_settlement(cell, owner)
		if near >= 0:
			label = _civ.settlements[near].name
	var defense := _militia(cell, owner)
	return {"kind": kind, "cell": cell, "name": label,
			"score": value - 1.5 * defense / maxf(men, 1.0) + _rng.randf() * 0.4}


# --- fighting ------------------------------------------------------------

## Both sides roll a d6 that scales their strength; the higher total wins.
## Returns {attacker_won, attacker_loss, defender_loss}.
func _roll_battle(attackers: int, defenders: int) -> Dictionary:
	var a := attackers * (1.0 + BATTLE_SWING * (_rng.randi_range(1, 6) - 3.5))
	var d := defenders * (1.0 + BATTLE_SWING * (_rng.randi_range(1, 6) - 3.5))
	var attacker_won := a > d
	var closeness := minf(minf(a, d) / maxf(maxf(a, d), 1.0), 1.0)
	var winner_men := attackers if attacker_won else defenders
	var loser_men := defenders if attacker_won else attackers
	var winner_loss := int(round(winner_men * closeness * 0.5))
	var loser_loss := int(round(loser_men * _rng.randf_range(0.6, 0.9)))
	return {
		"attacker_won": attacker_won,
		"attacker_loss": winner_loss if attacker_won else loser_loss,
		"defender_loss": loser_loss if attacker_won else winner_loss,
	}


## Defenders at a hex: the settlement's militia, or a thin screen drawn from
## the nearest town of the owner.
func _militia(cell: int, faction: int) -> int:
	var town := _settlement_at(cell)
	if town >= 0:
		var s := _civ.settlements[town]
		var share: float = MILITIA_SHARE[s.kind] * (CAPITAL_BONUS if s.is_capital else 1.0)
		return int(s.population * share)
	var near := _nearest_settlement(cell, faction)
	return int(_civ.settlements[near].population * OPEN_FIELD_MILITIA) if near >= 0 else 0


func _arrive(army: Dictionary) -> void:
	if army.phase == &"returning":
		_come_home(army)
		return
	var f: int = army.faction
	var enemy: int = army.enemy
	var goal: Dictionary = army.goal
	var war_index := _war_index(f)
	var town := _settlement_at(goal.cell)
	var still_there: bool = _civ.cell_faction[goal.cell] == enemy and (goal.kind == &"capture" or (town >= 0 and _civ.settlements[town].faction == enemy))
	if still_there:
		var result := _roll_battle(army.men, _militia(goal.cell, enemy))
		if war_index >= 0:
			wars[war_index].actions += 1
		army.men -= result.attacker_loss
		var local := town if town >= 0 else _nearest_settlement(goal.cell, enemy)
		if local >= 0:
			_civ.settlements[local].population = maxf(_civ.settlements[local].population - result.defender_loss, 1.0)
		var fname: String = _civ.factions[f].name
		if result.attacker_won:
			if goal.kind == &"capture":
				_civ.claim_cell(goal.cell, f)
				for loc in _locations:
					if loc.cell == goal.cell:
						loc.faction = f
				Production.assign_catchments(_map, _civ.settlements, _civ.cell_faction)
				event_occurred.emit("%s captured %s" % [fname, goal.name] if town >= 0 else "%s seized land near %s" % [fname, goal.name])
				status_changed.emit()
			else:
				event_occurred.emit("%s raided %s, carrying off %d goods" % [fname, goal.name, _plunder(army, town)])
		else:
			event_occurred.emit("%s's army was beaten at %s, losing %d men" % [fname, goal.name, result.attacker_loss])
	if army.men <= 0:
		_disband(army)
	else:
		_retreat(army)


## Loots a share of the settlement's stock. Returns the number of goods.
func _plunder(army: Dictionary, town: int) -> int:
	var s := _civ.settlements[town]
	var total := 0
	for r: StringName in s.stock:
		var take := int(s.stock[r] * PLUNDER_SHARE)
		s.stock[r] -= take
		army.plunder[r] = army.plunder.get(r, 0) + take
		total += take
	s.population = maxf(s.population * (1.0 - RAID_POP_LOSS), 1.0)
	return total


## Fights between enemy armies that meet in the field.
func _check_clashes() -> void:
	for i in armies.size():
		for j in range(i + 1, armies.size()):
			if i >= armies.size() or j >= armies.size():
				return
			var a := armies[i]
			var b := armies[j]
			if not at_war(a.faction, b.faction) or a.no_clash > 0.0 or b.no_clash > 0.0 or a.routed or b.routed:
				continue
			if a.pos.distance_to(b.pos) > _cell_size * CLASH_DISTANCE:
				continue
			_clash(a, b)
			return  # the list may have changed; further clashes wait for the next frame


func _clash(a: Dictionary, b: Dictionary) -> void:
	var result := _roll_battle(a.men, b.men)
	var war_index := _war_index(a.faction)
	if war_index >= 0:
		wars[war_index].actions += 1
	a.men -= result.attacker_loss
	b.men -= result.defender_loss
	a.no_clash = CLASH_IMMUNITY
	b.no_clash = CLASH_IMMUNITY
	var winner := a if result.attacker_won else b
	var loser := b if result.attacker_won else a
	for r: StringName in loser.plunder:
		winner.plunder[r] = winner.plunder.get(r, 0) + loser.plunder[r]
	loser.plunder = {}
	event_occurred.emit("The armies of %s and %s clashed; %s won (%d and %d men lost)" % [
			_civ.factions[a.faction].name, _civ.factions[b.faction].name, _civ.factions[winner.faction].name,
			maxi(result.attacker_loss, 0), maxi(result.defender_loss, 0)])
	for army in [loser, winner]:
		if army.men <= 0:
			_disband(army)
	if loser.men > 0:
		loser.routed = true
		_retreat(loser)


# --- moving and returning ------------------------------------------------

## Turns the army around toward the nearest of its faction's towns.
func _retreat(army: Dictionary) -> void:
	var from: int = army.path[army.segment]
	var home := _nearest_settlement(from, army.faction)
	var path: Array[int] = []
	if home >= 0:
		path = _roads.find_path(from, _civ.settlements[home].cell)
	army.phase = &"returning"
	if path.size() < 2:
		_come_home(army)
		return
	army.path = path
	army.segment = 0
	army.progress = 0.0


## Called when the war ends: armies in the field head home.
func _recall(army: Dictionary) -> void:
	if army.phase != &"returning":
		_retreat(army)


## The army reaches home: survivors rejoin the towns that sent them, with the
## loot going to the first of those towns still held.
func _come_home(army: Dictionary) -> void:
	var f: int = army.faction
	var origins: Array[int] = []
	var sent := 0
	for s: int in army.levy:
		if _civ.settlements[s].faction == f and not _civ.settlements[s].ruined:
			origins.append(s)
			sent += army.levy[s]
	if origins.is_empty():
		origins.append(_civ.factions[f].capital)
		sent = 1
		army.levy = {origins[0]: 1}
	var left: int = army.men
	for s in origins:
		var share := mini(int(round(float(army.men) * army.levy[s] / sent)), left)
		_civ.settlements[s].population += share
		left -= share
	_civ.settlements[origins[0]].population += left
	for r: StringName in army.plunder:
		_civ.settlements[origins[0]].stock[r] += army.plunder[r]
	armies.erase(army)
	_pause[f] = _day + _rng.randi_range(CAMPAIGN_PAUSE.x, CAMPAIGN_PAUSE.y)


## An army wiped out in battle: nobody comes home.
func _disband(army: Dictionary) -> void:
	armies.erase(army)
	_pause[army.faction] = _day + _rng.randi_range(CAMPAIGN_PAUSE.x, CAMPAIGN_PAUSE.y)
	event_occurred.emit("The army of %s was destroyed" % _civ.factions[army.faction].name)


func cell_site(cell: int) -> Vector2:
	return _map.cells[cell].site


func _update_pos(army: Dictionary) -> void:
	var a: Vector2 = _map.cells[army.path[army.segment]].site
	var b: Vector2 = _map.cells[army.path[army.segment + 1]].site
	army.pos = a.lerp(b, army.progress)


# --- helpers -------------------------------------------------------------

func _army_index(f: int) -> int:
	for i in armies.size():
		if armies[i].faction == f:
			return i
	return -1


func _war_index(f: int) -> int:
	for i in wars.size():
		if wars[i].a == f or wars[i].b == f:
			return i
	return -1


func _key(a: int, b: int) -> int:
	return mini(a, b) * 1000 + maxi(a, b)


## A faction's strength: the people in its towns.
func _power(f: int) -> float:
	var total := 0.0
	for s: int in _civ.factions[f].settlements:
		total += _civ.settlements[s].population
	return total


func _within_reach(f: int, g: int) -> bool:
	var reach := _cell_size * MAX_REACH_CELLS
	for a: int in _civ.factions[f].settlements:
		var ca: int = _civ.settlements[a].cell
		for b: int in _civ.factions[g].settlements:
			var cb: int = _civ.settlements[b].cell
			if _roads.landmass[ca] == _roads.landmass[cb] and _map.cells[ca].site.distance_to(_map.cells[cb].site) <= reach:
				return true
	return false


## Distance from a settlement to the closest of `others`.
func _gap_to(settlement: int, others: Array[int]) -> float:
	var site: Vector2 = _map.cells[_civ.settlements[settlement].cell].site
	var best := INF
	for o in others:
		best = minf(best, site.distance_to(_map.cells[_civ.settlements[o].cell].site))
	return best


## Living settlement on a cell, or -1.
func _settlement_at(cell: int) -> int:
	for i in _civ.settlements.size():
		if _civ.settlements[i].cell == cell and not _civ.settlements[i].ruined:
			return i
	return -1


## The faction's settlement nearest a cell, or -1.
func _nearest_settlement(cell: int, faction: int) -> int:
	if faction < 0:
		return -1
	var site: Vector2 = _map.cells[cell].site
	var best := -1
	var best_dist := INF
	for s: int in _civ.factions[faction].settlements:
		var d := site.distance_to(_map.cells[_civ.settlements[s].cell].site)
		if d < best_dist:
			best_dist = d
			best = s
	return best


## Whether a cell touches land owned by `faction`.
func _borders(cell: int, faction: int) -> bool:
	for nb: int in _map.cells[cell].neighbors:
		if _civ.cell_faction[nb] == faction:
			return true
	return false


func _transfer(cell: int, faction: int) -> void:
	_civ.claim_cell(cell, faction)
	for loc in _locations:
		if loc.cell == cell:
			loc.faction = faction
