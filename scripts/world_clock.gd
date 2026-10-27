class_name WorldClock
extends RefCounted
## In-world calendar (24-hour days, 12 months of 30 days). Feed it real time
## with advance(); it emits hour_passed every world hour and day_passed when
## a day rolls over. These are the hooks for anything that should change over
## time.

signal hour_passed
signal day_passed
signal week_passed  # every 7 world days, counted from the start

const HOURS_PER_DAY := 24
const DAYS_PER_MONTH := 30
const MONTHS_PER_YEAR := 12
## Cap per advance() call so a long frame at high speed can't stall the game.
const MAX_HOURS_PER_ADVANCE := 200

var year := 1
var month := 1
var day := 1
var hour := 0
var total_hours := 0  # hours elapsed since the start
var total_days := 0
var hours_per_second := 2.0
var paused := false
## World hours covered by the latest advance() call, for smooth movement.
var elapsed_hours := 0.0

var _accumulated := 0.0


func reset() -> void:
	year = 1
	month = 1
	day = 1
	hour = 0
	total_hours = 0
	total_days = 0
	_accumulated = 0.0


func advance(delta: float) -> void:
	elapsed_hours = 0.0
	if paused:
		return
	elapsed_hours = delta * hours_per_second
	_accumulated += delta * hours_per_second
	var steps := 0
	while _accumulated >= 1.0 and steps < MAX_HOURS_PER_ADVANCE:
		_accumulated -= 1.0
		_step_hour()
		steps += 1
	if steps == MAX_HOURS_PER_ADVANCE:
		_accumulated = 0.0


func date_text() -> String:
	return "Year %d  ·  Month %d  ·  Day %d  ·  %02d:00" % [year, month, day, hour]


## Compact date for log lines.
func short_text() -> String:
	return "Y%d M%d D%d" % [year, month, day]


func _step_hour() -> void:
	total_hours += 1
	hour += 1
	hour_passed.emit()
	if hour >= HOURS_PER_DAY:
		hour = 0
		day += 1
		if day > DAYS_PER_MONTH:
			day = 1
			month += 1
			if month > MONTHS_PER_YEAR:
				month = 1
				year += 1
		total_days += 1
		day_passed.emit()
		if total_days % 7 == 0:
			week_passed.emit()
