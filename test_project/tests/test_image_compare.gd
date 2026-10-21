@tool
extends McpTestSuite

const ImageCompare := preload("res://addons/godot_ai/utils/image_compare.gd")
const TMP_DIR := "user://mcp_image_compare_test"

func suite_name() -> String:
	return "image_compare"


func suite_teardown() -> void:
	for name in ["a.png", "diff.png", "nested/b.png"]:
		DirAccess.remove_absolute(ProjectSettings.globalize_path(TMP_DIR.path_join(name)))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TMP_DIR.path_join("nested")))
	DirAccess.remove_absolute(ProjectSettings.globalize_path(TMP_DIR))


func _pair(width := 20, height := 10) -> Array[Image]:
	var a := Image.create_empty(width, height, false, Image.FORMAT_RGBA8)
	a.fill(Color(0.2, 0.4, 0.6, 1))
	return [a, a.duplicate()]


func test_identical_images_report_no_difference() -> void:
	var pair := _pair()
	var result := ImageCompare.compare(pair[0], pair[1])
	assert_eq(result.compared_pixels, 200)
	assert_eq(result.different_pixels, 0)
	assert_true(result.identical)
	assert_eq(result.bbox, null)
	assert_eq(result.max_channel_delta, 0)


func test_changed_pixels_give_count_bbox_and_delta() -> void:
	var pair := _pair()
	pair[1].set_pixel(3, 2, Color(0.2, 0.4, 0.8, 1))
	pair[1].set_pixel(7, 5, Color(1, 0.4, 0.6, 1))
	var result := ImageCompare.compare(pair[0], pair[1])
	assert_eq(result.different_pixels, 2)
	assert_false(result.identical)
	assert_eq(result.bbox, {"x": 3, "y": 2, "width": 5, "height": 4})
	assert_eq(result.max_channel_delta, 204, "red moved from 51 to 255")
	assert_true(is_equal_approx(result.different_ratio, 0.01))


func test_tolerance_absorbs_small_channel_changes() -> void:
	var pair := _pair()
	pair[1].set_pixel(1, 1, Color8(51, 102, 156, 255))
	var strict := ImageCompare.compare(pair[0], pair[1])
	assert_eq(strict.different_pixels, 1)
	assert_eq(strict.max_channel_delta, 3, "blue moved from 153 to 156")
	var loose := ImageCompare.compare(pair[0], pair[1], {"tolerance": 3})
	assert_eq(loose.different_pixels, 0, "a change within tolerance counts as equal")
	assert_eq(loose.max_channel_delta, strict.max_channel_delta, "the largest delta is reported even under tolerance")


func test_region_and_ignore_limit_the_compared_area() -> void:
	var pair := _pair()
	pair[1].set_pixel(2, 2, Color.WHITE)
	pair[1].set_pixel(15, 8, Color.WHITE)
	var region := ImageCompare.compare(pair[0], pair[1], {"region": {"x": 10, "y": 5, "width": 10, "height": 5}})
	assert_eq(region.compared_pixels, 50)
	assert_eq(region.different_pixels, 1)
	assert_eq(region.bbox, {"x": 15, "y": 8, "width": 1, "height": 1}, "bbox stays in image coordinates")
	var ignored := ImageCompare.compare(pair[0], pair[1], {"ignore": [{"x": 0, "y": 0, "width": 5, "height": 5}]})
	assert_eq(ignored.compared_pixels, 175)
	assert_eq(ignored.different_pixels, 1)
	assert_eq(ignored.bbox.x, 15)


func test_mask_compares_only_its_opaque_pixels() -> void:
	var pair := _pair()
	pair[1].set_pixel(2, 2, Color.WHITE)
	pair[1].set_pixel(15, 8, Color.WHITE)
	var mask := Image.create_empty(20, 10, false, Image.FORMAT_RGBA8)
	mask.fill_rect(Rect2i(10, 0, 10, 10), Color.BLACK)
	var result := ImageCompare.compare(pair[0], pair[1], {"mask": mask})
	assert_eq(result.compared_pixels, 100)
	assert_eq(result.different_pixels, 1)
	assert_eq(result.bbox, {"x": 15, "y": 8, "width": 1, "height": 1})


func test_bad_inputs_are_refused() -> void:
	var pair := _pair()
	var other := Image.create_empty(21, 10, false, Image.FORMAT_RGBA8)
	assert_contains(ImageCompare.compare(pair[0], other).error, "differ in size")
	assert_contains(ImageCompare.compare(pair[0], pair[1], {"region": {"x": 50, "y": 50, "width": 5, "height": 5}}).error, "does not overlap")
	assert_contains(ImageCompare.compare(pair[0], pair[1], {"ignore": [{"x": 1}]}).error, "ignore")
	assert_contains(ImageCompare.compare(pair[0], pair[1], {"mask": other}).error, "mask")


func test_diff_image_marks_changed_pixels_red() -> void:
	var pair := _pair()
	pair[1].set_pixel(4, 3, Color.WHITE)
	var result := ImageCompare.compare(pair[0], pair[1], {"diff": true})
	var diff: Image = result.diff_image
	assert_eq(diff.get_size(), Vector2i(20, 10))
	assert_eq(diff.get_pixel(4, 3), Color.RED)
	assert_true(diff.get_pixel(0, 0).r < 0.2, "unchanged pixels are dimmed")


func test_png_round_trip_and_write_paths() -> void:
	var pair := _pair()
	assert_eq(ImageCompare.save_png_bytes(pair[0].save_png_to_buffer(), TMP_DIR.path_join("a.png")), "")
	assert_eq(ImageCompare.save_png_bytes(pair[1].save_png_to_buffer(), TMP_DIR.path_join("nested/b.png")), "", "missing folders are created")
	var loaded := ImageCompare.load_png(TMP_DIR.path_join("a.png"))
	assert_true(loaded.has("image"), str(loaded))
	if loaded.has("image"):
		assert_true(ImageCompare.compare(loaded.image, pair[1]).identical)
	assert_contains(ImageCompare.load_png(TMP_DIR.path_join("missing.png")).error, "not found")
	assert_contains(ImageCompare.load_png("/tmp/a.png").error, "res:// or user://")
	assert_contains(ImageCompare.png_write_error("user://shot.jpg"), ".png")
	assert_contains(ImageCompare.png_write_error("user://../escape.png"), "..")
	assert_contains(ImageCompare.png_write_error("res://addons/godot_ai/x.png"), "godot_ai")
	assert_eq(ImageCompare.png_write_error("user://shots/ok.png"), "")
