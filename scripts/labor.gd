class_name Labor
extends RefCounted
## How a settlement's people are split between producing each good.
##
## settlement.labor: resource -> share of the population working on it (sums
## to 1). A town's output of a good is what its land yields (see Production)
## x its share x the number of goods x its population relative to a typical
## settlement of its kind. So an even split at the reference population yields
## exactly the land's raw income, and putting more hands on a good makes more
## of it at the cost of the others.
##
## Every REVIEW_DAYS (each settlement on its own day, so towns don't all shift
## at once) a settlement re-plans: it works out what it needs made per day to
## cover its upkeep and rebuild its stock toward a target, assigns hands to
## those goods (food first, since people starve without it), spreads any
## spare hands over what its land is good at, and moves part of the way there.

const REVIEW_DAYS := 30
const REFERENCE_POPULATION := {&"city": 180.0, &"town": 100.0}
const STOCK_TARGET_DAYS := 30.0  # days of upkeep a settlement wants in store
const CATCH_UP_DAYS := 30.0  # time over which it tries to close a gap to that target
const FOOD_MARGIN := 1.25  # extra food planned for winter and spoilage
const FOOD_CAP := 0.85  # most hands that may go to food
const OTHER_CAP := 0.25  # most hands one non-food good may claim; scarce goods are better traded for
const ADJUST := 0.6  # how far toward the new plan each review moves


static func even() -> Dictionary[StringName, float]:
	var shares: Dictionary[StringName, float] = {}
	for r in TownResources.RESOURCES:
		shares[r] = 1.0 / TownResources.RESOURCES.size()
	return shares


## Multiplier on the land's raw yield of `r` for this settlement's workforce.
static func output_factor(s: Dictionary, r: StringName) -> float:
	return s.labor[r] * TownResources.RESOURCES.size() * s.population / REFERENCE_POPULATION[s.kind]


## Whether the settlement re-plans today.
static func review_due(index: int, total_days: int) -> bool:
	return total_days % REVIEW_DAYS == (index * 7) % REVIEW_DAYS


## Re-plans the split. `raw` is the settlement's raw daily yield per good.
static func review(s: Dictionary, raw: Dictionary) -> void:
	var count := TownResources.RESOURCES.size()
	var scale: float = s.population / REFERENCE_POPULATION[s.kind]
	var full: Dictionary[StringName, float] = {}  # daily output if everyone made it
	var producible := 0.0
	for r in TownResources.RESOURCES:
		full[r] = raw[r] * count * scale
		producible += full[r]
	if producible <= 0.0:
		return

	# What it wants made per day: upkeep plus closing the gap to its target stock.
	var food: float = s.population * Upkeep.FOOD_PER_PERSON * FOOD_MARGIN
	var food_land: float = raw[&"grain"] + raw[&"meat"]
	var needed: Dictionary[StringName, float] = {}
	var total := 0.0
	var food_total := 0.0
	for r in TownResources.RESOURCES:
		var upkeep: float
		if r == &"grain" or r == &"meat":
			upkeep = food * raw[r] / food_land if food_land > 0.0 else 0.0
		elif r == &"gold":
			upkeep = maxf(Upkeep.daily_need(s, r) - Production.BASE_GOLD[s.kind], 0.0)  # taxes cover the rest
		else:
			upkeep = Upkeep.daily_need(s, r)
		var gap: float = (upkeep * STOCK_TARGET_DAYS - s.stock[r]) / CATCH_UP_DAYS
		var want: float = maxf(upkeep + gap, upkeep * 0.25)
		needed[r] = want / full[r] if full[r] > 0.0 else 0.0
		if r != &"grain" and r != &"meat":
			needed[r] = minf(needed[r], OTHER_CAP)
		total += needed[r]
		if r == &"grain" or r == &"meat":
			food_total += needed[r]

	var plan: Dictionary[StringName, float] = {}
	if total > 1.0:
		# Too much to do: food gets its share (up to a cap), the rest is squeezed.
		var food_share := minf(food_total, FOOD_CAP)
		var other_total := total - food_total
		var room := 1.0 - food_share
		for r in TownResources.RESOURCES:
			if r == &"grain" or r == &"meat":
				plan[r] = needed[r] * food_share / food_total if food_total > 0.0 else 0.0
			else:
				plan[r] = needed[r] * room / other_total if other_total > 0.0 else 0.0
	else:
		# Spare hands go where the land is richest, which also builds trade goods.
		var spare := 1.0 - total
		for r in TownResources.RESOURCES:
			plan[r] = needed[r] + spare * full[r] / producible

	for r in TownResources.RESOURCES:
		s.labor[r] = lerpf(s.labor[r], plan[r], ADJUST)


## The largest shares as popup text, e.g. "Grain 40%   Meat 25%   Wood 15%".
static func lines(labor: Dictionary) -> Array[String]:
	var order: Array[StringName] = []
	order.assign(TownResources.RESOURCES)
	order.sort_custom(func(a: StringName, b: StringName) -> bool: return labor[a] > labor[b])
	var parts: Array[String] = []
	for r in order:
		if labor[r] >= 0.05:
			parts.append("%s %d%%" % [String(r).capitalize(), roundi(labor[r] * 100.0)])
	var result: Array[String] = []
	for i in range(0, parts.size(), 3):
		result.append("   ".join(PackedStringArray(parts.slice(i, i + 3))))
	return result
