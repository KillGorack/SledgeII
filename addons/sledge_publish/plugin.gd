@tool
extends EditorPlugin

# Project > Tools > "Publish Sledge 2 ...". Runs ~/Documents/Pipeline/publish_sledge.py
# (export both builds, zip them, replace the Linux/Windows builds on Portal-X) and
# prints its output in the editor's Output panel. The real runs ask first.
#
# The script exports through a second headless Godot process, so a run takes a
# minute or two; it runs on a thread, so the editor stays usable meanwhile.

# Brings back the dry-run, local-site and zip-only entries (see _extra_items).
const SHOW_EXTRA_ITEMS := false
const SCRIPT_REL := "Documents/Pipeline/publish_sledge.py"

var _confirm: ConfirmationDialog
var _done: AcceptDialog
var _pending_args: PackedStringArray = []
var _thread: Thread
var _busy: bool = false


func _enter_tree() -> void:
	_confirm = ConfirmationDialog.new()
	_confirm.confirmed.connect(_on_confirmed)
	EditorInterface.get_base_control().add_child(_confirm)
	# The two real publishes. Both export fresh first.
	add_tool_menu_item("Publish Sledge 2 to itch...", _ask.bind(PackedStringArray(["--itch-push"]),
		"Export both builds and push them to killgorack.itch.io/sledge (linux and windows channels) with butler?"))
	add_tool_menu_item("Publish Sledge 2 to LIVE site...", _ask.bind(PackedStringArray(["--profile", "live", "--go"]),
		"Export both builds, upload them, and DELETE every other file of the Sledge downloads part on the LIVE site (killgorack.com)?\n\nThere is no backup."))
	if SHOW_EXTRA_ITEMS:
		for item in _extra_items():
			add_tool_menu_item(item[0], item[1])


# The dry runs, the local-site copies and the zip-only pack: still here, just not in the menu.
# Set SHOW_EXTRA_ITEMS to true to bring them back.
func _extra_items() -> Array:
	return [
		["Publish Sledge 2 to itch: dry run", _start.bind(PackedStringArray(["--itch-push", "--dry-run"]))],
		["Pack Sledge 2 for itch (export + zip)", _start.bind(PackedStringArray(["--itch"]))],
		["Publish Sledge 2: dry run (local site)", _start.bind(PackedStringArray(["--profile", "local"]))],
		["Publish Sledge 2: to LOCAL site...", _ask.bind(PackedStringArray(["--profile", "local", "--go"]),
			"Export both builds, upload them, and DELETE every other file of the Sledge downloads part on the LOCAL site?")],
	]


func _exit_tree() -> void:
	remove_tool_menu_item("Publish Sledge 2 to itch...")
	remove_tool_menu_item("Publish Sledge 2 to LIVE site...")
	if SHOW_EXTRA_ITEMS:
		for item in _extra_items():
			remove_tool_menu_item(item[0])
	if _thread and _thread.is_started():
		_thread.wait_to_finish()
	if _confirm:
		_confirm.queue_free()
	if _done:
		_done.queue_free()


func _ask(args: PackedStringArray, question: String) -> void:
	_pending_args = args
	_confirm.dialog_text = question
	_confirm.popup_centered()


func _on_confirmed() -> void:
	_start(_pending_args)


func _start(args: PackedStringArray) -> void:
	if _busy:
		push_warning("Sledge publish: a run is already in progress.")
		return
	var script_path := OS.get_environment("HOME").path_join(SCRIPT_REL)
	if not FileAccess.file_exists(script_path):
		push_error("Sledge publish: %s not found." % script_path)
		return
	# The export reads the files on disk, so save what's open first.
	EditorInterface.save_all_scenes()
	var full_args := PackedStringArray([script_path, "--project", ProjectSettings.globalize_path("res://")])
	full_args.append_array(args)
	print("Sledge publish: python3 %s" % " ".join(full_args.slice(1)))
	print("Sledge publish: running - this takes a minute or two...")
	_busy = true
	_thread = Thread.new()
	_thread.start(_run.bind(full_args))


func _run(args: PackedStringArray) -> void:
	var output: Array = []
	var code := OS.execute("python3", args, output, true)
	_finished.call_deferred(code, "".join(output))


# Made on first use rather than in _enter_tree: the editor hot-reloads this script when it
# changes on disk without running _enter_tree again, which left this null.
func _done_dialog() -> AcceptDialog:
	if _done == null:
		_done = AcceptDialog.new()
		_done.title = "Sledge publish"
		EditorInterface.get_base_control().add_child(_done)
	return _done


func _finished(code: int, text: String) -> void:
	_thread.wait_to_finish()
	_busy = false
	for line in text.split("\n"):
		print("  " + line)
	# The script's last "FINISHED" line is the summary; show it in a popup too, since
	# the Output panel is easy to miss.
	var summary := ""
	for line in text.split("\n"):
		if line.begins_with("FINISHED"):
			summary = line
	if code == 0:
		print("Sledge publish: finished.")
		_done_dialog().dialog_text = summary if summary != "" else "Finished."
	else:
		# The tail of the script's output is the reason, so it goes in the error and the popup itself.
		var tail := text.strip_edges()
		if tail.length() > 700:
			tail = "..." + tail.substr(tail.length() - 700)
		if tail == "":
			tail = "(the script printed nothing - is python3 installed and on the editor's PATH?)"
		push_error("Sledge publish: failed (exit code %d):\n%s" % [code, tail])
		_done_dialog().dialog_text = "FAILED (exit code %d).\n\n%s" % [code, tail]
	_done_dialog().popup_centered()
