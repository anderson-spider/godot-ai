@tool
extends McpTestSuite

## Tests for script_manage(op="reload") — ScriptHandler.reload_scripts and
## utils/script_reloader.gd. Each test writes its own scripts under ROOT,
## registers them with the editor and loads them, then rewrites the files
## with FileAccess only (no update_file, which a GUI editor answers with its
## own reload) so the loaded copies go stale the way an outside edit leaves
## them.

const ErrorCodes := preload("res://addons/godot_ai/utils/error_codes.gd")
const ScriptHandler := preload("res://addons/godot_ai/handlers/script_handler.gd")
const ScriptReloader := preload("res://addons/godot_ai/utils/script_reloader.gd")

const ROOT := "res://tests/_mcp_reload_tmp/"
const LEAF_V1 := "@tool\nextends RefCounted\n\nconst VALUE := 1\nstatic var counter := 7\n\n\nstatic func version() -> int:\n\treturn 1\n"
const LEAF_V2 := "@tool\nextends RefCounted\n\nconst VALUE := 2\nstatic var counter := 7\n\n\nstatic func version() -> int:\n\treturn 2\n"
const MID := "@tool\nextends RefCounted\n\nconst Leaf := preload(\"leaf.gd\")\nconst INLINED := Leaf.VALUE\n\n\nstatic func leaf_version() -> int:\n\treturn Leaf.version()\n"

var _handler: ScriptHandler
var _written: Array[String] = []
var _dir := ""


func suite_name() -> String:
	return "script_reload"


func suite_setup(ctx: Dictionary) -> void:
	_handler = ScriptHandler.new(ctx.get("undo_redo"))


func teardown() -> void:
	var efs := EditorInterface.get_resource_filesystem()
	for path in _written:
		DirAccess.remove_absolute(path)
		DirAccess.remove_absolute(path + ".uid")
		efs.update_file(path)
	_written.clear()
	if DirAccess.dir_exists_absolute(ROOT):
		_remove_empty_dirs(ROOT)


func _remove_empty_dirs(dir: String) -> void:
	for sub in DirAccess.get_directories_at(dir):
		_remove_empty_dirs(dir.path_join(sub))
	DirAccess.remove_absolute(dir)


## Write `files` ({name: source}) under a fresh ROOT/<folder>_<n>/, register and
## load them, and keep the folder in _dir. The folder is new each run:
## ResourceLoader keeps an earlier run's scripts cached under their paths.
func _install(folder: String, files: Dictionary) -> Dictionary:
	_dir = "%s%s_%d/" % [ROOT, folder, Time.get_ticks_usec()]
	var dir := _dir
	DirAccess.make_dir_recursive_absolute(dir)
	var efs := EditorInterface.get_resource_filesystem()
	var scripts := {}
	for name: String in files:
		var path := dir + name
		_write(path, files[name])
		_written.append(path)
		efs.update_file(path)
	for name: String in files:
		scripts[name] = load(dir + name)
	return scripts


func _write(path: String, source: String) -> void:
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(source)
	file.close()


func _reloaded(data: Dictionary) -> Array:
	var rows := []
	for entry: Dictionary in data.reloaded:
		rows.append([entry.path.get_file(), entry.reason])
	return rows


# ----- reload -----

func test_reload_refreshes_a_changed_script_and_then_its_dependents() -> void:
	var scripts := _install("chain", {"leaf.gd": LEAF_V1, "mid.gd": MID})
	var mid: GDScript = scripts["mid.gd"]
	assert_eq(mid.leaf_version(), 1)
	_write(_dir + "leaf.gd", LEAF_V2)
	assert_eq(mid.leaf_version(), 1, "an outside edit leaves the loaded copy stale")

	var result := _handler.reload_scripts({"paths": [_dir]})
	assert_false(result.has("error"), str(result))
	assert_eq(_reloaded(result.data), [["leaf.gd", "changed"], ["mid.gd", "dependent"]], "the dependency reloads before its dependent")
	assert_eq(mid.leaf_version(), 2, "the preloaded leaf runs the new code")
	assert_eq(mid.INLINED, 2, "the dependent's inlined constant is recompiled")
	assert_eq(result.data.failed, [])
	assert_false(result.data.undoable)


func test_reload_skips_unchanged_scripts_and_keeps_statics() -> void:
	var scripts := _install("keep", {"leaf.gd": LEAF_V1})
	var leaf: GDScript = scripts["leaf.gd"]
	leaf.counter = 99
	var unchanged := _handler.reload_scripts({"paths": [_dir]})
	assert_eq(unchanged.data.reloaded, [], "nothing changed on disk, so nothing reloads")

	_write(_dir + "leaf.gd", LEAF_V2)
	var result := _handler.reload_scripts({"paths": [_dir + "leaf.gd"]})
	assert_eq(_reloaded(result.data), [["leaf.gd", "changed"]])
	assert_false(result.data.reloaded[0].static_reset)
	assert_eq(leaf.version(), 2)
	assert_eq(leaf.counter, 99, "a keep_state reload keeps static variables")


func test_reset_static_reruns_static_initializers_of_unchanged_scripts() -> void:
	var scripts := _install("reset", {"leaf.gd": LEAF_V1})
	var leaf: GDScript = scripts["leaf.gd"]
	leaf.counter = 99
	var result := _handler.reload_scripts({"paths": [_dir], "reset_static": true})
	assert_eq(_reloaded(result.data), [["leaf.gd", "reset_static"]])
	assert_true(result.data.reloaded[0].static_reset)
	assert_eq(leaf.counter, 7, "the static initializer ran again")


func test_reset_static_with_live_instances_keeps_state() -> void:
	var scripts := _install("alive", {"leaf.gd": LEAF_V1})
	var leaf: GDScript = scripts["leaf.gd"]
	leaf.counter = 99
	var instance: RefCounted = leaf.new()
	expect_script_error_containing("Cannot reload script while instances exist")
	_write(_dir + "leaf.gd", LEAF_V2)
	var result := _handler.reload_scripts({"paths": [_dir], "reset_static": true})
	assert_eq(_reloaded(result.data), [["leaf.gd", "changed"]])
	assert_false(result.data.reloaded[0].static_reset)
	assert_true(result.data.reloaded[0].instances_alive)
	assert_eq(leaf.version(), 2, "the code still updates")
	assert_eq(leaf.counter, 99)
	assert_true(instance != null)


func test_a_script_that_fails_to_compile_keeps_its_old_code_and_skips_dependents() -> void:
	var scripts := _install("broken", {"leaf.gd": LEAF_V1, "mid.gd": MID})
	var leaf: GDScript = scripts["leaf.gd"]
	for i in 3:
		expect_script_error_containing("_mcp_undefined_name")
	_write(_dir + "leaf.gd", LEAF_V1.replace("return 1", "return _mcp_undefined_name"))
	var result := _handler.reload_scripts({"paths": [_dir]})
	assert_eq(result.data.reloaded, [])
	var failed := {}
	for entry: Dictionary in result.data.failed:
		failed[entry.path.get_file()] = entry
	assert_eq(failed["leaf.gd"].reason, "parse_error", str(failed))
	assert_eq(failed["mid.gd"].reason, "dependency_failed")
	assert_eq(failed["mid.gd"].dependency, _dir + "leaf.gd")
	assert_true(leaf.can_instantiate(), "the old code is compiled back")
	assert_eq(leaf.version(), 1)


## A reloaded script must not be written back over a newer file. The editor
## saves every cached resource flagged as edited whenever it saves a scene
## (EditorNode::_save_external_resources), without comparing with the disk.
func test_a_scene_save_does_not_write_a_reloaded_script_over_a_newer_file() -> void:
	var scripts := _install("clobber", {"leaf.gd": LEAF_V1})
	assert_true(scripts["leaf.gd"] != null)
	var leaf_path := _dir + "leaf.gd"
	_write(leaf_path, LEAF_V2)
	var result := _handler.reload_scripts({"paths": [leaf_path]})
	assert_eq(_reloaded(result.data), [["leaf.gd", "changed"]])
	assert_false(result.data.reloaded[0].has("open_in_script_editor"), "the probe is not open in a Script Editor tab")
	var v3 := LEAF_V2.replace("return 2", "return 3")
	_write(leaf_path, v3)

	var previous_scene := ""
	var root := EditorInterface.get_edited_scene_root()
	if root != null:
		previous_scene = root.scene_file_path
	var scene_path := _dir + "save_probe.tscn"
	_write(scene_path, "[gd_scene format=3]\n\n[node name=\"SaveProbe\" type=\"Node\"]\n")
	_written.append(scene_path)
	EditorInterface.get_resource_filesystem().update_file(scene_path)
	EditorInterface.open_scene_from_path(scene_path)
	EditorInterface.mark_scene_as_unsaved()
	var err := EditorInterface.save_scene()
	EditorInterface.close_scene()
	if not previous_scene.is_empty():
		EditorInterface.open_scene_from_path(previous_scene)

	assert_eq(err, OK, "the probe scene should save")
	assert_eq(FileAccess.get_file_as_string(leaf_path), v3, "the newer file on disk survives the scene save")


func test_reload_refuses_bad_paths() -> void:
	assert_is_error(_handler.reload_scripts({"paths": ["res://addons/godot_ai/plugin.gd"]}), ErrorCodes.VALUE_OUT_OF_RANGE)
	assert_is_error(_handler.reload_scripts({"paths": ["res://addons/godot_ai"]}), ErrorCodes.VALUE_OUT_OF_RANGE)
	assert_is_error(_handler.reload_scripts({"paths": ["res://tests/_mcp_no_such.gd"]}), ErrorCodes.RESOURCE_NOT_FOUND)
	assert_is_error(_handler.reload_scripts({"paths": ["res://_mcp_no_such_dir"]}), ErrorCodes.RESOURCE_NOT_FOUND)
	assert_is_error(_handler.reload_scripts({"paths": ["res://../outside"]}), ErrorCodes.VALUE_OUT_OF_RANGE)
	assert_is_error(_handler.reload_scripts({"paths": 3}), ErrorCodes.WRONG_TYPE)
	assert_is_error(_handler.reload_scripts({"paths": [3]}), ErrorCodes.WRONG_TYPE)
	assert_is_error(_handler.reload_scripts({"paths": []}), ErrorCodes.MISSING_REQUIRED_PARAM)


func test_whole_project_reload_never_touches_the_plugin() -> void:
	var result := _handler.reload_scripts({"reset_static": false})
	assert_false(result.has("error"), str(result))
	assert_eq(result.data.paths, ["res://"])
	for entry: Dictionary in result.data.reloaded + result.data.failed:
		assert_false(entry.path.begins_with(ScriptReloader.EXCLUDED_ROOT), entry.path)


func test_dependencies_reads_preload_and_extends_paths() -> void:
	var source := "extends \"base.gd\"\nconst A := preload(\"res://x/a.gd\")\nconst B = preload( '../b.gd' )\nconst T := preload(\"res://x/t.tscn\")\n# preload(\"c.gd\") in a comment is still listed\n"
	var deps := ScriptReloader.dependencies("res://y/z/s.gd", source)
	assert_eq(Array(deps), ["res://y/z/base.gd", "res://x/a.gd", "res://y/b.gd", "res://y/z/c.gd"])
	assert_true(ScriptReloader.in_scope("res://a/b.gd", "res://"))
	assert_true(ScriptReloader.in_scope("res://a/b.gd", "res://a"))
	assert_false(ScriptReloader.in_scope("res://ab/c.gd", "res://a"))
	assert_true(ScriptReloader.in_scope("res://a/b.gd", "res://a/b.gd"))
