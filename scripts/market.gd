class_name Market
extends RefCounted
## What goods are worth to the player. Every settlement has a price per trade
## good (settlement.prices, fractional gold), reset each week from how scarce
## the good is there: the town's stock compared with what a settlement of its
## size typically holds in this world. Scarce goods cost more, plentiful ones
## less. Gold is the currency, not a trade good.

const TRADE_GOODS: Array[StringName] = [&"grain", &"meat", &"wood", &"textiles", &"ore"]
## Gold value of a unit at typical stock.
const BASE_VALUE := {&"grain": 1.0, &"meat": 2.0, &"wood": 2.0, &"textiles": 3.0, &"ore": 4.0}
const SELL_FACTOR := 0.85  # what a town pays, as a share of what it charges
const MIN_REFERENCE := 5.0  # typical stock is never taken as less than this
const PRICE_RANGE := Vector2(0.4, 3.0)  # multiplier on the base value


## Reprices every living settlement.
static func update_all(settlements: Array[Dictionary]) -> void:
	var living: Array[Dictionary] = []
	var mean_pop := 0.0
	var mean_stock: Dictionary[StringName, float] = {}
	for r in TRADE_GOODS:
		mean_stock[r] = 0.0
	for s in settlements:
		if s.ruined:
			continue
		living.append(s)
		mean_pop += s.population
		for r in TRADE_GOODS:
			mean_stock[r] += s.stock[r]
	if living.is_empty():
		return
	mean_pop /= living.size()
	for r in TRADE_GOODS:
		mean_stock[r] /= living.size()

	for s in living:
		var size_factor := clampf(s.population / maxf(mean_pop, 1.0), 0.5, 2.0)
		var prices: Dictionary[StringName, float] = {}
		for r in TRADE_GOODS:
			var typical := maxf(mean_stock[r] * size_factor, MIN_REFERENCE)
			var scarcity := sqrt(typical / maxf(s.stock[r], 1.0))
			prices[r] = snappedf(BASE_VALUE[r] * clampf(scarcity, PRICE_RANGE.x, PRICE_RANGE.y), 0.01)
		s["prices"] = prices


## What the settlement charges for one unit.
static func buy_price(s: Dictionary, r: StringName) -> float:
	return s.get("prices", {}).get(r, BASE_VALUE[r])


## What the settlement pays for one unit.
static func sell_price(s: Dictionary, r: StringName) -> float:
	return snappedf(buy_price(s, r) * SELL_FACTOR, 0.01)


## Prices as popup text, three goods per line.
static func lines(s: Dictionary) -> Array[String]:
	var parts: Array[String] = []
	for r in TRADE_GOODS:
		parts.append("%s %.2f" % [String(r).capitalize(), buy_price(s, r)])
	var result: Array[String] = []
	for i in range(0, parts.size(), 3):
		result.append("   ".join(PackedStringArray(parts.slice(i, i + 3))))
	return result
