@tool
class_name PPSim
extends Node

signal sim_tick(elapsed: float)
signal sim_finished()

class SimItem extends RefCounted:
	var source: Node3D = null
	var body: RigidBody3D = null
	var preview: Node3D = null
	var spawn_scene: PackedScene = null
	var is_spawn: bool = false
	var native: bool = false
	var start_global: Transform3D = Transform3D.IDENTITY
	var final_global: Transform3D = Transform3D.IDENTITY
	var scale: Vector3 = Vector3.ONE
	var generated: bool = false
	var gen_shapes: Array = []
	var settled_for: float = 0.0
	var settled: bool = false
	var asleep: bool = false
	var retired: bool = false
	var preview_clean: bool = false
	var pending_launch: bool = false
	var launch_time: float = 0.0
	var launch_velocity: Vector3 = Vector3.ZERO
	var launch_spin: Vector3 = Vector3.ZERO
	var native_freeze: bool = false
	var native_freeze_mode: int = 0
	var native_gravity: float = 1.0

	func rid() -> RID:
		if body == null:
			return RID()
		return body.get_rid()

var settings: PPSettings = null
var items: Array = []
var elapsed: float = 0.0
var running: bool = false
var time_limited: bool = true
var launch_offset: float = 0.0
var last_warning: String = ""
var env_shape_count: int = 0
var env_source_count: int = 0
var env_truncated: bool = false

var _viewport: SubViewport = null
var _env_root: Node3D = null
var _env_centers: Array = []
var _env_key: String = ""
var _preview_clock: float = 0.0
var _body_root: Node3D = null
var _gravity_area: Area3D = null
var _scene_root: Node = null
var _trimesh_cache: Dictionary = {}
var _pending_snap: Array = []
var _drag_item: SimItem = null
var _drag_local_point: Vector3 = Vector3.ZERO
var _drag_target: Vector3 = Vector3.ZERO
var _drag_active: bool = false
var _drag_handle_pos: Vector3 = Vector3.ZERO
var _drag_lock_quat: Quaternion = Quaternion.IDENTITY
var _motion_seen: bool = false
var _suspended_spaces: Array = []
var _server_activated: bool = false


func _enter_tree() -> void:
	set_physics_process(false)


func _exit_tree() -> void:
	reset(true)


func setup(p_settings: PPSettings) -> void:
	settings = p_settings


func set_scene(scene_root: Node) -> void:
	_scene_root = scene_root


func _ensure_viewport() -> void:
	if is_instance_valid(_viewport):
		return
	_viewport = SubViewport.new()
	_viewport.name = "PPSimViewport"
	_viewport.world_3d = World3D.new()
	_viewport.own_world_3d = true
	_viewport.disable_3d = false
	_viewport.physics_object_picking = false
	_viewport.handle_input_locally = false
	_viewport.gui_disable_input = true
	_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_viewport.size = Vector2i(2, 2)
	add_child(_viewport)

	_env_root = Node3D.new()
	_env_root.name = "Environment"
	_viewport.add_child(_env_root)

	_body_root = Node3D.new()
	_body_root.name = "Bodies"
	_viewport.add_child(_body_root)

	var space: RID = _viewport.world_3d.space
	if space.is_valid():
		PhysicsServer3D.space_set_active(space, true)


func _refresh_gravity() -> void:
	if settings == null or _viewport == null:
		return
	if settings.use_project_gravity:
		if is_instance_valid(_gravity_area):
			_gravity_area.queue_free()
			_gravity_area = null
		return
	if not is_instance_valid(_gravity_area):
		_gravity_area = Area3D.new()
		_gravity_area.name = "GravityOverride"
		var shape := CollisionShape3D.new()
		var box := BoxShape3D.new()
		box.size = Vector3.ONE * 100000.0
		shape.shape = box
		_gravity_area.add_child(shape)
		_viewport.add_child(_gravity_area)
	var g: Vector3 = settings.gravity_vector()
	_gravity_area.gravity_space_override = Area3D.SPACE_OVERRIDE_REPLACE
	_gravity_area.gravity_point = false
	_gravity_area.gravity_direction = g.normalized()
	_gravity_area.gravity = g.length()
	_gravity_area.priority = 100


func has_items() -> bool:
	return not items.is_empty()


func _editor_spaces() -> Array:
	var out: Array = []
	if not Engine.is_editor_hint():
		return out
	for i in 4:
		var vp: SubViewport = EditorInterface.get_editor_viewport_3d(i)
		if vp == null:
			continue
		var world: World3D = vp.find_world_3d()
		if world != null and world.space.is_valid() and not out.has(world.space):
			out.append(world.space)
	var root: Node = EditorInterface.get_edited_scene_root()
	if root != null and root.get_viewport() != null:
		var world2: World3D = root.get_viewport().find_world_3d()
		if world2 != null and world2.space.is_valid() and not out.has(world2.space):
			out.append(world2.space)
	return out


func _activate_server() -> void:
	if _server_activated:
		return
	_suspended_spaces.clear()
	var own_space: RID = _viewport.world_3d.space if is_instance_valid(_viewport) else RID()
	if settings == null or settings.sim_mode != PPSettings.SimMode.NATIVE:
		for space in _editor_spaces():
			if space == own_space:
				continue
			PhysicsServer3D.space_set_active(space, false)
			_suspended_spaces.append(space)
	if own_space.is_valid():
		PhysicsServer3D.space_set_active(own_space, true)
	PhysicsServer3D.set_active(true)
	_server_activated = true


func _deactivate_server() -> void:
	if not _server_activated:
		return
	PhysicsServer3D.set_active(false)
	for space in _suspended_spaces:
		PhysicsServer3D.space_set_active(space, true)
	_suspended_spaces.clear()
	_server_activated = false


func add_object(node: Node3D) -> SimItem:
	if node == null or settings == null:
		return null
	_ensure_viewport()
	var item := SimItem.new()
	item.source = node
	item.start_global = node.global_transform
	var dec: Dictionary = PPUtils.decompose(node.global_transform)
	item.scale = dec["scale"]

	if settings.sim_mode == PPSettings.SimMode.NATIVE:
		if node is RigidBody3D:
			var rb: RigidBody3D = node
			item.native = true
			item.body = rb
			item.native_freeze = rb.freeze
			item.native_freeze_mode = rb.freeze_mode
			item.native_gravity = rb.gravity_scale
			rb.freeze = false
			rb.sleeping = false
			items.append(item)
			return item
		last_warning = "Native mode skipped %s (not a RigidBody3D)." % node.name
		return null

	var res: Dictionary = PPUtils.make_dynamic_shapes(node, settings.dynamic_shape_mode)
	item.generated = res["generated"]
	item.gen_shapes = res["shapes"]
	item.body = _make_body(res["shapes"], item.scale, dec["rigid"])
	items.append(item)
	return item


func add_spawn(scene: PackedScene, xform: Transform3D, velocity: Vector3, spin: Vector3, delay: float, preview_parent: Node) -> SimItem:
	if scene == null or settings == null or preview_parent == null:
		return null
	_ensure_viewport()
	var inst: Node = scene.instantiate()
	if not (inst is Node3D):
		inst.free()
		last_warning = "Tosser scene root must be a Node3D."
		return null
	var node3d: Node3D = inst
	var own_scale: Vector3 = node3d.transform.basis.get_scale()
	preview_parent.add_child(node3d)
	node3d.owner = null
	node3d.set_meta("_pp_preview", true)
	var placed: Transform3D = PPUtils.recompose(xform, own_scale * xform.basis.get_scale())
	node3d.global_transform = placed
	if node3d is RigidBody3D:
		(node3d as RigidBody3D).freeze = true

	var item := SimItem.new()
	item.is_spawn = true
	item.spawn_scene = scene
	item.preview = node3d
	item.start_global = placed
	var dec: Dictionary = PPUtils.decompose(placed)
	item.scale = dec["scale"]
	var res: Dictionary = PPUtils.make_dynamic_shapes(node3d, settings.dynamic_shape_mode)
	item.generated = res["generated"]
	item.gen_shapes = res["shapes"]
	item.body = _make_body(res["shapes"], item.scale, dec["rigid"])
	item.body.freeze = true
	item.body.freeze_mode = RigidBody3D.FREEZE_MODE_STATIC
	item.pending_launch = true
	item.launch_time = delay
	item.launch_velocity = velocity
	item.launch_spin = spin
	_set_body_collision(item.body, false)
	items.append(item)
	return item


func _make_body(shapes: Array, scale: Vector3, rigid_xform: Transform3D) -> RigidBody3D:
	var body := RigidBody3D.new()
	body.mass = maxf(0.001, settings.mass)
	body.physics_material_override = settings.make_physics_material()
	body.continuous_cd = settings.continuous_cd
	body.linear_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	body.angular_damp_mode = RigidBody3D.DAMP_MODE_REPLACE
	body.linear_damp = settings.linear_damp
	body.angular_damp = settings.angular_damp
	body.can_sleep = true
	body.contact_monitor = false
	var scale_basis := Transform3D(Basis.from_scale(scale), Vector3.ZERO)
	for entry in shapes:
		var cs := CollisionShape3D.new()
		cs.shape = entry["shape"]
		cs.transform = scale_basis * (entry["xform"] as Transform3D)
		body.add_child(cs)
	_body_root.add_child(body)
	body.global_transform = rigid_xform
	return body


func _set_body_collision(body: RigidBody3D, enabled: bool) -> void:
	if not is_instance_valid(body):
		return
	body.collision_layer = 1 if enabled else 0
	body.collision_mask = 1 if enabled else 0


func environment_key(exclude: Array) -> String:
	var ids: Array = []
	for n in exclude:
		if n is Node:
			ids.append(str((n as Node).get_instance_id()))
	ids.sort()
	# The node count is a cheap change signal: baking new objects, deleting props or
	# opening another scene all move it, which retires the cached environment.
	return "%s|%d|%s|%s|%s|%d|%.2f" % [
		str(_scene_root.get_instance_id()) if _scene_root != null else "0",
		PPUtils.count_descendants(_scene_root),
		",".join(PackedStringArray(ids)),
		str(settings.env_use_scene_colliders), str(settings.env_use_mesh_geometry),
		settings.env_mesh_budget, settings.env_radius]


func invalidate_environment() -> void:
	_env_key = ""


func build_environment(exclude: Array, force: bool = false) -> void:
	_ensure_viewport()
	if not force and settings != null and _scene_root != null:
		var key: String = environment_key(exclude)
		if key == _env_key and is_instance_valid(_env_root) and _env_root.get_child_count() > 0:
			return
		_env_key = key
	_clear_env()
	if _scene_root == null or settings == null:
		return
	env_shape_count = 0
	env_source_count = 0
	env_truncated = false
	_env_centers.clear()
	if settings.env_radius > 0.0:
		for n in exclude:
			if n is Node3D:
				_env_centers.append((n as Node3D).global_position)
	var env := StaticBody3D.new()
	env.name = "EnvCollision"
	env.physics_material_override = settings.make_physics_material()
	_env_root.add_child(env)

	var covered: Array = []
	if settings.env_use_scene_colliders:
		var bodies: Array = []
		if _scene_root is CollisionObject3D and not PPUtils.is_excluded(_scene_root, exclude):
			bodies.append(_scene_root)
		PPUtils.collect_descendants(_scene_root, func(n: Node) -> bool:
			return n is CollisionObject3D and not (n is Area3D), exclude, bodies)
		for co in bodies:
			if not _within_env_radius(co):
				continue
			var entries: Array = PPUtils.collect_collision_shapes(co, exclude)
			if entries.is_empty():
				continue
			covered.append(co)
			env_source_count += 1
			for entry in entries:
				var world_xf: Transform3D = (co as Node3D).global_transform * (entry["xform"] as Transform3D)
				var cs := CollisionShape3D.new()
				cs.shape = entry["shape"]
				env.add_child(cs)
				cs.global_transform = world_xf
				env_shape_count += 1

	if settings.env_use_mesh_geometry:
		var baked: Array = []
		if _is_baked_geometry(_scene_root) and not PPUtils.is_excluded(_scene_root, exclude):
			baked.append(_scene_root)
		PPUtils.collect_descendants(_scene_root, func(n: Node) -> bool: return _is_baked_geometry(n), exclude, baked)
		for source in baked:
			if PPUtils.is_excluded(source, covered) or not _within_env_radius(source):
				continue
			var pairs: Array = source.call("get_meshes")
			var i := 0
			while i + 1 < pairs.size():
				var local_xf: Transform3D = pairs[i]
				var baked_mesh: Mesh = pairs[i + 1]
				i += 2
				if baked_mesh == null:
					continue
				var baked_shape: Shape3D = _trimesh_for(baked_mesh)
				if baked_shape == null:
					continue
				var bxf: Transform3D = (source as Node3D).global_transform * local_xf
				var bcs := CollisionShape3D.new()
				bcs.shape = baked_shape
				env.add_child(bcs)
				bcs.global_transform = bxf
				env_shape_count += 1
			env_source_count += 1

		var meshes: Array = []
		if _scene_root is MeshInstance3D and not PPUtils.is_excluded(_scene_root, exclude):
			meshes.append(_scene_root)
		PPUtils.collect_descendants(_scene_root, func(n: Node) -> bool: return n is MeshInstance3D, exclude, meshes)
		var count := 0
		var converted := 0
		for mi in meshes:
			if PPUtils.is_excluded(mi, covered) or not _within_env_radius(mi):
				continue
			var mesh: Mesh = (mi as MeshInstance3D).mesh
			if mesh == null:
				continue
			# The budget caps how many DISTINCT meshes get converted to a trimesh,
			# not how many instances are placed: reusing a cached shape is free.
			if not _trimesh_cache.has(str(mesh.get_rid())):
				if converted >= settings.env_mesh_budget:
					env_truncated = true
					continue
				converted += 1
			var shape: Shape3D = _trimesh_for(mesh)
			if shape == null:
				continue
			var mxf: Transform3D = (mi as Node3D).global_transform
			var cs2 := CollisionShape3D.new()
			cs2.shape = shape
			env.add_child(cs2)
			cs2.global_transform = mxf
			count += 1
			env_shape_count += 1
			env_source_count += 1


func _within_env_radius(node: Node) -> bool:
	if settings.env_radius <= 0.0 or _env_centers.is_empty():
		return true
	if not (node is Node3D):
		return true
	var aabb: AABB = PPUtils.pickable_aabb(node as Node3D)
	var reach: float = settings.env_radius + aabb.size.length() * 0.5
	var p: Vector3 = (node as Node3D).global_position
	for c in _env_centers:
		if p.distance_to(c) <= reach:
			return true
	return false


func _is_baked_geometry(node: Node) -> bool:
	if node == null or not (node is Node3D):
		return false
	if node.is_class("GridMap"):
		return true
	if node.is_class("CSGShape3D"):
		return bool(node.call("is_root_shape"))
	return false


func _trimesh_for(mesh: Mesh) -> Shape3D:
	var key: String = str(mesh.get_rid())
	if _trimesh_cache.has(key):
		return _trimesh_cache[key]
	var shape: Shape3D = mesh.create_trimesh_shape()
	_trimesh_cache[key] = shape
	return shape


func start(p_time_limited: bool = true) -> void:
	if settings == null:
		return
	_ensure_viewport()
	_refresh_gravity()
	elapsed = 0.0
	_preview_clock = 0.0
	_motion_seen = false
	time_limited = p_time_limited
	running = true
	launch_offset = 0.0
	for item in items:
		item.settled = false
		item.settled_for = 0.0
		if item.pending_launch:
			launch_offset = maxf(launch_offset, item.launch_time)
		if item.native and is_instance_valid(item.body):
			item.body.sleeping = false
	_activate_server()
	set_physics_process(true)


func stop() -> void:
	if not running:
		return
	running = false
	set_physics_process(false)
	_capture_finals()
	_restore_native()
	_deactivate_server()
	sim_finished.emit()


func set_time_limited(value: bool) -> void:
	time_limited = value
	if value:
		elapsed = 0.0
		launch_offset = 0.0


func request_snap(item: SimItem, gap: float) -> void:
	_pending_snap.append({"item": item, "gap": gap})


func begin_drag(item: SimItem, world_point: Vector3) -> void:
	if item == null or not is_instance_valid(item.body):
		return
	end_drag()
	_drag_item = item
	_drag_active = true
	var body: RigidBody3D = item.body
	var body_xform: Transform3D = body.global_transform
	if settings.drag_grab_at_point:
		_drag_local_point = body_xform.affine_inverse() * world_point
	else:
		_drag_local_point = _body_local_center(body)
	var anchor: Vector3 = body_xform * _drag_local_point
	_drag_target = anchor
	_drag_handle_pos = anchor
	_drag_lock_quat = body_xform.basis.get_rotation_quaternion()
	body.sleeping = false


func update_drag(world_point: Vector3) -> void:
	_drag_target = world_point


func end_drag() -> void:
	_drag_active = false
	_drag_item = null


func is_dragging() -> bool:
	return _drag_active


func drag_anchor_world() -> Vector3:
	if _drag_item == null or not is_instance_valid(_drag_item.body):
		return Vector3.ZERO
	return _drag_item.body.global_transform * _drag_local_point


func _physics_process(delta: float) -> void:
	if not running or settings == null:
		return
	elapsed += delta
	_process_snaps()
	_process_launches()
	_apply_drag(delta)
	var all_settled := _update_settling(delta)
	_preview_clock += delta
	var beat: float = 1.0 / clampf(settings.preview_hz, 1.0, 120.0)
	if _drag_active or _preview_clock >= beat:
		_preview_clock = 0.0
		_mirror()
	sim_tick.emit(elapsed)
	if not time_limited:
		return
	var run_time: float = elapsed - launch_offset
	if run_time >= settings.time_limit:
		stop()
		return
	if settings.stop_when_settled and all_settled and run_time > 0.3 and not _drag_active:
		stop()


func _process_snaps() -> void:
	if _pending_snap.is_empty():
		return
	var space_state: PhysicsDirectSpaceState3D = _viewport.world_3d.direct_space_state
	for entry in _pending_snap:
		var item: SimItem = entry["item"]
		if item == null or not is_instance_valid(item.body):
			continue
		var from: Vector3 = item.body.global_position
		var down: Vector3 = settings.gravity_vector().normalized()
		var query := PhysicsRayQueryParameters3D.create(from, from + down * 1000.0)
		query.exclude = [item.body.get_rid()]
		var hit: Dictionary = space_state.intersect_ray(query)
		if hit.is_empty():
			continue
		var lowest: float = _lowest_offset(item, down)
		var gap: float = entry["gap"]
		var target: Vector3 = hit["position"] - down * (lowest + gap)
		var xf: Transform3D = item.body.global_transform
		xf.origin = target
		PhysicsServer3D.body_set_state(item.body.get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM, xf)
		item.body.global_transform = xf
	_pending_snap.clear()


func _lowest_offset(item: SimItem, down: Vector3) -> float:
	var best := 0.0
	for child in item.body.get_children():
		if not (child is CollisionShape3D):
			continue
		var cs: CollisionShape3D = child
		if cs.shape == null:
			continue
		var box: AABB = _shape_aabb(cs.shape)
		var xf: Transform3D = cs.transform
		for i in 8:
			var corner: Vector3 = xf * box.get_endpoint(i)
			var depth: float = corner.dot(down)
			best = maxf(best, depth)
	return best


func _shape_aabb(shape: Shape3D) -> AABB:
	if shape is BoxShape3D:
		var s: Vector3 = (shape as BoxShape3D).size
		return AABB(-s * 0.5, s)
	if shape is SphereShape3D:
		var r: float = (shape as SphereShape3D).radius
		return AABB(Vector3.ONE * -r, Vector3.ONE * r * 2.0)
	if shape is CapsuleShape3D:
		var cap: CapsuleShape3D = shape
		var h: float = cap.height
		var r2: float = cap.radius
		return AABB(Vector3(-r2, -h * 0.5, -r2), Vector3(r2 * 2.0, h, r2 * 2.0))
	if shape is CylinderShape3D:
		var cyl: CylinderShape3D = shape
		return AABB(Vector3(-cyl.radius, -cyl.height * 0.5, -cyl.radius), Vector3(cyl.radius * 2.0, cyl.height, cyl.radius * 2.0))
	if shape is ConvexPolygonShape3D:
		var pts: PackedVector3Array = (shape as ConvexPolygonShape3D).points
		if pts.is_empty():
			return AABB()
		var box := AABB(pts[0], Vector3.ZERO)
		for p in pts:
			box = box.expand(p)
		return box
	return AABB(Vector3.ONE * -0.1, Vector3.ONE * 0.2)


func _process_launches() -> void:
	for item in items:
		if not item.pending_launch:
			continue
		if item.launch_time > 0.0 and elapsed < item.launch_time:
			continue
		if not is_instance_valid(item.body):
			item.pending_launch = false
			continue
		item.pending_launch = false
		_set_body_collision(item.body, true)
		item.body.freeze = false
		item.body.sleeping = false
		PhysicsServer3D.body_set_state(item.body.get_rid(), PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, item.launch_velocity)
		PhysicsServer3D.body_set_state(item.body.get_rid(), PhysicsServer3D.BODY_STATE_ANGULAR_VELOCITY, item.launch_spin)


func _body_local_center(body: RigidBody3D) -> Vector3:
	var total := Vector3.ZERO
	var count := 0
	for child in body.get_children():
		if not (child is CollisionShape3D):
			continue
		var cs: CollisionShape3D = child
		if cs.shape == null:
			continue
		total += cs.transform * _shape_aabb(cs.shape).get_center()
		count += 1
	if count == 0:
		return Vector3.ZERO
	return total / float(count)


func _apply_drag(delta: float) -> void:
	if not _drag_active or _drag_item == null or not is_instance_valid(_drag_item.body):
		return
	var body: RigidBody3D = _drag_item.body
	body.sleeping = false
	var rid: RID = body.get_rid()
	var mass: float = maxf(0.001, body.mass)
	var xform: Transform3D = body.global_transform
	var carrying: bool = settings.drag_hold_mode == PPSettings.DragHold.CARRY
	var local_point: Vector3 = _body_local_center(body) if carrying else _drag_local_point
	var anchor: Vector3 = xform * local_point

	var step: Vector3 = (_drag_target - _drag_handle_pos) * clampf(settings.drag_strength, 0.01, 1.0)
	var max_step: float = maxf(0.001, settings.drag_max_speed) * delta
	if step.length() > max_step:
		step = step.normalized() * max_step
	_drag_handle_pos += step
	var stretch: Vector3 = _drag_handle_pos - anchor
	var max_stretch: float = maxf(0.001, settings.drag_max_stretch)
	if stretch.length() > max_stretch:
		stretch = stretch.normalized() * max_stretch
		_drag_handle_pos = anchor + stretch

	var omega: float = TAU * maxf(0.05, settings.drag_stiffness)
	var stiffness: float = mass * omega * omega
	var damping: float = 2.0 * mass * omega
	var offset: Vector3 = anchor - xform.origin
	var lin: Vector3 = PhysicsServer3D.body_get_state(rid, PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY)
	var ang: Vector3 = PhysicsServer3D.body_get_state(rid, PhysicsServer3D.BODY_STATE_ANGULAR_VELOCITY)
	var point_vel: Vector3 = lin + ang.cross(offset)
	var force: Vector3 = stretch * stiffness - point_vel * damping
	var cap: float = maxf(0.0, settings.drag_max_force) * mass
	if cap > 0.0 and force.length() > cap:
		force = force.normalized() * cap
	PhysicsServer3D.body_apply_force(rid, force, offset)

	var max_speed: float = maxf(0.1, settings.drag_max_speed)
	if lin.length() > max_speed * 2.0:
		PhysicsServer3D.body_set_state(rid, PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY, lin.normalized() * max_speed * 2.0)

	if carrying:
		var current: Quaternion = xform.basis.get_rotation_quaternion().normalized()
		var error: Quaternion = (_drag_lock_quat * current.inverse()).normalized()
		if error.w < 0.0:
			error = -error
		var angle: float = 2.0 * acos(clampf(error.w, -1.0, 1.0))
		var correction := Vector3.ZERO
		if angle > 0.0005:
			var sin_half: float = sqrt(maxf(0.0, 1.0 - error.w * error.w))
			if sin_half > 0.00001:
				correction = Vector3(error.x, error.y, error.z) / sin_half * angle * 12.0
		if correction.length() > 20.0:
			correction = correction.normalized() * 20.0
		PhysicsServer3D.body_set_state(rid, PhysicsServer3D.BODY_STATE_ANGULAR_VELOCITY, correction)
		return

	ang *= maxf(0.0, 1.0 - maxf(0.0, settings.drag_angular_damp) * delta)
	if ang.length() > 25.0:
		ang = ang.normalized() * 25.0
	PhysicsServer3D.body_set_state(rid, PhysicsServer3D.BODY_STATE_ANGULAR_VELOCITY, ang)


func _mirror() -> void:
	for item in items:
		if item.native:
			if is_instance_valid(item.source):
				item.final_global = item.source.global_transform
			continue
		if not is_instance_valid(item.body):
			continue
		if item.retired or (item.asleep and item.preview_clean):
			continue
		item.preview_clean = item.asleep
		var xf: Transform3D = PhysicsServer3D.body_get_state(item.body.get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM)
		item.final_global = PPUtils.recompose(xf, item.scale)
		if not item.start_global.origin.is_equal_approx(item.final_global.origin):
			_motion_seen = true
		if not settings.live_preview:
			continue
		var target: Node3D = item.preview if item.is_spawn else item.source
		if is_instance_valid(target):
			target.global_transform = item.final_global


func _update_settling(delta: float) -> bool:
	var all_settled := true
	for item in items:
		if item.pending_launch:
			all_settled = false
			continue
		if item.retired:
			continue
		if not is_instance_valid(item.body):
			continue
		var rid: RID = item.body.get_rid()
		# A sleeping body cannot be moving, so skip the velocity queries entirely.
		# This is re-checked every frame, so a body woken by a later impact resumes.
		if bool(PhysicsServer3D.body_get_state(rid, PhysicsServer3D.BODY_STATE_SLEEPING)):
			item.asleep = true
			item.settled = true
			item.settled_for = maxf(item.settled_for, settings.settle_time)
			continue
		item.asleep = false
		item.preview_clean = false
		var lin: Vector3 = PhysicsServer3D.body_get_state(rid, PhysicsServer3D.BODY_STATE_LINEAR_VELOCITY)
		var ang: Vector3 = PhysicsServer3D.body_get_state(rid, PhysicsServer3D.BODY_STATE_ANGULAR_VELOCITY)
		if lin.length() <= settings.settle_linear and ang.length() <= settings.settle_angular:
			item.settled_for += delta
		else:
			item.settled_for = 0.0
		item.settled = item.settled_for >= settings.settle_time
		var held: bool = _drag_active and item == _drag_item
		if item.settled and not held and time_limited and settings.retire_settled \
				and item.settled_for >= settings.settle_time * 2.0:
			# Once the volley is over and a body has held still, take it out of the
			# physics space completely. A sleeping body still carries its contact
			# pairs; a spaceless one costs nothing at all.
			item.final_global = PPUtils.recompose(
				PhysicsServer3D.body_get_state(rid, PhysicsServer3D.BODY_STATE_TRANSFORM), item.scale)
			PhysicsServer3D.body_set_space(rid, RID())
			item.retired = true
			item.asleep = true
			continue
		if item.settled and not held and settings.sleep_settled:
			# Godot's own sleep thresholds rarely fire for a pile of resting props,
			# so once our settle test passes we park the body ourselves. The solver
			# skips sleeping bodies, and a later impact still wakes them.
			PhysicsServer3D.body_set_state(rid, PhysicsServer3D.BODY_STATE_SLEEPING, true)
			item.asleep = true
		if not item.settled:
			all_settled = false
	return all_settled


func _capture_finals() -> void:
	for item in items:
		if item.retired:
			continue
		if item.native:
			if is_instance_valid(item.source):
				item.final_global = item.source.global_transform
			continue
		if not is_instance_valid(item.body):
			continue
		var xf: Transform3D = PhysicsServer3D.body_get_state(item.body.get_rid(), PhysicsServer3D.BODY_STATE_TRANSFORM)
		item.final_global = PPUtils.recompose(xf, item.scale)


func _restore_native() -> void:
	for item in items:
		if not item.native or not is_instance_valid(item.body):
			continue
		item.body.freeze = item.native_freeze
		item.body.freeze_mode = item.native_freeze_mode


func restore_start_transforms() -> void:
	for item in items:
		if item.is_spawn:
			continue
		if is_instance_valid(item.source):
			item.source.global_transform = item.start_global


func generated_count() -> int:
	var n := 0
	for item in items:
		if item.generated and not item.is_spawn:
			n += 1
	return n


func moved() -> bool:
	return _motion_seen


func clear_previews() -> void:
	for item in items:
		if is_instance_valid(item.preview):
			item.preview.get_parent().remove_child(item.preview)
			item.preview.queue_free()
		item.preview = null


func reset(full: bool = false) -> void:
	running = false
	set_physics_process(false)
	_deactivate_server()
	_drag_active = false
	_drag_item = null
	_pending_snap.clear()
	_restore_native()
	clear_previews()
	for item in items:
		if item.native:
			continue
		if is_instance_valid(item.body):
			item.body.get_parent().remove_child(item.body)
			item.body.queue_free()
	items.clear()
	if full:
		_clear_env()
		_trimesh_cache.clear()
		_env_key = ""


func _clear_env() -> void:
	if not is_instance_valid(_env_root):
		return
	for child in _env_root.get_children():
		_env_root.remove_child(child)
		child.queue_free()
