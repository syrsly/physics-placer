@tool
class_name PPSettings
extends Resource

enum SimMode {
	PROXY,
	NATIVE,
}

enum ShapeMode {
	CONVEX,
	SIMPLIFIED_CONVEX,
	BOX,
}

enum DynamicScope {
	SELECTION_ONLY,
	NEARBY,
	ALL_TAGGED,
}

enum DragHold {
	HANG,
	CARRY,
}

enum GrabTarget {
	PROP,
	EXACT,
	TOP,
}

enum GeneratedBodyType {
	STATIC_BODY,
	RIGID_BODY,
	ANIMATABLE_BODY,
}

const SETTINGS_VERSION := 4
const SETTINGS_PATH := "user://physics_placer_settings.tres"
const DYNAMIC_GROUP := "pp_dynamic"
const IGNORE_GROUP := "pp_ignore"

@export var version: int = 0

@export var sim_mode: int = SimMode.PROXY
@export var time_limit: float = 8.0
@export var stop_when_settled: bool = true
@export var sleep_settled: bool = true
@export var retire_settled: bool = true
@export var settle_time: float = 0.4
@export var settle_linear: float = 0.04
@export var settle_angular: float = 0.08

@export var use_project_gravity: bool = true
@export var gravity_magnitude: float = 9.8
@export var gravity_direction: Vector3 = Vector3.DOWN

@export var mass: float = 1.0
@export var friction: float = 0.7
@export var bounce: float = 0.0
@export var linear_damp: float = 0.15
@export var angular_damp: float = 0.35
@export var continuous_cd: bool = true

@export var dynamic_shape_mode: int = ShapeMode.SIMPLIFIED_CONVEX
@export var keep_generated_colliders: bool = false
@export var generated_body_type: int = GeneratedBodyType.STATIC_BODY

@export var env_use_scene_colliders: bool = true
@export var env_use_mesh_geometry: bool = true
@export var env_mesh_budget: int = 2000
@export var env_radius: float = 0.0

@export var affect_scene_objects: bool = false
@export var dynamic_scope: int = DynamicScope.SELECTION_ONLY
@export var nearby_radius: float = 2.5

@export var drop_snap_before_sim: bool = false
@export var drop_snap_gap: float = 0.02
@export var drop_random_tilt: float = 0.0
@export var drop_on_click: bool = false

@export var drag_strength: float = 0.5
@export var drag_max_speed: float = 10.0
@export var drag_max_force: float = 200.0
@export var drag_max_stretch: float = 0.25
@export var drag_stiffness: float = 2.0
@export var drag_angular_damp: float = 0.6
@export var grab_target: int = GrabTarget.PROP
@export var drag_grab_at_point: bool = true
@export var drag_hold_mode: int = DragHold.HANG
@export var drag_settle_after_release: bool = false


@export var shoot_scene: PackedScene = null
@export var shoot_force: float = 18.0
@export var shoot_force_jitter: float = 0.05
@export var shoot_rapid_fire: bool = true
@export var shoot_rate: float = 6.0
@export var shoot_spread: float = 1.5
@export var shoot_recoil: float = 0.4
@export var shoot_recoil_max: float = 5.0
@export var shoot_recoil_recovery: float = 12.0
@export var shoot_spin: float = 8.0
@export var shoot_random_rotation: bool = true
@export var shoot_muzzle_offset: float = 0.6
@export var shoot_max_rounds: int = 80
@export var shoot_fixed_crosshair: bool = false
@export var shoot_hold_to_accumulate: bool = false
@export var shoot_freeze_result: bool = false
@export var shoot_name_prefix: String = ""
@export var shoot_parent_selected: bool = false

@export var show_overlay: bool = true
@export var live_preview: bool = true
@export var preview_hz: float = 30.0


func gravity_vector() -> Vector3:
	if use_project_gravity:
		var mag: float = float(ProjectSettings.get_setting("physics/3d/default_gravity", 9.8))
		var dir: Vector3 = ProjectSettings.get_setting("physics/3d/default_gravity_vector", Vector3.DOWN)
		if dir.length() < 0.0001:
			dir = Vector3.DOWN
		return dir.normalized() * mag
	var d := gravity_direction
	if d.length() < 0.0001:
		d = Vector3.DOWN
	return d.normalized() * gravity_magnitude


func make_physics_material() -> PhysicsMaterial:
	var pm := PhysicsMaterial.new()
	pm.friction = friction
	pm.bounce = bounce
	return pm


func save() -> void:
	version = SETTINGS_VERSION
	var copy: PPSettings = duplicate(false)
	copy.version = SETTINGS_VERSION
	ResourceSaver.save(copy, SETTINGS_PATH)


func reset_to_defaults() -> void:
	var fresh := PPSettings.new()
	for info in fresh.get_property_list():
		if not (info["usage"] & PROPERTY_USAGE_STORAGE):
			continue
		var key: String = info["name"]
		if key == "script" or key == "resource_path" or key == "resource_name":
			continue
		set(key, fresh.get(key))
	save()


static func load_or_create() -> PPSettings:
	if ResourceLoader.exists(SETTINGS_PATH):
		var res: Resource = ResourceLoader.load(SETTINGS_PATH, "", ResourceLoader.CACHE_MODE_IGNORE)
		if res is PPSettings and (res as PPSettings).version == SETTINGS_VERSION:
			return res
	return PPSettings.new()
