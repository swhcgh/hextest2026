class_name History
extends RefCounted
## Daily record of every faction's and settlement's stock, for analysis tools.
## Call reset() for a new world, then record() once per world day.
##
## days: world day of each sample (one per day, so sample i is days[i])
## Factions are fixed for a world; their totals cover all their settlements.
## Settlements can be founded later, so each keeps the index of its first sample.

var days := PackedInt32Array()

var _factions: Array[Dictionary] = []  # per faction: resource -> PackedInt32Array
var _towns: Array[Dictionary] = []  # per settlement: {"start": int, resource: PackedInt32Array}


func reset() -> void:
	days.clear()
	_factions.clear()
	_towns.clear()


func record(civ: Civilization, total_days: int) -> void:
	while _factions.size() < civ.factions.size():
		_factions.append(_blank())
	while _towns.size() < civ.settlements.size():
		var town := _blank()
		town["start"] = days.size()
		_towns.append(town)

	var totals: Array[Dictionary] = []
	for f in civ.factions.size():
		totals.append({})
	for i in civ.settlements.size():
		var s := civ.settlements[i]
		for r in TownResources.RESOURCES:
			_towns[i][r].append(s.stock[r])
			if s.faction >= 0:
				totals[s.faction][r] = totals[s.faction].get(r, 0) + s.stock[r]
	for f in civ.factions.size():
		for r in TownResources.RESOURCES:
			_factions[f][r].append(totals[f].get(r, 0))
	days.append(total_days)


## One line per faction: its total stock of `resource`.
## Each line is {name, color, start, values}; `start` indexes into `days`.
func faction_series(civ: Civilization, resource: StringName) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	for f in mini(civ.factions.size(), _factions.size()):
		result.append({
			"name": civ.factions[f].name,
			"color": civ.factions[f].color,
			"start": 0,
			"values": _factions[f][resource],
		})
	return result


## One line per settlement of `faction` (-1 for independent ones).
func town_series(civ: Civilization, faction: int, resource: StringName) -> Array[Dictionary]:
	var members: Array[int] = []
	for i in mini(civ.settlements.size(), _towns.size()):
		if civ.settlements[i].faction == faction:
			members.append(i)
	var result: Array[Dictionary] = []
	for n in members.size():
		var i := members[n]
		result.append({
			"name": civ.settlements[i].name,
			"color": Color.from_hsv(float(n) / members.size(), 0.6, 0.95),
			"start": _towns[i].start,
			"values": _towns[i][resource],
		})
	return result


func _blank() -> Dictionary:
	var d := {}
	for r in TownResources.RESOURCES:
		d[r] = PackedInt32Array()
	return d
