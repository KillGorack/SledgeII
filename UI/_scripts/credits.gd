class_name Credits

# The text of the Credits screen and the engine's licence text. Kept in a script (not a text file) so it is packaged
# with the game. Add attributions here as they are confirmed.
#
# Not listed yet: the authors of the original maps. Those maps are hidden from the public list, so their credits wait
# until they are shown. The 58 author names (from the pipeline's records, odd capitalisations merged, "unknown" left
# out) are in /home/dave/Documents/Pipeline/out/map_authors.txt.

# The third-party art, sound and music, one row each: what it is, who made it and where from, its license. A link
# (opened by the Credits screen's meta_clicked handler in index.gd) makes the "who" cell clickable. Add a row here
# whenever something with a license that asks for credit goes into the game.
const ASSETS := [
	{"what": "Base ambience: \"4 Atmospheric / Ghostly Loops\"", "who": "OpenGameArt.org", "license": "CC0", "url": "https://opengameart.org/content/4-atmospheric-ghostly-loops"},
	{"what": "Sound effects (edited)", "who": "Freesound.org: mrspivey, Julien_Matthey, SieuAmThanh, tradeachest, Jarusca, C-V, Anomaex, GameAudio", "license": "CC0"},
	{"what": "Rocket launch (edited)", "who": "Jarusca, Freesound.org", "license": "CC0", "url": "https://freesound.org/people/Jarusca/sounds/521377/"},
	{"what": "Plasma shot (edited)", "who": "@listener4me, OpenGameArt.org", "license": "CC0", "url": "https://opengameart.org/content/sound-effects-for-platformer"},
	{"what": "Cannon shot (edited)", "who": "qubodup, Freesound.org", "license": "CC0", "url": "https://freesound.org/people/qubodup/sounds/187767/"},
	{"what": "Impact sounds", "who": "natlapse, OpenGameArt.org", "license": "CC0", "url": "https://opengameart.org/content/ingame-samples-audio"},
	{"what": "Tornado wind: \"Blowind Wind\" (edited to loop)", "who": "Roloxi, Freesound.org", "license": "CC BY 4.0", "url": "https://freesound.org/people/roloxi/sounds/666847"},
	{"what": "Engine hum: \"SpaceShip_Engine_Large_Loop_00\" (edited to loop)", "who": "LittleRobotSoundFactory, Freesound.org", "license": "CC BY 4.0", "url": "https://freesound.org/people/LittleRobotSoundFactory/sounds/270539"},
	{"what": "Menu music: \"Break The Line\" (Uppbeat license code HYHE2XELUFQRVHCC)", "who": "Abbynoise, Uppbeat", "license": "Uppbeat free license", "url": "https://uppbeat.io/c/abbynoise"},
	{"what": "Freeze powerup icon: \"Snow vector weather icon\" (made into a 3D medallion)", "who": "publicdomainvectors.org", "license": "Public Domain", "url": "https://publicdomainvectors.org/en/free-clipart/Snow-vector-weather-icon/1030.html"},
	{"what": "Haste powerup icon: \"Curly wing\" (made into a 3D medallion)", "who": "Lorc, game-icons.net", "license": "CC BY 3.0", "url": "https://game-icons.net/1x1/lorc/curly-wing.html"},
]

const ENGINE := [
	{"what": "Godot Engine", "license": "MIT license", "url": "https://godotengine.org"},
	{"what": "Jolt Physics", "license": "MIT license", "url": "https://github.com/jrouwe/JoltPhysics"},
]

const HEADER_BG := "#ffffff1c"
const TITLE_SIZE := 30
const SECTION_SIZE := 20


static func text() -> String:
	var version := str(ProjectSettings.get_setting("application/config/version", ""))
	var out: Array[String] = []
	out.append("[font_size=%d][b]Sledge 2[/b][/font_size]%s" % [TITLE_SIZE, ("   [color=#9aa]v" + version + "[/color]") if version != "" else ""])
	out.append("Made by [b]KillGorack[/b]")
	out.append("")
	out.append(_section("Community levels"))
	out.append("The levels in the Create Game list are built by players with the in-game editor. Each level's author is shown with it.")
	out.append("")
	out.append(_section("Engine and code"))
	var engine_rows: Array = [["Made with", "License"]]
	for item in ENGINE:
		engine_rows.append([_link(item.what, item.get("url", "")), item.license])
	out.append(_table(engine_rows, [3, 2]))
	out.append("The full license texts are under [b]Licenses[/b].")
	out.append("")
	out.append(_section("Art, sound and music"))
	var asset_rows: Array = [["What", "Made by", "License"]]
	for item in ASSETS:
		asset_rows.append([item.what, _link(item.who, item.get("url", "")), item.license])
	out.append(_table(asset_rows, [5, 4, 1.5]))
	out.append("Thank you to everyone who made and shared the textures, sounds and models this game uses.")
	out.append("")
	out.append(_section("Thanks"))
	out.append("To everyone who tests it and tells me what is broken.")
	return "\n".join(out)


static func _section(title: String) -> String:
	return "[font_size=%d][b]%s[/b][/font_size]" % [SECTION_SIZE, title]


static func _link(label: String, url: String) -> String:
	return "[url=%s]%s[/url]" % [url, label] if url != "" else label


# A BBCode table. The first row is the header; `ratios` sets each column's share of the width.
static func _table(rows: Array, ratios: Array) -> String:
	var out := "[table=%d]" % ratios.size()
	for r in rows.size():
		for c in ratios.size():
			var background := (" bg=" + HEADER_BG) if r == 0 else ""
			var cell: String = str(rows[r][c])
			if r == 0:
				cell = "[b]" + cell + "[/b]"
			out += "[cell ratio=%s padding=6,4,14,4%s]%s[/cell]" % [ratios[c], background, cell]
	return out + "[/table]"


# Godot's own licence, the licences of the third-party code inside it, and who holds the copyright on each part.
# This is the notice the MIT licence asks a game to carry.
static func licenses_text() -> String:
	var out: Array[String] = []
	out.append("GODOT ENGINE\n")
	out.append(Engine.get_license_text())
	out.append("\n\nTHIRD-PARTY COMPONENTS\n")
	for component in Engine.get_copyright_info():
		out.append("\n%s" % component.get("name", ""))
		for part in component.get("parts", []):
			var copyrights: PackedStringArray = part.get("copyright", PackedStringArray())
			out.append("   %s  (%s)" % ["; ".join(copyrights), part.get("license", "")])
	out.append("\n\nLICENSE TEXTS\n")
	var texts: Dictionary = Engine.get_license_info()
	for license_name in texts:
		out.append("\n--- %s ---\n%s" % [license_name, texts[license_name]])
	return "\n".join(out)
