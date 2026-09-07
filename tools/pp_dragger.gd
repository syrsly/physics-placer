@tool
class_name PPDragger
extends PPTool

enum State { IDLE, DRAGGING, SETTLING }

var state: int = State.IDLE
var _depth: float = 2.0
var _camera: Camera3D = null
var _screen_point: Vector2 = Vector2.ZERO
var _anchor_screen: Vector2 = Vector2.ZERO
var _lock_axis: bool = false
var _plane_origin: Vector3 = Vector3.ZERO


func tool_name() -> String:
	return "Dragger"


func activate() -> void:
	super.activate()
	set_status("Dragger: click and hold on an object to pull it around.")


func deactivate() -> void:
	super.deactivate()
	if state != State.IDLE:
		state = State.IDLE
		sim.end_drag()
		sim.stop()
		cancel()


func handle_input(camera: Camera3D, event: InputEvent) -> int:
	if not active:
		return EditorPlugin.AFTER_GUI_INPUT_PASS
	_camera = camera

	if event is InputEventKey:
		var key: InputEventKey = event
		if key.pressed and key.keycode == KEY_ESCAPE and state != State.IDLE:
			state = State.IDLE
			sim.end_drag()
			sim.stop()
			cancel()
			return EditorPlugin.AFTER_GUI_INPUT_STOP
		if key.keycode == KEY_CTRL:
			_lock_axis = key.pressed

	if event is InputEventMouseButton:
		var mb: InputEventMouseButton = event
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				return _try_grab(camera, mb.position)
			elif state == State.DRAGGING:
				_release()
				return EditorPlugin.AFTER_GUI_INPUT_STOP
		elif state == State.DRAGGING and mb.pressed:
			if mb.button_index == MOUSE_BUTTON_WHEEL_UP:
				_depth = maxf(0.05, _depth * 1.08)
				_update_target()
				return EditorPlugin.AFTER_GUI_INPUT_STOP
			if mb.button_index == MOUSE_BUTTON_WHEEL_DOWN:
				_depth = maxf(0.05, _depth * 0.925)
				_update_target()
				return EditorPlugin.AFTER_GUI_INPUT_STOP

	if event is InputEventMouseMotion and state == State.DRAGGING:
		_screen_point = (event as InputEventMouseMotion).position
		_update_target()
		return EditorPlugin.AFTER_GUI_INPUT_STOP

	return EditorPlugin.AFTER_GUI_INPUT_PASS


func _try_grab(camera: Camera3D, screen_pos: Vector2) -> int:
	if state != State.IDLE or camera == null:
		return EditorPlugin.AFTER_GUI_INPUT_PASS
	var root: Node = scene_root()
	if root == null:
		return EditorPlugin.AFTER_GUI_INPUT_PASS
	var from: Vector3 = camera.project_ray_origin(screen_pos)
	var dir: Vector3 = camera.project_ray_normal(screen_pos)
	var hit: Dictionary = PPUtils.pick_object(root, from, dir, [], settings.grab_target)
	if hit.is_empty():
		set_status("Dragger: nothing grabbable under the cursor. Physics Placer did not handle this click.")
		return EditorPlugin.AFTER_GUI_INPUT_STOP
	var node: Node3D = hit["node"]
	var point: Vector3 = hit["position"]

	var items: Array = prepare_sim([node])
	if items.is_empty():
		if sim.last_warning != "":
			set_status("Dragger: " + sim.last_warning)
		sim.reset()
		return EditorPlugin.AFTER_GUI_INPUT_PASS
	var grabbed = null
	for item in items:
		if item.source == node:
			grabbed = item
			break
	if grabbed == null:
		sim.reset()
		return EditorPlugin.AFTER_GUI_INPUT_PASS

	_depth = from.distance_to(point)
	_screen_point = screen_pos
	_plane_origin = point
	state = State.DRAGGING
	sim.start(false)
	sim.begin_drag(grabbed, point)
	EditorInterface.get_selection().clear()
	EditorInterface.get_selection().add_node(node)
	var own_shapes := 0
	if is_instance_valid(grabbed.body):
		for ch in grabbed.body.get_children():
			if ch is CollisionShape3D:
				own_shapes += 1
	var report: String = "Physics Placer / Dragger: grabbed %s -- %d collider(s) on it, %d collider(s) from %d scene object(s)." % [node.name, own_shapes, sim.env_shape_count, sim.env_source_count]
	print(report)
	if sim.env_shape_count == 0:
		set_status("Dragger: %s has %d collider(s) but the scene contributed NO collision geometry, so nothing can block it. Run the Scene Diagnostic below." % [node.name, own_shapes])
	elif own_shapes == 0:
		set_status("Dragger: %s produced NO collider of its own, so it cannot collide. Run the Scene Diagnostic below." % node.name)
	else:
		set_status("Dragger: %s (%d collider(s)) vs %d scene collider(s). Wheel changes depth, Ctrl locks vertical." % [node.name, own_shapes, sim.env_shape_count])
	return EditorPlugin.AFTER_GUI_INPUT_STOP


func _update_target() -> void:
	if _camera == null or state != State.DRAGGING:
		return
	var from: Vector3 = _camera.project_ray_origin(_screen_point)
	var dir: Vector3 = _camera.project_ray_normal(_screen_point)
	var target: Vector3
	if _lock_axis:
		var up: Vector3 = -settings.gravity_vector().normalized()
		var normal: Vector3 = (_camera.global_transform.basis.z - up * _camera.global_transform.basis.z.dot(up))
		if normal.length() < 0.001:
			normal = Vector3.FORWARD
		var hit: Variant = PPUtils.ray_plane(from, dir, _plane_origin, normal.normalized())
		if hit == null:
			return
		target = hit
	else:
		target = from + dir * _depth
	sim.update_drag(target)


func _release() -> void:
	sim.end_drag()
	if settings.drag_settle_after_release:
		state = State.SETTLING
		sim.set_time_limited(true)
		set_status("Dragger: settling...")
	else:
		state = State.SETTLING
		sim.stop()


func on_sim_finished() -> void:
	if state == State.IDLE:
		return
	state = State.IDLE
	finish_and_bake("Physics Placer: Drag")


func draw_overlay(overlay: Control, camera: Camera3D) -> void:
	if state != State.DRAGGING or camera == null or not settings.show_overlay:
		return
	var anchor: Vector3 = sim.drag_anchor_world()
	if camera.is_position_behind(anchor):
		return
	var a: Vector2 = camera.unproject_position(anchor)
	overlay.draw_line(a, _screen_point, Color(1.0, 0.75, 0.2, 0.9), 2.0, true)
	overlay.draw_circle(a, 5.0, Color(1.0, 0.75, 0.2, 0.9))
	overlay.draw_arc(_screen_point, 8.0, 0.0, TAU, 24, Color(1.0, 0.9, 0.5, 0.9), 2.0, true)
