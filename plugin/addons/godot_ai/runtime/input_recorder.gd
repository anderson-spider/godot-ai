extends RefCounted

## Records the input a running game receives and plays it back.
##
## Capture listens to the root Window's `window_input` signal rather than
## `_input`, so events a game marks handled in its own `_input` are still
## seen, and it includes what MCP input_* ops inject. Each event is stored by
## the process frame it arrived on, relative to the start, as typed JSON: the
## class name from a closed list plus its stored properties, rebuilt on load
## from the types ClassDB declares (never str_to_var). Playback re-emits the
## events through Input.parse_input_event on their frames, driven by `tick()`
## from the game helper's _process, and nothing is recorded while it runs.

const FORMAT := "godot_ai.input_recording"
const VERSION := 1
const DEFAULT_DIR := "user://mcp_recordings"
const MAX_EVENTS := 100000
## The InputEvent classes a recording may hold. A file naming any other class
## is refused, so loading never instantiates something arbitrary.
const EVENT_CLASSES: Array[String] = [
	"InputEventKey",
	"InputEventMouseButton",
	"InputEventMouseMotion",
	"InputEventJoypadButton",
	"InputEventJoypadMotion",
	"InputEventAction",
	"InputEventScreenTouch",
	"InputEventScreenDrag",
	"InputEventMagnifyGesture",
	"InputEventPanGesture",
]
const SKIPPED_PROPERTIES: Array[String] = [
	"resource_local_to_scene", "resource_name", "resource_path", "resource_scene_unique_id", "script",
]
const STORED_TYPES: Array[int] = [TYPE_BOOL, TYPE_INT, TYPE_FLOAT, TYPE_STRING, TYPE_STRING_NAME, TYPE_VECTOR2]

enum State { IDLE, RECORDING, REPLAYING }

var state := State.IDLE
## Test seam: replaces Input.parse_input_event during playback.
var emit_event: Callable = Callable()

var _path := ""
var _events: Array[Dictionary] = []
var _window_size := Vector2i.ZERO
var _start_frame := 0
var _start_msec := 0
var _truncated := false

var _replay_events: Array[InputEvent] = []
var _replay_frames: PackedInt32Array = PackedInt32Array()
var _replay_next := 0
var _replay_frame := 0
var _replay_total_frames := 0
var _replay_path := ""
var _replay_finished := false
## Press events emitted by the replay and not yet released, by input key.
var _replay_held: Dictionary = {}
var _replay_released_at_end := 0


## "" when `path` may hold a recording: a .json under user://, or under res://
## outside the plugin and the import cache, with no "..".
static func path_error(path: String) -> String:
	if not (path.begins_with("user://") or path.begins_with("res://")):
		return "path must start with user:// or res:// (got %s)" % path
	if not path.to_lower().ends_with(".json"):
		return "path must end in .json (got %s)" % path
	if ".." in path.replace("\\", "/").split("/"):
		return "path must not contain .. (got %s)" % path
	for blocked in ["res://addons/godot_ai/", "res://.godot/"]:
		if path.begins_with(blocked):
			return "path must not be under %s (got %s)" % [blocked, path]
	return ""


static func default_path() -> String:
	return DEFAULT_DIR.path_join("recording_%s.json" % Time.get_datetime_string_from_system().replace(":", "-"))


## Typed JSON for one event, or {} when its class is not recordable.
static func event_to_json(event: InputEvent) -> Dictionary:
	var type := event.get_class()
	if not type in EVENT_CLASSES:
		return {}
	var props := {}
	for prop in event.get_property_list():
		var name: String = prop.name
		if not (prop.usage & PROPERTY_USAGE_STORAGE) or name in SKIPPED_PROPERTIES or not (int(prop.type) in STORED_TYPES):
			continue
		var value: Variant = event.get(name)
		props[name] = [value.x, value.y] if value is Vector2 else value
	return {"type": type, "props": props}


## Rebuild an event from event_to_json output. Returns {event} or {error}.
static func event_from_json(data: Variant) -> Dictionary:
	if not data is Dictionary or not (data as Dictionary).has("type"):
		return {"error": "event must be {type, props}"}
	var type := str(data.type)
	if not type in EVENT_CLASSES:
		return {"error": "event type %s is not a recordable InputEvent" % type}
	var event: InputEvent = ClassDB.instantiate(type)
	var props: Variant = data.get("props", {})
	if not props is Dictionary:
		return {"error": "props of %s must be an object" % type}
	var types := {}
	for prop in event.get_property_list():
		types[prop.name] = int(prop.type)
	for name: String in props:
		if not types.has(name) or name in SKIPPED_PROPERTIES:
			continue
		var value: Variant = props[name]
		match types[name]:
			TYPE_BOOL:
				if not value is bool:
					return {"error": "%s.%s must be true or false" % [type, name]}
				event.set(name, value)
			TYPE_INT, TYPE_FLOAT:
				if not _is_number(value):
					return {"error": "%s.%s must be a number" % [type, name]}
				event.set(name, int(value) if types[name] == TYPE_INT else float(value))
			TYPE_STRING, TYPE_STRING_NAME:
				if not value is String:
					return {"error": "%s.%s must be a string" % [type, name]}
				event.set(name, value)
			TYPE_VECTOR2:
				if not (value is Array and (value as Array).size() == 2 and _is_number(value[0]) and _is_number(value[1])):
					return {"error": "%s.%s must be [x, y]" % [type, name]}
				event.set(name, Vector2(float(value[0]), float(value[1])))
	return {"event": event}


static func _is_number(value: Variant) -> bool:
	return typeof(value) in [TYPE_INT, TYPE_FLOAT] and is_finite(float(value))


func start_recording(path: String, window_size: Vector2i) -> Dictionary:
	if state == State.RECORDING:
		return {"error": "Already recording to %s; stop it first" % _path}
	if state == State.REPLAYING:
		return {"error": "A replay is running; wait for it to finish"}
	if path.is_empty():
		path = default_path()
	var err := path_error(path)
	if not err.is_empty():
		return {"error": err}
	_path = path
	_events.clear()
	_window_size = window_size
	_start_frame = Engine.get_process_frames()
	_start_msec = Time.get_ticks_msec()
	_truncated = false
	state = State.RECORDING
	return {"recording": true, "path": path, "window_size": [window_size.x, window_size.y]}


## Connected to the root Window's window_input while recording.
func capture(event: InputEvent) -> void:
	if state != State.RECORDING:
		return
	if _events.size() >= MAX_EVENTS:
		_truncated = true
		return
	var json := event_to_json(event)
	if json.is_empty():
		return
	json["frame"] = Engine.get_process_frames() - _start_frame
	json["msec"] = Time.get_ticks_msec() - _start_msec
	_events.append(json)


## Stop recording and write the file. Returns its summary or {error}; on a
## write error the events stay in memory, so stop can be retried.
func stop_recording() -> Dictionary:
	if state != State.RECORDING:
		return {"error": "Not recording"}
	var frames := Engine.get_process_frames() - _start_frame
	var document := {
		"format": FORMAT,
		"version": VERSION,
		"window_size": [_window_size.x, _window_size.y],
		"frames": frames,
		"duration_ms": Time.get_ticks_msec() - _start_msec,
		"truncated": _truncated,
		"events": _events,
	}
	var write_err := _write(_path, JSON.stringify(document))
	if not write_err.is_empty():
		return {"error": write_err}
	state = State.IDLE
	return {
		"path": _path,
		"events": _events.size(),
		"frames": frames,
		"duration_ms": document.duration_ms,
		"truncated": _truncated,
		"window_size": document.window_size,
	}


## Load `path` and start playing it back. Refuses a recording made at another
## window size, since mouse positions would land elsewhere.
func start_replay(path: String, window_size: Vector2i) -> Dictionary:
	if state != State.IDLE:
		return {"error": "Busy %s; wait or stop first" % ("recording" if state == State.RECORDING else "replaying")}
	var err := path_error(path)
	if not err.is_empty():
		return {"error": err}
	if not FileAccess.file_exists(path):
		return {"error": "Recording not found: %s" % path}
	var parsed := load_document(FileAccess.get_file_as_string(path))
	if parsed.has("error"):
		return {"error": "%s: %s" % [path, parsed.error]}
	var recorded_size: Vector2i = parsed.window_size
	if recorded_size != window_size:
		return {"error": "%s was recorded at %dx%d but the window is %dx%d; resize it first (project_run window_size)" % [path, recorded_size.x, recorded_size.y, window_size.x, window_size.y]}
	_replay_events = parsed.events
	_replay_frames = parsed.frames
	_replay_total_frames = parsed.total_frames
	_replay_next = 0
	_replay_frame = 0
	_replay_path = path
	_replay_finished = false
	_replay_held.clear()
	_replay_released_at_end = 0
	state = State.REPLAYING
	return {"replaying": true, "path": path, "events": _replay_events.size(), "frames": _replay_total_frames}


## Parse a recording's text. Returns {window_size, events, frames,
## total_frames} or {error}.
static func load_document(text: String) -> Dictionary:
	var json := JSON.new()
	if json.parse(text) != OK or not json.data is Dictionary:
		return {"error": "not a JSON object"}
	var data: Dictionary = json.data
	if data.get("format") != FORMAT:
		return {"error": "not a %s file" % FORMAT}
	if not _is_number(data.get("version")) or int(data.version) != VERSION:
		return {"error": "unsupported version %s" % str(data.get("version"))}
	var size: Variant = data.get("window_size")
	if not (size is Array and (size as Array).size() == 2 and _is_number(size[0]) and _is_number(size[1])):
		return {"error": "window_size must be [width, height]"}
	if data.get("frames") != null and not _is_number(data.frames):
		return {"error": "frames must be a number"}
	var raw: Variant = data.get("events")
	if not raw is Array:
		return {"error": "events must be a list"}
	if (raw as Array).size() > MAX_EVENTS:
		return {"error": "more than %d events" % MAX_EVENTS}
	var events: Array[InputEvent] = []
	var frames := PackedInt32Array()
	var last_frame := 0
	for entry: Variant in raw:
		var built := event_from_json(entry)
		if built.has("error"):
			return {"error": "event %d: %s" % [events.size(), built.error]}
		var raw_frame: Variant = (entry as Dictionary).get("frame")
		var frame := int(raw_frame) if _is_number(raw_frame) else -1
		if frame < last_frame:
			return {"error": "event %d: frames must be non-negative and in order" % events.size()}
		last_frame = frame
		events.append(built.event)
		frames.append(frame)
	return {
		"window_size": Vector2i(int(size[0]), int(size[1])),
		"events": events,
		"frames": frames,
		"total_frames": maxi(int(data.get("frames", last_frame)), last_frame),
	}


## Advance playback by one frame, emitting the events due on it.
func tick() -> void:
	if state != State.REPLAYING:
		return
	while _replay_next < _replay_events.size() and _replay_frames[_replay_next] <= _replay_frame:
		var event := _replay_events[_replay_next]
		_track_held(event)
		_emit(event)
		_replay_next += 1
	_replay_frame += 1
	if _replay_next >= _replay_events.size() and _replay_frame > _replay_total_frames:
		## A recording stopped mid-press would leave that input stuck down.
		for held: InputEvent in _replay_held.values():
			var release: InputEvent = held.duplicate()
			release.set("pressed", false)
			_emit(release)
		_replay_released_at_end = _replay_held.size()
		_replay_held.clear()
		state = State.IDLE
		_replay_finished = true


func _emit(event: InputEvent) -> void:
	if emit_event.is_valid():
		emit_event.call(event)
	else:
		Input.parse_input_event(event)


## Key of a pressable event (key, mouse or joypad button, action), or "".
static func _held_key(event: InputEvent) -> String:
	if event is InputEventKey:
		return "key:%d:%d" % [(event as InputEventKey).keycode, (event as InputEventKey).physical_keycode]
	if event is InputEventMouseButton:
		return "mouse:%d" % (event as InputEventMouseButton).button_index
	if event is InputEventJoypadButton:
		return "joy:%d:%d" % [event.device, (event as InputEventJoypadButton).button_index]
	if event is InputEventAction:
		return "action:%s" % (event as InputEventAction).action
	return ""


func _track_held(event: InputEvent) -> void:
	var key := _held_key(event)
	if key.is_empty():
		return
	if event.is_pressed():
		_replay_held[key] = event
	else:
		_replay_held.erase(key)


func replay_status() -> Dictionary:
	return {
		"state": ["idle", "recording", "replaying"][state],
		"path": _replay_path,
		"events_applied": _replay_next,
		"events_total": _replay_events.size(),
		"frame": _replay_frame,
		"frames_total": _replay_total_frames,
		"finished": _replay_finished,
		"released_at_end": _replay_released_at_end,
		"recording_path": _path if state == State.RECORDING else "",
		"recorded_events": _events.size() if state == State.RECORDING else 0,
	}


static func _write(path: String, text: String) -> String:
	var folder := path.get_base_dir()
	var dir_err := DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(folder))
	if dir_err != OK and dir_err != ERR_ALREADY_EXISTS:
		return "Cannot create %s (%s)" % [folder, error_string(dir_err)]
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return "Cannot write %s (%s)" % [path, error_string(FileAccess.get_open_error())]
	file.store_string(text)
	file.close()
	return ""
