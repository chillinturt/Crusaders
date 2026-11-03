extends StaticBody3D
## The interactable mouth of a tunnel through the mountains. Press E to travel to
## the next (or previous) region. The way onward stays shut until the region's
## titans are dead (the generator decides). Lives on the interactables layer, so
## it's not solid.

## The WorldGenerator that rebuilds the world around the player.
var generator: Node
## +1 = onward to the next region, -1 = back to the previous one.
var step := 1


func _ready() -> void:
	add_to_group(&"tunnels")  # for the minimap


func get_interact_prompt(_by: Node) -> String:
	return generator.tunnel_prompt(step)


func interact(by: Node) -> void:
	if generator.can_travel(step):
		generator.travel(step)
	else:
		by.notify(generator.tunnel_prompt(step))
