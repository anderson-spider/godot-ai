@tool
extends McpTestSuite

const InputRecorder := preload("res://addons/godot_ai/runtime/input_recorder.gd")
const TMP_PATH := "user://mcp_input_recorder_test/take.json"

func suite_name() -> String:
	return "input_recorder"


func suite_teardown() -> void:
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TMP_PATH))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TMP_PATH.get_base_dir()))


func _key(keycode: Key, pressed: bool) -> InputEventKey:
	var event := InputEventKey.new()
	event.keycode = keycode
	event.physical_keycode = keycode
	event.pressed = pressed
	event.shift_pressed = true
	return event


func test_events_round_trip_through_typed_json() -> void:
	var motion := InputEventMouseMotion.new()
	motion.position = Vector2(12.5, 40)
	motion.relative = Vector2(3, -2)
	motion.button_mask = MOUSE_BUTTON_MASK_LEFT
	var action := InputEventAction.new()
	action.action = &"ui_accept"
	action.pressed = true
	action.strength = 0.5
	for event: InputEvent in [_key(KEY_A, true), motion, action]:
		var json := InputRecorder.event_to_json(event)
		assert_eq(json.type, event.get_class())
		## Through text, as the file stores it.
		var rebuilt := InputRecorder.event_from_json(JSON.parse_string(JSON.stringify(json)))
		assert_has_key(rebuilt, "event", str(rebuilt))
		if rebuilt.has("event"):
			assert_eq(rebuilt.event.get_class(), event.get_class())
			assert_eq(InputRecorder.event_to_json(rebuilt.event), json, "%s survives the round trip" % event.get_class())
	var key: InputEventKey = InputRecorder.event_from_json(InputRecorder.event_to_json(_key(KEY_B, false))).event
	assert_eq(key.keycode, KEY_B)
	assert_true(key.shift_pressed)
	assert_false(key.pressed)


func test_unknown_event_types_are_refused() -> void:
	assert_eq(InputRecorder.event_to_json(InputEventShortcut.new()), {})
	assert_contains(InputRecorder.event_from_json({"type": "Node", "props": {}}).error, "not a recordable")
	assert_contains(InputRecorder.event_from_json({"type": "InputEventMouseMotion", "props": {"position": "x"}}).error, "position")
	assert_contains(InputRecorder.event_from_json("nope").error, "type")
	## Hand-edited or corrupt values are refused instead of erroring at runtime.
	for bad: Dictionary in [{"pressed": "yes"}, {"keycode": null}, {"keycode": [1]}, {"unicode": "x"}]:
		assert_has_key(InputRecorder.event_from_json({"type": "InputEventKey", "props": bad}), "error", str(bad))
	assert_has_key(InputRecorder.event_from_json({"type": "InputEventAction", "props": {"action": 3}}), "error")
	assert_has_key(InputRecorder.event_from_json({"type": "InputEventMouseMotion", "props": {"position": [1, null]}}), "error")


func test_path_rules() -> void:
	assert_eq(InputRecorder.path_error("user://takes/a.json"), "")
	assert_eq(InputRecorder.path_error("res://qa/takes/a.json"), "")
	assert_contains(InputRecorder.path_error("/tmp/a.json"), "user://")
	assert_contains(InputRecorder.path_error("user://a.txt"), ".json")
	assert_contains(InputRecorder.path_error("user://../a.json"), "..")
	assert_contains(InputRecorder.path_error("user://..\\a.json"), "..")
	assert_contains(InputRecorder.path_error("res://addons/godot_ai/a.json"), "addons/godot_ai")
	assert_contains(InputRecorder.path_error("res://.godot/a.json"), ".godot")
	assert_true(InputRecorder.default_path().begins_with(InputRecorder.DEFAULT_DIR))


func test_record_write_load_and_replay_by_frame() -> void:
	var recorder := InputRecorder.new()
	assert_has_key(recorder.start_recording(TMP_PATH, Vector2i(800, 600)), "recording")
	assert_contains(recorder.start_recording(TMP_PATH, Vector2i(800, 600)).error, "Already recording")
	recorder.capture(_key(KEY_A, true))
	recorder.capture(InputEventShortcut.new())
	recorder.capture(_key(KEY_A, false))
	var summary := recorder.stop_recording()
	assert_eq(summary.path, TMP_PATH)
	assert_eq(summary.events, 2, "the unrecordable event is skipped")
	assert_eq(summary.window_size, [800, 600])
	assert_true(FileAccess.file_exists(TMP_PATH))

	## Rewrite the frames so playback spreads over three frames.
	var document: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(TMP_PATH))
	document.events[0].frame = 0
	document.events[1].frame = 2
	document.frames = 2
	var file := FileAccess.open(TMP_PATH, FileAccess.WRITE)
	file.store_string(JSON.stringify(document))
	file.close()

	assert_contains(recorder.start_replay(TMP_PATH, Vector2i(1024, 600)).error, "800x600")
	var emitted: Array[InputEvent] = []
	recorder.emit_event = func(event: InputEvent) -> void: emitted.append(event)
	var started := recorder.start_replay(TMP_PATH, Vector2i(800, 600))
	assert_eq(started.events, 2)
	assert_contains(recorder.start_recording(TMP_PATH, Vector2i(800, 600)).error, "replay")
	recorder.capture(_key(KEY_C, true))
	recorder.tick()
	assert_eq(emitted.size(), 1, "frame 0 emits the first event")
	assert_true((emitted[0] as InputEventKey).pressed)
	recorder.tick()
	assert_eq(emitted.size(), 1, "nothing due on frame 1")
	assert_eq(recorder.replay_status().state, "replaying")
	recorder.tick()
	assert_eq(emitted.size(), 2, "frame 2 emits the release")
	assert_false((emitted[1] as InputEventKey).pressed)
	var status := recorder.replay_status()
	assert_eq(status.state, "idle")
	assert_true(status.finished)
	assert_eq(status.events_applied, 2)
	assert_eq(status.events_total, 2)


func test_bad_recordings_are_refused() -> void:
	assert_contains(InputRecorder.load_document("[]").error, "JSON object")
	assert_contains(InputRecorder.load_document('{"format": "other"}').error, "not a")
	var base := {"format": InputRecorder.FORMAT, "version": InputRecorder.VERSION, "window_size": [10, 10]}
	var unordered := base.duplicate()
	unordered["events"] = [
		{"type": "InputEventAction", "props": {"action": "a"}, "frame": 3},
		{"type": "InputEventAction", "props": {"action": "a"}, "frame": 1},
	]
	assert_contains(InputRecorder.load_document(JSON.stringify(unordered)).error, "in order")
	var future := base.duplicate()
	future["version"] = 99
	future["events"] = []
	assert_contains(InputRecorder.load_document(JSON.stringify(future)).error, "version")
	for broken: Dictionary in [{"version": null}, {"window_size": [10, null]}, {"frames": "many"}]:
		var doc := base.duplicate()
		doc["events"] = []
		doc.merge(broken, true)
		assert_has_key(InputRecorder.load_document(JSON.stringify(doc)), "error", str(broken))
	var no_frame := base.duplicate()
	no_frame["events"] = [{"type": "InputEventAction", "props": {"action": "a"}, "frame": null}]
	assert_has_key(InputRecorder.load_document(JSON.stringify(no_frame)), "error")
	var recorder := InputRecorder.new()
	assert_contains(recorder.start_replay("user://mcp_input_recorder_test/missing.json", Vector2i(10, 10)).error, "not found")
	assert_contains(recorder.stop_recording().error, "Not recording")


func test_replay_releases_what_the_recording_left_pressed() -> void:
	var recorder := InputRecorder.new()
	var mouse := InputEventMouseButton.new()
	mouse.button_index = MOUSE_BUTTON_LEFT
	mouse.pressed = true
	var document := {
		"format": InputRecorder.FORMAT, "version": InputRecorder.VERSION, "window_size": [10, 10], "frames": 0,
		"events": [
			InputRecorder.event_to_json(_key(KEY_A, true)).merged({"frame": 0}),
			InputRecorder.event_to_json(_key(KEY_B, true)).merged({"frame": 0}),
			InputRecorder.event_to_json(_key(KEY_B, false)).merged({"frame": 0}),
			InputRecorder.event_to_json(mouse).merged({"frame": 0}),
		],
	}
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(TMP_PATH.get_base_dir()))
	var file := FileAccess.open(TMP_PATH, FileAccess.WRITE)
	file.store_string(JSON.stringify(document))
	file.close()
	var emitted: Array[InputEvent] = []
	recorder.emit_event = func(event: InputEvent) -> void: emitted.append(event)
	assert_has_key(recorder.start_replay(TMP_PATH, Vector2i(10, 10)), "replaying")
	recorder.tick()
	assert_eq(recorder.replay_status().state, "idle")
	assert_eq(recorder.replay_status().released_at_end, 2, "A and the left button were still down")
	var tail := emitted.slice(4)
	assert_eq(tail.size(), 2)
	for event in tail:
		assert_false(event.is_pressed(), "%s is released" % event.as_text())
