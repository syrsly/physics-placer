@tool
class_name PPTosser
extends PPTool
## This tool is a WIP state and may never be finished because it was replaced with the Shoot tool.

enum Place { SOURCE, ARC, TARGET }

signal points_changed()

var place_mode: int = Place.SOURCE
var _running: bool = false
var _camera: Camera3D = null


func tool_name() -> String:
	return "Tosser"


func spawn_name_prefix() -> String:
	return settings.toss_name_prefix


func spawn_freeze() -> bool:
	return settings.toss_freeze_result


func activate() -> void:
	super.activate()
	_update_place_status()


func deactivate() -> void:
	super.deactivate()
	if _running:
		_running = false
		sim.stop()
		cancel()


func set_place_mode(mode: int) -> void:
	place_mode = mode
	_update_place_status()


func _update_place_status() -> void:
	match place_mode:
		Place.SOURCE:
			set_status("Tosser: click in the viewport to set the SOURCE point.")
		Place.ARC:
			set_status("Tosser: click to set the ARC height.")
		_:
			set_status("Tosser: click in the viewport to set the TARGET point.")


func clear_points() -> void:
	settings.has_source = false
	settings.has_arc = false
	settings.has_target = false
	place_mode = Place.SOURCE
	points_changed.emit()
	_update_place_status()


func ready_to_fire() -> bool:
	return settings.has_source and settings.has_target and settings.toss_scene != null


func handle_input(camera: Camera3D, event: InputEvent) -> int:
	if not active:
		return EditorPlugin.AFTER_GUI_INPUT_PASS
	_camera = camera
	if event is InputEventKey:
		var key: InputEventKey = event
		if key.pressed and key.keycode == KEY_ESCAPE and _running:
			_running = false
			sim.stop()
			cancel()
			return EditorPlugin.AFTER_GUI_INPUT_STOP
	if not (event is InputEventMouseButton):
		return EditorPlugin.AFTER_GUI_INPUT_PASS
	var mb: InputEventMouseButton = event
	if mb.button_index != MOUSE_BUTTON_LEFT or not mb.pressed or _running or camera == null:
		return EditorPlugin.AFTER_GUI_INPUT_PASS

	var from: Vector3 = camera.project_ray_origin(mb.position)
	var dir: Vector3 = camera.project_ray_normal(mb.position)
	var point: Variant = _resolve_point(camera, from, dir)
	if point == null:
		return EditorPlugin.AFTER_GUI_INPUT_PASS
	match place_mode:
		Place.SOURCE:
			settings.source_point = point
			settings.has_source = true
			place_mode = Place.TARGET
		Place.ARC:
			settings.arc_point = point
			settings.has_arc = true
			place_mode = Place.TARGET
		_:
			settings.target_point = point
			settings.has_target = true
			place_mode = Place.ARC
	points_changed.emit()
	_update_place_status()
	return EditorPlugin.AFTER_GUI_INPUT_STOP


func _resolve_point(camera: Camera3D, from: Vector3, dir: Vector3) -> Variant:
	var up: Vector3 = -settings.gravity_vector().normalized()
	if place_mode == Place.ARC and settings.has_source:
		var mid: Vector3 = settings.source_point
		if settings.has_target:
			mid = (settings.source_point + settings.target_point) * 0.5
		var along: Vector3 = Vector3.RIGHT
		if settings.has_target:
			along = settings.target_point - settings.source_point
			along -= up * along.dot(up)
		if along.length() < 0.001:
			along = camera.global_transform.basis.x
		var normal: Vector3 = along.normalized().cross(up).normalized()
		if normal.length() < 0.001:
			normal = camera.global_transform.basis.z
		return PPUtils.ray_plane(from, dir, mid, normal)
	var root: Node = scene_root()
	var hit: Dictionary = PPUtils.pick_object(root, from, dir, [], settings.grab_target)
	if not hit.is_empty():
		return hit["position"]
	var plane_origin: Vector3 = Vector3.ZERO
	if settings.has_source:
		plane_origin = up * settings.source_point.dot(up)
	return PPUtils.ray_plane(from, dir, plane_origin, up)


func solve_velocity(s: Vector3, apex_point: Vector3, t: Vector3) -> Vector3:
	var g_vec: Vector3 = settings.gravity_vector()
	var g: float = g_vec.length()
	var delta: Vector3 = t - s
	if g < 0.001:
		return delta.normalized() * 6.0
	var up: Vector3 = -g_vec.normalized()
	var sy: float = s.dot(up)
	var ty: float = t.dot(up)
	var ay: float = apex_point.dot(up) if settings.has_arc else maxf(sy, ty) + delta.length() * 0.25
	var apex: float = maxf(ay, maxf(sy, ty) + 0.05) - sy
	apex = maxf(apex, 0.05)
	var v_up: float = sqrt(2.0 * g * apex)
	var t_up: float = v_up / g
	var fall: float = maxf(0.0, (sy + apex) - ty)
	var t_down: float = sqrt(2.0 * fall / g)
	var total: float = maxf(0.05, t_up + t_down)
	var horiz: Vector3 = delta - up * delta.dot(up)
	return horiz / total + up * v_up


func fire() -> void:
	if _running:
		return
	if settings.toss_scene == null:
		set_status("Tosser: load an object (PackedScene) first.")
		return
	if not (settings.has_source and settings.has_target):
		set_status("Tosser: set both a source and a target point.")
		return
	var root: Node = scene_root()
	if root == null:
		set_status("Tosser: no 3D scene is open.")
		return

	sim.reset()
	sim.setup(settings)
	sim.set_scene(root)
	var dynamic: Array = PPUtils.find_dynamic_candidates(root, [], settings, [settings.target_point])
	sim.build_environment(dynamic)
	for node in dynamic:
		sim.add_object(node)

	var up: Vector3 = -settings.gravity_vector().normalized()
	var count: int = maxi(1, settings.toss_count)
	var spawned := 0
	for i in count:
		var src: Vector3 = settings.source_point + _random_offset(up, settings.toss_source_radius)
		var dst: Vector3 = settings.target_point + _random_offset(up, settings.toss_target_radius)
		var vel: Vector3 = solve_velocity(src, settings.arc_point, dst)
		vel *= 1.0 + randf_range(-settings.toss_speed_jitter, settings.toss_speed_jitter)
		var basis := Basis.IDENTITY
		if settings.toss_random_rotation:
			basis = Basis.from_euler(Vector3(randf_range(0.0, TAU), randf_range(0.0, TAU), randf_range(0.0, TAU)))
		var spin := Vector3(
			randf_range(-settings.toss_spin, settings.toss_spin),
			randf_range(-settings.toss_spin, settings.toss_spin),
			randf_range(-settings.toss_spin, settings.toss_spin))
		var item = sim.add_spawn(settings.toss_scene, Transform3D(basis, src), vel, spin, i * settings.toss_interval, root)
		if item != null:
			spawned += 1
	if spawned == 0:
		set_status("Tosser: " + (sim.last_warning if sim.last_warning != "" else "nothing was spawned."))
		sim.reset()
		return
	_running = true
	sim.start(true)
	set_status("Tosser: launching %d object(s)..." % spawned)


func _random_offset(up: Vector3, radius: float) -> Vector3:
	if radius <= 0.0:
		return Vector3.ZERO
	var basis_x: Vector3 = up.cross(Vector3.RIGHT)
	if basis_x.length() < 0.01:
		basis_x = up.cross(Vector3.FORWARD)
	basis_x = basis_x.normalized()
	var basis_z: Vector3 = up.cross(basis_x).normalized()
	var angle: float = randf() * TAU
	var r: float = sqrt(randf()) * radius
	return basis_x * cos(angle) * r + basis_z * sin(angle) * r


func spawn_parent() -> Node:
	if not settings.toss_parent_selected:
		return scene_root()
	var sel: Array[Node] = EditorInterface.get_selection().get_selected_nodes()
	for n in sel:
		if n is Node3D:
			return n
	return scene_root()


func on_sim_finished() -> void:
	if not _running:
		return
	_running = false
	finish_and_bake("Physics Placer: Toss", spawn_parent())


func draw_overlay(overlay: Control, camera: Camera3D) -> void:
	if camera == null or not settings.show_overlay or not active:
		return
	var up: Vector3 = -settings.gravity_vector().normalized()
	if settings.has_source:
		_draw_marker(overlay, camera, settings.source_point, Color(0.35, 0.9, 0.45), "Source")
	if settings.has_target:
		_draw_marker(overlay, camera, settings.target_point, Color(0.95, 0.35, 0.35), "Target")
		_draw_ring(overlay, camera, settings.target_point, up, settings.toss_target_radius, Color(0.95, 0.35, 0.35, 0.6))
	if settings.has_arc:
		_draw_marker(overlay, camera, settings.arc_point, Color(0.95, 0.85, 0.3), "Arc")
	if not (settings.has_source and settings.has_target):
		return
	var vel: Vector3 = solve_velocity(settings.source_point, settings.arc_point, settings.target_point)
	var g_vec: Vector3 = settings.gravity_vector()
	var points: PackedVector2Array = PackedVector2Array()
	var steps := 48
	var flight: float = _flight_time(vel, g_vec)
	for i in steps + 1:
		var t: float = flight * float(i) / float(steps)
		var p: Vector3 = settings.source_point + vel * t + g_vec * 0.5 * t * t
		if camera.is_position_behind(p):
			continue
		points.append(camera.unproject_position(p))
	if points.size() > 1:
		overlay.draw_polyline(points, Color(0.4, 0.8, 1.0, 0.9), 2.0, true)


func _flight_time(vel: Vector3, g_vec: Vector3) -> float:
	var g: float = g_vec.length()
	if g < 0.001:
		return 1.0
	var up: Vector3 = -g_vec.normalized()
	var v_up: float = vel.dot(up)
	var drop: float = (settings.source_point - settings.target_point).dot(up)
	var t_up: float = maxf(0.0, v_up / g)
	var apex_h: float = v_up * t_up - 0.5 * g * t_up * t_up
	var fall: float = maxf(0.0, apex_h + drop)
	return t_up + sqrt(2.0 * fall / g)


func _draw_marker(overlay: Control, camera: Camera3D, point: Vector3, color: Color, label: String) -> void:
	if camera.is_position_behind(point):
		return
	var p: Vector2 = camera.unproject_position(point)
	overlay.draw_circle(p, 5.0, color)
	overlay.draw_arc(p, 9.0, 0.0, TAU, 20, color, 1.5, true)
	var font: Font = overlay.get_theme_default_font()
	if font != null:
		overlay.draw_string(font, p + Vector2(12, 4), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, color)


func _draw_ring(overlay: Control, camera: Camera3D, center: Vector3, up: Vector3, radius: float, color: Color) -> void:
	if radius <= 0.0:
		return
	var axis_x: Vector3 = up.cross(Vector3.RIGHT)
	if axis_x.length() < 0.01:
		axis_x = up.cross(Vector3.FORWARD)
	axis_x = axis_x.normalized()
	var axis_z: Vector3 = up.cross(axis_x).normalized()
	var pts: PackedVector2Array = PackedVector2Array()
	for i in 33:
		var a: float = TAU * float(i) / 32.0
		var world: Vector3 = center + axis_x * cos(a) * radius + axis_z * sin(a) * radius
		if camera.is_position_behind(world):
			continue
		pts.append(camera.unproject_position(world))
	if pts.size() > 1:
		overlay.draw_polyline(pts, color, 1.5, true)
