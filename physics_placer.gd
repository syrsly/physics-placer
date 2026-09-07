@tool
extends EditorPlugin

const SettingsScript := preload("res://addons/physics_placer/core/pp_settings.gd")
const UtilsScript := preload("res://addons/physics_placer/core/pp_utils.gd")
const BakerScript := preload("res://addons/physics_placer/core/pp_baker.gd")
const SimScript := preload("res://addons/physics_placer/core/pp_sim.gd")
const ToolScript := preload("res://addons/physics_placer/tools/pp_tool.gd")
const DropperScript := preload("res://addons/physics_placer/tools/pp_dropper.gd")
const DraggerScript := preload("res://addons/physics_placer/tools/pp_dragger.gd")
const ShooterScript := preload("res://addons/physics_placer/tools/pp_shooter.gd")
const DockScript := preload("res://addons/physics_placer/ui/pp_dock.gd")

var settings: PPSettings = null
var sim: PPSim = null
var dropper: PPDropper = null
var dragger: PPDragger = null
var shooter: PPShooter = null
var tools: Array = []
var current_index: int = -1
var current_tool: PPTool = null

var dock: PPDock = null
var toolbar: HBoxContainer = null
var _toolbar_buttons: Array = []
var _overlay_clock: float = 0.0
var _input_calls: int = 0
var _reassert_clock: float = 0.0
var _progress_ticks: int = 0


func _enter_tree() -> void:
	settings = SettingsScript.load_or_create()

	sim = SimScript.new()
	sim.name = "PhysicsPlacerSim"
	sim.setup(settings)
	add_child(sim)
	sim.sim_finished.connect(_on_sim_finished)
	sim.sim_tick.connect(_on_sim_tick)

	dropper = DropperScript.new()
	dragger = DraggerScript.new()
	shooter = ShooterScript.new()
	tools = [dropper, dragger, shooter]
	for t in tools:
		t.setup(self, sim, settings)
		t.status_changed.connect(_on_status)

	dock = DockScript.new()
	dock.setup(self, settings, dropper, dragger, shooter)
	add_control_to_dock(DOCK_SLOT_RIGHT_BL, dock)

	toolbar = HBoxContainer.new()
	toolbar.add_theme_constant_override("separation", 2)
	var sep := VSeparator.new()
	toolbar.add_child(sep)
	for entry in [["Drop", 0], ["Drag", 1], ["Shoot", 2]]:
		var b := Button.new()
		b.text = entry[0]
		b.toggle_mode = true
		b.flat = true
		b.tooltip_text = "Physics Placer: %s" % entry[0]
		b.pressed.connect(_on_toolbar_pressed.bind(entry[1]))
		toolbar.add_child(b)
		_toolbar_buttons.append(b)
	add_control_to_container(CONTAINER_SPATIAL_EDITOR_MENU, toolbar)

	set_tool(-1)


func _exit_tree() -> void:
	set_tool(-1)
	if settings != null:
		settings.save()
	if toolbar != null:
		remove_control_from_container(CONTAINER_SPATIAL_EDITOR_MENU, toolbar)
		toolbar.queue_free()
		toolbar = null
	if dock != null:
		remove_control_from_docks(dock)
		dock.queue_free()
		dock = null
	if sim != null:
		sim.reset(true)
		remove_child(sim)
		sim.queue_free()
		sim = null


func _get_plugin_name() -> String:
	return "Physics Placer"


func set_tool(index: int) -> void:
	if current_tool != null:
		current_tool.deactivate()
	current_index = index
	current_tool = null
	if index >= 0 and index < tools.size():
		current_tool = tools[index]
		_ensure_viewport_focus()
		current_tool.activate()
	set_process(current_tool != null)
	if dock != null:
		dock.sync_tool(index)
		if current_tool == null:
			dock.set_status("Pick a subtool.")
		dock.set_progress(0.0)
	for i in _toolbar_buttons.size():
		_toolbar_buttons[i].set_pressed_no_signal(i == index)
	update_overlays()


func _process(delta: float) -> void:
	if current_tool == null:
		return
	# If the editor never handed us viewport input, re-assert that we edit the
	# current node so the forwarding chain is rebuilt.
	if _input_calls == 0:
		_reassert_clock += delta
		if _reassert_clock >= 2.0:
			_reassert_clock = 0.0
			_ensure_viewport_focus()
	current_tool.tick(delta)
	_overlay_clock += delta
	if _overlay_clock < 0.033:
		return
	_overlay_clock = 0.0
	if current_tool.wants_continuous_overlay():
		update_overlays()


func _ensure_viewport_focus() -> void:
	var root: Node = EditorInterface.get_edited_scene_root()
	if root == null:
		return
	var selection: EditorSelection = EditorInterface.get_selection()
	var target: Node = null
	for n in selection.get_selected_nodes():
		if n is Node3D:
			target = n
			break
	if target == null:
		target = root
		selection.add_node(root)
	EditorInterface.edit_node(target)


func cancel_current() -> void:
	if current_tool != null:
		current_tool.cancel()
	elif sim != null:
		sim.reset()
	if dock != null:
		dock.set_progress(0.0)
	update_overlays()


func _on_toolbar_pressed(index: int) -> void:
	set_tool(-1 if current_index == index else index)


func _on_status(text: String) -> void:
	if dock != null:
		dock.set_status(text)


func _on_sim_tick(elapsed: float) -> void:
	# The dock progress bar and the viewport overlay are both redraw-heavy; the
	# process loop already refreshes the overlay at its own rate.
	_progress_ticks += 1
	if _progress_ticks < 8:
		return
	_progress_ticks = 0
	if dock != null and settings != null:
		var limit: float = maxf(0.01, settings.time_limit)
		dock.set_progress(clampf((elapsed - sim.launch_offset) / limit, 0.0, 1.0))


func _on_sim_finished() -> void:
	if current_tool != null:
		current_tool.on_sim_finished()
	if dock != null:
		dock.set_progress(0.0)
	update_overlays()


func build_diagnostic() -> String:
	var lines: PackedStringArray = PackedStringArray()
	lines.append("=== Physics Placer diagnostic ===")
	lines.append("Godot %s" % Engine.get_version_info().get("string", "?"))
	lines.append("Physics engine: %s" % str(ProjectSettings.get_setting("physics/3d/physics_engine", "DEFAULT")))
	lines.append("Settings version: %d (current %d)" % [settings.version, PPSettings.SETTINGS_VERSION])
	lines.append("Hold mode: %s   Grab at contact point: %s   Swing damping: %.2f"
		% ["HANG" if settings.drag_hold_mode == PPSettings.DragHold.HANG else "CARRY",
			str(settings.drag_grab_at_point), settings.drag_angular_damp])
	lines.append("Max stretch: %.3f   Stiffness: %.2f Hz   Max force: %.0f"
		% [settings.drag_max_stretch, settings.drag_stiffness, settings.drag_max_force])
	lines.append("Env from colliders: %s   from mesh geometry: %s"
		% [str(settings.env_use_scene_colliders), str(settings.env_use_mesh_geometry)])
	lines.append("Input forwarding calls received: %d" % _input_calls)

	var root: Node = EditorInterface.get_edited_scene_root()
	if root == null:
		lines.append("NO 3D SCENE IS OPEN.")
		return "\n".join(lines)
	lines.append("Edited scene root: %s (%s)" % [root.name, root.get_class()])

	var counts: Dictionary = {}
	_count_types(root, counts)
	var keys: Array = counts.keys()
	keys.sort()
	for k in keys:
		lines.append("  %-26s %d" % [k, counts[k]])

	sim.setup(settings)
	sim.set_scene(root)
	sim.reset()
	sim.build_environment([])
	lines.append("Environment built: %d collider(s) from %d source object(s)."
		% [sim.env_shape_count, sim.env_source_count])
	if sim.env_shape_count == 0:
		lines.append("  >>> The scene contributes no collision geometry. Nothing can block a dragged object.")

	var sel: Array[Node] = EditorInterface.get_selection().get_selected_nodes()
	for n in sel:
		if not (n is Node3D):
			continue
		var node3d: Node3D = n
		var res: Dictionary = PPUtils.make_dynamic_shapes(node3d, settings.dynamic_shape_mode)
		var shapes: Array = res["shapes"]
		var desc: PackedStringArray = PackedStringArray()
		for entry in shapes:
			var sh: Shape3D = entry["shape"]
			if sh is ConvexPolygonShape3D:
				desc.append("Convex(%d pts)" % (sh as ConvexPolygonShape3D).points.size())
			else:
				desc.append(sh.get_class())
		lines.append("Selected %s: %d shape(s) %s, generated=%s, scale=%s"
			% [node3d.name, shapes.size(), str(desc), str(res["generated"]),
				str(node3d.global_transform.basis.get_scale())])
		var aabb: AABB = PPUtils.pickable_aabb(node3d)
		lines.append("  pickable directly: %s" % str(aabb.size != Vector3.ZERO))
	if sel.is_empty():
		lines.append("Nothing selected - select the object you drag to include its collider report.")
	sim.reset()
	return "\n".join(lines)


func _count_types(node: Node, counts: Dictionary) -> void:
	for child in node.get_children():
		var key: String = child.get_class()
		counts[key] = int(counts.get(key, 0)) + 1
		_count_types(child, counts)


func _handles(_object: Object) -> bool:
	return current_tool != null


func _forward_3d_gui_input(camera: Camera3D, event: InputEvent) -> int:
	if current_tool == null:
		return AFTER_GUI_INPUT_PASS
	_input_calls += 1
	var result: int = current_tool.handle_input(camera, event)
	update_overlays()
	return result


func _forward_3d_draw_over_viewport(overlay: Control) -> void:
	if current_tool == null:
		return
	var camera: Camera3D = _editor_camera()
	if camera == null:
		return
	current_tool.draw_overlay(overlay, camera)


func _editor_camera() -> Camera3D:
	var vp: SubViewport = EditorInterface.get_editor_viewport_3d(0)
	if vp == null:
		return null
	return vp.get_camera_3d()
