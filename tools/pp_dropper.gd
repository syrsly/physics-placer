@tool
class_name PPDropper
extends PPTool

var _running: bool = false
var _generated: int = 0


func tool_name() -> String:
	return "Dropper"


func deactivate() -> void:
	super.deactivate()
	if _running:
		cancel()
		_running = false


func drop_selection() -> void:
	var targets: Array = selected_nodes()
	if targets.is_empty():
		set_status("Dropper: select one or more 3D nodes first.")
		return
	_begin(targets)


func drop_nodes(nodes: Array) -> void:
	if nodes.is_empty():
		return
	_begin(PPUtils.top_level_nodes(nodes))


func _begin(targets: Array) -> void:
	if _running:
		return
	var items: Array = prepare_sim(targets)
	if items.is_empty():
		if sim.last_warning != "":
			set_status("Dropper: " + sim.last_warning)
		else:
			set_status("Dropper: nothing to simulate.")
		sim.reset()
		return
	_generated = sim.generated_count()
	for item in items:
		if item.native:
			continue
		if settings.drop_snap_before_sim and targets.has(item.source):
			sim.request_snap(item, settings.drop_snap_gap)
		if settings.drop_random_tilt > 0.001 and targets.has(item.source):
			_apply_tilt(item)
	_running = true
	sim.start(true)
	set_status("Dropper: simulating %d object(s)..." % items.size())


func _apply_tilt(item) -> void:
	if not is_instance_valid(item.body):
		return
	var amount: float = deg_to_rad(settings.drop_random_tilt)
	var axis: Vector3 = Vector3(randf() - 0.5, randf() - 0.5, randf() - 0.5)
	if axis.length() < 0.001:
		axis = Vector3.RIGHT
	var xf: Transform3D = item.body.global_transform
	xf.basis = Basis(axis.normalized(), randf_range(-amount, amount)) * xf.basis
	item.body.global_transform = xf


func on_sim_finished() -> void:
	if not _running:
		return
	_running = false
	var msg := ""
	if _generated > 0:
		msg = " (%d collider(s) generated)" % _generated
	finish_and_bake("Physics Placer: Drop")
	set_status(status_text + msg)


func handle_input(camera: Camera3D, event: InputEvent) -> int:
	if not active:
		return EditorPlugin.AFTER_GUI_INPUT_PASS
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE and _running:
		_running = false
		sim.stop()
		cancel()
		return EditorPlugin.AFTER_GUI_INPUT_STOP
	if not (event is InputEventMouseButton):
		return EditorPlugin.AFTER_GUI_INPUT_PASS
	var mb: InputEventMouseButton = event
	if mb.button_index != MOUSE_BUTTON_LEFT or not mb.pressed or _running:
		return EditorPlugin.AFTER_GUI_INPUT_PASS
	var root: Node = scene_root()
	if root == null or camera == null:
		return EditorPlugin.AFTER_GUI_INPUT_PASS
	var from: Vector3 = camera.project_ray_origin(mb.position)
	var dir: Vector3 = camera.project_ray_normal(mb.position)
	var hit: Dictionary = PPUtils.pick_object(root, from, dir, [], settings.grab_target)
	if hit.is_empty():
		return EditorPlugin.AFTER_GUI_INPUT_PASS
	var node: Node3D = hit["node"]
	EditorInterface.get_selection().clear()
	EditorInterface.get_selection().add_node(node)
	if mb.double_click or settings.drop_on_click:
		drop_nodes([node])
	else:
		set_status("Dropper: %s selected. Press Drop Selection or double-click to drop it." % node.name)
	return EditorPlugin.AFTER_GUI_INPUT_STOP
