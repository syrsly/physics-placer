@tool
class_name PPTool
extends RefCounted

signal status_changed(text: String)

var plugin: Node = null
var sim: PPSim = null
var settings: PPSettings = null
var active: bool = false
var status_text: String = ""


func setup(p_plugin: Node, p_sim: PPSim, p_settings: PPSettings) -> void:
	plugin = p_plugin
	sim = p_sim
	settings = p_settings


func tool_name() -> String:
	return "Tool"


func activate() -> void:
	active = true
	if sim != null:
		sim.invalidate_environment()


func deactivate() -> void:
	active = false


func handle_input(_camera: Camera3D, _event: InputEvent) -> int:
	return EditorPlugin.AFTER_GUI_INPUT_PASS


func draw_overlay(_overlay: Control, _camera: Camera3D) -> void:
	pass


func on_sim_finished() -> void:
	pass


func set_status(text: String) -> void:
	status_text = text
	status_changed.emit(text)


func wants_continuous_overlay() -> bool:
	return false


func tick(_delta: float) -> void:
	pass


func scene_root() -> Node:
	return EditorInterface.get_edited_scene_root()


func editor_camera() -> Camera3D:
	var vp: SubViewport = EditorInterface.get_editor_viewport_3d(0)
	if vp == null:
		return null
	return vp.get_camera_3d()


func selected_nodes() -> Array:
	var out: Array = []
	var sel: Array[Node] = EditorInterface.get_selection().get_selected_nodes()
	for n in sel:
		if n is Node3D and PPUtils.is_simulatable(n):
			out.append(n)
	return PPUtils.top_level_nodes(out)


func prepare_sim(targets: Array, extra_centers: Array = []) -> Array:
	var root: Node = scene_root()
	if root == null:
		set_status("No 3D scene is open.")
		return []
	sim.reset()
	sim.setup(settings)
	sim.set_scene(root)
	var dynamic: Array = targets.duplicate()
	for extra in PPUtils.find_dynamic_candidates(root, targets, settings, extra_centers):
		if not dynamic.has(extra):
			dynamic.append(extra)
	sim.build_environment(dynamic)
	var added: Array = []
	for node in dynamic:
		var item = sim.add_object(node)
		if item != null:
			added.append(item)
	return added


func spawn_name_prefix() -> String:
	return ""


func spawn_freeze() -> bool:
	return false


func finish_and_bake(action_name: String, spawn_parent: Node = null) -> void:
	var root: Node = scene_root()
	if root == null:
		sim.reset()
		return
	var undo_redo: EditorUndoRedoManager = plugin.get_undo_redo()
	var count: int = PPBaker.bake(undo_redo, sim, settings, root, action_name, spawn_parent, spawn_name_prefix(), spawn_freeze())
	sim.clear_previews()
	sim.reset()
	set_status("%s: %d object(s) placed." % [tool_name(), count])


func cancel() -> void:
	if sim == null:
		return
	sim.restore_start_transforms()
	sim.clear_previews()
	sim.reset()
	set_status("%s: cancelled." % tool_name())
