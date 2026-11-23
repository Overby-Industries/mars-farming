extends RefCounted
## What the game remembers between runs, in user://prefs.cfg (a Godot ConfigFile, so it is plain text): which crew voice the
## player picked (male or female), whether the voice speaks, the last difficulty, and the name for the leaderboard. Nothing is
## sent anywhere; the file lives in the game's own user folder on this PC. The tests point `path` at a scratch file.

static var path := "user://prefs.cfg"

static func read(section: String, key: String, default: Variant = null) -> Variant:
	var cfg := ConfigFile.new()
	if cfg.load(path) != OK:
		return default
	return cfg.get_value(section, key, default)

static func write(section: String, key: String, value: Variant) -> void:
	var cfg := ConfigFile.new()
	cfg.load(path)                         # keep what is there (a missing file is fine)
	cfg.set_value(section, key, value)
	cfg.save(path)

static func erase() -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
