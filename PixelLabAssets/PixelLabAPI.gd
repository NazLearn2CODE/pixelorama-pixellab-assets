extends RefCounted
## Thin HTTP client for the pixellab.ai v2 REST API.
## Evidence: A-project/api-reference.md + artifacts/evidence/pixellab-openapi-v2.json
## All endpoints used here are free (lists, exports, imports) — never generation.

var base_url := "https://api.pixellab.ai/v2"
const DEFAULT_BASE_URL := "https://api.pixellab.ai/v2"
const TIMEOUT_SECONDS := 30.0

var secret_key := ""


func _headers(extra: PackedStringArray = PackedStringArray(), with_auth := true) -> PackedStringArray:
	var headers := PackedStringArray(extra)
	if with_auth and not secret_key.is_empty():
		headers.append("Authorization: Bearer " + secret_key)
	return headers


## One awaited HTTP round trip. Returns a Dictionary:
## {ok: bool, status: int, json: Variant, bytes: PackedByteArray, error: String}
## Absolute URLs are fetched as-is; relative paths get base_url prepended.
## with_auth=false MUST be used for non-API hosts (never send the key to a CDN).
func _do_request(
	parent: Node, method: HTTPClient.Method, path: String,
	extra_headers := PackedStringArray(), body := PackedByteArray(), with_auth := true
) -> Dictionary:
	var url := path if path.begins_with("http") else base_url + path
	var http := HTTPRequest.new()
	http.timeout = TIMEOUT_SECONDS
	parent.add_child(http)
	var err := http.request_raw(url, _headers(extra_headers, with_auth), method, body)
	if err != OK:
		http.queue_free()
		return {"ok": false, "status": 0, "json": null, "bytes": PackedByteArray(),
				"error": "HTTPRequest start failed (%d)" % err}
	var result: Array = await http.request_completed
	var curl_result: int = result[0]
	var status: int = result[1]
	var resp_headers: PackedStringArray = result[2]
	var resp_body: PackedByteArray = result[3]
	http.queue_free()
	if curl_result != HTTPRequest.RESULT_SUCCESS:
		return {"ok": false, "status": status, "json": null, "bytes": PackedByteArray(),
				"error": "Transfer failed (code %d)" % curl_result}
	var content_type := ""
	for h in resp_headers:
		if h.begins_with("Content-Type:"):
			content_type = h.get_slice(":", 1).strip_edges()
	var json: Variant = null
	if content_type.begins_with("application/json"):
		json = JSON.parse_string(resp_body.get_string_from_utf8())
	var ok := status >= 200 and status < 300
	var error := ""
	if not ok:
		error = _extract_error(json, status)
	return {"ok": ok, "status": status, "json": json, "bytes": resp_body, "error": error}


func _extract_error(json: Variant, status: int) -> String:
	if json is Dictionary:
		if json.has("detail"):
			var detail: Variant = json["detail"]
			# FastAPI validation errors put an ARRAY under detail.
			if detail is Array:
				var parts := []
				for part in detail:
					parts.append(str(part.get("msg", part)) if part is Dictionary else str(part))
				return "; ".join(parts)
			return str(detail)
		if json.has("message"):
			return str(json["message"])
	return "HTTP %d" % status


## category: "characters" | "objects" (more later: tilesets, ui-assets...)
func list_assets(
	parent: Node, category: String, limit := 50, offset := 0
) -> Dictionary:
	var res := await _do_request(parent, HTTPClient.METHOD_GET,
			"/%s?limit=%d&offset=%d" % [category, limit, offset])
	if not res.ok:
		return res
	var items: Array = res.json.get(category, []) if res.json is Dictionary else []
	return {
		"ok": true, "status": res.status, "error": "",
		"items": items, "total": res.json.get("total", items.size()) if res.json is Dictionary else items.size(),
	}


## Downloads the spritesheet for one asset and returns the PNG bytes plus the
## parsed layout JSON ("layout"; {} when the answer is a bare PNG or carries
## no readable JSON). The layout is what orders rotation directions for
## save-back planning (PixelLabUtil.rotations_plan).
## Evidence (pixellab-sdk-report.md + live probes): the export endpoint answers
## application/zip containing "<name>.png" + "<name>.json" layout; a 1-direction
## object may answer a bare PNG; HTTP 423 means still generating.
func download_spritesheet(parent: Node, category: String, id: String) -> Dictionary:
	var res := await _do_request(parent, HTTPClient.METHOD_GET,
			"/%s/%s/spritesheet" % [category, id])
	if not res.ok:
		return res
	var bytes: PackedByteArray = res.bytes
	# Case 1: bare PNG (1-direction object edge case)
	if bytes.size() > 8 and bytes[0] == 0x89 and bytes[1] == 0x50:
		return {"ok": true, "status": res.status, "error": "", "png": bytes,
				"layout": {}}
	# Case 2: ZIP — extract the first PNG inside (primary documented shape)
	if bytes.size() > 4 and bytes[0] == 0x50 and bytes[1] == 0x4B:
		var zip_path := "user://pixellab_tmp_spritesheet.zip"
		var file := FileAccess.open(zip_path, FileAccess.WRITE)
		if file == null:
			return {"ok": false, "status": res.status, "error": "Could not buffer spritesheet zip",
					"png": PackedByteArray(), "layout": {}}
		file.store_buffer(bytes)
		file.close()
		var zip := ZIPReader.new()
		var err := zip.open(zip_path)
		if err != OK:
			DirAccess.remove_absolute(ProjectSettings.globalize_path(zip_path))
			return {"ok": false, "status": res.status,
					"error": "Spritesheet zip unreadable (err %d)" % err, "png": PackedByteArray(),
					"layout": {}}
		var png_bytes := PackedByteArray()
		var layout: Dictionary = {}
		for member in zip.get_files():
			var lower := member.to_lower()
			if lower.ends_with(".png") and png_bytes.is_empty():
				png_bytes = zip.read_file(member)
			elif lower.ends_with(".json"):
				var parsed: Variant = JSON.parse_string(
						zip.read_file(member).get_string_from_utf8())
				if parsed is Dictionary:
					layout = parsed
		zip.close()
		DirAccess.remove_absolute(ProjectSettings.globalize_path(zip_path))
		if png_bytes.is_empty():
			return {"ok": false, "status": res.status,
					"error": "Spritesheet zip contains no PNG", "png": PackedByteArray(),
					"layout": {}}
		return {"ok": true, "status": res.status, "error": "", "png": png_bytes,
				"layout": layout}
	return {"ok": false, "status": res.status,
			"error": "Unrecognized spritesheet response (not zip/png)", "png": PackedByteArray(),
			"layout": {}}


## Fetches a public asset URL (e.g. preview_url on a CDN). No auth header —
## the secret key must never leave the API host.
func fetch_preview(parent: Node, url: String) -> PackedByteArray:
	var res := await _do_request(parent, HTTPClient.METHOD_GET, url,
			PackedStringArray(), PackedByteArray(), false)
	if not res.ok:
		return PackedByteArray()
	return res.bytes


## Downloads the tagged Aseprite file for one asset (characters and objects).
## Evidence: spec says application/octet-stream, single .ase; AUTH required.
## PixelLab aseprite tags: "rotations" + "<animation_type>-<direction>".
func download_aseprite(parent: Node, category: String, id: String) -> Dictionary:
	var res := await _do_request(parent, HTTPClient.METHOD_GET,
			"/%s/%s/aseprite" % [category, id])
	if not res.ok:
		return res
	var bytes: PackedByteArray = res.bytes
	# .aseprite header: u32 file size first, then u16 magic 0xA5E0 (LE -> E0 A5)
	if bytes.size() > 148 and bytes[4] == 0xE0 and bytes[5] == 0xA5:
		return {"ok": true, "status": res.status, "error": "", "ase": bytes}
	return {"ok": false, "status": res.status,
			"error": "Response is not an Aseprite file", "ase": PackedByteArray()}


## Full asset detail — used for the tag->save-target mapping (animations[]).
## Works for both categories: GET /characters/{id} and GET /objects/{id}.
func get_character_detail(parent: Node, id: String) -> Dictionary:
	return await _do_request(parent, HTTPClient.METHOD_GET, "/characters/%s" % id)


func get_object_detail(parent: Node, id: String) -> Dictionary:
	return await _do_request(parent, HTTPClient.METHOD_GET, "/objects/%s" % id)


## Pushes edited frames/images back INTO an existing cloud asset.
## target: "character:<id>:<direction>:<group_id>" (animation direction),
## "character:<id>:<direction>" (rotation), "object:<id>[:<direction>]",
## "gallery:new" (add a gallery image; set name/description), "tileset:<id>".
## Give frames (animation, <=128 same-size PNGs) XOR image (PNG, or an
## animated GIF via image_format="gif" — the gallery accepts both).
## Evidence: spec SaveToAssetRequest (additionalProperties: false) — only
## target/image/frames/description/name keys are legal, name+description are
## gallery:new-only, so they are sent only when non-empty.
func save_to_asset(parent: Node, target: String, frames := [], image := PackedByteArray(),
		image_format := "png", name := "", description := "") -> Dictionary:
	var payload := {"target": target}
	if not frames.is_empty():
		var encoded: Array = []
		for png in frames:
			encoded.append({"type": "base64", "base64": Marshalls.raw_to_base64(png),
					"format": "png"})
		payload["frames"] = encoded
	elif not image.is_empty():
		payload["image"] = {"type": "base64", "base64": Marshalls.raw_to_base64(image),
				"format": image_format}
	if not name.is_empty():
		payload["name"] = name
	if not description.is_empty():
		payload["description"] = description
	var body := PackedByteArray()
	body.append_array(JSON.stringify(payload).to_utf8_buffer())
	return await _do_request(parent, HTTPClient.METHOD_POST, "/save-to-asset",
			PackedStringArray(["Content-Type: application/json"]), body)


## Pushes an edited PNG into the user's library as an object.
## Spec constraint: image at most 256x256, stored exactly as sent, PNG only.
func import_object(parent: Node, png_bytes: PackedByteArray, name: String) -> Dictionary:
	var payload := {
		"image": {
			"type": "base64",
			"base64": Marshalls.raw_to_base64(png_bytes),
			"format": "png",
		},
		"name": name,
	}
	var body := PackedByteArray()
	body.append_array(JSON.stringify(payload).to_utf8_buffer())
	return await _do_request(parent, HTTPClient.METHOD_POST, "/objects/import",
			PackedStringArray(["Content-Type: application/json"]), body)


func get_balance(parent: Node) -> Dictionary:
	return await _do_request(parent, HTTPClient.METHOD_GET, "/balance")
