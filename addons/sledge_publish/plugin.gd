@tool
extends EditorPlugin

# Project > Tools > "Publish Sledge 2 ...". Runs ~/Documents/Pipeline/publish_sledge.py
# (export both builds, zip them, replace the Linux/Windows builds on Portal-X) and
# prints its output in the editor's Output panel. The real runs ask first.
#
# The script exports through a second headless Godot process, so a run takes a
# minute or two; it runs on a thread, so the editor stays usable meanwhile.

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
	add_tool_menu_item("Publish Sledge 2: dry run (local site)", _start.bind(PackedStringArray(["--profile", "local"])))
	add_tool_menu_item("Publish Sledge 2: to LOCAL site...", _ask.bind(PackedStringArray(["--profile", "local", "--go"]),
		"Export both builds, upload them, and DELETE every other file on the LOCAL site's record?"))
	add_tool_menu_item("Publish Sledge 2: to LIVE site...", _ask.bind(PackedStringArray(["--profile", "live", "--go"]),
		"Export both builds, upload them, and DELETE every other file on the LIVE site's record (killgorack.com)?\n\nThere is no backup."))


func _exit_tree() -> void:
	remove_tool_menu_item("Publish Sledge 2: dry run (local site)")
	remove_tool_menu_item("Publish Sledge 2: to LOCAL site...")
	remove_tool_menu_item("Publish Sledge 2: to LIVE site...")
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
