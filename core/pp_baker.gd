@tool
class_name PPBaker
extends RefCounted


static func bake(undo_redo: EditorUndoRedoManager, sim: PPSim, settings: PPSettings, scene_root: Node, action_name: String, spawn_parent: Node, name_prefix: String = "", freeze_result: bool = false) -> int:
	if undo_redo == null or sim == null or scene_root == null:
		return 0
	var moved: Array = []
	var spawns: Array = []
	for item in sim.items:
		if item.is_spawn:
			if item.spawn_scene != null:
				spawns.append(item)
		elif is_instance_valid(item.source):
			moved.append(item)
	if moved.is_empty() and spawns.is_empty():
		return 0

	undo_redo.create_action(action_name)

	for item in moved:
		undo_redo.add_do_property(item.source, "global_transform", item.final_global)
		undo_redo.add_undo_property(item.source, "global_transform", item.start_global)
		if settings.keep_generated_colliders and item.generated:
			_queue_generated_body(undo_redo, item, settings, scene_root)

	var parent: Node = spawn_parent if spawn_parent != null else scene_root
	var parent_gx := Transform3D.IDENTITY
	if parent is Node3D:
		parent_gx = (parent as Node3D).global_transform
	var index := 1
	for item in spawns:
		var inst: Node = item.spawn_scene.instantiate()
		if not (inst is Node3D):
			inst.free()
			continue
		var n3: Node3D = inst
		var base_name: String = name_prefix
		if base_name.is_empty():
			base_name = n3.name
		n3.name = "%s_%02d" % [base_name, index]
		index += 1
		n3.transform = parent_gx.affine_inverse() * item.final_global
		if n3 is RigidBody3D and freeze_result:
			var rb: RigidBody3D = n3
			rb.freeze = true
			rb.freeze_mode = RigidBody3D.FREEZE_MODE_STATIC
		undo_redo.add_do_method(parent, "add_child", n3, true)
		undo_redo.add_do_method(n3, "set_owner", scene_root)
		undo_redo.add_do_reference(n3)
		undo_redo.add_undo_method(parent, "remove_child", n3)

	undo_redo.commit_action()
	return moved.size() + spawns.size()


static func _queue_generated_body(undo_redo: EditorUndoRedoManager, item, settings: PPSettings, scene_root: Node) -> void:
	var body: CollisionObject3D = null
	match settings.generated_body_type:
		PPSettings.GeneratedBodyType.RIGID_BODY:
			body = RigidBody3D.new()
		PPSettings.GeneratedBodyType.ANIMATABLE_BODY:
			body = AnimatableBody3D.new()
		_:
			body = StaticBody3D.new()
	body.name = "GeneratedCollision"
	var shapes: Array = []
	for entry in item.gen_shapes:
		var cs := CollisionShape3D.new()
		cs.shape = entry["shape"]
		cs.transform = entry["xform"]
		body.add_child(cs)
		shapes.append(cs)
	undo_redo.add_do_method(item.source, "add_child", body, true)
	undo_redo.add_do_method(body, "set_owner", scene_root)
	for cs in shapes:
		undo_redo.add_do_method(cs, "set_owner", scene_root)
	undo_redo.add_do_reference(body)
	undo_redo.add_undo_method(item.source, "remove_child", body)
