@tool
class_name PPShooter
extends PPTool
## This tool evolved from the Spray tool and a few other WIP ideas I had laying around.

var _armed: bool = false
var _firing: bool = false
var _settling: bool = false
var _screen_point: Vector2 = Vector2(-1, -1)
var _cooldown: float = 0.0
var _recoil: float = 0.0
var _rounds: int = 0
var _camera: Camera3D = null


func tool_name() -> String:
	return "Shoot"


func spawn_name_prefix() -> String:
	return settings.shoot_name_prefix


func spawn_freeze() -> bool:
	return settings.shoot_freeze_result


func wants_continuous_overlay() -> bool:
	return true


func activate() -> void:
	super.activate()
	_screen_point = Vector2(-1, -1)
	_recoil = 0.0
	_rounds = 0
	if settings.shoot_rapid_fire:
		set_status("Shoot: hold the left mouse button to fire (%.0f rounds/sec). Release to let them settle." % settings.shoot_rate)
	else:
		set_status("Shoot: click to fire one round.")


func deactivate() -> void:
	super.deactivate()
	if _armed or _settling:
		_armed = false
		_firing = false
		_settling = false
		sim.stop()
		cancel()


func aim_point(camera: Camera3D) -> Vector2:
	if not settings.shoot_fixed_crosshair and _screen_point.x >= 0.0:
		return _screen_point
	if camera != null:
		var vp: Viewport = camera.get_viewport()
		if vp != null:
			return Vector2(vp.get_visible_rect().size) * 0.5
	return Vector2.ZERO


func muzzle_point(camera: Camera3D) -> Vector3:
	if camera == null:
		return Vector3.ZERO
	var at: Vector2 = aim_point(camera)
	return camera.project_ray_origin(at) + aim_direction(camera) * settings.shoot_muzzle_offset


func aim_direction(camera: Camera3D) -> Vector3:
	if camera == null:
		return Vector3.FORWARD
	var at: Vector2 = aim_point(camera)
	var dir: Vector3 = camera.project_ray_normal(at).normalized()
	if _recoil > 0.0001:
		var right: Vector3 = camera.global_transform.basis.x.normalized()
		dir = dir.rotated(right, deg_to_rad(_recoil))
	return dir.normalized()


func _spread_direction(camera: Camera3D, base: Vector3) -> Vector3:
	var half: float = deg_to_rad(clampf(settings.shoot_spread, 0.0, 60.0)) * 0.5
	if half <= 0.0001:
		return base
	var right: Vector3 = camera.global_transform.basis.x.normalized()
	if absf(right.dot(base)) > 0.99:
		right = camera.global_transform.basis.y.normalized()
	var up: Vector3 = right.cross(base).normalized()
	right = base.cross(up).normalized()
	var cos_theta: float = lerpf(1.0, cos(half), randf())
	var theta: float = acos(clampf(cos_theta, -1.0, 1.0))
	var phi: float = randf() * TAU
	var local := Vector3(sin(theta) * cos(phi), sin(theta) * sin(phi), cos(theta))
	return (Basis(right, up, base) * local).normalized()


func handle_input(camera: Camera3D, event: InputEvent) -> int:
	if not active:
		return EditorPlugin.AFTER_GUI_INPUT_PASS
	if event is InputEventKey:
		var key: InputEventKey = event
		if key.pressed and key.keycode == KEY_ESCAPE and (_armed or _settling):
			_armed = false
			_firing = false
			_settling = false
			sim.stop()
			cancel()
			return EditorPlugin.AFTER_GUI_INPUT_STOP
	_camera = camera
	if event is InputEventMouseMotion:
		_screen_point = (event as InputEventMouseMotion).position
		return EditorPlugin.AFTER_GUI_INPUT_PASS
	if not (event is InputEventMouseButton):
		return EditorPlugin.AFTER_GUI_INPUT_PASS
	var mb: InputEventMouseButton = event
	if mb.button_index != MOUSE_BUTTON_LEFT:
		return EditorPlugin.AFTER_GUI_INPUT_PASS
	if mb.pressed:
		_screen_point = mb.position
		return _trigger_down(camera)
	return _trigger_up()


func _trigger_down(camera: Camera3D) -> int:
	if _settling:
		return EditorPlugin.AFTER_GUI_INPUT_STOP
	if settings.shoot_scene == null:
		set_status("Shoot: load an ammo object (PackedScene) first.")
		return EditorPlugin.AFTER_GUI_INPUT_STOP
	if camera == null:
		camera = editor_camera()
	if camera == null:
		set_status("Shoot: no 3D viewport camera found.")
		return EditorPlugin.AFTER_GUI_INPUT_STOP
	_camera = camera
	if not _armed and not _begin_burst(camera):
		return EditorPlugin.AFTER_GUI_INPUT_STOP
	_fire_round(camera)
	_firing = settings.shoot_rapid_fire
	_cooldown = 1.0 / maxf(0.5, settings.shoot_rate)
	return EditorPlugin.AFTER_GUI_INPUT_STOP


func _trigger_up() -> int:
	if not _armed:
		return EditorPlugin.AFTER_GUI_INPUT_PASS
	_firing = false
	if settings.shoot_hold_to_accumulate:
		set_status("Shoot: %d round(s) fired. Keep firing, or press Finish Volley to place them." % _rounds)
		return EditorPlugin.AFTER_GUI_INPUT_STOP
	finish_volley()
	return EditorPlugin.AFTER_GUI_INPUT_STOP


func _begin_burst(camera: Camera3D) -> bool:
	var root: Node = scene_root()
	if root == null:
		set_status("Shoot: no 3D scene is open.")
		return false
	sim.reset()
	sim.setup(settings)
	sim.set_scene(root)
	var aim_at: Vector3 = muzzle_point(camera) + aim_direction(camera) * 8.0
	var dynamic: Array = PPUtils.find_dynamic_candidates(root, [], settings, [aim_at])
	sim.build_environment(dynamic)
	for node in dynamic:
		sim.add_object(node)
	sim.start(false)
	_armed = true
	_rounds = 0
	_recoil = 0.0
	return true


func _fire_round(camera: Camera3D) -> void:
	if _rounds >= settings.shoot_max_rounds:
		_firing = false
		set_status("Shoot: magazine limit of %d reached. Release to place them." % settings.shoot_max_rounds)
		return
	var root: Node = scene_root()
	if root == null:
		return
	var base: Vector3 = aim_direction(camera)
	var dir: Vector3 = _spread_direction(camera, base)
	var speed: float = settings.shoot_force * (1.0 + randf_range(-settings.shoot_force_jitter, settings.shoot_force_jitter))
	var rot := Basis.IDENTITY
	if settings.shoot_random_rotation:
		rot = Basis.from_euler(Vector3(randf_range(0.0, TAU), randf_range(0.0, TAU), randf_range(0.0, TAU)))
	var spin := Vector3(
		randf_range(-settings.shoot_spin, settings.shoot_spin),
		randf_range(-settings.shoot_spin, settings.shoot_spin),
		randf_range(-settings.shoot_spin, settings.shoot_spin))
	var item = sim.add_spawn(settings.shoot_scene, Transform3D(rot, muzzle_point(camera)), dir * speed, spin, 0.0, root)
	if item == null:
		set_status("Shoot: " + (sim.last_warning if sim.last_warning != "" else "the round could not be spawned."))
		_firing = false
		return
	_rounds += 1
	_recoil = minf(settings.shoot_recoil_max, _recoil + settings.shoot_recoil)
	set_status("Shoot: %d round(s) in the air." % _rounds)


func tick(delta: float) -> void:
	if not active:
		return
	if not _firing and _recoil > 0.0:
		_recoil = maxf(0.0, _recoil - settings.shoot_recoil_recovery * delta)
	if not _firing or not _armed:
		return
	var camera: Camera3D = editor_camera()
	if camera == null:
		camera = _camera
	if camera == null:
		return
	var interval: float = 1.0 / clampf(settings.shoot_rate, 0.5, 60.0)
	_cooldown -= delta
	var guard := 0
	while _cooldown <= 0.0 and guard < 8:
		_fire_round(camera)
		_cooldown += interval
		guard += 1
		if not _firing:
			break


func finish_volley() -> void:
	if not _armed:
		return
	_armed = false
	_firing = false
	_settling = true
	set_status("Shoot: settling %d round(s)..." % _rounds)
	sim.set_time_limited(true)


func on_sim_finished() -> void:
	if not (_armed or _settling):
		return
	_armed = false
	_firing = false
	_settling = false
	finish_and_bake("Physics Placer: Shoot", spawn_parent())
	_rounds = 0


func spawn_parent() -> Node:
	if not settings.shoot_parent_selected:
		return scene_root()
	var sel: Array[Node] = EditorInterface.get_selection().get_selected_nodes()
	for n in sel:
		if n is Node3D:
			return n
	return scene_root()


func draw_overlay(overlay: Control, camera: Camera3D) -> void:
	if camera == null or not settings.show_overlay or not active:
		return
	var at: Vector2 = aim_point(camera)
	var muzzle: Vector3 = muzzle_point(camera)
	var dir: Vector3 = aim_direction(camera)

	var hot: bool = _firing or _armed
	var color: Color = Color(1.0, 0.45, 0.3, 0.95) if hot else Color(0.45, 0.9, 1.0, 0.9)
	var gap: float = 5.0 + _recoil * 2.5
	var arm: float = 11.0
	for d in [Vector2(1, 0), Vector2(-1, 0), Vector2(0, 1), Vector2(0, -1)]:
		overlay.draw_line(at + d * gap, at + d * (gap + arm), color, 1.5, true)
	overlay.draw_circle(at, 1.5, color)
	if settings.shoot_spread > 0.01:
		var dist: float = _impact_distance(camera, muzzle, dir)
		var radius3d: float = tan(deg_to_rad(settings.shoot_spread) * 0.5) * dist
		var edge: Vector3 = muzzle + dir * dist + camera.global_transform.basis.x.normalized() * radius3d
		if not camera.is_position_behind(edge):
			overlay.draw_arc(at, maxf(3.0, at.distance_to(camera.unproject_position(edge))), 0.0, TAU, 32,
				Color(color.r, color.g, color.b, 0.35), 1.0, true)

	_draw_tracer(overlay, camera, muzzle, dir)

	var font: Font = overlay.get_theme_default_font()
	if font != null:
		var mode: String = "auto %.0f/s" % settings.shoot_rate if settings.shoot_rapid_fire else "single"
		var label: String = "Shoot  %.0f m/s   %s   rounds %d/%d" % [settings.shoot_force, mode, _rounds, settings.shoot_max_rounds]
		overlay.draw_string(font, Vector2(12, overlay.size.y - 14), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, color)


func _impact_distance(camera: Camera3D, muzzle: Vector3, dir: Vector3) -> float:
	var hit: Dictionary = PPUtils.pick_object(scene_root(), muzzle, dir, [], settings.grab_target)
	if hit.is_empty():
		return 12.0
	return clampf(muzzle.distance_to(hit["position"]), 0.5, 500.0)


func _draw_tracer(overlay: Control, camera: Camera3D, muzzle: Vector3, dir: Vector3) -> void:
	var g: Vector3 = settings.gravity_vector()
	var speed: float = maxf(0.01, settings.shoot_force)
	var span: float = clampf(_impact_distance(camera, muzzle, dir) / speed, 0.05, 3.0)
	var points: PackedVector2Array = PackedVector2Array()
	for i in 25:
		var t: float = span * float(i) / 24.0
		var p: Vector3 = muzzle + dir * speed * t + g * 0.5 * t * t
		if camera.is_position_behind(p):
			continue
		points.append(camera.unproject_position(p))
	if points.size() > 1:
		overlay.draw_polyline(points, Color(1.0, 0.8, 0.35, 0.5), 1.5, true)
