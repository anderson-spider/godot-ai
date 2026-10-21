@tool
extends RefCounted

## Brings already-loaded GDScripts back in step with their files on disk, for
## script_manage(op="reload").
##
## ResourceLoader caches a GDScript by path, and every preload() of it holds
## that same object. A file edited outside the editor (or written without
## script_patch's targeted refresh) keeps running its old code until something
## reloads the cached object — and until then the state is mixed: a dependent
## recompiled for another reason already inlines the new constants while
## calls into the stale script still run the old bodies. Restarting the editor
## was the only general fix (#938).
##
## The reload is in place: source_code is set from disk and Script.reload()
## recompiles the cached object, so every holder of it sees the new code. A
## dependent is recompiled too, after the scripts it depends on, so constants
## it inlined from them are refreshed. Dependencies are read from the source —
## preload("...") and extends "..." paths, absolute, relative or uid:// —
## because ResourceLoader.get_dependencies() reports none for a .gd. Scripts
## reached only through load() or a class_name are not followed.
##
## keep_state (reset_static=false) keeps static variables and live instances.
## reset_static=true reloads without keeping state, which reruns static
## initializers; the engine refuses that while instances of the script exist
## (ERR_ALREADY_IN_USE, logged as "Cannot reload script while instances
## exist"), and those scripts fall back to a keep_state reload. In the editor
## only @tool scripts run static initializers: a non-@tool script's statics
## come back as their type's default, not their initializer.
##
## The plugin's own scripts are never reloaded: they include the code running
## this reload.

const EXCLUDED_ROOT := "res://addons/godot_ai/"
## Bound on the .gd files walked per reload, so a huge project cannot stall
## the editor; the reply says `truncated` when it is reached.
const MAX_SCRIPTS := 5000

static var _dependency_regex: RegEx = null


## Every loaded GDScript in the project outside EXCLUDED_ROOT, as
## {"scripts": {path: GDScript}, "walked": int, "truncated": bool}.
## The walk reads the disk, not EditorFileSystem: a script loaded from a folder
## the editor has not scanned yet is just as stale. It skips what the editor
## skips — hidden folders and folders holding a .gdignore.
static func loaded_scripts() -> Dictionary:
	var result := {"scripts": {}, "walked": 0, "truncated": false}
	_walk("res://", result)
	return result


static func _walk(dir_path: String, result: Dictionary) -> void:
	if dir_path.begins_with(EXCLUDED_ROOT) or FileAccess.file_exists(dir_path.path_join(".gdignore")):
		return
	for file in DirAccess.get_files_at(dir_path):
		if not file.ends_with(".gd"):
			continue
		if int(result.walked) >= MAX_SCRIPTS:
			result.truncated = true
			return
		result.walked = int(result.walked) + 1
		var path := dir_path.path_join(file)
		if not ResourceLoader.has_cached(path):
			continue
		var script := ResourceLoader.load(path) as GDScript
		if script != null:
			result.scripts[path] = script
	for sub in DirAccess.get_directories_at(dir_path):
		if sub.begins_with("."):
			continue
		_walk(dir_path.path_join(sub) + "/", result)
		if result.truncated:
			return


## The .gd paths `source` (the script at `path`) preloads or extends by path.
static func dependencies(path: String, source: String) -> PackedStringArray:
	if _dependency_regex == null:
		_dependency_regex = RegEx.create_from_string(
			"(?m)(?:preload\\s*\\(|^\\s*extends\\s+)\\s*[\"']([^\"']+)[\"']"
		)
	var found := PackedStringArray()
	for match in _dependency_regex.search_all(source):
		var target := _resolve(path, match.get_string(1))
		if target.ends_with(".gd") and not found.has(target):
			found.append(target)
	return found


static func _resolve(from_path: String, target: String) -> String:
	if target.begins_with("uid://"):
		var id := ResourceUID.text_to_id(target)
		return ResourceUID.get_id_path(id) if ResourceUID.has_id(id) else ""
	if target.begins_with("res://"):
		return target.simplify_path()
	return from_path.get_base_dir().path_join(target).simplify_path()


## True when `path` is `root` itself or lies inside the folder `root`.
static func in_scope(path: String, root: String) -> bool:
	if root.ends_with(".gd"):
		return path == root
	return path.begins_with(root if root.ends_with("/") else root + "/")


static func _in_any_scope(path: String, roots: PackedStringArray) -> bool:
	if roots.is_empty():
		return true
	for root in roots:
		if in_scope(path, root):
			return true
	return false


## Reload the loaded scripts that changed on disk under `roots` (all of them
## with `reset_static`), plus every loaded script that depends on one, in
## dependency order. Returns the reply data for script_manage(op="reload").
static func reload_changed(roots: PackedStringArray, reset_static: bool) -> Dictionary:
	var loaded := loaded_scripts()
	var scripts: Dictionary = loaded.scripts
	var disk := {}
	var deps := {}
	var dependents := {}
	for path: String in scripts:
		var source := FileAccess.get_file_as_string(path)
		if source.is_empty() and FileAccess.get_open_error() != OK:
			continue
		disk[path] = source
		deps[path] = dependencies(path, source)
		for dep: String in deps[path]:
			if not dependents.has(dep):
				dependents[dep] = []
			dependents[dep].append(path)

	var reasons := {}
	for path: String in disk:
		if not _in_any_scope(path, roots):
			continue
		if (scripts[path] as GDScript).source_code != disk[path]:
			reasons[path] = "changed"
		elif reset_static:
			reasons[path] = "reset_static"
	var queue: Array = reasons.keys()
	while not queue.is_empty():
		var path: String = queue.pop_back()
		for dependent: String in dependents.get(path, []):
			if disk.has(dependent) and not reasons.has(dependent):
				reasons[dependent] = "dependent"
				queue.append(dependent)

	var order: Array[String] = []
	var visited := {}
	for path: String in reasons:
		_visit(path, reasons, deps, visited, order)

	var reloaded: Array = []
	var failed: Array = []
	var failed_paths := {}
	for path in order:
		var blocked: String = ""
		for dep: String in deps.get(path, []):
			if failed_paths.has(dep):
				blocked = dep
				break
		if not blocked.is_empty():
			failed.append({"path": path, "reason": "dependency_failed", "dependency": blocked})
			failed_paths[path] = true
			continue
		## A dependent is recompiled for its inlined constants only; its own
		## statics are reset only when it is in scope on its own account.
		var entry := _reload_one(scripts[path], disk[path], reset_static and reasons[path] != "dependent")
		entry["path"] = path
		entry["reason"] = reasons[path]
		if entry.has("error"):
			entry["reason"] = entry.get("failure", "reload_failed")
			entry.erase("failure")
			failed.append(entry)
			failed_paths[path] = true
		else:
			reloaded.append(entry)

	return {
		"paths": Array(roots),
		"reset_static": reset_static,
		"loaded_scripts": scripts.size(),
		"reloaded": reloaded,
		"reloaded_count": reloaded.size(),
		"failed": failed,
		"failed_count": failed.size(),
		"truncated": loaded.truncated,
		"excluded": EXCLUDED_ROOT,
		"undoable": false,
		"reason": "Script reloads cannot be undone via editor undo",
	}


## Depth-first, dependencies before dependents; a cycle is broken where it closes.
static func _visit(path: String, selected: Dictionary, deps: Dictionary, visited: Dictionary, order: Array[String]) -> void:
	if visited.has(path):
		return
	visited[path] = true
	for dep: String in deps.get(path, []):
		if selected.has(dep):
			_visit(dep, selected, deps, visited, order)
	order.append(path)


## Push `source` into `script` and recompile it. On failure the previous source
## is put back and recompiled, so the script keeps running its old code instead
## of being left invalid.
static func _reload_one(script: GDScript, source: String, reset_static: bool) -> Dictionary:
	var previous := script.source_code
	script.source_code = source
	var err := script.reload(not reset_static)
	var entry := {"static_reset": reset_static}
	if err == ERR_ALREADY_IN_USE and reset_static:
		err = script.reload(true)
		entry["static_reset"] = false
		entry["instances_alive"] = true
	if err == OK:
		return entry
	script.source_code = previous
	script.reload(true)
	return {
		"failure": "parse_error" if err == ERR_PARSE_ERROR or err == ERR_COMPILATION_FAILED else "reload_failed",
		"error": error_string(err),
	}
