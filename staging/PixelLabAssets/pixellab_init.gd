extends Node
## PixelLab Assets — extension bootstrap.
## Adds "PixelLab Assets" to the Project menu; the menu entry opens the
## PixelLab dialog. Removes itself cleanly when the extension is disabled.

const DIALOG_SCENE := preload("res://src/Extensions/PixelLabAssets/PixelLabDialog.tscn")

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


func _exit_tree() -> void:
	var api := get_node_or_null("/root/ExtensionsApi")
	if api != null and _menu_item_id >= 0:
		api.menu.remove_menu_item(api.menu.PROJECT, _menu_item_id)
