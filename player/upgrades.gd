class_name Upgrades
extends Node
## Permanent upgrades from treasure chests. Each one stacks; this node just
## counts the stacks and answers "what's my multiplier now?" for whoever applies
## it (the player for speed/health/resist, weapons for damage/fire rate/magazines,
## Vitals for stamina/regen).
##
## Stacks can be fractional: chests in later regions cost more and grant
## proportionally stronger upgrades (1.5 stacks, 2 stacks, ...), so a coin buys
## the same amount everywhere.

signal changed(id: StringName)

## id -> [name, what it does (%s = the amount), amount per stack]
const DEFS := {
	&"move_speed": ["Swiftness", "+%s%% movement speed", 5.0],
	&"damage": ["Power", "+%s%% damage with all weapons", 8.0],
	&"damage_resist": ["Toughness", "-%s%% damage taken", 6.0],
	&"magazine": ["Extended Magazines", "+%s%% magazine size", 15.0],
	&"fire_rate": ["Rapid Fire", "+%s%% fire rate", 6.0],
	&"max_health": ["Vitality", "+%s max health", 15.0],
	&"reload_speed": ["Quick Hands", "+%s%% reload speed", 8.0],
	&"max_stamina": ["Endurance", "+%s max stamina", 15.0],
	&"health_regen": ["Recovery", "+%s health regenerated per second", 2.0],
}

var _counts := {}


## Stacks held (may be fractional).
func count(id: StringName) -> float:
	return _counts.get(id, 0.0)


func add(id: StringName, stacks := 1.0) -> void:
	_counts[id] = count(id) + stacks
	changed.emit(id)


## Grants `stacks` of a random upgrade and returns its id.
func grant_random(stacks := 1.0) -> StringName:
	var id: StringName = DEFS.keys().pick_random()
	add(id, stacks)
	return id


## What you have in total: "Swiftness: +15% movement speed".
func describe(id: StringName) -> String:
	var total: float = DEFS[id][2] * count(id)
	if id == &"damage_resist":
		total = (1.0 - damage_taken_multiplier()) * 100.0  # compounds, so not just a sum
	return "%s: %s" % [DEFS[id][0], DEFS[id][1] % _number(total)]


## What `stacks` of it adds: "Swiftness: +7.5% movement speed".
func describe_gain(id: StringName, stacks: float) -> String:
	return "%s: %s" % [DEFS[id][0], DEFS[id][1] % _number(DEFS[id][2] * stacks)]


static func _number(value: float) -> String:
	return "%d" % roundi(value) if is_equal_approx(value, roundf(value)) else "%.1f" % value


func move_speed_multiplier() -> float:
	return 1.0 + 0.05 * count(&"move_speed")


func damage_multiplier() -> float:
	return 1.0 + 0.08 * count(&"damage")


## Multiplies damage the player takes: 6% less per stack, compounding (never reaches 0).
func damage_taken_multiplier() -> float:
	return pow(0.94, count(&"damage_resist"))


func magazine_multiplier() -> float:
	return 1.0 + 0.15 * count(&"magazine")


func fire_rate_multiplier() -> float:
	return 1.0 + 0.06 * count(&"fire_rate")


func reload_speed_multiplier() -> float:
	return 1.0 + 0.08 * count(&"reload_speed")


func bonus_health() -> float:
	return 15.0 * count(&"max_health")


func bonus_stamina() -> float:
	return 15.0 * count(&"max_stamina")


func bonus_health_regen() -> float:
	return 2.0 * count(&"health_regen")
