@tool
class_name McpImageCompare
extends RefCounted

## Pixel comparison of two captures for visual checks, plus the PNG reads and
## writes it needs. Pure static on Image and FileAccess, shared by the editor
## handler (compare_images, screenshot save_to) and the debugger plugin (game
## screenshot save_to).


## "" when `path` may receive a PNG: a .png under user:// or a writable res://.
static func png_write_error(path: String) -> String:
	if not path.to_lower().ends_with(".png"):
		return "Path must end in .png"
	if path.begins_with("user://"):
		return McpPathValidator.validate_loadable_path(path)
	return McpPathValidator.validate_resource_path(path, true)


## Write already-encoded PNG bytes, creating missing folders. Returns "" or an
## error message.
static func save_png_bytes(bytes: PackedByteArray, path: String) -> String:
	var err := png_write_error(path)
	if not err.is_empty():
		return err
	var folder := ProjectSettings.globalize_path(path.get_base_dir())
	var dir_err := DirAccess.make_dir_recursive_absolute(folder)
	if dir_err != OK and dir_err != ERR_ALREADY_EXISTS:
		return "Cannot create folder for %s (%s)" % [path, error_string(dir_err)]
	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return "Cannot write %s (%s)" % [path, error_string(FileAccess.get_open_error())]
	file.store_buffer(bytes)
	file.close()
	return ""


## Read a PNG from res:// or user:// as RGBA8. The bytes are decoded directly,
## so an imported res:// PNG loads without the editor's import-cache warning.
## Returns {image} or {error}.
static func load_png(path: String) -> Dictionary:
	if path.is_empty():
		return {"error": "Missing path"}
	if not (path.begins_with("res://") or path.begins_with("user://")):
		return {"error": "Path must start with res:// or user:// (got %s)" % path}
	var err := McpPathValidator.validate_loadable_path(path)
	if not err.is_empty():
		return {"error": err}
	if not FileAccess.file_exists(path):
		return {"error": "File not found: %s" % path}
	var image := Image.new()
	if image.load_png_from_buffer(FileAccess.get_file_as_bytes(path)) != OK or image.is_empty():
		return {"error": "Cannot decode PNG %s" % path}
	image.convert(Image.FORMAT_RGBA8)
	return {"image": image}


## Compare two same-size RGBA8 images. Options:
##   region     {x, y, width, height}: only this rectangle is compared.
##   ignore     list of such rectangles left out (animated areas, clocks).
##   mask       Image of the same size; only its opaque pixels are compared.
##   tolerance  per-channel difference (0-255) that still counts as equal.
##   diff       true to also return `diff_image`: `b` dimmed, with the
##              differing pixels in red and the excluded ones dark.
## Returns the compared and differing pixel counts, the bounding box of the
## differing pixels in image coordinates and the largest channel difference
## seen, or {error}.
##
## Excluded pixels are cleared in both images first, and rows whose bytes match
## are skipped with one PackedByteArray comparison, so only rows that differ
## are walked pixel by pixel.
static func compare(a: Image, b: Image, options: Dictionary = {}) -> Dictionary:
	if a.get_size() != b.get_size():
		return {"error": "Images differ in size: %dx%d vs %dx%d" % [a.get_width(), a.get_height(), b.get_width(), b.get_height()]}
	var full := Rect2i(Vector2i.ZERO, a.get_size())
	var region := full
	if options.get("region") != null:
		var parsed := _rect(options.region)
		if parsed.has("error"):
			return {"error": "region: %s" % parsed.error}
		region = full.intersection(parsed.rect)
		if not region.has_area():
			return {"error": "region does not overlap the %dx%d image" % [full.size.x, full.size.y]}
	var local := Rect2i(Vector2i.ZERO, region.size)

	var coverage := Image.create_empty(region.size.x, region.size.y, false, Image.FORMAT_RGBA8)
	coverage.fill(Color.WHITE)
	var mask: Variant = options.get("mask")
	if mask != null:
		var mask_image: Image = mask
		if mask_image.get_size() != a.get_size():
			return {"error": "mask is %dx%d, images are %dx%d" % [mask_image.get_width(), mask_image.get_height(), full.size.x, full.size.y]}
		var kept := Image.create_empty(region.size.x, region.size.y, false, Image.FORMAT_RGBA8)
		kept.blit_rect_mask(coverage, mask_image.get_region(region), local, Vector2i.ZERO)
		coverage = kept
	var ignore: Variant = options.get("ignore", [])
	if not ignore is Array:
		return {"error": "ignore must be a list of rectangles"}
	for entry: Variant in ignore:
		var parsed := _rect(entry)
		if parsed.has("error"):
			return {"error": "ignore: %s" % parsed.error}
		var cut: Rect2i = (parsed.rect as Rect2i).intersection(region)
		if cut.has_area():
			coverage.fill_rect(Rect2i(cut.position - region.position, cut.size), Color(0, 0, 0, 0))

	var left := _covered(a.get_region(region), coverage)
	var right := _covered(b.get_region(region), coverage)
	var tolerance := clampi(int(options.get("tolerance", 0)), 0, 255)
	var width := region.size.x
	var row_bytes := width * 4
	var da := left.get_data()
	var db := right.get_data()
	var dc := coverage.get_data()
	var full_row := PackedByteArray()
	full_row.resize(row_bytes)
	full_row.fill(255)
	var empty_row := PackedByteArray()
	empty_row.resize(row_bytes)

	var compared := 0
	var different := 0
	var max_delta := 0
	var low := Vector2i(width, region.size.y)
	var high := Vector2i(-1, -1)
	var hits := PackedVector2Array()
	for y in region.size.y:
		var start := y * row_bytes
		var row_coverage := dc.slice(start, start + row_bytes)
		if row_coverage == full_row:
			compared += width
		elif row_coverage != empty_row:
			for x in width:
				if row_coverage[x * 4 + 3] != 0:
					compared += 1
		if da.slice(start, start + row_bytes) == db.slice(start, start + row_bytes):
			continue
		for x in width:
			var i := start + x * 4
			var delta := maxi(maxi(absi(da[i] - db[i]), absi(da[i + 1] - db[i + 1])), maxi(absi(da[i + 2] - db[i + 2]), absi(da[i + 3] - db[i + 3])))
			if delta == 0:
				continue
			max_delta = maxi(max_delta, delta)
			if delta <= tolerance:
				continue
			different += 1
			low = Vector2i(mini(low.x, x), mini(low.y, y))
			high = Vector2i(maxi(high.x, x), maxi(high.y, y))
			if bool(options.get("diff", false)):
				hits.append(Vector2(x, y))

	var result := {
		"width": full.size.x,
		"height": full.size.y,
		"region": _rect_json(region),
		"tolerance": tolerance,
		"compared_pixels": compared,
		"different_pixels": different,
		"different_ratio": float(different) / float(compared) if compared > 0 else 0.0,
		"identical": different == 0,
		"max_channel_delta": max_delta,
		"bbox": _rect_json(Rect2i(low + region.position, high - low + Vector2i.ONE)) if different > 0 else null,
	}
	if bool(options.get("diff", false)):
		result["diff_image"] = _diff_image(b.get_region(region), coverage, hits)
	return result


## Copy of `image` with the pixels outside `coverage` cleared to transparent.
static func _covered(image: Image, coverage: Image) -> Image:
	var out := Image.create_empty(image.get_width(), image.get_height(), false, Image.FORMAT_RGBA8)
	out.blit_rect_mask(image, coverage, Rect2i(Vector2i.ZERO, image.get_size()), Vector2i.ZERO)
	return out


static func _diff_image(base: Image, coverage: Image, hits: PackedVector2Array) -> Image:
	var size := base.get_size()
	var shade := Image.create_empty(size.x, size.y, false, Image.FORMAT_RGBA8)
	shade.fill(Color(0, 0, 0, 0.6))
	var out := Image.create_empty(size.x, size.y, false, Image.FORMAT_RGBA8)
	out.fill(Color(0.05, 0.05, 0.05, 1))
	out.blit_rect_mask(base, coverage, Rect2i(Vector2i.ZERO, size), Vector2i.ZERO)
	out.blend_rect(shade, Rect2i(Vector2i.ZERO, size), Vector2i.ZERO)
	for hit in hits:
		out.set_pixelv(Vector2i(hit), Color.RED)
	return out


## Parse {x, y, width, height} into {rect} or {error}.
static func _rect(value: Variant) -> Dictionary:
	if not value is Dictionary:
		return {"error": "expected {x, y, width, height} (got %s)" % type_string(typeof(value))}
	var dict: Dictionary = value
	for key in ["x", "y", "width", "height"]:
		if not dict.has(key) or not (typeof(dict[key]) in [TYPE_INT, TYPE_FLOAT]):
			return {"error": "expected numeric x, y, width and height (got keys %s)" % str(dict.keys())}
	var rect := Rect2i(int(dict.x), int(dict.y), int(dict.width), int(dict.height))
	if not rect.has_area():
		return {"error": "width and height must be positive"}
	return {"rect": rect}


static func _rect_json(rect: Rect2i) -> Dictionary:
	return {"x": rect.position.x, "y": rect.position.y, "width": rect.size.x, "height": rect.size.y}
