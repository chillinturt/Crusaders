class_name Skills
extends Node
## XP and levels for what the player gets better at, all trained by doing:
## fitness (moving), strength (melee), aiming (shooting) and explosives (blasts).
## Effects are read by whoever cares (Vitals for stamina, weapons for damage...).

signal leveled_up(skill: StringName, new_level: int)

const MAX_LEVEL := 20
const SKILLS := {
	&"fitness": "Fitness",
	&"strength": "Strength",
	&"aiming": "Aiming",
	&"explosives": "Explosives",
}
const DESCRIPTIONS := {
	&"fitness": "Max stamina, stamina regen and max health. Trained by jumping and moving.",
	&"strength": "Melee damage, swing speed and max health. Trained by melee hits and deflections.",
	&"aiming": "Gun damage, accuracy, reload speed and portal gun range. Trained by shooting enemies.",
	&"explosives": "Explosion damage, blast radius and knockback, and less damage from your own blasts. Trained by blowing up enemies.",
}

var _xp := {}


func _ready() -> void:
	for id in SKILLS:
		_xp[id] = 0.0


## Total XP needed to reach a level: 20, 60, 120, 200, ... (level 1 is free).
static func xp_for_level(lvl: int) -> float:
	return 10.0 * (lvl - 1) * lvl


func xp(skill: StringName) -> float:
	return _xp[skill]


func level(skill: StringName) -> int:
	var lvl := 1
	while lvl < MAX_LEVEL and _xp[skill] >= xp_for_level(lvl + 1):
		lvl += 1
	return lvl


## 0..1 progress toward the next level (1 at max level).
func progress(skill: StringName) -> float:
	var lvl := level(skill)
	if lvl >= MAX_LEVEL:
		return 1.0
	var start := xp_for_level(lvl)
	return (_xp[skill] - start) / (xp_for_level(lvl + 1) - start)


func add_xp(skill: StringName, amount: float) -> void:
	if not _xp.has(skill) or amount <= 0.0:
		return
	var before := level(skill)
	_xp[skill] += amount
	var after := level(skill)
	if after > before:
		leveled_up.emit(skill, after)


# --- Stat effects (level 1 = no bonus) ----------------------------------------

func bonus_levels(skill: StringName) -> int:
	return level(skill) - 1


## Multiplies melee damage: +6% per strength level.
func melee_damage_multiplier() -> float:
	return 1.0 + 0.06 * bonus_levels(&"strength")


## Divides melee windup/recovery: +4% swing speed per strength level.
func swing_speed_multiplier() -> float:
	return 1.0 + 0.04 * bonus_levels(&"strength")


## Multiplies gun damage: +5% per aiming level.
func aim_damage_multiplier() -> float:
	return 1.0 + 0.05 * bonus_levels(&"aiming")


## Multiplies gun spread: 10% tighter with each aiming level (level 10 = 39% of
## the base spread, level 20 = 14%). Compounding, so it never reaches zero.
func aim_spread_multiplier() -> float:
	return pow(0.9, bonus_levels(&"aiming"))


## Divides reload time: +5% reload speed per aiming level.
func reload_speed_multiplier() -> float:
	return 1.0 + 0.05 * bonus_levels(&"aiming")


## Multiplies how far away the portal gun can place a doorway: +5% per aiming level.
func portal_range_multiplier() -> float:
	return 1.0 + 0.05 * bonus_levels(&"aiming")


## Multiplies the damage of explosions you cause: +6% per explosives level.
func blast_damage_multiplier() -> float:
	return 1.0 + 0.06 * bonus_levels(&"explosives")


## Multiplies blast radius: +4% per explosives level.
func blast_radius_multiplier() -> float:
	return 1.0 + 0.04 * bonus_levels(&"explosives")


## Multiplies blast knockback (on enemies and on you: bigger rocket jumps): +5% per level.
func blast_force_multiplier() -> float:
	return 1.0 + 0.05 * bonus_levels(&"explosives")


## Multiplies the damage your own explosions do to you: -5% per level.
func blast_self_damage_multiplier() -> float:
	return 1.0 - 0.05 * bonus_levels(&"explosives")


## Added to the player's base max health: +5 per fitness and per strength level.
func bonus_health() -> float:
	return 5.0 * (bonus_levels(&"fitness") + bonus_levels(&"strength"))
