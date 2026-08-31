extends Node

var emit_id: int
var user_id: int
var username: String
var email: String
var enabled: bool
var user_key: String
var freshness: String


func _ready() -> void:
	pass

func _process(_delta: float) -> void:
	pass


func populate_user_data(data: Dictionary):
	user_id = data.get("ID", 0)
	username = data.get("usr_login", "")
	email = data.get("usr_email", "")
	enabled = data.get("usr_enable", 0) == 1
	user_key = data.get("usr_key", "")
	freshness = data.get("usr_freshness", "")
