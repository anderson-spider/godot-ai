@tool
extends McpTestSuite

## Tests for the plugin half of script_manage(op="find_usages"):
## ScriptHandler.lsp_endpoint (where the language server listens, and the
## project root it must answer for) and find_scene_connections
## (utils/scene_connection_scan.gd). The language-server half runs in Python
## against the editor's real server; tests/unit/test_script_find_usages.py
## covers it.

const ErrorCodes := preload("res://addons/godot_ai/utils/error_codes.gd")
const ScriptHandler := preload("res://addons/godot_ai/handlers/script_handler.gd")
const SceneConnectionScan := preload("res://addons/godot_ai/utils/scene_connection_scan.gd")

const ROOT := "res://tests/_mcp_usages_tmp/"
const SELF_PATH := "res://tests/test_script_find_usages.gd"

var _handler: ScriptHandler


func suite_name() -> String:
	return "script_find_usages"


func suite_setup(ctx: Dictionary) -> void:
	_handler = ScriptHandler.new(ctx.get("undo_redo"))


func teardown() -> void:
	if DirAccess.dir_exists_absolute(ROOT):
		_remove_tree(ROOT)


## Fixtures include a .gdignore and a hidden folder, which the static
## DirAccess listings leave out.
func _remove_tree(dir: String) -> void:
	var access := DirAccess.open(dir)
	if access == null:
		return
	access.include_hidden = true
	for file in access.get_files():
		DirAccess.remove_absolute(dir.path_join(file))
	for sub in access.get_directories():
		_remove_tree(dir.path_join(sub))
	DirAccess.remove_absolute(dir)


func _write(path: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_string(text)
	file.close()


## A name no other file in the project uses, so the project-wide scan
## returns only this test's fixtures.
func _unique(prefix: String) -> String:
	return "%s_%d" % [prefix, Time.get_ticks_usec()]


# ----- lsp_endpoint -----------------------------------------------------------

func test_lsp_endpoint_reports_the_root_the_language_server_compares() -> void:
	var result := _handler.lsp_endpoint({"path": SELF_PATH})
	assert_has_key(result, "data")
	var data: Dictionary = result.data
	assert_eq(data.available, Engine.has_singleton("GDScriptLanguageProtocol"))
	var root := ProjectSettings.globalize_path("res://")
	assert_true(root.ends_with("/"), "globalize_path(res://) is expected to end with a slash")
	assert_eq(data.project_root, root.trim_suffix("/"), "the server rejects a rootPath with a trailing slash")
	assert_eq(data.file, ProjectSettings.globalize_path(SELF_PATH))
	assert_true(int(data.port) > 0, "port should be positive, got %s" % data.port)
	assert_contains(["cmdline", "editor_settings"], data.port_source)
	assert_true(String(data.host).length() > 0, "host should not be empty")


func test_lsp_endpoint_port_matches_the_editor_setting_without_override() -> void:
	if ScriptHandler.lsp_port_override(OS.get_cmdline_args()) > 0:
		skip("editor was launched with --lsp-port")
		return
	var result := _handler.lsp_endpoint({"path": SELF_PATH})
	var settings := EditorInterface.get_editor_settings()
	assert_eq(result.data.port_source, "editor_settings")
	assert_eq(int(result.data.port), int(settings.get_setting(ScriptHandler.LSP_PORT_SETTING)))


func test_lsp_endpoint_rejects_non_gdscript() -> void:
	var result := _handler.lsp_endpoint({"path": "res://tests/whatever.cs"})
	assert_is_error(result, ErrorCodes.VALUE_OUT_OF_RANGE)


func test_lsp_endpoint_rejects_missing_file() -> void:
	var result := _handler.lsp_endpoint({"path": "res://tests/_no_such_script_for_usages.gd"})
	assert_is_error(result, ErrorCodes.RESOURCE_NOT_FOUND)


func test_lsp_endpoint_rejects_traversal() -> void:
	var result := _handler.lsp_endpoint({"path": "res://../outside.gd"})
	assert_is_error(result)


func test_lsp_endpoint_requires_path() -> void:
	var result := _handler.lsp_endpoint({})
	assert_is_error(result)


func test_lsp_port_override_reads_both_forms() -> void:
	assert_eq(ScriptHandler.lsp_port_override(PackedStringArray(["--editor", "--lsp-port", "6123"])), 6123)
	assert_eq(ScriptHandler.lsp_port_override(PackedStringArray(["--lsp-port=6124", "--path", "x"])), 6124)
	assert_eq(ScriptHandler.lsp_port_override(PackedStringArray(["--editor", "--path", "x"])), -1)
	assert_eq(ScriptHandler.lsp_port_override(PackedStringArray(["--lsp-port"])), -1, "a dangling flag is not a port")
	assert_eq(ScriptHandler.lsp_port_override(PackedStringArray(["--lsp-port", "abc"])), -1)


# ----- find_scene_connections ------------------------------------------------

func test_find_scene_connections_matches_method_and_signal() -> void:
	var method := _unique("_on_usages_probe")
	var signal_name := _unique("usages_probe_signal")
	var scene := "[gd_scene format=3]\n\n[node name=\"Root\" type=\"Node\"]\n\n[node name=\"Button\" type=\"Button\" parent=\".\"]\n\n" \
		+ "[connection signal=\"pressed\" from=\"Button\" to=\".\" method=\"%s\"]\n" % method \
		+ "[connection signal=\"%s\" from=\".\" to=\"Button\" method=\"_on_other\"]\n" % signal_name \
		+ "[connection signal=\"pressed\" from=\"Button\" to=\".\" method=\"%s_suffix\"]\n" % method
	_write(ROOT + "probe.tscn", scene)
	_write(ROOT + "nested/probe_res.tres", "[gd_resource format=3]\n\n[connection signal=\"changed\" from=\".\" to=\".\" method=\"%s\"]\n" % method)

	var by_method := _handler.find_scene_connections({"method": method})
	assert_has_key(by_method, "data")
	var hits: Array = by_method.data.connections
	assert_eq(hits.size(), 2, "the exact name in both files, not the _suffix one")
	var first: Dictionary = hits[0] if hits[0].path.ends_with(".tscn") else hits[1]
	assert_eq(first.path, ROOT + "probe.tscn")
	assert_eq(first.line, 7)
	assert_eq(first.signal, "pressed")
	assert_eq(first.from, "Button")
	assert_eq(first.to, ".")
	assert_eq(first.method, method)

	var by_signal := _handler.find_scene_connections({"signal": signal_name})
	assert_eq(by_signal.data.connections.size(), 1)
	assert_eq(by_signal.data.connections[0].method, "_on_other")
	assert_eq(by_signal.data.connections[0].line, 8)
	assert_true(int(by_signal.data.scanned_files) >= 2, "both fixtures are scanned")


func test_find_scene_connections_skips_gdignore_and_hidden_folders() -> void:
	var method := _unique("_on_usages_hidden")
	var line := "[connection signal=\"pressed\" from=\".\" to=\".\" method=\"%s\"]\n" % method
	_write(ROOT + "ignored/probe.tscn", line)
	_write(ROOT + "ignored/.gdignore", "")
	_write(ROOT + ".hidden/probe.tscn", line)
	var result := _handler.find_scene_connections({"method": method})
	assert_eq(result.data.connections.size(), 0)


func test_find_scene_connections_counts_binary_scenes() -> void:
	var before := SceneConnectionScan.find(_unique("_on_none"), "")
	_write(ROOT + "binary.scn", "RSRC")
	var after := SceneConnectionScan.find(_unique("_on_none"), "")
	assert_eq(int(after.skipped_binary), int(before.skipped_binary) + 1)
	assert_eq(after.connections.size(), 0)


func test_find_scene_connections_requires_a_name() -> void:
	assert_is_error(_handler.find_scene_connections({}), ErrorCodes.MISSING_REQUIRED_PARAM)
	assert_is_error(_handler.find_scene_connections({"method": 3}), ErrorCodes.WRONG_TYPE)


func test_connection_attributes_resolve_escapes() -> void:
	var attrs := SceneConnectionScan.connection_attributes(
		"[connection signal=\"pressed\" from=\"A/\\\"quoted\\\"\" to=\".\" method=\"_on_a\" flags=3]")
	assert_eq(attrs.signal, "pressed")
	assert_eq(attrs.from, "A/\"quoted\"")
	assert_eq(attrs.to, ".")
	assert_eq(attrs.method, "_on_a")
	assert_false(attrs.has("flags"), "unquoted values are not string attributes")
