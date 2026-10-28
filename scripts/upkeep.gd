class_name Upkeep
extends RefCounted
## Ongoing costs that drain every settlement's stock, so supply rises and falls
## instead of only piling up. Food and fuel are eaten by the population (fuel
## by the cold), stored food spoils, and officials and tools cost gold and
## ore. Harvests follow the seasons, so winter is when shortages bite.
## Tune the constants below to change how tight things get.
##
## Shortfalls shrink the population; when it recovers, so does demand.
## settlement.owed holds fractional costs carried between days, like
## settlement.carry does for income.

const SEASON_NAMES: Array[String] = ["Winter", "Spring", "Summer", "Autumn"]
const FOOD_PER_PERSON := 0.006  # grain + meat per person per day
const FUEL_PER_PERSON := 0.004  # wood per person per day at the coldest
const CLOTH_PER_PERSON := 0.0008
const GOLD_UPKEEP := {&"city": 0.3, &"town": 0.1}  # officials and guards
const GOLD_PER_PERSON := 0.0006
const ORE_UPKEEP := 0.03  # tool wear, per settlement
const SPOILAGE := {&"grain": 0.002, &"meat": 0.01}  # share of stock lost per day
const SEASON_SWING := 0.6  # harvests run from 1 - this (winter) to 1 + this (summer)
const FOOD_STARVE_RATE := 0.01  # share of population lost per day, at total shortfall
const FUEL_STARVE_RATE := 0.003
const STARVING_BELOW := 0.9  # fed share under which a settlement counts as in shortage


## -1 at midwinter (day 0 of the year) to +1 at midsummer.
static func season(total_days: int) -> float:
	var days_per_year := WorldClock.DAYS_PER_MONTH * WorldClock.MONTHS_PER_YEAR
	return -cos(TAU * float(total_days % days_per_year) / days_per_year)


## Position in the year: 0 at midwinter, 0.25 spring's peak, 0.5 midsummer,
## 0.75 autumn's peak, back to 1 (= 0) at the next midwinter.
static func year_phase(total_days: int) -> float:
	var days_per_year := WorldClock.DAYS_PER_MONTH * WorldClock.MONTHS_PER_YEAR
	return float(total_days % days_per_year) / days_per_year


## Winter, Spring, Summer or Autumn. Each season is centered on its phase.
static func season_name(total_days: int) -> String:
	var phase := year_phase(total_days)
	return SEASON_NAMES[int(floor(phase * 4.0 + 0.5)) % 4]


## Multiplier on farmed goods (grain, meat) for the time of year.
static func harvest_factor(total_days: int) -> float:
	return 1.0 + SEASON_SWING * season(total_days)


## What a settlement uses of a good per day, on average over the year. Goods
## nothing consumes still get a small stand-in so traders can trade them.
static func daily_need(s: Dictionary, r: StringName) -> float:
	var pop: float = s.population
	match r:
		&"grain", &"meat":
			return pop * FOOD_PER_PERSON * 0.5
		&"wood":
			return pop * FUEL_PER_PERSON * 0.5
		&"textiles":
			return pop * CLOTH_PER_PERSON
		&"gold":
			return GOLD_UPKEEP[s.kind] + pop * GOLD_PER_PERSON
		&"ore":
			return ORE_UPKEEP
	return 0.0


## One day of upkeep for every settlement. Returns log lines for settlements
## that just fell into, or recovered from, a food shortage.
static func apply_daily(settlements: Array[Dictionary], total_days: int) -> Array[String]:
	var cold := (1.0 - season(total_days)) * 0.5  # 0 summer .. 1 winter
	var events: Array[String] = []
	for s in settlements:
		if s.ruined:
			continue
		if not s.has("owed"):
			s["owed"] = {}
		var owed: Dictionary = s.owed
		var pop: float = s.population

		# Perishables rot, which also caps how much a town can hoard.
		for r: StringName in SPOILAGE:
			_take(s, owed, r, s.stock[r] * SPOILAGE[r])

		var fed := _eat(s, owed, pop * FOOD_PER_PERSON)
		var warm := _take(s, owed, &"wood", pop * FUEL_PER_PERSON * cold)
		_take(s, owed, &"textiles", pop * CLOTH_PER_PERSON)
		_take(s, owed, &"gold", GOLD_UPKEEP[s.kind] + pop * GOLD_PER_PERSON)
		_take(s, owed, &"ore", ORE_UPKEEP)

		s.population = maxf(pop * (1.0 - (1.0 - fed) * FOOD_STARVE_RATE - (1.0 - warm) * FUEL_STARVE_RATE), 1.0)
		s["fed"] = fed
		var starving: bool = fed < STARVING_BELOW
		if starving != s.get("starving", false):
			s["starving"] = starving
			events.append("%s is short of food" % s.name if starving else "%s has food again" % s.name)
	return events


## Eats the day's food from grain and meat, whichever is more plentiful
## first. Returns the share of the need that was met.
static func _eat(s: Dictionary, owed: Dictionary, amount: float) -> float:
	var first: StringName = &"grain" if s.stock[&"grain"] >= s.stock[&"meat"] else &"meat"
	var second: StringName = &"meat" if first == &"grain" else &"grain"
	owed[&"food"] = owed.get(&"food", 0.0) + amount
	var due := int(owed[&"food"])
	var paid := mini(due, s.stock[first])
	s.stock[first] -= paid
	var from_second := mini(due - paid, s.stock[second])
	s.stock[second] -= from_second
	paid += from_second
	owed[&"food"] = minf(owed[&"food"] - paid, 1.0)  # a missed meal isn't a debt
	return 1.0 if due == 0 else float(paid) / due


## Takes a fractional cost in whole units as it accrues. Unmet costs are
## forgiven rather than piling up as debt. Returns the share that was paid
## (1 when nothing was due yet).
static func _take(s: Dictionary, owed: Dictionary, r: StringName, amount: float) -> float:
	owed[r] = owed.get(r, 0.0) + amount
	var due := int(owed[r])
	if due <= 0:
		return 1.0
	var paid := mini(due, s.stock[r])
	s.stock[r] -= paid
	owed[r] = minf(owed[r] - paid, 1.0)
	return float(paid) / due
