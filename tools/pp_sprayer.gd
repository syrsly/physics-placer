@tool
class_name PPSprayer
extends PPTool
## This tool was removed from the toolset for now because it and some other tools were combined into the Shoot tool.

var _running: bool = false
var _screen_point: Vector2 = Vector2(-1, -1)


func tool_name() -> String:
	return "Sprayer"


func spawn_name_prefix() -> String:
	return settings.spray_name_prefix


func spawn_freeze() -> bool:
	return settings.spray_freeze_result


func wants_continuous_overlay() -> bool:
	return true


func activate() -> void:
	super.activate()
	_screen_point = Vector2(-1, -1)
	if settings.spray_on_click:
		set_status("Sprayer: click anywhere in the scene to spray toward that spot from the viewport camera.")
	else:
		set_status("Sprayer: point the cursor at a spot and press Spray From Current View.")


func deactivate() -> void:
	super.deactivate()
	if _running:
		_running = false
		sim.stop()
		cancel()


func screen_point(camera: Camera3D) -> Vector2:
	if _screen_point.x >= 0.0:
		return _screen_point
	if camera != null:
		var vp: Viewport = camera.get_viewport()
		if vp != null:
			return Vector2(vp.get_visible_rect().size) * 0.5
	return Vector2.ZERO


func nozzle_point(camera: Camera3D, at: Vector2 = Vector2(-1, -1)) -> Vector3:
	if camera == null:
		return Vector3.ZERO
	var p: Vector2 = at if at.x >= 0.0 else screen_point(camera)
	return camera.project_ray_origin(p) + aim_direction(camera, p) * settings.spray_muzzle_offset


func aim_direction(camera: Camera3D, at: Vector2 = Vector2(-1, -1)) -> Vector3:
	if camera == null:
		return Vector3.FORWARD
	var p: Vector2 = at if at.x >= 0.0 else screen_point(camera)
	return camera.project_ray_normal(p).normalized()


func cone_basis(camera: Camera3D, at: Vector2 = Vector2(-1, -1)) -> Basis:
	var forward: Vector3 = aim_direction(camera, at)
	var right: Vector3 = camera.global_transform.basis.x.normalized() if camera != null else Vector3.RIGHT
	if absf(right.dot(forward)) > 0.99:
		right = camera.global_transform.basis.y.normalized() if camera != null else Vector3.UP
	var up: Vector3 = right.cross(forward).normalized()
	right = forward.cross(up).normalized()
	return Basis(right, up, forward)


func cone_direction(basis: Basis, u: float, v: float) -> Vector3:
	var half: float = deg_to_rad(clampf(settings.spray_cone_fov, 0.0, 179.0)) * 0.5
	var cos_theta: float = lerpf(1.0, cos(half), u)
	var theta: float = acos(clampf(cos_theta, -1.0, 1.0))
	var phi: float = v * TAU
	var local := Vector3(sin(theta) * cos(phi), sin(theta) * sin(phi), cos(theta))
	return (basis * local).normalized()


func preview_distance(camera: Camera3D, at: Vector2 = Vector2(-1, -1)) -> float:
	if settings.spray_preview_distance > 0.001:
		return settings.spray_preview_distance
	if camera == null:
		return 6.0
	var origin: Vector3 = nozzle_point(camera, at)
	var hit: Dictionary = PPUtils.pick_object(scene_root(), origin, aim_direction(camera, at), [])
	if not hit.is_empty():
		return clampf(origin.distance_to(hit["position"]), 0.5, 500.0)
	return 6.0


func handle_input(camera: Camera3D, event: InputEvent) -> int:
	if not active:
		return EditorPlugin.AFTER_GUI_INPUT_PASS
	if event is InputEventKey:
		var key: InputEventKey = event
		if key.pressed and key.keycode == KEY_ESCAPE and _running:
			_running = false
			sim.stop()
			cancel()
			return EditorPlugin.AFTER_GUI_INPUT_STOP
	if event is InputEventMouseMotion:
		_screen_point = (event as InputEventMouseMotion).position
		return EditorPlugin.AFTER_GUI_INPUT_PASS
	if not settings.spray_on_click:
		return EditorPlugin.AFTER_GUI_INPUT_PASS
	if not (event is InputEventMouseButton):
		return EditorPlugin.AFTER_GUI_INPUT_PASS
	var mb: InputEventMouseButton = event
	if mb.button_index != MOUSE_BUTTON_LEFT or not mb.pressed or _running:
		return EditorPlugin.AFTER_GUI_INPUT_PASS
	_screen_point = mb.position
	fire(camera, mb.position)
	return EditorPlugin.AFTER_GUI_INPUT_STOP


func fire(camera: Camera3D = null, at: Vector2 = Vector2(-1, -1)) -> void:
	if _running:
		return
	if camera == null:
		camera = editor_camera()
	if camera == null:
		set_status("Sprayer: no 3D viewport camera found.")
		return
	if settings.spray_scene == null:
		set_status("Sprayer: load an object (PackedScene) first.")
		return
	var root: Node = scene_root()
	if root == null:
		set_status("Sprayer: no 3D scene is open.")
		return

	sim.reset()
	sim.setup(settings)
	sim.set_scene(root)
	var origin: Vector3 = nozzle_point(camera, at)
	var basis: Basis = cone_basis(camera, at)
	var aim_at: Vector3 = origin + aim_direction(camera, at) * preview_distance(camera, at)
	var dynamic: Array = PPUtils.find_dynamic_candidates(root, [], settings, [aim_at])
	sim.build_environment(dynamic)
	for node in dynamic:
		sim.add_object(node)

	var count: int = maxi(1, settings.spray_count)
	var spawned := 0
	for i in count:
		var dir: Vector3 = cone_direction(basis, randf(), randf())
		var offset: Vector3 = (basis.x * (randf() - 0.5) + basis.y * (randf() - 0.5)) * 2.0 * settings.spray_nozzle_radius
		var speed: float = settings.spray_force * (1.0 + randf_range(-settings.spray_force_jitter, settings.spray_force_jitter))
		var rot := Basis.IDENTITY
		if settings.spray_random_rotation:
			rot = Basis.from_euler(Vector3(randf_range(0.0, TAU), randf_range(0.0, TAU), randf_range(0.0, TAU)))
		var spin := Vector3(
			randf_range(-settings.spray_spin, settings.spray_spin),
			randf_range(-settings.spray_spin, settings.spray_spin),
			randf_range(-settings.spray_spin, settings.spray_spin))
		var item = sim.add_spawn(settings.spray_scene, Transform3D(rot, origin + offset), dir * speed, spin, i * settings.spray_interval, root)
		if item != null:
			spawned += 1
	if spawned == 0:
		set_status("Sprayer: " + (sim.last_warning if sim.last_warning != "" else "nothing was spawned."))
		sim.reset()
		return
	_running = true
	sim.start(true)
	set_status("Sprayer: spraying %d object(s)..." % spawned)


func spawn_parent() -> Node:
	if not settings.spray_parent_selected:
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
	finish_and_bake("Physics Placer: Spray", spawn_parent())


func draw_overlay(overlay: Control, camera: Camera3D) -> void:
	if camera == null or not settings.show_overlay or not active:
		return
	var at: Vector2 = screen_point(camera)
	var apex: Vector3 = nozzle_point(camera, at)
	var forward: Vector3 = aim_direction(camera, at)
	var dist: float = preview_distance(camera, at)
	var half: float = deg_to_rad(clampf(settings.spray_cone_fov, 0.0, 179.0)) * 0.5
	var radius: float = tan(minf(half, deg_to_rad(89.0))) * dist
	var basis: Basis = cone_basis(camera, at)
	var center: Vector3 = apex + forward * dist
	var cone_color := Color(0.4, 0.8, 1.0, 0.55)

	var ring: PackedVector2Array = PackedVector2Array()
	for i in 33:
		var a: float = TAU * float(i) / 32.0
		var world: Vector3 = center + basis.x * cos(a) * radius + basis.y * sin(a) * radius
		if camera.is_position_behind(world):
			continue
		ring.append(camera.unproject_position(world))
	if ring.size() > 1:
		overlay.draw_polyline(ring, cone_color, 1.5, true)

	if not camera.is_position_behind(center):
		var c2: Vector2 = camera.unproject_position(center)
		overlay.draw_arc(c2, 4.0, 0.0, TAU, 12, Color(0.95, 0.35, 0.35, 0.9), 1.5, true)
		overlay.draw_line(c2 - Vector2(9, 0), c2 + Vector2(9, 0), Color(0.95, 0.35, 0.35, 0.9), 1.0, true)
		overlay.draw_line(c2 - Vector2(0, 9), c2 + Vector2(0, 9), Color(0.95, 0.35, 0.35, 0.9), 1.0, true)

	_draw_arc_path(overlay, camera, apex, forward, dist, Color(0.45, 0.85, 1.0, 0.95))
	for i in 4:
		_draw_arc_path(overlay, camera, apex, cone_direction(basis, 1.0, float(i) / 4.0), dist, Color(0.4, 0.7, 1.0, 0.45))

	var font: Font = overlay.get_theme_default_font()
	if font != null:
		var label := "Cone %.0f deg   Force %.1f m/s   x%d" % [settings.spray_cone_fov, settings.spray_force, settings.spray_count]
		overlay.draw_string(font, Vector2(12, overlay.size.y - 14), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(0.7, 0.85, 1.0, 0.9))


func _draw_arc_path(overlay: Control, camera: Camera3D, origin: Vector3, direction: Vector3, dist: float, color: Color) -> void:
	var g: Vector3 = settings.gravity_vector()
	var vel: Vector3 = direction * maxf(0.01, settings.spray_force)
	var points: PackedVector2Array = PackedVector2Array()
	var steps := 32
	var span: float = clampf(dist / maxf(0.5, settings.spray_force) * 2.0, 0.4, 5.0)
	for i in steps + 1:
		var t: float = span * float(i) / float(steps)
		var p: Vector3 = origin + vel * t + g * 0.5 * t * t
		if camera.is_position_behind(p):
			continue
		points.append(camera.unproject_position(p))
	if points.size() > 1:
		overlay.draw_polyline(points, color, 1.5, true)
