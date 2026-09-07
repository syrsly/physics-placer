@tool
class_name PPDock
extends VBoxContainer

var plugin: Node = null
var settings: PPSettings = null
var dropper: PPDropper = null
var dragger: PPDragger = null
var shooter: PPShooter = null

var _tool_buttons: Array = []
var _panels: Dictionary = {}
var _status: Label = null
var _progress: ProgressBar = null
var _save_timer: Timer = null
var _diag_box: TextEdit = null


func setup(p_plugin: Node, p_settings: PPSettings, p_dropper: PPDropper, p_dragger: PPDragger, p_shooter: PPShooter) -> void:
	plugin = p_plugin
	settings = p_settings
	dropper = p_dropper
	dragger = p_dragger
	shooter = p_shooter
	name = "Physics Placer"
	_build()


func _build() -> void:
	custom_minimum_size = Vector2(280, 0)
	add_theme_constant_override("separation", 6)

	_save_timer = Timer.new()
	_save_timer.one_shot = true
	_save_timer.wait_time = 1.0
	_save_timer.timeout.connect(func() -> void: settings.save())
	add_child(_save_timer)

	var title := Label.new()
	title.text = "Physics Placer"
	title.add_theme_font_size_override("font_size", 15)
	add_child(title)

	var row := GridContainer.new()
	row.columns = 2
	row.add_theme_constant_override("h_separation", 2)
	row.add_theme_constant_override("v_separation", 2)
	add_child(row)
	for entry in [["Drop", 0], ["Drag", 1], ["Shoot", 2]]:
		var b := Button.new()
		b.text = entry[0]
		b.toggle_mode = true
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.tooltip_text = _tooltip_for(entry[1])
		b.pressed.connect(_on_tool_button.bind(entry[1]))
		row.add_child(b)
		_tool_buttons.append(b)

	_status = Label.new()
	_status.text = "Pick a subtool."
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.custom_minimum_size = Vector2(0, 34)
	add_child(_status)

	_progress = ProgressBar.new()
	_progress.min_value = 0.0
	_progress.max_value = 1.0
	_progress.value = 0.0
	_progress.show_percentage = false
	_progress.custom_minimum_size = Vector2(0, 6)
	add_child(_progress)

	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(scroll)

	var body := VBoxContainer.new()
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 4)
	scroll.add_child(body)

	_panels[0] = _build_dropper_panel(body)
	_panels[1] = _build_dragger_panel(body)
	_panels[2] = _build_shooter_panel(body)
	_build_physics_panel(body)
	_build_scene_panel(body)

	var diag := Button.new()
	diag.text = "Run Scene Diagnostic"
	diag.pressed.connect(_on_diagnostic)
	body.add_child(diag)

	_diag_box = TextEdit.new()
	_diag_box.custom_minimum_size = Vector2(0, 190)
	_diag_box.wrap_mode = TextEdit.LINE_WRAPPING_NONE
	_diag_box.visible = false
	body.add_child(_diag_box)

	var reset := Button.new()
	reset.text = "Reset All Settings To Defaults"
	reset.pressed.connect(_on_reset)
	body.add_child(reset)

	var cancel := Button.new()
	cancel.text = "Cancel / Revert Current Run"
	cancel.pressed.connect(_on_cancel)
	add_child(cancel)

	_set_visible_panel(-1)


func _tooltip_for(id: int) -> String:
	match id:
		0:
			return "Drop the selected objects onto whatever is below them and let them land naturally."
		1:
			return "Grab an object with the mouse and push, lean or tip it while physics keeps running."
		_:
			return "Shoot objects from the viewport camera."


func _section(parent: Control, title: String) -> VBoxContainer:
	var sep := HSeparator.new()
	parent.add_child(sep)
	var label := Label.new()
	label.text = title
	label.add_theme_color_override("font_color", Color(0.65, 0.75, 0.95))
	parent.add_child(label)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 3)
	parent.add_child(box)
	return box


func _row(parent: Control, text: String) -> HBoxContainer:
	var hb := HBoxContainer.new()
	hb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(hb)
	if text != "":
		var l := Label.new()
		l.text = text
		l.custom_minimum_size = Vector2(120, 0)
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		hb.add_child(l)
	return hb


func _spin(parent: Control, text: String, value: float, vmin: float, vmax: float, step: float, prop: String) -> SpinBox:
	var hb := _row(parent, text)
	var sb := SpinBox.new()
	sb.min_value = vmin
	sb.max_value = vmax
	sb.step = step
	sb.value = value
	sb.custom_minimum_size = Vector2(90, 0)
	sb.value_changed.connect(func(v: float) -> void: _apply(prop, v))
	hb.add_child(sb)
	return sb


func _check(parent: Control, text: String, value: bool, prop: String) -> CheckBox:
	var cb := CheckBox.new()
	cb.text = text
	cb.button_pressed = value
	cb.toggled.connect(func(v: bool) -> void: _apply(prop, v))
	parent.add_child(cb)
	return cb


func _option(parent: Control, text: String, entries: Array, selected: int, prop: String) -> OptionButton:
	var hb := _row(parent, text)
	var ob := OptionButton.new()
	ob.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for i in entries.size():
		ob.add_item(entries[i], i)
	ob.selected = selected
	ob.item_selected.connect(func(v: int) -> void: _apply(prop, v))
	hb.add_child(ob)
	return ob


func _apply(prop: String, value: Variant) -> void:
	settings.set(prop, value)
	if _save_timer != null:
		_save_timer.start()


func _build_dropper_panel(parent: Control) -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	parent.add_child(box)

	var info := Label.new()
	info.text = "Click an object in the viewport to select it, then press Drop. Double-clicking drops it right away."
	info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(info)

	var drop := Button.new()
	drop.text = "Drop Selection"
	drop.pressed.connect(func() -> void: dropper.drop_selection())
	box.add_child(drop)

	var opts := _section(box, "Dropper Options")
	_check(opts, "Drop immediately on single click", settings.drop_on_click, "drop_on_click")
	_check(opts, "Snap down before simulating", settings.drop_snap_before_sim, "drop_snap_before_sim")
	_spin(opts, "Snap gap (m)", settings.drop_snap_gap, 0.0, 1.0, 0.005, "drop_snap_gap")
	_spin(opts, "Random tilt (deg)", settings.drop_random_tilt, 0.0, 90.0, 1.0, "drop_random_tilt")
	return box


func _build_dragger_panel(parent: Control) -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	parent.add_child(box)

	var info := Label.new()
	info.text = "Hold the left mouse button on an object to pull it. Mouse wheel changes depth, Ctrl locks to the vertical axis, Esc reverts. Releasing freezes it exactly where it is unless you let it settle."
	info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(info)

	var opts := _section(box, "Dragger Options")
	_option(opts, "Hold mode", ["Hang from grab point", "Carry rigidly"], settings.drag_hold_mode, "drag_hold_mode")
	_option(opts, "Grab target", ["Whole prop", "Exact node clicked", "Top node under scene root"], settings.grab_target, "grab_target")
	_check(opts, "Grab at the exact contact point", settings.drag_grab_at_point, "drag_grab_at_point")
	_check(opts, "Let it settle after release", settings.drag_settle_after_release, "drag_settle_after_release")
	_spin(opts, "Stiffness (Hz)", settings.drag_stiffness, 0.1, 20.0, 0.1, "drag_stiffness")
	_spin(opts, "Follow strength", settings.drag_strength, 0.01, 1.0, 0.01, "drag_strength")
	_spin(opts, "Max speed (m/s)", settings.drag_max_speed, 0.1, 200.0, 0.5, "drag_max_speed")
	_spin(opts, "Max stretch (m)", settings.drag_max_stretch, 0.01, 10.0, 0.01, "drag_max_stretch")
	_spin(opts, "Swing damping", settings.drag_angular_damp, 0.0, 40.0, 0.1, "drag_angular_damp")
	_spin(opts, "Max force", settings.drag_max_force, 1.0, 100000.0, 10.0, "drag_max_force")
	return box


func _build_shooter_panel(parent: Control) -> Control:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 4)
	parent.add_child(box)

	var pick_row := _row(box, "Ammo")
	var picker := EditorResourcePicker.new()
	picker.base_type = "PackedScene"
	picker.edited_resource = settings.shoot_scene
	picker.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	picker.resource_changed.connect(func(res: Resource) -> void:
		settings.shoot_scene = res as PackedScene
		_save_timer.start())
	pick_row.add_child(picker)

	var info := Label.new()
	info.text = "Aim in the viewport and hold the left mouse button to fire. Esc cancels the volley."
	info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(info)

	var finish := Button.new()
	finish.text = "Finish Volley"
	finish.pressed.connect(func() -> void: shooter.finish_volley())
	box.add_child(finish)

	var opts := _section(box, "Weapon")
	_spin(opts, "Shot force (m/s)", settings.shoot_force, 0.1, 500.0, 0.5, "shoot_force")
	_spin(opts, "Force jitter", settings.shoot_force_jitter, 0.0, 1.0, 0.01, "shoot_force_jitter")
	_check(opts, "Rapid fire (hold to shoot)", settings.shoot_rapid_fire, "shoot_rapid_fire")
	_spin(opts, "Rate (rounds/sec)", settings.shoot_rate, 0.5, 60.0, 0.5, "shoot_rate")
	_spin(opts, "Spread (deg)", settings.shoot_spread, 0.0, 60.0, 0.1, "shoot_spread")
	_spin(opts, "Magazine limit", settings.shoot_max_rounds, 1, 5000, 10, "shoot_max_rounds")

	var rec := _section(box, "Recoil")
	_spin(rec, "Climb per shot (deg)", settings.shoot_recoil, 0.0, 10.0, 0.05, "shoot_recoil")
	_spin(rec, "Max climb (deg)", settings.shoot_recoil_max, 0.0, 45.0, 0.5, "shoot_recoil_max")
	_spin(rec, "Recovery (deg/sec)", settings.shoot_recoil_recovery, 0.0, 180.0, 1.0, "shoot_recoil_recovery")

	var misc := _section(box, "Rounds")
	_spin(misc, "Muzzle offset (m)", settings.shoot_muzzle_offset, 0.0, 50.0, 0.05, "shoot_muzzle_offset")
	_spin(misc, "Spin (rad/s)", settings.shoot_spin, 0.0, 40.0, 0.5, "shoot_spin")
	_check(misc, "Random start rotation", settings.shoot_random_rotation, "shoot_random_rotation")
	_check(misc, "Fixed crosshair (fire at view centre)", settings.shoot_fixed_crosshair, "shoot_fixed_crosshair")
	_check(misc, "Keep firing between clicks", settings.shoot_hold_to_accumulate, "shoot_hold_to_accumulate")
	_check(misc, "Freeze spawned rigid bodies", settings.shoot_freeze_result, "shoot_freeze_result")
	_check(misc, "Parent to selected node", settings.shoot_parent_selected, "shoot_parent_selected")

	var name_row := _row(misc, "Name prefix")
	var le := LineEdit.new()
	le.text = settings.shoot_name_prefix
	le.placeholder_text = "scene root name"
	le.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	le.text_changed.connect(func(t: String) -> void: _apply("shoot_name_prefix", t))
	name_row.add_child(le)
	return box


func _build_physics_panel(parent: Control) -> void:
	var box := _section(parent, "Simulation")
	_spin(box, "Time limit (s)", settings.time_limit, 0.1, 120.0, 0.1, "time_limit")
	_check(box, "Stop early once everything settles", settings.stop_when_settled, "stop_when_settled")
	_spin(box, "Settle time (s)", settings.settle_time, 0.05, 5.0, 0.05, "settle_time")
	_option(box, "Bodies", ["Temporary proxies (safe)", "Native RigidBody3D nodes"], settings.sim_mode, "sim_mode")
	_check(box, "Live preview in viewport", settings.live_preview, "live_preview")
	_spin(box, "Preview refresh (Hz)", settings.preview_hz, 1.0, 120.0, 1.0, "preview_hz")
	_check(box, "Park bodies once they settle", settings.sleep_settled, "sleep_settled")
	_check(box, "Retire settled bodies from the sim", settings.retire_settled, "retire_settled")
	_check(box, "Draw tool overlay", settings.show_overlay, "show_overlay")

	var mat := _section(parent, "Material")
	_spin(mat, "Mass", settings.mass, 0.001, 10000.0, 0.1, "mass")
	_spin(mat, "Friction", settings.friction, 0.0, 2.0, 0.05, "friction")
	_spin(mat, "Bounce", settings.bounce, 0.0, 1.0, 0.05, "bounce")
	_spin(mat, "Linear damp", settings.linear_damp, 0.0, 30.0, 0.05, "linear_damp")
	_spin(mat, "Angular damp", settings.angular_damp, 0.0, 30.0, 0.05, "angular_damp")
	_check(mat, "Continuous collision detection", settings.continuous_cd, "continuous_cd")

	var grav := _section(parent, "Gravity")
	_check(grav, "Use project gravity", settings.use_project_gravity, "use_project_gravity")
	_spin(grav, "Magnitude", settings.gravity_magnitude, 0.0, 200.0, 0.1, "gravity_magnitude")
	var dir_row := _row(grav, "Direction")
	for axis in 3:
		var sb := SpinBox.new()
		sb.min_value = -1.0
		sb.max_value = 1.0
		sb.step = 0.05
		sb.value = settings.gravity_direction[axis]
		sb.custom_minimum_size = Vector2(58, 0)
		sb.value_changed.connect(func(v: float) -> void:
			var d: Vector3 = settings.gravity_direction
			d[axis] = v
			_apply("gravity_direction", d))
		dir_row.add_child(sb)


func _build_scene_panel(parent: Control) -> void:
	var col := _section(parent, "Colliders")
	_option(col, "Generate as", ["Convex hull", "Simplified convex hull", "Box"], settings.dynamic_shape_mode, "dynamic_shape_mode")
	_check(col, "Keep generated colliders in the scene", settings.keep_generated_colliders, "keep_generated_colliders")
	_option(col, "Generated body", ["StaticBody3D", "RigidBody3D", "AnimatableBody3D"], settings.generated_body_type, "generated_body_type")

	var env := _section(parent, "Environment")
	_check(env, "Use existing scene colliders", settings.env_use_scene_colliders, "env_use_scene_colliders")
	_check(env, "Use mesh geometry without colliders", settings.env_use_mesh_geometry, "env_use_mesh_geometry")
	_spin(env, "Mesh budget", settings.env_mesh_budget, 1, 20000, 10, "env_mesh_budget")
	_spin(env, "Radius (0 = all)", settings.env_radius, 0.0, 5000.0, 1.0, "env_radius")

	var scope := _section(parent, "Scene Interaction")
	_check(scope, "Affect Scene Objects", settings.affect_scene_objects, "affect_scene_objects")
	_option(scope, "Scope", ["Selection only", "Nearby movable objects", "All nodes in group pp_dynamic"], settings.dynamic_scope, "dynamic_scope")
	_spin(scope, "Nearby radius (m)", settings.nearby_radius, 0.1, 200.0, 0.1, "nearby_radius")
	var note := Label.new()
	note.text = "Tag movable props with the group \"pp_dynamic\" and static-only props with \"pp_ignore\"."
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7))
	scope.add_child(note)


func _on_tool_button(id: int) -> void:
	var already: bool = plugin.current_index == id
	plugin.set_tool(-1 if already else id)


func _on_diagnostic() -> void:
	var text: String = plugin.build_diagnostic()
	if _diag_box != null:
		_diag_box.text = text
		_diag_box.visible = true
	print(text)
	set_status("Diagnostic written to the Output panel and the box below.")


func _on_reset() -> void:
	settings.reset_to_defaults()
	_tool_buttons.clear()
	_panels.clear()
	_status = null
	_progress = null
	for child in get_children():
		remove_child(child)
		child.queue_free()
	_build()
	sync_tool(plugin.current_index)
	set_status("Settings reset to defaults.")


func _on_cancel() -> void:
	plugin.cancel_current()


func sync_tool(id: int) -> void:
	for i in _tool_buttons.size():
		_tool_buttons[i].set_pressed_no_signal(i == id)
	_set_visible_panel(id)


func _set_visible_panel(id: int) -> void:
	for key in _panels.keys():
		_panels[key].visible = key == id


func set_status(text: String) -> void:
	if _status != null:
		_status.text = text


func set_progress(value: float) -> void:
	if _progress != null:
		_progress.value = clampf(value, 0.0, 1.0)
