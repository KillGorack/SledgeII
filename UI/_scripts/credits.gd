class_name Credits

# The text of the Credits screen and the engine's licence text. Kept in a script (not a text file) so it is packaged
# with the game. Add attributions here as they are confirmed.
#
# Not listed yet: the authors of the original maps. Those maps are hidden from the public list, so their credits wait
# until they are shown. The 58 author names (from the pipeline's records, odd capitalisations merged, "unknown" left
# out) are in /home/dave/Documents/Pipeline/out/map_authors.txt.

static func text() -> String:
	var version := str(ProjectSettings.get_setting("application/config/version", ""))
	var lines: Array[String] = [
		"[b]Sledge 2[/b]" + ("   v" + version if version != "" else ""),
		"",
		"[b]Made by[/b]",
		"KillGorack",
		"",
		"[b]Community levels[/b]",
		"The levels in the Create Game list are built by players with the in-game editor. Each level's author is shown with it.",
		"",
		"[b]Engine and code[/b]",
		"Made with the Godot Engine (MIT license), godotengine.org.",
		"Physics by Jolt Physics (MIT license).",
		"The full license texts are under [b]Licenses[/b].",
		"",
		"[b]Art, sound and music[/b]",
		"Base ambience: \"4 Atmospheric / Ghostly Loops\" from OpenGameArt.org (CC0), opengameart.org/content/4-atmospheric-ghostly-loops",
		"Sound effects (CC0, edited) from Freesound.org: mrspivey, Julien_Matthey, SieuAmThanh, tradeachest, Jarusca, C-V, Anomaex, GameAudio.",
		"Tornado wind: \"Blowind Wind\" by Roloxi, freesound.org/people/roloxi/sounds/666847, licensed CC BY 4.0 (creativecommons.org/licenses/by/4.0). Edited to loop.",
		"Engine hum: \"SpaceShip_Engine_Large_Loop_00\" by LittleRobotSoundFactory, freesound.org/people/LittleRobotSoundFactory/sounds/270539, licensed CC BY 4.0. Edited to loop.",
		"Boulders: \"Low Poly Rocks\" by para, OpenGameArt.org (CC0), opengameart.org/content/low-poly-rocks",
		"Impact sounds: natlapse, OpenGameArt.org (CC0), opengameart.org/content/ingame-samples-audio",
		"Haste powerup icon: \"Curly wing\" by Lorc, game-icons.net/1x1/lorc/curly-wing.html, licensed CC BY 3.0 (creativecommons.org/licenses/by/3.0). Modified into a 3D medallion.",
		"Thank you to everyone who made and shared the textures, sounds and models this game uses.",
		"",
		"[b]Thanks[/b]",
		"To everyone who tests it and tells me what is broken.",
	]
	return "\n".join(lines)


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
