extends RefCounted
## Pure helper logic for the PixelLab dialog — kept static and Global-free
## so it stays testable headless (src/pixellab_utiltest.gd).

const ROTATIONS_TAG := "rotations"


## Maps aseprite tag names to /save-to-asset targets from an asset detail
## response (works for both characters and objects — same animations[] shape).
## detail.animations[] = [{animation_type, animation_group_id,
## directions: [{direction, frame_count, frames}]}]. PixelLab aseprite exports
## tag each animation-direction as "<animation_type>-<direction>".
## kind: "character" or "object" (the save-to-asset target prefix).
## Result: {tag_name: target_string} — "rotations" maps to a marker
## "rotations:<kind>:<asset_id>" when the asset has state rotations
## (detail.directions > 0): saving them back is expanded per direction from a
## fresh spritesheet layout at save time (see rotations_plan). Empty string
## when the asset has no rotations at all.
static func build_tag_target_map(detail: Dictionary, asset_id: String,
		kind := "character") -> Dictionary:
	var map := {}
	map[ROTATIONS_TAG] = ""
	for anim in detail.get("animations", []):
		var group_id: String = str(anim.get("animation_group_id", ""))
		var raw_type: String = str(anim.get("animation_type", ""))
		if raw_type.is_empty():
			continue
		# PixelLab's aseprite exporter derives tag names from the animation
		# type: strips the "custom-" prefix, underscores spaces, truncates to
		# 16 chars, then appends "-<direction>" (verified against a real
		# The Producer export: "The_character_tu-west"). Register BOTH the
		# truncated and full forms so either tag style matches.
		var base := raw_type
		if base.begins_with("custom-"):
			base = base.substr(7)
		var underscored := base.replace(" ", "_")
		for direction in anim.get("directions", []):
			var dir_name: String = str(direction.get("direction", ""))
			if dir_name.is_empty():
				continue
			var target := ""
			if group_id.is_empty():
				target = "%s:%s:%s" % [kind, asset_id, dir_name]
			else:
				target = "%s:%s:%s:%s" % [kind, asset_id, dir_name, group_id]
			map[underscored.substr(0, 16) + "-" + dir_name] = target
			map[underscored + "-" + dir_name] = target
	# State rotations: the detail carries only the COUNT (directions: 4), the
	# ORDER lives in the spritesheet layout — fetched and validated at save
	# time. The marker form keeps every string-based map consumer working.
	if int(detail.get("directions", 0)) > 0:
		map[ROTATIONS_TAG] = "rotations:%s:%s" % [kind, asset_id]
	return map


## True when some project tag is the rotations tag AND the pull-time map gave
## it a rotations marker (i.e. the asset actually has state rotations).
static func has_mapped_rotations(tags: Array, map: Dictionary) -> bool:
	for tag in tags:
		if str(_tag_field(tag, "name", "")) == ROTATIONS_TAG \
				and str(map.get(ROTATIONS_TAG, "")).begins_with("rotations:"):
			return true
	return false


## Plans a whole-project save-back: one job per project tag that has a cloud
## target in the pull-time map. tags = project.animation_tags entries with
## {name, from, to}; map = the tag->target map stored in pixellab_source.
## Returns [{tag_name, target, from, to, frame_count}] in tag order.
## The "rotations" marker target ("rotations:<kind>:<id>") is skipped here —
## it expands per direction via rotations_plan (needs a fresh layout).
## Tags the map does not know (added after the pull) are skipped too.
static func collect_save_jobs(tags: Array, map: Dictionary) -> Array:
	var jobs: Array = []
	for tag in tags:
		var tag_name: String = str(_tag_field(tag, "name", ""))
		var target: String = str(map.get(tag_name, ""))
		if target.is_empty() or target.begins_with("rotations:"):
			continue
		var from := int(_tag_field(tag, "from", 0))
		var to := int(_tag_field(tag, "to", 0))
		if from < 1 or to < from:
			continue
		jobs.append({"tag_name": tag_name, "target": target,
				"from": from, "to": to, "frame_count": to - from + 1})
	return jobs


## Plans the rotations save-back from a FRESH spritesheet layout. PixelLab
## rotations rows are flat — exactly one frame per direction, in the order
## listed ("frame_count" == directions count; verified pixel-level against two
## real exports, see src/pixellab_mapdiag.gd VERDICT-ORDER). Each project frame
## in the rotations tag maps to "<kind>:<asset_id>:<direction>" — the
## documented rotation target form of /save-to-asset.
## marker: the pull-time map entry ("rotations:<kind>:<asset_id>").
## from/to: the project rotations tag's inclusive frame bounds.
## layout: the parsed layout JSON from a fresh spritesheet download.
## stored_directions: the order recorded at pull time (may be empty when the
## pull could not fetch a layout — then no order drift check is possible).
## canvas: the asset's rotation canvas from its detail ("size") — sheet cells
## are sized to the export's LARGEST frame, so for mixed-canvas assets each
## rotation job carries the true canvas and the push crops to it (verified
## live: cropped cells wrote 0 changed pixels against 128x128 targets).
## Returns {ok, error, jobs} — jobs share the collect_save_jobs shape plus
## "direction"; on ok=false, error says what to fix and jobs is [].
## ponytail: order drift between pull and save is only caught when the pull
## stored directions (rotations_directions in pixellab_source); the upgrade
## path is always storing them at pull and failing closed here.
static func rotations_plan(marker: String, from: int, to: int, layout: Dictionary,
		stored_directions: Array, canvas: Dictionary = {}) -> Dictionary:
	var no := {"ok": false, "error": "", "jobs": []}
	var parts := marker.split(":")
	if parts.size() != 3 or parts[0] != "rotations" or str(parts[2]).is_empty():
		no["error"] = "rotations marker is malformed (%s)" % marker
		return no
	var kind := str(parts[1])
	var asset_id := str(parts[2])
	var sheet: Dictionary = layout.get("spritesheet", {}) if layout is Dictionary else {}
	var rows: Array = sheet.get("rows", []) if sheet is Dictionary else []
	var rot_row: Variant = null
	for row in rows:
		if row is Dictionary and str(row.get("type", "")) == "rotations":
			rot_row = row
			break
	if rot_row == null:
		no["error"] = "the fresh spritesheet layout has no rotations row"
		return no
	var dirs: Array = rot_row.get("directions", [])
	var span := to - from + 1
	if dirs.is_empty():
		no["error"] = "the fresh spritesheet layout lists no rotation directions"
		return no
	if span != dirs.size():
		no["error"] = "rotations frame count changed since the pull: the project tag has %d frames, the cloud layout has %d directions" % [span, dirs.size()]
		return no
	if not stored_directions.is_empty() and stored_directions != dirs:
		no["error"] = "rotation direction order changed since the pull (was %s, now %s) — re-pull the asset before saving rotations back" % [stored_directions, dirs]
		return no
	var jobs: Array = []
	for i in range(dirs.size()):
		var dir_name := str(dirs[i])
		if dir_name.is_empty():
			no["error"] = "the fresh spritesheet layout has an unnamed rotation direction (index %d)" % i
			return no
		# One-direction objects take the bare object:<id> form ("a one-direction
		# object needs no direction" — spec target syntax).
		var target := "%s:%s" % [kind, asset_id] \
				if (kind == "object" and dirs.size() == 1) \
				else "%s:%s:%s" % [kind, asset_id, dir_name]
		jobs.append({"tag_name": ROTATIONS_TAG, "direction": dir_name,
				"target": target, "canvas": canvas,
				"from": from + i, "to": from + i, "frame_count": 1})
	return {"ok": true, "error": "", "jobs": jobs}


## Reads the rotation direction order out of a spritesheet layout (the shape
## download_spritesheet returns in "layout"). Empty array when absent.
static func layout_rotations_directions(layout: Dictionary) -> Array:
	if not (layout is Dictionary):
		return []
	var sheet: Dictionary = layout.get("spritesheet", {})
	if not (sheet is Dictionary):
		return []
	for row in sheet.get("rows", []):
		if row is Dictionary and str(row.get("type", "")) == "rotations":
			var dirs: Array = row.get("directions", [])
			if not dirs.is_empty():
				return dirs
	return []


## Reads a field from either a real AnimationTag object or a plain Dictionary
## (tests pass dicts; the dialog passes AnimationTags). Object.get() takes no
## default argument and returns null for a missing property, so the fallback
## is applied here for both shapes.
static func _tag_field(tag: Variant, key: String, fallback: Variant) -> Variant:
	if tag is Dictionary:
		return tag.get(key, fallback)
	var value: Variant = tag.get(key)
	return fallback if value == null else value


## Frame-count pre-check against a FRESH asset detail response. PixelLab only
## accepts a save when the frame count matches what is stored, so check before
## pushing anything. Returns [] when every job matches (or cannot be judged —
## the server still validates); otherwise [{tag_name, expected, actual}].
## Target syntax "<kind>:<id>:<direction>[:<group>]" is parsed to find the
## matching detail.animations entry (by group id + direction).
static func count_mismatches(jobs: Array, detail: Dictionary) -> Array:
	# Index the detail once: "<group_id>:<direction>" -> frame_count.
	var counts := {}
	for anim in detail.get("animations", []):
		var group: String = str(anim.get("animation_group_id", ""))
		for direction in anim.get("directions", []):
			var dir_name: String = str(direction.get("direction", ""))
			if not dir_name.is_empty():
				counts["%s:%s" % [group, dir_name]] = int(direction.get("frame_count", 0))
	var problems: Array = []
	for job in jobs:
		if job.has("direction"):
			continue  # rotations job — validated against the fresh layout by rotations_plan
		var parts := str(job["target"]).split(":")
		if parts.size() < 3:
			continue  # object:<id> form or malformed — let the server judge
		var key := "%s:%s" % [parts[3] if parts.size() > 3 else "", parts[2]]
		if not counts.has(key):
			continue
		var expected := int(counts[key])
		var actual := int(job["frame_count"])
		if actual != expected:
			problems.append({"tag_name": job["tag_name"],
					"expected": expected, "actual": actual})
	return problems


## Extracts the frames a save replaced (previous_frames in the response body,
## an array of Base64Image dicts) into raw PNG byte arrays, ready to push back
## to the same target as an undo. Empty array when the body carries none.
static func previous_frames_to_pngs(body: Dictionary) -> Array:
	var pngs: Array = []
	for frame in body.get("previous_frames", []):
		var b64 := ""
		if frame is Dictionary:
			b64 = str(frame.get("base64", ""))
		elif frame is String:
			b64 = frame  # tolerate a bare base64 string
		if b64.is_empty():
			continue
		var decoded := Marshalls.base64_to_raw(b64)
		if not decoded.is_empty():
			pngs.append(decoded)
	return pngs


## Groups list items into display rows for the browser. items = list entries
## with at least {id, name, group_id?}. Returns an ordered array of
## {header: String, items: Array[Dictionary]}; groups keep first-seen order,
## keyless assets land in "Ungrouped".
static func grouped_rows(items: Array) -> Array:
	var order: Array = []
	var buckets := {}
	for item in items:
		var group_id: String = str(item.get("group_id", ""))
		var key := group_id if not group_id.is_empty() else "ungrouped"
		if not buckets.has(key):
			buckets[key] = []
			order.append(key)
		buckets[key].append(item)
	var rows: Array = []
	for key in order:
		var members: Array = buckets[key]
		var label := "Ungrouped"
		if key != "ungrouped":
			# Group display name: the longest common prefix of member names,
			# trimmed to something readable; fall back to the short id.
			label = _common_prefix_names(members)
			if label.is_empty():
				label = "Project " + key.substr(0, 8)
		rows.append({"header": label, "items": members})
	return rows


static func _common_prefix_names(members: Array) -> String:
	var names: Array = []
	for m in members:
		names.append(str(m.get("name", "")))
	if names.is_empty():
		return ""
	var prefix: String = names[0]
	for n in names:
		while not n.begins_with(prefix) and not prefix.is_empty():
			prefix = prefix.substr(0, prefix.length() - 1)
	return prefix.strip_edges()
