extends AcceptDialog
## PixelLab asset browser — browse your pixellab.ai library, pull assets as
## tagged Aseprite projects (or flat spritesheet layers), and save edits back
## to the exact cloud animation they came from.

const API := preload("res://src/Extensions/PixelLabAssets/PixelLabAPI.gd")
const Util := preload("res://src/Extensions/PixelLabAssets/PixelLabUtil.gd")
const GIFExporter := preload("res://addons/gdgifexporter/exporter.gd")
const MedianCutQuantization := preload("res://addons/gdgifexporter/quantization/median_cut.gd")
const CONFIG_PATH := "user://pixellab.cfg"
const CATEGORIES := ["characters", "objects"]
const MAX_UPLOAD_SIZE := 256
const THUMB_SIZE := 48

var api: RefCounted
var _busy := false
var _list_generation := 0
var _thumbnails_pending := 0
var _selected_tag := ""

@onready var secret_key_edit: LineEdit = %SecretKey
@onready var save_key_button: Button = %SaveKey
@onready var category_option: OptionButton = %Category
@onready var refresh_button: Button = %Refresh
@onready var asset_list: ItemList = %Assets
@onready var status_label: Label = %Status
@onready var pull_aseprite_button: Button = %PullAseprite
@onready var pull_sheet_button: Button = %PullSheet
@onready var save_tag_option: OptionButton = %SaveTag
@onready var save_back_button: Button = %SaveBack
@onready var save_all_button: Button = %SaveAll
@onready var undo_button: Button = %UndoSave
@onready var publish_button: Button = %PublishGif
@onready var upload_button: Button = %UploadFrame


func _ready() -> void:
	api = API.new()
	_load_config()
	for category in CATEGORIES:
		category_option.add_item(category.capitalize())
	secret_key_edit.secret = true
	secret_key_edit.text_changed.connect(_on_key_edited)
	save_key_button.pressed.connect(_on_save_key_pressed)
	refresh_button.pressed.connect(_refresh)
	pull_aseprite_button.pressed.connect(_on_pull_aseprite_pressed)
	pull_sheet_button.pressed.connect(_on_pull_sheet_pressed)
	save_back_button.pressed.connect(_on_save_back_pressed)
	save_all_button.pressed.connect(_on_save_all_pressed)
	undo_button.pressed.connect(_on_undo_pressed)
	publish_button.pressed.connect(_on_publish_gif_pressed)
	upload_button.pressed.connect(_on_upload_pressed)
	save_tag_option.item_selected.connect(
			func(i: int) -> void: _selected_tag = save_tag_option.get_item_text(i))
	visibility_changed.connect(_on_visibility_changed)
	_set_status("Paste your pixellab.ai secret key (from pixellab.ai/account), then Refresh.")


func _on_visibility_changed() -> void:
	if not visible:
		return
	_refresh_save_tags()


## Save-back targets live in project metadata (set at pull time). Repopulate
## the tag picker from the CURRENT project every time the dialog opens.
## Also syncs every action button's availability to the current project:
##   Save edits back / Save all back — need pulled source + a mapped tag.
##   Undo last save — needs a stored previous-frames snapshot.
##   Publish tag as GIF — needs any non-empty project (no pull required).
func _refresh_save_tags() -> void:
	save_tag_option.clear()
	var project := Global.current_project
	undo_button.disabled = project == null or not project.has_meta("pixellab_undo")
	publish_button.disabled = project == null or project.is_empty()
	save_back_button.disabled = true
	save_all_button.disabled = true
	if project == null or not project.has_meta("pixellab_source"):
		return
	var source: Dictionary = project.get_meta("pixellab_source")
	var map: Dictionary = source.get("map", {})
	var tags_found := 0
	var restore_index := -1
	for tag in project.animation_tags:
		if map.has(tag.name) and not str(map[tag.name]).is_empty():
			save_tag_option.add_item(tag.name)
			var idx := save_tag_option.item_count - 1
			if tag.name == _selected_tag:
				save_tag_option.select(idx)
				restore_index = idx
			tags_found += 1
	if restore_index >= 0:
		save_tag_option.select(restore_index)
	var has_jobs: bool = not Util.collect_save_jobs(project.animation_tags, map).is_empty() \
			or Util.has_mapped_rotations(project.animation_tags, map)
	save_back_button.disabled = tags_found == 0
	save_all_button.disabled = not has_jobs


func _load_config() -> void:
	var config := ConfigFile.new()
	if config.load(CONFIG_PATH) == OK:
		api.secret_key = config.get_value("pixellab", "secret_key", "")
		if not api.secret_key.is_empty():
			secret_key_edit.text = api.secret_key


func _save_config() -> void:
	var config := ConfigFile.new()
	config.set_value("pixellab", "secret_key", api.secret_key)
	config.save(CONFIG_PATH)


func _on_key_edited(_text: String) -> void:
	api.secret_key = secret_key_edit.text.strip_edges()


func _on_save_key_pressed() -> void:
	_on_key_edited(secret_key_edit.text)
	if api.secret_key.is_empty():
		_set_status("Key is empty.", true)
		return
	_save_config()
	var balance = await api.get_balance(self)
	if balance.ok and balance.json is Dictionary:
		var credits: Variant = balance.json.get("credits", {})
		# v2 shape: credits is {type: "usd", usd: <float>}
		var credits_text := str(credits.get("usd", credits)) if credits is Dictionary else str(credits)
		_set_status("Key saved. Balance: %s USD" % credits_text)
	else:
		_set_status("Key saved, but balance check failed: %s" % balance.error, true)


func _set_status(text: String, is_error := false) -> void:
	if is_error:
		status_label.add_theme_color_override("font_color", Color.ORANGE_RED)
	else:
		status_label.remove_theme_color_override("font_color")
	status_label.text = text


func _set_busy(busy: bool) -> void:
	_busy = busy
	for button: Button in [refresh_button, pull_aseprite_button, pull_sheet_button,
			save_back_button, save_all_button, undo_button, publish_button,
			upload_button, save_key_button]:
		button.disabled = busy


func _refresh() -> void:
	if _busy:
		return
	if api.secret_key.is_empty():
		_set_status("Enter your secret key first.", true)
		return
	asset_list.clear()
	var category: String = CATEGORIES[category_option.selected]
	_set_busy(true)
	_set_status("Listing %s..." % category)
	var res = await api.list_assets(self, category)
	_set_busy(false)
	if not res.ok:
		_set_status("Listing failed: %s" % res.error, true)
		return
	# Grouped rendering: bold header rows per PixelLab project/group.
	var rows: Array = Util.grouped_rows(res.items)
	for row in rows:
		var header_idx := asset_list.add_item("— %s —" % row["header"])
		asset_list.set_item_disabled(header_idx, true)
		for item in row["items"]:
			var label: String = str(item.get("name", "(unnamed)"))
			var size_info: Dictionary = item.get("size", {})
			var dims := "%dx%d" % [int(size_info.get("width", 0)), int(size_info.get("height", 0))] if size_info else ""
			var suffix := "  [%s, %d dir]" % [dims, item.get("directions", 1)] if not dims.is_empty() else ""
			var idx := asset_list.add_item(label + suffix)
			asset_list.set_item_metadata(idx, {
				"id": str(item.get("id", "")), "name": label,
				"group_id": str(item.get("group_id", "")),
				"preview_url": str(item.get("preview_url", "")),
			})
	_set_status("Loaded %d of %d %s." % [res.items.size(), res.total, category])
	# Thumbnails: fire-and-forget, generation-guarded against stale fills.
	_list_generation += 1
	var gen := _list_generation
	var flat_idx := 0
	for row in rows:
		flat_idx += 1  # skip header row
		for item in row["items"]:
			var preview: String = str(item.get("preview_url", ""))
			if not preview.is_empty():
				_thumbnails_pending += 1
				_fetch_thumbnail(gen, flat_idx, preview)
			flat_idx += 1


func _fetch_thumbnail(gen: int, idx: int, url: String) -> void:
	# Disk cache first: same preview never refetches within/between sessions.
	var cache_path := "user://pixellab_cache/%s.png" % url.md5_text()
	var bytes := PackedByteArray()
	if FileAccess.file_exists(cache_path):
		var cached := FileAccess.open(cache_path, FileAccess.READ)
		if cached != null:
			bytes = cached.get_buffer(cached.get_length())
	if bytes.is_empty():
		bytes = await api.fetch_preview(self, url)
		if not bytes.is_empty():
			DirAccess.make_dir_recursive_absolute(cache_path.get_base_dir())
			var cache_file := FileAccess.open(cache_path, FileAccess.WRITE)
			if cache_file != null:
				cache_file.store_buffer(bytes)
				cache_file.close()
	_thumbnails_pending = maxi(0, _thumbnails_pending - 1)
	if gen != _list_generation:
		return  # the list was refreshed meanwhile; discard stale result
	if bytes.is_empty():
		return
	var image := Image.new()
	if image.load_png_from_buffer(bytes) != OK:
		return
	if idx >= asset_list.item_count:
		return
	image.resize(THUMB_SIZE, THUMB_SIZE, Image.INTERPOLATE_NEAREST)
	asset_list.set_item_icon(idx, ImageTexture.create_from_image(image))


func _selected_asset() -> Dictionary:
	var selected := asset_list.get_selected_items()
	if selected.is_empty():
		return {}
	var meta: Variant = asset_list.get_item_metadata(selected[0])
	return meta if meta is Dictionary else {}


## Pull as Aseprite: downloads the tagged file and opens it as its own
## Pixelorama project (frames, layers and animation tags preserved), then
## records the source mapping so "Save edits back" can target the cloud.
func _on_pull_aseprite_pressed() -> void:
	if _busy:
		return
	var asset := _selected_asset()
	if asset.is_empty():
		_set_status("Select an asset first.", true)
		return
	var category: String = CATEGORIES[category_option.selected]
	_set_busy(true)
	_set_status("Downloading Aseprite file for %s..." % asset["name"])
	var res = await api.download_aseprite(self, category, asset["id"])
	if not res.ok:
		_set_busy(false)
		_set_status("Download failed: %s" % res.error, true)
		return
	var tmp_path := "user://tmp_pull.aseprite"
	var file := FileAccess.open(tmp_path, FileAccess.WRITE)
	if file == null:
		_set_busy(false)
		_set_status("Could not buffer the downloaded file.", true)
		return
	file.store_buffer(res.ase)
	file.close()
	var projects_before := Global.projects.size()
	load("res://src/Classes/SoftwareParsers/AsepriteParser.gd").open_aseprite_file(tmp_path)
	if Global.projects.size() != projects_before + 1:
		_set_busy(false)
		_set_status("Import failed — not a valid Aseprite file?", true)
		return
	var source := {"source": category, "id": asset["id"], "name": asset["name"],
			"map": {}, "pulled_at": Time.get_datetime_string_from_system()}
	if category == "characters":
		var detail = await api.get_character_detail(self, asset["id"])
		if detail.ok and detail.json is Dictionary:
			source["map"] = Util.build_tag_target_map(detail.json, asset["id"], "character")
		else:
			source["map"] = {Util.ROTATIONS_TAG: ""}
	else:
		var detail = await api.get_object_detail(self, asset["id"])
		if detail.ok and detail.json is Dictionary:
			source["map"] = Util.build_tag_target_map(detail.json, asset["id"], "object")
		else:
			source["map"] = {"*": "object:%s" % asset["id"]}
	# Rotation direction order, recorded at pull time so save-back can detect
	# order drift later (free GET; failure only means no drift check exists).
	var sheet = await api.download_spritesheet(self, category, asset["id"])
	if sheet.ok:
		source["rotations_directions"] = Util.layout_rotations_directions(sheet.layout)
	Global.current_project.set_meta("pixellab_source", source)
	_set_busy(false)
	_refresh_save_tags()
	_set_status("Pulled %s as its own project (%d frames, %d tags). Save-back targets recorded." %
			[asset["name"], Global.current_project.frames.size(),
			Global.current_project.animation_tags.size()])


## Legacy path: flat spritesheet pulled as one new layer in the current project.
func _on_pull_sheet_pressed() -> void:
	if _busy:
		return
	var asset := _selected_asset()
	if asset.is_empty():
		_set_status("Select an asset first.", true)
		return
	var category: String = CATEGORIES[category_option.selected]
	_set_busy(true)
	_set_status("Downloading spritesheet for %s..." % asset["name"])
	var res = await api.download_spritesheet(self, category, asset["id"])
	if not res.ok:
		_set_busy(false)
		_set_status("Download failed: %s" % res.error, true)
		return
	var image := Image.new()
	if image.load_png_from_buffer(res.png) != OK:
		_set_busy(false)
		_set_status("Downloaded data is not a valid PNG.", true)
		return
	OpenSave.open_image_as_new_layer(image, str(asset["name"]))
	_set_busy(false)
	_set_status("Pulled %s into the project as a new layer (%dx%d)." %
			[asset["name"], image.get_width(), image.get_height()])


## Builds the per-direction save jobs for the project's rotations tag against
## a fresh spritesheet layout, or {ok: false, error} when rotations cannot be
## planned (no tag, fetch failure, count/order drift — the error says which).
## canvas: the asset's rotation canvas (detail "size") when the caller already
## fetched it; when empty, the detail is fetched here (needed for mixed-canvas
## assets whose sheet cells are bigger than their rotation canvas).
func _rotations_jobs_for(project: Variant, source: Dictionary, canvas := {}) -> Dictionary:
	var none := {"ok": false, "error": "", "jobs": []}
	var map: Dictionary = source.get("map", {})
	var marker := str(map.get(Util.ROTATIONS_TAG, ""))
	if not marker.begins_with("rotations:"):
		none["error"] = "this asset has no state rotations"
		return none
	var tag: Variant = null
	for t in project.animation_tags:
		if str(t.name) == Util.ROTATIONS_TAG:
			tag = t
			break
	if tag == null:
		none["error"] = "the project has no rotations tag"
		return none
	var asset_id := str(source.get("id", ""))
	if canvas.is_empty():
		_set_status("Fetching asset canvas size...")
		var d: Dictionary
		if str(source.get("source", "characters")) == "characters":
			d = await api.get_character_detail(self, asset_id)
		else:
			d = await api.get_object_detail(self, asset_id)
		if d.ok and d.json is Dictionary:
			canvas = d.json.get("size", {})
	_set_status("Planning rotations save-back (fetching fresh layout)...")
	var sheet = await api.download_spritesheet(self,
			str(source.get("source", "characters")), asset_id)
	if not sheet.ok:
		none["error"] = "spritesheet fetch failed: %s" % sheet.error
		return none
	return Util.rotations_plan(marker, int(tag.from), int(tag.to), sheet.layout,
			source.get("rotations_directions", []), canvas)


## Renders and pushes one job set (the shared write path of Save edits back /
## Save all back). A failing job never blocks the others. Returns
## {saved, changed, failed, undo_entries} — undo_entries carry the frames each
## push replaced, ready for Undo to restore the cloud asset byte-for-byte.
func _push_jobs(jobs: Array) -> Dictionary:
	var saved := 0
	var changed_total := 0
	var failed: Array = []
	var undo_entries: Array = []
	for job in jobs:
		var label: String = str(job["tag_name"])
		if job.has("direction"):
			label = "%s/%s" % [label, job["direction"]]
		var done := saved + failed.size()
		_set_status("Saving %s (%d/%d)..." % [label, done + 1, jobs.size()])
		var frames: Array = []
		var render_failed := false
		for i in range(int(job["from"]) - 1, int(job["to"])):
			var frame = Global.current_project.frames[i]
			var img: Image = Export.blended_frames.get(frame)
			if img == null:
				failed.append("%s: frame %d failed to render" % [label, i + 1])
				render_failed = true
				break
			var png := img.save_png_to_buffer()
			if png.is_empty():
				failed.append("%s: PNG encoding failed on frame %d" % [label, i + 1])
				render_failed = true
				break
			frames.append(png)
		if render_failed:
			continue
		# A rotation target takes ONE image (the documented request shape —
		# "a rotation" under .image); frames arrays are for animation
		# directions. Single-frame rotation jobs therefore push via image.
		var is_rotation_push: bool = job.has("direction") and frames.size() == 1
		var res: Dictionary
		if is_rotation_push:
			res = await api.save_to_asset(self, str(job["target"]), [],
					_crop_to_canvas(frames[0], job.get("canvas", {})))
		else:
			res = await api.save_to_asset(self, str(job["target"]), frames)
		if not res.ok:
			failed.append("%s: %s" % [label, res.error])
			continue
		saved += 1
		var body: Dictionary = res.json if res.json is Dictionary else {}
		changed_total += int(body.get("changed_pixels", 0))
		var previous: Array = Util.previous_frames_to_pngs(body)
		if not previous.is_empty():
			undo_entries.append({"target": str(job["target"]), "frames": previous,
					"mode": "image" if is_rotation_push else "frames"})
	return {"saved": saved, "changed": changed_total, "failed": failed,
			"undo_entries": undo_entries}


## Save edits back: sends the edited frames of the chosen tag to the exact
## cloud animation they were pulled from. The rotations tag expands to one
## push per direction (order validated against a fresh layout first).
func _on_save_back_pressed() -> void:
	if _busy:
		return
	var project := Global.current_project
	if project == null:
		return
	if not project.has_meta("pixellab_source"):
		_set_status("This project was not pulled from PixelLab — pull an asset first.", true)
		return
	if save_tag_option.selected < 0:
		_set_status("Pick which tagged animation to save back.", true)
		return
	var source: Dictionary = project.get_meta("pixellab_source")
	var tag_name := save_tag_option.get_item_text(save_tag_option.selected)
	var map: Dictionary = source.get("map", {})
	var target: String = str(map.get(tag_name, ""))
	if target.is_empty():
		_set_status("Tag '%s' has no cloud target (was it added after the pull?)" % tag_name, true)
		return
	var tag = null
	for t in project.animation_tags:
		if t.name == tag_name:
			tag = t
			break
	if tag == null:
		_set_status("Tag '%s' vanished from the timeline." % tag_name, true)
		return
	_set_busy(true)
	var jobs: Array = []
	if target.begins_with("rotations:"):
		var plan: Dictionary = await _rotations_jobs_for(project, source)
		if not plan.ok:
			_set_busy(false)
			_set_status("Rotations cannot be saved back: %s" % plan.error, true)
			return
		jobs = plan.jobs
	else:
		jobs = [{"tag_name": tag_name, "target": target,
				"from": tag.from, "to": tag.to, "frame_count": tag.to - tag.from + 1}]
	Export.cache_blended_frames(project)
	var out: Dictionary = await _push_jobs(jobs)
	if not out.undo_entries.is_empty():
		# One snapshot slot: the LAST save wins.
		project.set_meta("pixellab_undo", {"entries": out.undo_entries})
	_set_busy(false)
	_refresh_save_tags()
	if out.failed.is_empty():
		_set_status("Saved %d/%d push(es) back to %s — cloud pixels changed: %d%s" %
				[out.saved, jobs.size(), source.get("name", "asset"), out.changed,
				". Undo is available." if not out.undo_entries.is_empty() else ""])
	else:
		_set_status("Saved %d/%d back to %s. FAILED: %s" %
				[out.saved, jobs.size(), source.get("name", "asset"), "; ".join(out.failed)], true)


## Save the WHOLE edited asset back: one /save-to-asset call per tagged
## animation (the same write the PixelLab web editor performs), plus one call
## per rotation direction when the project carries the rotations tag. A failing
## tag never blocks the others; frame-count drift is caught BEFORE anything is
## pushed by pre-checking against a fresh asset detail, and rotation order
## drift against the pull-time directions.
func _on_save_all_pressed() -> void:
	if _busy:
		return
	var project := Global.current_project
	if project == null:
		return
	if not project.has_meta("pixellab_source"):
		_set_status("This project was not pulled from PixelLab — pull an asset first.", true)
		return
	var source: Dictionary = project.get_meta("pixellab_source")
	var map: Dictionary = source.get("map", {})
	var jobs: Array = Util.collect_save_jobs(project.animation_tags, map)
	var want_rotations := Util.has_mapped_rotations(project.animation_tags, map)
	if jobs.is_empty() and not want_rotations:
		_set_status("No tagged animation has a cloud target — pull the asset again to rebuild the mapping.", true)
		return
	_set_busy(true)
	var asset_id := str(source.get("id", ""))
	var category := str(source.get("source", "characters"))
	# ONE fresh detail serves both the animation count-check and the rotation
	# canvas (sheet cells are the export's largest frame; rotation canvases can
	# be smaller — the push crops, verified live against a real 128x128 asset).
	var has_animations := not Util.collect_save_jobs(project.animation_tags, map).is_empty()
	var detail: Dictionary = {"ok": false}
	if has_animations or want_rotations:
		_set_status("Checking against PixelLab...")
		if category == "characters":
			detail = await api.get_character_detail(self, asset_id)
		else:
			detail = await api.get_object_detail(self, asset_id)
	# Rotations plan (fresh layout + order drift check). A planning failure
	# fails ONLY the rotations tag — the rest still saves.
	var rotations_error := ""
	if want_rotations:
		var canvas: Dictionary = detail.json.get("size", {}) \
				if detail.ok and detail.json is Dictionary else {}
		var plan: Dictionary = await _rotations_jobs_for(project, source, canvas)
		if plan.ok:
			jobs.append_array(plan.jobs)
		else:
			rotations_error = plan.error
	if has_animations and detail.ok and detail.json is Dictionary:
		var mismatches: Array = Util.count_mismatches(jobs, detail.json)
		if not mismatches.is_empty():
			var parts := []
			for m in mismatches:
				parts.append("%s: cloud has %d frames, project has %d" %
						[m["tag_name"], m["expected"], m["actual"]])
			_set_busy(false)
			_set_status("Nothing was pushed — frame counts changed since the pull: %s. Match the counts and try again (pad or crop with transparent frames, never rescale)." %
					"; ".join(parts), true)
			return
	_set_status("Rendering frames...")
	Export.cache_blended_frames(project)
	var out: Dictionary = await _push_jobs(jobs)
	if not rotations_error.is_empty():
		out["failed"].append("rotations: %s" % rotations_error)
	if not out.undo_entries.is_empty():
		# One snapshot slot: the last batch wins (same rule as single saves).
		project.set_meta("pixellab_undo", {"entries": out.undo_entries})
	_set_busy(false)
	_refresh_save_tags()
	var summary := ("Saved %d/%d push(es) back to %s — cloud pixels changed: %d"
			% [out.saved, jobs.size(), source.get("name", "asset"), out.changed])
	if out.failed.is_empty():
		_set_status(summary + (". Undo is available." if not out.undo_entries.is_empty() else ""))
	else:
		_set_status(summary + ". FAILED: " + "; ".join(out.failed), true)


## Undo the last save-back (single tag or whole batch): the saved responses
## carried the frames they replaced; pushing them back restores the cloud
## asset byte-for-byte. The snapshot survives until the undo fully succeeds.
func _on_undo_pressed() -> void:
	if _busy:
		return
	var project := Global.current_project
	if project == null or not project.has_meta("pixellab_undo"):
		_set_status("Nothing to undo — no save-back has happened in this session.", true)
		return
	var entries: Array = project.get_meta("pixellab_undo").get("entries", [])
	_set_busy(true)
	var restored := 0
	var failed: Array = []
	for entry in entries:
		_set_status("Restoring %s (%d/%d)..." %
				[str(entry["target"]), restored + failed.size() + 1, entries.size()])
		# Entries carry how they were pushed: rotation targets took a single
		# image, animation directions took a frames array. Old v1.2 snapshots
		# have no mode and default to frames.
		var mode := str(entry.get("mode", "frames"))
		var res: Dictionary
		if mode == "image" and not entry["frames"].is_empty():
			res = await api.save_to_asset(self, str(entry["target"]), [],
					entry["frames"][0])
		else:
			res = await api.save_to_asset(self, str(entry["target"]), entry["frames"])
		if res.ok:
			restored += 1
		else:
			failed.append("%s: %s" % [entry["target"], res.error])
	_set_busy(false)
	if failed.is_empty():
		project.remove_meta("pixellab_undo")
		_refresh_save_tags()
		_set_status("Undone — %d target(s) restored to their previous pixels." % restored)
	else:
		_set_status("Undo partly failed (%d/%d restored — snapshot kept, try again): %s" %
				[restored, entries.size(), "; ".join(failed)], true)


## Publish the selected tag (or the whole project if no tag applies) to the
## PixelLab gallery as an animated GIF — the way to keep a FULL edited
## animation in the cloud when no origin asset exists. Free, pixel-exact.
func _on_publish_gif_pressed() -> void:
	if _busy:
		return
	var project := Global.current_project
	if project == null or project.is_empty():
		_set_status("No project open.", true)
		return
	_set_busy(true)
	_set_status("Rendering frames for GIF...")
	Export.cache_blended_frames(project)
	var images: Array = []
	var tag_name := "all frames"
	if save_tag_option.selected >= 0:
		var chosen := save_tag_option.get_item_text(save_tag_option.selected)
		for t in project.animation_tags:
			if t.name == chosen:
				for i in range(t.from - 1, t.to):
					images.append(Export.blended_frames.get(project.frames[i]))
				tag_name = t.name
				break
	if images.is_empty():
		for frame in project.frames:
			images.append(Export.blended_frames.get(frame))
	for img in images:
		if img == null:
			_set_busy(false)
			_set_status("Frame rendering failed.", true)
			return
	var exporter := GIFExporter.new(images[0].get_width(), images[0].get_height())
	for img in images:
		var rgba: Image = img.duplicate()
		if rgba.get_format() != Image.FORMAT_RGBA8:
			rgba.convert(Image.FORMAT_RGBA8)
		exporter.add_frame(rgba, 1.0 / maxf(project.fps, 1.0), MedianCutQuantization)
	var gif := exporter.export_file_data()
	var pub_name := "%s (%s)" % [project.name, tag_name]
	if pub_name.length() > 120:
		pub_name = pub_name.substr(0, 120)
	_set_status("Publishing to your PixelLab gallery...")
	var res = await api.save_to_asset(self, "gallery:new", [], gif, "gif", pub_name)
	_set_busy(false)
	if not res.ok:
		_set_status("Publish failed: %s" % res.error, true)
		return
	var body: Dictionary = res.json if res.json is Dictionary else {}
	_set_status("Published to your gallery as %s — view it on pixellab.ai (Creator gallery)." %
			str(body.get("target", "?")))


func _on_upload_pressed() -> void:
	if _busy:
		return
	var project := Global.current_project
	if project == null or project.is_empty():
		_set_status("No project open.", true)
		return
	_set_busy(true)
	_set_status("Flattening current frame...")
	Export.cache_blended_frames(project)
	var frame := project.frames[project.current_frame]
	var image: Image = Export.blended_frames.get(frame)
	if image == null:
		_set_busy(false)
		_set_status("Flattening failed.", true)
		return
	if image.get_width() > MAX_UPLOAD_SIZE or image.get_height() > MAX_UPLOAD_SIZE:
		_set_busy(false)
		_set_status("Frame is %dx%d — PixelLab accepts objects up to %dx%d. Scale it down first." %
				[image.get_width(), image.get_height(), MAX_UPLOAD_SIZE, MAX_UPLOAD_SIZE], true)
		return
	var png := image.save_png_to_buffer()
	if png.is_empty():
		_set_busy(false)
		_set_status("PNG encoding failed.", true)
		return
	_set_status("Uploading to your PixelLab library...")
	var res = await api.import_object(self, png, project.name)
	_set_busy(false)
	if not res.ok:
		_set_status("Upload failed: %s" % res.error, true)
		return
	var object_id: String = str(res.json.get("object_id", "?")) if res.json is Dictionary else "?"
	_set_status("Uploaded! Object id: %s (check your library on pixellab.ai)." % object_id)


## Centre-crops a PNG to the given {width, height} canvas when they differ.
## Sheet cells are sized to the export's largest frame, while rotation
## canvases can be smaller with the content centred inside the cell — the
## server explicitly asks for pad-or-crop, never rescale. Verified live:
## cropped cells wrote 0 changed pixels against real 128x128 targets.
func _crop_to_canvas(png: PackedByteArray, canvas: Dictionary) -> PackedByteArray:
	if canvas.is_empty() or not (canvas.has("width") and canvas.has("height")):
		return png
	var img := Image.new()
	if img.load_png_from_buffer(png) != OK:
		return png
	var cw := int(canvas["width"])
	var ch := int(canvas["height"])
	if cw <= 0 or ch <= 0 or (img.get_width() == cw and img.get_height() == ch):
		return png
	if img.get_width() < cw or img.get_height() < ch:
		return png  # smaller than target — cannot crop, let the server judge
	@warning_ignore("integer_division")
	var x := (img.get_width() - cw) / 2
	@warning_ignore("integer_division")
	var y := (img.get_height() - ch) / 2
	return img.get_region(Rect2i(x, y, cw, ch)).save_png_to_buffer()

## Called by Pixelorama when the user clicks the Project-menu entry this
## extension registered (menu metadata convention — see ExtensionsApi).
func menu_item_clicked() -> void:
	popup()
