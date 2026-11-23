extends RefCounted
## The leaderboard: the best runs on THIS PC, ten for each difficulty, kept in user://leaderboard.json (plain JSON in the game's own
## user folder: nothing is sent anywhere, and the two farming games each have their own file). A run is ranked by its score (the
## core works it out, see core/colony.hpp); ties go to the run that was set first.
##
##   Leaderboard.submit({"name": "Ada", "score": 5230, "difficulty": 1, "outcome": "success", "day": 200.0})   # returns the rank, 0 if not kept
##   Leaderboard.entries(1)          # the Intermediate table, best first
##
## An online board would need a server to send scores to; this file is the seam: `submit()` and `entries()` are all the game calls.
## The tests point `path` at a scratch file.

static var path := "user://leaderboard.json"

const KEEP := 10                  # runs kept per difficulty
const NAME_MAX := 16
const DEFAULT_NAME := "Commander"

# A name for the table: no control characters, no edges of white space, at most NAME_MAX characters, never empty.
static func clean_name(raw: String) -> String:
	var out := ""
	for i in raw.length():
		var c := raw.unicode_at(i)
		out += " " if c < 32 or c == 127 else raw[i]
	out = out.strip_edges()
	while out.contains("  "):
		out = out.replace("  ", " ")
	if out.length() > NAME_MAX:
		out = out.substr(0, NAME_MAX).strip_edges()
	return out if out != "" else DEFAULT_NAME

static func _load_all() -> Array:
	if not FileAccess.file_exists(path):
		return []
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return []
	var json := JSON.new()
	if json.parse(f.get_as_text()) != OK:                  # a damaged file is an empty table (and is quietly replaced by the next save)
		return []
	var parsed: Variant = json.data
	if parsed is Dictionary and (parsed as Dictionary).get("entries") is Array:
		return (parsed as Dictionary)["entries"]
	return []

static func _save_all(all: Array) -> bool:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return false
	f.store_string(JSON.stringify({"version": 1, "entries": all}, "\t"))
	return true

# Best first: by score, then by who got there first.
static func _before(a: Dictionary, b: Dictionary) -> bool:
	if int(a.get("score", 0)) != int(b.get("score", 0)):
		return int(a.get("score", 0)) > int(b.get("score", 0))
	return str(a.get("date", "")) < str(b.get("date", ""))

# The table for one difficulty (0 Easy, 1 Intermediate, 2 Difficult), best first, at most KEEP long.
static func entries(difficulty: int) -> Array:
	var mine: Array = []
	for e in _load_all():
		if e is Dictionary and int((e as Dictionary).get("difficulty", -1)) == difficulty:
			mine.append(e)
	mine.sort_custom(_before)
	return mine.slice(0, KEEP)

# Would this score make the table?
static func qualifies(difficulty: int, score: int) -> bool:
	if score <= 0:
		return false
	var table := entries(difficulty)
	return table.size() < KEEP or score > int((table[table.size() - 1] as Dictionary).get("score", 0))

# Add a run. Returns its rank in its difficulty's table (1 is the best), or 0 when it did not make the table (or could not be saved).
static func submit(entry: Dictionary) -> int:
	var e := {
		"name": clean_name(str(entry.get("name", ""))),
		"score": int(entry.get("score", 0)),
		"difficulty": int(entry.get("difficulty", 0)),
		"outcome": str(entry.get("outcome", "")),
		"day": snappedf(float(entry.get("day", 0.0)), 0.1),
		"date": str(entry.get("date", Time.get_datetime_string_from_system())),
	}
	if not qualifies(e["difficulty"], e["score"]):
		return 0
	var others: Array = []
	for old in _load_all():                       # the other difficulties stay as they are
		if old is Dictionary and int((old as Dictionary).get("difficulty", -1)) != e["difficulty"]:
			others.append(old)
	var table := entries(e["difficulty"])
	table.append(e)
	table.sort_custom(_before)
	table = table.slice(0, KEEP)
	if not _save_all(others + table):
		return 0
	return table.find(e) + 1

static func clear() -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))
