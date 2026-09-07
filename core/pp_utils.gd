@tool
class_name PPUtils
extends RefCounted


static func count_descendants(root: Node) -> int:
	if root == null:
		return 0
	var n: int = root.get_child_count()
	for c in root.get_children():
		n += count_descendants(c)
	return n


static func is_excluded(node: Node, exclude: Array) -> bool:
	var n: Node = node
	while n != null:
		if exclude.has(n):
			return true
		n = n.get_parent()
	return false


static func collect_descendants(root: Node, type_check: Callable, exclude: Array, out: Array) -> void:
	if root == null:
		return
	for child in root.get_children():
		if is_excluded(child, exclude):
			continue
		if type_check.call(child):
			out.append(child)
		collect_descendants(child, type_check, exclude, out)


static func find_mesh_instances(root: Node3D, exclude: Array) -> Array:
	var out: Array = []
	if root is MeshInstance3D:
		out.append(root)
	collect_descendants(root, func(n: Node) -> bool: return n is MeshInstance3D, exclude, out)
	return out


static func collect_collision_shapes(root: Node3D, exclude: Array) -> Array:
	var out: Array = []
	_collect_shapes_rec(root, root, out, root is CollisionObject3D, exclude)
	return out


static func _collect_shapes_rec(root: Node3D, node: Node, out: Array, seen_body: bool, exclude: Array) -> void:
	if node != root:
		if exclude.has(node):
			return
		if node is CollisionObject3D:
			if seen_body:
				return
			seen_body = true
	if node is CollisionShape3D:
		var cs: CollisionShape3D = node
		if cs.shape != null and not cs.disabled:
			out.append({
				"shape": cs.shape,
				"xform": root.global_transform.affine_inverse() * cs.global_transform,
			})
	for child in node.get_children():
		_collect_shapes_rec(root, child, out, seen_body, exclude)


static func make_dynamic_shapes(node: Node3D, shape_mode: int) -> Dictionary:
	var existing: Array = collect_collision_shapes(node, [])
	var usable: Array = []
	for entry in existing:
		var s: Shape3D = entry["shape"]
		if s is ConcavePolygonShape3D or s is HeightMapShape3D or s is WorldBoundaryShape3D:
			continue
		usable.append(entry)
	if not usable.is_empty():
		return {"shapes": usable, "generated": false}

	var generated: Array = []
	var inv: Transform3D = node.global_transform.affine_inverse()
	for mi in find_mesh_instances(node, []):
		var mesh: Mesh = mi.mesh
		if mesh == null:
			continue
		var rel: Transform3D = inv * mi.global_transform
		if shape_mode == PPSettings.ShapeMode.BOX:
			var aabb: AABB = mesh.get_aabb()
			var box := BoxShape3D.new()
			box.size = aabb.size.max(Vector3.ONE * 0.001)
			generated.append({"shape": box, "xform": rel.translated_local(aabb.get_center())})
		else:
			var simplify: bool = shape_mode == PPSettings.ShapeMode.SIMPLIFIED_CONVEX
			var convex: Shape3D = mesh.create_convex_shape(true, simplify)
			if not is_usable_convex(convex) and simplify:
				convex = mesh.create_convex_shape(true, false)
			if is_usable_convex(convex):
				generated.append({"shape": convex, "xform": rel})
			else:
				var aabb2: AABB = mesh.get_aabb()
				if aabb2.size.length() > 0.0:
					var fallback_box := BoxShape3D.new()
					fallback_box.size = aabb2.size.max(Vector3.ONE * 0.002)
					generated.append({"shape": fallback_box, "xform": rel.translated_local(aabb2.get_center())})

	if generated.is_empty():
		var fallback := BoxShape3D.new()
		fallback.size = Vector3.ONE * 0.25
		generated.append({"shape": fallback, "xform": Transform3D.IDENTITY})

	return {"shapes": generated, "generated": true}


static func is_usable_convex(shape: Shape3D) -> bool:
	if shape == null:
		return false
	if shape is ConvexPolygonShape3D:
		return (shape as ConvexPolygonShape3D).points.size() >= 4
	return true


static func node_local_aabb(node: Node3D) -> AABB:
	var result := AABB()
	var first := true
	var inv: Transform3D = node.global_transform.affine_inverse()
	for mi in find_mesh_instances(node, []):
		if mi.mesh == null:
			continue
		var box: AABB = (inv * mi.global_transform) * mi.mesh.get_aabb()
		if first:
			result = box
			first = false
		else:
			result = result.merge(box)
	if first:
		result = AABB(Vector3.ONE * -0.125, Vector3.ONE * 0.25)
	return result


static func decompose(xform: Transform3D) -> Dictionary:
	var scale: Vector3 = xform.basis.get_scale()
	if absf(scale.x) < 0.0001:
		scale.x = 1.0
	if absf(scale.y) < 0.0001:
		scale.y = 1.0
	if absf(scale.z) < 0.0001:
		scale.z = 1.0
	return {
		"scale": scale,
		"rigid": Transform3D(xform.basis.orthonormalized(), xform.origin),
	}


static func recompose(rigid: Transform3D, scale: Vector3) -> Transform3D:
	return Transform3D(rigid.basis.orthonormalized() * Basis.from_scale(scale), rigid.origin)


static func is_simulatable(node: Node) -> bool:
	if not (node is Node3D):
		return false
	if node.is_in_group(PPSettings.IGNORE_GROUP):
		return false
	if node is Camera3D or node is Light3D or node is Marker3D:
		return false
	if node is CollisionShape3D or node is CollisionPolygon3D:
		return false
	return true


static func find_dynamic_candidates(scene_root: Node, selection: Array, settings: PPSettings, extra_centers: Array = []) -> Array:
	var extra: Array = []
	if not settings.affect_scene_objects:
		return extra
	if scene_root == null:
		return extra

	var pool: Array = []
	if settings.dynamic_scope == PPSettings.DynamicScope.ALL_TAGGED:
		collect_descendants(scene_root, func(n: Node) -> bool:
			return n is Node3D and n.is_in_group(PPSettings.DYNAMIC_GROUP), [], pool)
	elif settings.dynamic_scope == PPSettings.DynamicScope.NEARBY:
		var centers: Array = extra_centers.duplicate()
		for s in selection:
			if s is Node3D:
				centers.append((s as Node3D).global_position)
		if centers.is_empty():
			return extra
		var near: Array = []
		collect_descendants(scene_root, func(n: Node) -> bool:
			return n is RigidBody3D or (n is Node3D and n.is_in_group(PPSettings.DYNAMIC_GROUP)), [], near)
		for n in near:
			var p: Vector3 = (n as Node3D).global_position
			for c in centers:
				if p.distance_to(c) <= settings.nearby_radius:
					pool.append(n)
					break
	else:
		return extra

	for n in pool:
		if selection.has(n):
			continue
		if is_excluded(n, selection):
			continue
		if not is_simulatable(n):
			continue
		if not extra.has(n):
			extra.append(n)
	return extra


static func ray_plane(from: Vector3, dir: Vector3, plane_point: Vector3, plane_normal: Vector3) -> Variant:
	var denom: float = plane_normal.dot(dir)
	if absf(denom) < 0.00001:
		return null
	var t: float = plane_normal.dot(plane_point - from) / denom
	if t < 0.0:
		return null
	return from + dir * t


static func subtree_has_geometry(node: Node) -> bool:
	if node is GeometryInstance3D:
		return true
	for c in node.get_children():
		if subtree_has_geometry(c):
			return true
	return false


static func geometry_child_count(node: Node) -> int:
	var n := 0
	for c in node.get_children():
		if subtree_has_geometry(c):
			n += 1
			if n > 1:
				return n
	return n


static func has_direct_body_child(node: Node) -> bool:
	for c in node.get_children():
		if c is CollisionObject3D:
			return true
	return false


static func resolve_object_root(node: Node, scene_root: Node, mode: int = PPSettings.GrabTarget.PROP) -> Node3D:
	if not (node is Node3D):
		return null
	var start: Node3D = node
	if mode == PPSettings.GrabTarget.EXACT:
		return start

	# Explicit signals win: an author-tagged prop, then the nearest instanced scene.
	var n: Node = start
	var instanced: Node3D = null
	while n != null and n != scene_root:
		if n is Node3D:
			if n.is_in_group(PPSettings.DYNAMIC_GROUP):
				return n
			if instanced == null and not (n as Node3D).scene_file_path.is_empty():
				instanced = n
		n = n.get_parent()
	if instanced != null:
		return instanced

	if mode == PPSettings.GrabTarget.TOP:
		var top: Node3D = start
		var t: Node = start
		while t != null and t != scene_root:
			if t is Node3D and t.get_parent() == scene_root:
				top = t
			t = t.get_parent()
		return top

	# Climb only while the parent still describes ONE prop: it either holds a single
	# geometry-bearing subtree, or owns collision directly. A node holding several
	# separate geometry children is a container and must not be grabbed as a whole.
	var current: Node3D = start
	while true:
		var parent: Node = current.get_parent()
		if parent == null or parent == scene_root or not (parent is Node3D):
			break
		if geometry_child_count(parent) > 1 and not has_direct_body_child(parent):
			break
		current = parent
	return current


static func pickable_aabb(node: Node3D) -> AABB:
	if node is GeometryInstance3D:
		return (node as GeometryInstance3D).get_aabb()
	return AABB()


static func pick_object(scene_root: Node, from: Vector3, dir: Vector3, exclude: Array, grab_mode: int = PPSettings.GrabTarget.PROP) -> Dictionary:
	var result: Dictionary = {}
	if scene_root == null:
		return result
	var visuals: Array = []
	if scene_root is GeometryInstance3D:
		visuals.append(scene_root)
	collect_descendants(scene_root, func(n: Node) -> bool: return n is GeometryInstance3D, exclude, visuals)
	var best_dist: float = INF
	for v in visuals:
		var gi: GeometryInstance3D = v
		if not gi.is_visible_in_tree():
			continue
		var aabb: AABB = pickable_aabb(gi)
		if aabb.size.x <= 0.0 and aabb.size.y <= 0.0 and aabb.size.z <= 0.0:
			continue
		var inv: Transform3D = gi.global_transform.affine_inverse()
		var local_from: Vector3 = inv * from
		var local_dir: Vector3 = (inv.basis * dir).normalized()
		var hit: Variant = aabb.intersects_ray(local_from, local_dir)
		if hit == null:
			continue
		var world_hit: Vector3 = gi.global_transform * (hit as Vector3)
		var d: float = from.distance_to(world_hit)
		if d < best_dist:
			best_dist = d
			result = {
				"node": resolve_object_root(gi, scene_root, grab_mode),
				"visual": gi,
				"position": world_hit,
				"distance": d,
			}
	return result


static func top_level_nodes(nodes: Array) -> Array:
	var out: Array = []
	for n in nodes:
		if not (n is Node3D):
			continue
		var skip := false
		for other in nodes:
			if other == n or not (other is Node3D):
				continue
			if n != other and (other as Node).is_ancestor_of(n):
				skip = true
				break
		if not skip and not out.has(n):
			out.append(n)
	return out
