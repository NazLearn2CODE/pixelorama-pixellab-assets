extends Node
## PixelLab Assets — extension bootstrap.
## Adds "PixelLab Assets" to the Project menu; the menu entry opens the
## PixelLab dialog. Removes itself cleanly when the extension is disabled.
## Also keeps its own name out of Pixelorama's crash-suspicion list
## (user://extensions/Monitoring.ini): on Android a force-stop looks like a
## crash, and the next boot auto-disables any extension named in that file
## (or MOVES its .pck away when it is the only one listed) — so once the
## user enabled us, we must never sit in that file while we run.

const DIALOG_SCENE := preload("res://src/Extensions/PixelLabAssets/PixelLabDialog.tscn")
const MONITOR_PATH := "user://extensions/Monitoring.ini"

var _dialog: Node = null
var _menu_item_id := -1


func _ready() -> void:
	var api := get_node_or_null("/root/ExtensionsApi")
	if api == null:
		push_error("PixelLab Assets: ExtensionsApi not found")
		return
	_dialog = DIALOG_SCENE.instantiate()
	add_child(_dialog)
	_menu_item_id = api.menu.add_menu_item(api.menu.PROJECT,
			"PixelLab Assets", _dialog)
	# Enable-at-boot re-arms suspicion (HandleExtensions.enable_extension
	# re-adds our name right before instantiating us), so erase immediately,
	# then keep erasing every 30 s for the rest of the session.
	_clear_own_suspicion()
	var heal := Timer.new()
	heal.wait_time = 30.0
	heal.timeout.connect(_clear_own_suspicion)
	add_child(heal)
	heal.start()


func _exit_tree() -> void:
	var api := get_node_or_null("/root/ExtensionsApi")
	if api != null and _menu_item_id >= 0:
		api.menu.remove_menu_item(api.menu.PROJECT, _menu_item_id)


## Erase only OUR entry from the suspicion file (a single var_to_str'ed
## PackedStringArray of "<name>.pck" entries). Third-party entries are left
## untouched; the file is deleted when nothing else is listed. Same
## tablet-proven approach as the Touch Shortcuts panel.
func _clear_own_suspicion() -> void:
	if not FileAccess.file_exists(MONITOR_PATH):
		return
	var f := FileAccess.open(MONITOR_PATH, FileAccess.READ)
	if f == null:
		return
	var parsed: Variant = str_to_var(f.get_line())
	f.close()
	if typeof(parsed) != TYPE_PACKED_STRING_ARRAY:
		return
	var kept: PackedStringArray = PackedStringArray()
	var changed := false
	for entry: String in parsed:
		if String(entry).begins_with("PixelLabAssets"):
			changed = true
		else:
			kept.append(entry)
	if not changed:
		return
	if kept.is_empty():
		DirAccess.remove_absolute(MONITOR_PATH)
	else:
		var w := FileAccess.open(MONITOR_PATH, FileAccess.WRITE)
		if w != null:
			w.store_line(var_to_str(kept))
			w.close()
