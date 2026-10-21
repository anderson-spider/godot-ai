@tool
extends RefCounted

## Text scan of saved scenes and resources for `[connection]` entries, the
## half of script_manage(op="find_usages") the GDScript language server cannot
## see: a handler wired in the scene editor has no call site in any .gd.
##
## Matching is by name only. A connection naming `method="_on_hit"` matches
## every script that declares `_on_hit`, because resolving which script the
## `to` node carries would mean instancing the scene. Binary .scn/.res files
## are counted, not read.

const TEXT_EXTENSIONS: PackedStringArray = ["tscn", "tres"]
const BINARY_EXTENSIONS: PackedStringArray = ["scn", "res"]
const MAX_FILES := 5000
const MAX_MATCHES := 1000

static var _attribute_regex: RegEx


## Connections whose `method` equals `method` or whose `signal` equals
## `signal_name` (an empty name matches nothing), as
## {"connections": [{path, line, signal, from, to, method}], "scanned_files",
## "skipped_binary", "truncated"}. Lines are 1-based.
static func find(method: String, signal_name: String) -> Dictionary:
	var result := {
		"connections": [],
		"scanned_files": 0,
		"skipped_binary": 0,
		"truncated": false,
	}
	_walk("res://", method, signal_name, result)
	return result


static func _walk(dir_path: String, method: String, signal_name: String, result: Dictionary) -> void:
	if FileAccess.file_exists(dir_path.path_join(".gdignore")):
		return
	for file in DirAccess.get_files_at(dir_path):
		var extension := file.get_extension().to_lower()
		if BINARY_EXTENSIONS.has(extension):
			result.skipped_binary = int(result.skipped_binary) + 1
			continue
		if not TEXT_EXTENSIONS.has(extension):
			continue
		if int(result.scanned_files) >= MAX_FILES:
			result.truncated = true
			return
		result.scanned_files = int(result.scanned_files) + 1
		_scan_file(dir_path.path_join(file), method, signal_name, result)
		if result.truncated:
			return
	for sub in DirAccess.get_directories_at(dir_path):
		if sub.begins_with("."):
			continue
		_walk(dir_path.path_join(sub) + "/", method, signal_name, result)
		if result.truncated:
			return


static func _scan_file(path: String, method: String, signal_name: String, result: Dictionary) -> void:
	var text := FileAccess.get_file_as_string(path)
	if text.is_empty():
		return
	var lines := text.split("\n")
	for i in lines.size():
		var line := lines[i]
		if not line.begins_with("[connection "):
			continue
		var attrs := connection_attributes(line)
		var method_hit: bool = not method.is_empty() and attrs.get("method", "") == method
		var signal_hit: bool = not signal_name.is_empty() and attrs.get("signal", "") == signal_name
		if not (method_hit or signal_hit):
			continue
		var connections: Array = result.connections
		if connections.size() >= MAX_MATCHES:
			result.truncated = true
			return
		connections.append({
			"path": path,
			"line": i + 1,
			"signal": attrs.get("signal", ""),
			"from": attrs.get("from", ""),
			"to": attrs.get("to", ""),
			"method": attrs.get("method", ""),
		})


## The `key="value"` pairs of one `[connection ...]` header line. Values are
## returned with their escapes resolved (node paths may carry `\"`).
static func connection_attributes(line: String) -> Dictionary:
	if _attribute_regex == null:
		_attribute_regex = RegEx.create_from_string("(\\w+)=\"((?:[^\"\\\\]|\\\\.)*)\"")
	var attrs := {}
	for m in _attribute_regex.search_all(line):
		attrs[m.get_string(1)] = m.get_string(2).c_unescape()
	return attrs
