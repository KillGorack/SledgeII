class_name CreativeApi

# Calls to the site's game endpoint (alacarte\game\gameAPI) for publishing
# Creative levels: publishLevel, getMyLevels, deleteLevel. Needs a logged in
# player; the server takes the owner from the login, never from anything sent.
#
# var result := await CreativeApi.request(self, "getMyLevels")
# result = {ok, code, message, body}. `message` is always something a player
# can be shown.

const TIMEOUT_SECONDS := 30.0

# The site's tan_genre options (kept with the level data, which must not depend on this file's login globals).
const GENRES := CreativeLevel.GENRES


static func logged_in() -> bool:
	return UserData.user_id > 0 and not UserData.user_key.is_empty()


static func request(host: Node, function_name: String, fields: Dictionary = {}) -> Dictionary:
	if not logged_in():
		return _failure(0, "Log in to publish levels.")
	var post_data := {
		"user_id": UserData.user_id,
		"username": UserData.username,
		"user_key": UserData.user_key,
		"freshness": UserData.freshness,
		"function": function_name,
		"formidentifier": "alacarte\\game\\gameAPI",
	}
	post_data.merge(fields, true)
	var api_params := {
		"ap": "game",
		"cn": "hme",
		"apikeyid": Creds.apiID,
		"api": "json",
		"vc": Creds.apiKEY,
	}
	var http := HTTPRequest.new()
	http.timeout = TIMEOUT_SECONDS
	host.add_child(http)
	var error := http.request(
		NetworkManager.API_URL + "?" + Utilities.encode_dict_string(api_params),
		["Content-Type: application/x-www-form-urlencoded"],
		HTTPClient.METHOD_POST,
		Utilities.encode_dict_string(post_data))
	if error != OK:
		http.queue_free()
		return _failure(0, "Could not reach the server.")
	var response: Array = await http.request_completed
	http.queue_free()
	var code: int = response[1]
	var parsed: Variant = JSON.parse_string((response[3] as PackedByteArray).get_string_from_utf8())
	var body: Dictionary = parsed if parsed is Dictionary else {}
	if code == 0 or (code != 200 and body.is_empty()):
		return _failure(code, "Could not reach the server." if code == 0 else "The server returned error %d." % code)
	var ok: bool = code == 200 and body.get("status", "") == "success"
	return {
		"ok": ok,
		"code": code,
		"message": str(body.get("message", "Done." if ok else "The server refused that.")),
		"body": body,
	}


static func _failure(code: int, message: String) -> Dictionary:
	return {"ok": false, "code": code, "message": message, "body": {}}
