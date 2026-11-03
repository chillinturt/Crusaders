extends Node
## Stamina, gas and health regeneration for the Player (its parent). Health
## itself stays on the Player; this calls player.heal().

@export_group("Stamina")
## At Fitness 1. Each Fitness level adds 10.
@export var base_max_stamina := 100.0
## Per second, at Fitness 1. Each Fitness level adds 8%.
@export var base_stamina_regen := 30.0
## Regen only starts this long after spending, and only on the ground,
## so a bhop chain drains you instead of paying for itself.
@export var stamina_regen_delay := 0.5
## Emptying the bar makes you exhausted (no jumping, slower on foot)
## until it refills to this fraction.
@export var exhausted_recover_fraction := 0.3

@export_group("Gas")
## Everyone has a gas pack: Shift burns it for thrust (see Player and GrappleGear).
@export var max_gas := 100.0
@export var gas_per_second := 20.0
## Gas regained per second, starting gas_regen_delay after you stop burning.
@export var gas_regen := 16.0
@export var gas_regen_delay := 1.2

@export_group("Health regen")
## Health starts coming back this long after you last took damage...
@export var health_regen_delay := 6.0
## ...at this many points per second.
@export var health_regen := 8.0

var stamina: float
var gas: float
var exhausted := false
var _since_gas := 0.0
var _regen_wait := 0.0
var _since_damage := 0.0

@onready var player: Node = get_parent()


func _ready() -> void:
	stamina = base_max_stamina
	gas = max_gas


func _physics_process(delta: float) -> void:
	_regen_wait -= delta
	if _regen_wait <= 0.0 and player.is_on_floor():
		stamina = minf(stamina + stamina_regen() * delta, max_stamina())
		if exhausted and stamina >= max_stamina() * exhausted_recover_fraction:
			exhausted = false

	_since_gas += delta
	if _since_gas >= gas_regen_delay:
		gas = minf(gas + gas_regen * delta, max_gas)

	_since_damage += delta
	if is_healing():
		player.heal((health_regen + player.upgrades.bonus_health_regen()) * delta)


## Called by the player whenever it takes damage: restarts the regen delay.
func on_damaged() -> void:
	_since_damage = 0.0


func is_healing() -> bool:
	return _since_damage >= health_regen_delay and player.health < player.max_health


func max_stamina() -> float:
	return base_max_stamina + 10.0 * player.skills.bonus_levels(&"fitness") + player.upgrades.bonus_stamina()


func stamina_regen() -> float:
	return base_stamina_regen * (1.0 + 0.08 * player.skills.bonus_levels(&"fitness"))


## Spends stamina if you're not exhausted. The last bit can overdraw to 0
## (you always get the jump you pressed), which then exhausts you.
func try_spend_stamina(amount: float) -> bool:
	if exhausted or stamina <= 0.0:
		return false
	stamina = maxf(stamina - amount, 0.0)
	_regen_wait = stamina_regen_delay
	if stamina <= 0.0:
		exhausted = true
	return true


## Burns gas for this tick if there's any. Returns whether thrust is available.
func burn_gas(delta: float) -> bool:
	if gas <= 0.0:
		return false
	gas = maxf(gas - gas_per_second * delta, 0.0)
	_since_gas = 0.0
	return true


func reset() -> void:
	gas = max_gas
	stamina = max_stamina()
	exhausted = false
	_since_damage = health_regen_delay
