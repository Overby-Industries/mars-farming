extends SceneTree
# The colony on screen, in the game the project starts with: the difficulty picker, the bar along the top, what the crew says as the food
# runs low and out, the four endings, the score and the leaderboard, and the choice of a male or a female crew voice. The core's rules and
# score are tested in tests/test_colony.cpp; this checks what the player sees and does. The same file is used by both farming games.
#
#   Godot --headless --path godot -s res://tests/colony_ui_test.gd
#
# It points the leaderboard and the saved preferences at scratch files, so the player's own are never touched.

const Leaderboard = preload("res://scripts/leaderboard.gd")
const Prefs = preload("res://scripts/prefs.gd")
const CrewVoice = preload("res://scripts/crew_voice.gd")
const Driver = preload("res://scripts/training_driver.gd")

var checks := 0
var failures := 0

func check(cond: bool, what: String) -> void:
	checks += 1
	if not cond:
		failures += 1
		print("FAIL  ", what)

# `ask` opens the difficulty picker with the scene, as the real game does (headless runs do not ask by themselves).
func make_scene(ask := false) -> Node3D:
	var packed := load(ProjectSettings.get_setting("application/run/main_scene")) as PackedScene
	var scene: Node3D = packed.instantiate()
	scene.astronaut_recipe = {"skins": false}
	scene.ask_difficulty = ask
	root.add_child(scene)
	scene.set_speed(0.0)
	if scene.get("_next_storm_sol") != null:
		scene._next_storm_sol = 1000000
	await process_frame
	await process_frame
	return scene

func discard(scene: Node) -> void:
	scene.queue_free()
	await process_frame
	await process_frame

# every word on the labels and buttons under a node
func texts_of(node: Node) -> String:
	var out := ""
	if node is Label:
		out += (node as Label).text + "\n"
	elif node is Button:
		out += (node as Button).text + "\n"
	for c in node.get_children():
		out += texts_of(c)
	return out

# Let days pass until the colony is decided (or `limit` days), a day at a time. Returns the days it took.
func run_to_the_end(scene: Node3D, limit := 500) -> int:
	var days := 0
	while scene.colony_ui.phase != "ending" and days < limit:
		Driver.advance(scene, 24.0, false)
		days += 1
	scene._refresh_all()
	return days

func _initialize() -> void:
	_run()

func _run() -> void:
	await process_frame
	root.size = Vector2i(1600, 900)
	Leaderboard.path = "user://test_leaderboard.json"
	Prefs.path = "user://test_prefs.cfg"
	Leaderboard.clear()
	Prefs.erase()
	if Engine.has_meta("colony_start"):
		Engine.remove_meta("colony_start")

	# ---- the scores table, on its own ----
	check(Leaderboard.clean_name("  Ada \t Lovelace  ") == "Ada Lovelace", "a name loses its stray white space and tabs")
	check(Leaderboard.clean_name("") == Leaderboard.DEFAULT_NAME and Leaderboard.clean_name("   ") == Leaderboard.DEFAULT_NAME, "an empty name is the default")
	check(Leaderboard.clean_name("A".repeat(40)).length() == Leaderboard.NAME_MAX, "a long name is cut to %d characters" % Leaderboard.NAME_MAX)
	check(Leaderboard.entries(0).is_empty() and Leaderboard.qualifies(0, 1) and not Leaderboard.qualifies(0, 0), "an empty table takes any score above zero")
	check(Leaderboard.submit({"name": "A", "score": 500, "difficulty": 0, "outcome": "success", "day": 120.0, "date": "2026-01-01T10:00:00"}) == 1, "the first run is number 1")
	check(Leaderboard.submit({"name": "B", "score": 900, "difficulty": 0, "outcome": "success", "day": 120.0, "date": "2026-01-02T10:00:00"}) == 1, "a better one takes number 1")
	check(Leaderboard.submit({"name": "C", "score": 700, "difficulty": 0, "outcome": "evacuated", "day": 90.0, "date": "2026-01-03T10:00:00"}) == 2, "and one between them is number 2")
	check(Leaderboard.entries(0).map(func(e): return e["name"]) == ["B", "C", "A"], "the table runs best first")
	check(Leaderboard.submit({"name": "D", "score": 700, "difficulty": 0, "outcome": "evacuated", "day": 90.0, "date": "2026-01-04T10:00:00"}) == 3, "a tie goes to the run that was set first")
	check(Leaderboard.entries(1).is_empty() and Leaderboard.entries(2).is_empty(), "each difficulty has its own table")
	check(Leaderboard.submit({"name": "E", "score": 100, "difficulty": 2, "outcome": "extinct", "day": 100.0}) == 1 and Leaderboard.entries(0).size() == 4, "a run on another difficulty leaves the first table alone")
	for i in 10:
		Leaderboard.submit({"name": "N%d" % i, "score": 1000 + i, "difficulty": 1})
	check(Leaderboard.entries(1).size() == Leaderboard.KEEP, "a table keeps %d runs" % Leaderboard.KEEP)
	check(not Leaderboard.qualifies(1, 900) and Leaderboard.submit({"name": "Low", "score": 900, "difficulty": 1}) == 0, "a score below the tenth does not make it")
	check(Leaderboard.qualifies(1, 1005) and Leaderboard.submit({"name": "High", "score": 5000, "difficulty": 1}) == 1 and Leaderboard.entries(1).size() == Leaderboard.KEEP, "a better one pushes the tenth off")
	check(Leaderboard.entries(1)[Leaderboard.KEEP - 1]["score"] == 1001, "the lowest left is the right one")
	var f := FileAccess.open(Leaderboard.path, FileAccess.WRITE)
	f.store_string("{ this is not json")
	f.close()
	check(Leaderboard.entries(0).is_empty() and Leaderboard.submit({"name": "After", "score": 5, "difficulty": 0}) == 1, "a damaged file is an empty table, and scores can be saved again")
	Leaderboard.clear()
	check(not FileAccess.file_exists(Leaderboard.path), "the table can be cleared")

	# ---- what is remembered ----
	check(Prefs.read("voice", "gender", "male") == "male", "with nothing saved, the default comes back")
	Prefs.write("voice", "gender", "female")
	Prefs.write("player", "name", "Ada")
	check(Prefs.read("voice", "gender", "male") == "female" and Prefs.read("player", "name", "") == "Ada", "a saved choice comes back, next to others")
	Prefs.erase()

	# ---- the names of voices ----
	var names := {
		"Microsoft David - English (United States)": "male", "Microsoft Zira - English (United States)": "female",
		"Microsoft Mark - English (United States)": "male", "Microsoft Hazel - English (Great Britain)": "female",
		"Alex": "male", "Samantha": "female", "Daniel (English (United Kingdom))": "male", "Karen": "female",
		"english-us+f3": "female", "en+m2": "male", "Female Voice 1": "female", "Male Voice 1": "male",
		"Some Unknown Voice": "", "": "",
	}
	var wrong := 0
	for n in names:
		if CrewVoice.classify_voice(n) != names[n]:
			wrong += 1
			print("   voice name '%s' is %s, expected %s" % [n, CrewVoice.classify_voice(n), names[n]])
	check(wrong == 0, "the gender of a voice is read from its name (%d wrong)" % wrong)

	# ---- the species carry food energy, and the rules reach Godot ----
	var scene := await make_scene()
	var kcal := {}
	for sp in scene.bay.get_species_list():
		kcal[sp["key"]] = sp["kcal_per_kg"]
	check(kcal.get("lettuce") == 150.0 and kcal.get("potato") == 770.0, "every crop has food energy (%s)" % str(kcal))
	check(FarmBay.get_difficulty_rules(0)["name"] == "Easy" and FarmBay.get_difficulty_rules(2)["evacuation_share"] == 0.0 and FarmBay.get_difficulty_rules(1)["crew"] == 8, "the three rules can be read")

	# ---- a sandbox until a colony is started ----
	var ui = scene.colony_ui
	check(ui != null and ui.is_inside_tree(), "the game has a colony UI")
	check(not scene.ask_difficulty and ui.phase == "sandbox" and not scene.bay.get_colony()["started"], "headless runs do not ask for a difficulty: a sandbox")
	check(ui._mode_label.text.begins_with("SANDBOX") and ui._btn_new.visible and not ui._food_box.visible and not ui._score_label.visible, "the bar says so, and offers a new colony")
	check(scene.bay.get_colony().get("outcome") == FarmBay.OUTCOME_RUNNING and scene.bay.get_colony().get("score", 0) == 0, "no colony, no score")
	await discard(scene)

	# ---- the picker, at the start ----
	scene = await make_scene(true)
	ui = scene.colony_ui
	check(ui.phase == "picker" and ui._picker.visible, "a game that asks opens the picker")
	check(scene.bay.time_scale == 0.0, "the clock waits for the choice")
	for button_name in ["PlayEasy", "PlayIntermediate", "PlayDifficult"]:
		check(ui._picker.find_child(button_name, true, false) != null, "the picker offers %s" % button_name)
	var picker_text := texts_of(ui._picker)
	check(picker_text.contains("Earth is safe") and picker_text.contains("Earth is damaged") and picker_text.contains("Earth cannot be lived on"), "each card says what failing means")
	check(picker_text.contains("Crew of 4") and picker_text.contains("Crew of 8") and picker_text.contains("Crew of 12"), "and how big the crew is")
	check(picker_text.contains("No speech voice was found"), "with no speech voice on the PC the picker says the crew will use captions")
	check(not ui._btn_voice.visible, "and there is no voice button on the bar")

	# ---- starting a colony ----
	ui.choose(1)
	var c: Dictionary = scene.bay.get_colony()
	check(c["started"] and c["running"] and c["difficulty"] == 1 and c["crew"] == 8 and not ui._picker.visible and ui.phase == "playing", "choosing Intermediate starts an Intermediate colony")
	check(scene.bay.time_scale == ui.START_SPEED, "and starts the clock")
	var tuning: Dictionary = scene.colony_tuning
	var demand: float = (tuning.get("demand", [1.0, 1.0, 1.0]) as Array)[1]
	check(is_equal_approx(c["need_kcal_day"], 50.0 * demand), "its need is the rule scaled for this game (%.1f kcal a day)" % c["need_kcal_day"])
	check(scene.voice.lines.size() > 0 and scene.voice.lines[scene.voice.lines.size() - 1]["key"] == "colony_start", "the crew says the colony has begun")
	check(str(scene.voice.lines[scene.voice.lines.size() - 1]["text"]).contains("We are 8"), "and how many of them there are: %s" % scene.voice.lines[scene.voice.lines.size() - 1]["text"])
	check(Prefs.read("colony", "difficulty", -1) == 1, "the difficulty is remembered for next time")
	scene.set_speed(0.0)
	await process_frame
	await process_frame
	ui._refresh_bar()
	check(ui._mode_label.text.begins_with("INTERMEDIATE") and ui._mode_label.text.contains("Pop 8/12") and ui._mode_label.text.contains("Day 1 / 200"), "the bar shows the mode, the people and the day: %s" % ui._mode_label.text)
	check(ui._food_box.visible and ui._score_label.visible and not ui._btn_new.visible, "and the food and the score")

	# ---- the bar fits: on the screen, clear of the other panels and of every slot button ----
	var bar: Rect2 = (ui._bar as Control).get_global_rect()
	var view := Rect2(Vector2.ZERO, Vector2(1600, 900))
	check(view.encloses(bar) and bar.size.y < 110.0, "the bar is on the screen and slim: %s" % str(bar))
	var overlapped := 0
	for pc in scene.find_children("*", "PanelContainer", true, false):
		var holder: Node = pc.get_parent()
		if holder is MarginContainer and holder.name != "CrewCaption" and holder != ui._bar and (pc as Control).is_visible_in_tree():
			if (pc as Control).get_global_rect().intersects(bar):
				overlapped += 1
	check(overlapped == 0, "it covers none of the HUD's panels (%d)" % overlapped)
	var under := 0
	for key in scene.slot_buttons.buttons:
		var btn: Button = scene.slot_buttons.buttons[key]
		if btn.visible and bar.intersects(btn.get_global_rect()):
			under += 1
	check(under == 0, "and none of the slot buttons (%d)" % under)

	# ---- time passes: the day, the food, the score ----
	Driver.advance(scene, 24.0 * 3.0, false)
	ui._refresh_bar()
	c = scene.bay.get_colony()
	check(ui._mode_label.text.contains("Day 4 / 200"), "three days on it is day 4: %s" % ui._mode_label.text)
	check(ui._food_value.text == "%d days" % int(ceilf(c["reserve_days"])), "the food in store is in days: %s" % ui._food_value.text)
	check(ui._score_label.text.begins_with("Score ") and c["score"] > 0, "the score is shown: %s" % ui._score_label.text)
	check(ui._food_fill.bg_color == Color("7bd35a"), "the food bar is green while there is plenty")

	# ---- the food runs low, then out: the crew says so ----
	ui.choose(0, false)                      # Easy: 100 days of food
	scene.set_speed(0.0)
	Driver.advance(scene, 24.0 * 85.0, false)
	ui._refresh_bar()
	c = scene.bay.get_colony()
	check(c["reserve_days"] > 14.0 and c["reserve_days"] < 16.0 and ui._food_fill.bg_color == Color("e8a33d"), "at about 15 days of food the bar turns amber (%.1f days)" % c["reserve_days"])
	check(ui.urgent_notes().is_empty() and ui.voice_notes().size() == 1 and ui.voice_notes()[0]["key"] == "colony_low", "and the crew has a low-food note")
	var low_note: Dictionary = scene.voice_notes().filter(func(n): return n["key"] == "colony_low")[0]
	check(str(low_note["text"]).contains("15 days") or str(low_note["text"]).contains("16 days"), "which says how many days are left: %s" % low_note["text"])
	Driver.advance(scene, 24.0 * 16.0, false)
	ui._refresh_bar()
	c = scene.bay.get_colony()
	check(c["running"] and c["starving"] and ui._food_value.text.begins_with("EMPTY") and ui._food_fill.bg_color == Color("c4472f"), "with the store empty the bar says EMPTY, in red: %s" % ui._food_value.text)
	var urgent: Array = ui.urgent_notes()
	check(urgent.size() == 1 and urgent[0]["key"] == "colony_hunger" and str(urgent[0]["text"]).contains("out of food"), "and the crew's note cannot wait: %s" % str(urgent))
	var adv: Dictionary = scene.voice.advice(true)
	check(adv.get("key", "") == "colony_hunger", "it comes before everything else the crew might say (%s)" % adv.get("key", ""))

	# ---- an Easy failure: evacuated home ----
	var days := run_to_the_end(scene)
	check(ui.phase == "ending" and ui._ending.visible and scene.bay.time_scale == 0.0, "when the colony fails the ending opens and the clock stops (after %d more days)" % days)
	check(ui.result["outcome"] == FarmBay.OUTCOME_EVACUATED and ui.result["survivors"] == 4 and ui.result["crew"] == 4, "Easy: everyone evacuated")
	var ending_text := texts_of(ui._ending)
	check(ending_text.contains("EVACUATED: THE COLONY HAS FAILED") and ending_text.contains("brought home") and ending_text.contains(scene.colony_place), "the ending says what happened, in this game's place (%s)" % scene.colony_place)
	check(scene.voice.lines[scene.voice.lines.size() - 1]["key"] == "colony_end" and str(scene.voice.lines[scene.voice.lines.size() - 1]["text"]).contains("evacuated"), "and the crew says it too")
	check(ui._ending_box.find_child("Total", true, false) != null and (ui._ending_box.find_child("Total", true, false) as Label).text.begins_with("SCORE"), "with the score")
	check(ending_text.contains("Hungry days") and ending_text.contains("Days lasted"), "and what it is made of")
	await discard(scene)

	# ---- an Intermediate failure: part of the crew lost ----
	scene = await make_scene()
	ui = scene.colony_ui
	ui.choose(1, false)
	scene.set_speed(0.0)
	run_to_the_end(scene)
	check(ui.result["outcome"] == FarmBay.OUTCOME_EVACUATED_WITH_LOSSES and ui.result["survivors"] == 4 and ui.result["crew"] == 8, "Intermediate: half the crew brought home")
	ending_text = texts_of(ui._ending)
	check(ending_text.contains("PARTIAL EVACUATION") and ending_text.contains("only 4 of the 8") and ending_text.contains("The other 4"), "the ending counts them")

	# play again and the other buttons, from here
	var reloads := [0]
	ui.restart = func(): reloads[0] += 1
	ui.play_again()
	check(reloads[0] == 1 and Engine.has_meta("colony_start") and int(Engine.get_meta("colony_start")) == 1, "Play again reloads, remembering the difficulty")
	ui.change_difficulty()
	check(reloads[0] == 2 and not Engine.has_meta("colony_start"), "Change difficulty reloads and forgets it")
	ui.keep_playing()
	check(not ui._ending.visible and ui.phase == "sandbox" and scene.bay.time_scale > 0.0 and scene.bay.get_colony()["outcome"] == FarmBay.OUTCOME_EVACUATED_WITH_LOSSES, "Keep playing carries on in the same bay, the colony still over")
	await discard(scene)

	# the reloaded game starts the same difficulty without asking
	Engine.set_meta("colony_start", 1)
	scene = await make_scene(true)
	ui = scene.colony_ui
	check(ui.phase == "playing" and scene.bay.get_colony()["running"] and scene.bay.get_colony()["difficulty"] == 1 and (ui._picker == null or not ui._picker.visible), "a game reloaded by Play again starts at once, with no picker")
	check(not Engine.has_meta("colony_start"), "and uses the request up")
	await discard(scene)

	# ---- a Difficult failure: extinction, and the leaderboard ----
	scene = await make_scene()
	ui = scene.colony_ui
	ui.choose(2, false)
	scene.set_speed(0.0)
	run_to_the_end(scene)
	check(ui.result["outcome"] == FarmBay.OUTCOME_EXTINCT and ui.result["survivors"] == 0, "Difficult: nobody survives")
	ending_text = texts_of(ui._ending)
	check(ending_text.contains("EXTINCTION") and ending_text.contains("nowhere to go") and ending_text.contains("None of the 12"), "the ending says so")
	check(ui.result["score"] > 0 and ui._name_edit != null and ui._ending_box.get_node_or_null("Entry") != null, "there is a score to save, and a place for a name")
	check(Leaderboard.entries(2).is_empty() and ui.rank == 0 and not ui.saved, "nothing is on the table yet")
	ui._name_edit.text = "  Ada \t Lovelace  "
	var rank: int = ui.submit_score(ui._name_edit.text)
	check(rank == 1 and ui.saved and ui.rank == 1, "saving puts the run at number 1")
	check(Leaderboard.entries(2).size() == 1 and Leaderboard.entries(2)[0]["name"] == "Ada Lovelace" and Leaderboard.entries(2)[0]["score"] == ui.result["score"], "under a clean name, with the score")
	check(Leaderboard.entries(2)[0]["outcome"] == "extinct" and Prefs.read("player", "name", "") == "Ada Lovelace", "and the name is remembered for next time")
	check(ui._board.visible and not ui._ending.visible and texts_of(ui._board).contains("Ada Lovelace") and texts_of(ui._board).contains("Extinct"), "the leaderboard opens at the new entry")
	check(ui.submit_score("Someone Else") == 1 and Leaderboard.entries(2).size() == 1, "a score is saved once")
	ui.show_board(0, 0, "ending")
	check(texts_of(ui._board).contains("No runs yet"), "another difficulty's table is empty: it says so")
	ui.close_board()
	check(not ui._board.visible and ui._ending.visible, "closing the board returns to the ending")
	await discard(scene)

	# ---- the crew keeps quiet behind the picker, and speaks up once the game is on ----
	scene = await make_scene(true)
	ui = scene.colony_ui
	scene.voice.tick(0.4)
	scene.voice.tick(6.0)
	check(ui.phase == "picker" and scene.voice_held() and scene.voice.lines.is_empty(), "behind the picker the crew does not chat")
	ui.choose(0, false)
	scene.set_speed(0.0)
	check(not scene.voice_held(), "and it is let go when the game starts")
	scene.voice.tick(1.6)
	check(scene.voice.lines.size() == 1 and scene.voice.lines[0]["key"] == "intro", "so it gives its welcome then")
	await discard(scene)

	# ---- all four endings read well ----
	scene = await make_scene()
	ui = scene.colony_ui
	var samples := [
		{"outcome": FarmBay.OUTCOME_SUCCESS, "title": "COLONY ESTABLISHED", "story": "fed for 120 days", "voice": "The colony is established"},
		{"outcome": FarmBay.OUTCOME_EVACUATED, "title": "EVACUATED", "story": "brought home", "voice": "evacuated"},
		{"outcome": FarmBay.OUTCOME_EVACUATED_WITH_LOSSES, "title": "PARTIAL EVACUATION", "story": "only 4 of the 8", "voice": "only 4 of us"},
		{"outcome": FarmBay.OUTCOME_EXTINCT, "title": "EXTINCTION", "story": "extinct", "voice": "nowhere to go"},
	]
	for s in samples:
		ui.result = {"outcome": s["outcome"], "crew": 8, "survivors": 4, "goal_days": 120.0, "day": 87.0, "difficulty": 1, "difficulty_name": "Intermediate",
				"score": 4321, "score_parts": {"days": 261.0, "food": 800.0, "variety": 300.0, "reserve": 0.0, "lost": 80.0, "hunger": 100.0, "bonus": 0.0, "multiplier": 1.5},
				"harvested_kcal": 1600.0, "crops_grown": 2, "reserve_days": 0.0, "plants_lost": 2, "hungry_days_total": 4.0, "outcome_name": "x"}
		check(ui._title_text().contains(s["title"]) and ui._story_text().contains(s["story"]) and ui._voice_line().contains(s["voice"]), "ending %d: %s | %s" % [s["outcome"], ui._title_text(), ui._story_text()])
	await discard(scene)

	# ---- the crew's voice: male or female ----
	scene = await make_scene(true)
	ui = scene.colony_ui
	var voice: Node = scene.voice
	check(voice.available_genders().is_empty() and not voice.set_gender("female") and not ui.choose_voice("female"), "with no voices, no gender can be chosen")
	voice._voices = {"male": {"id": "m1", "name": "Test David - English (United States)", "language": "en_US"},
			"female": {"id": "f1", "name": "Test Zira - English (United States)", "language": "en_US"}}
	check(voice.available_genders() == ["male", "female"] and voice.voice_name("female").contains("Zira"), "a PC with both voices offers both")
	ui._refresh_picker_voice()
	var male_btn: Button = ui._picker_voice_row.find_child("VoiceMale", true, false)
	var female_btn: Button = ui._picker_voice_row.find_child("VoiceFemale", true, false)
	check(male_btn != null and female_btn != null and not male_btn.disabled and not female_btn.disabled and male_btn.button_pressed and not female_btn.button_pressed, "the picker offers a male and a female voice, the male one chosen")
	check(female_btn.tooltip_text.contains("Zira"), "and each says which voice it is")
	female_btn.pressed.emit()
	check(voice.gender == "female" and voice._voice_id == "f1" and Prefs.read("voice", "gender", "") == "female", "choosing the female voice switches it and remembers it")
	check(scene.voice.lines[scene.voice.lines.size() - 1]["key"] == "voice_preview", "and the crew says a line in it")
	ui._refresh_bar()
	check(ui._btn_voice.visible and ui._btn_voice.text == "Voice: Female", "the bar has a button for it: %s" % ui._btn_voice.text)
	ui.toggle_voice()
	check(voice.gender == "male" and voice._voice_id == "m1" and ui._btn_voice.text == "Voice: Male", "which swaps it back")
	voice._voices.erase("female")
	ui._refresh_picker_voice()
	check(texts_of(ui._picker_voice_row).contains("only a male voice") and ui._picker_voice_row.find_child("VoiceFemale", true, false).disabled, "a PC with only a male voice says so, and the female button is off")
	ui._refresh_bar()
	check(not ui._btn_voice.visible, "and the bar has no voice button")
	await discard(scene)

	Leaderboard.clear()
	Prefs.erase()
	print("\n%d checks, %d failures" % [checks, failures])
	quit(0 if failures == 0 else 1)
