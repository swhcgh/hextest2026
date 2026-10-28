class_name PlayerView
extends Node2D
## Draws the player's unit and the route it is walking. Redraws every frame
## so the marker moves smoothly.

var player: Player
var map: VoronoiMap


func _process(_delta: float) -> void:
	if visible:
		queue_redraw()


func _draw() -> void:
	if player == null or player.cell < 0:
		return
	var p := player.pos
	if player.is_moving():
		var route := PackedVector2Array([p])
		for k in range(player.segment + 1, player.path.size()):
			route.append(map.cells[player.path[k]].site)
		draw_polyline(route, Color(1, 1, 1, 0.55), 1.5)
		draw_circle(route[-1], 3.0, Color(1, 1, 1, 0.55))
	draw_circle(p, 8.0, Color.BLACK)
	draw_circle(p, 6.5, Color("ffd24a"))
	draw_circle(p, 3.0, Color("2a2a2a"))
