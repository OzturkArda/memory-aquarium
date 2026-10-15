extends Node2D
## Memory Aquarium: shows this PC's RAM as a fish tank. The water level is memory in use,
## every app is a fish sized by its private memory, and the kernel's non-paged pool is the
## sludge on the bottom. Click a fish to reel it in, which ends that app's processes.
##
## sampler.py does the measuring (Win32 calls Godot can't make) and drops a JSON snapshot
## in the user data dir every couple of seconds.

const TankArt := preload("res://tank_art.gd")

const PX := 3
const TANK_H := TankArt.H * PX
const FISH_COUNT := 12
const FISH_MIN := 80.0 * 1024.0 * 1024.0
const FRY := "small fry"
const GB := 1024.0 * 1024.0 * 1024.0
const INK := Color("2a1f3d")
const PAPER := Color("fff6dc")
const PAPER_EDGE := Color("c8961e")
const PROTECTED := ["System", "Registry", "smss", "csrss", "wininit", "winlogon", "services", "lsass",
		"LsaIso", "svchost", "dwm", "explorer", "Memory Compression", "Secure System", "fontdrvhost",
		"sihost", "ctfmon", "MsMpEng", "SearchHost", "StartMenuExperienceHost", "ShellExperienceHost",
		"RuntimeBroker", "conhost", "audiodg", "spoolsv", "WmiPrvSE", "dllhost", "taskhostw",
		"TextInputHost", "SecurityHealthService", "SgrmBroker", "MemCompression"]

var tank: TankArt
var overlay: Node2D
var font: SystemFont
var font_bold: SystemFont
var panel: PanelContainer
var panel_title: Label
var panel_body: Label
var btn_yes: Button
var btn_no: Button

var snap_path := ""
var sampler_pid := -1
var snap_mtime := 0
var snap := {}
var groups := {}          # name -> {name, mem, count, pids, fry}
var private_sum := 0.0
var hover := ""           # fish name, or "@water" / "@air" / "@sludge"
var mouse := Vector2.ZERO
var pending := ""         # fish the confirm panel is about
var toast := ""
var toast_until := 0.0
var poll := 0.0


func _ready() -> void:
	DisplayServer.window_set_title("Memory Aquarium")
	font = SystemFont.new()
	font.font_names = PackedStringArray(["Segoe UI", "sans-serif"])
	font_bold = SystemFont.new()
	font_bold.font_names = PackedStringArray(["Segoe UI Black", "Segoe UI", "sans-serif"])
	font_bold.font_weight = 800

	var vp := SubViewport.new()
	vp.size = Vector2i(TankArt.W, TankArt.H)
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	vp.canvas_item_default_texture_filter = Viewport.DEFAULT_CANVAS_ITEM_TEXTURE_FILTER_NEAREST
	tank = TankArt.new()
	tank.reeled_in.connect(_on_reeled_in)
	vp.add_child(tank)
	add_child(vp)
	var tex := TextureRect.new()
	tex.texture = vp.get_texture()
	tex.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	tex.stretch_mode = TextureRect.STRETCH_SCALE
	tex.size = Vector2(TankArt.W * PX, TANK_H)
	tex.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(tex)

	overlay = Node2D.new()
	overlay.draw.connect(_draw_overlay)
	add_child(overlay)
	_build_panel()
	_start_sampler()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST and sampler_pid > 0:
		OS.kill(sampler_pid)


func _start_sampler() -> void:
	snap_path = OS.get_user_data_dir().path_join("snapshot.json")
	var script := ProjectSettings.globalize_path("res://sampler.py")
	var args := [script, snap_path, str(OS.get_process_id()), "2"]
	for exe in ["pythonw", "python"]:
		sampler_pid = OS.create_process(exe, args)
		if sampler_pid > 0:
			return
	_show_toast("Couldn't start Python, so the tank stays empty.", 3600.0)


func _process(delta: float) -> void:
	poll -= delta
	if poll <= 0.0:
		poll = 1.0
		_read_snapshot()
	var m := get_viewport().get_mouse_position()
	if m != mouse:
		mouse = m
		_update_hover()
	overlay.queue_redraw()


func _read_snapshot() -> void:
	if not FileAccess.file_exists(snap_path):
		return
	var mt := FileAccess.get_modified_time(snap_path)
	if mt == snap_mtime:
		return
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(snap_path))
	if typeof(parsed) != TYPE_DICTIONARY:
		return  # caught it mid-write; next poll gets it
	snap_mtime = mt
	snap = parsed
	_regroup()


func _regroup() -> void:
	var by := {}
	private_sum = 0.0
	for p in snap.procs:
		var n: String = p.name
		if not by.has(n):
			by[n] = {"name": n, "mem": 0.0, "count": 0, "pids": [], "fry": false}
		by[n].mem += float(p.mem)
		by[n].count += 1
		by[n].pids.append(int(p.pid))
		private_sum += float(p.mem)
	var all := by.values()
	all.sort_custom(func(a, b): return a.mem > b.mem)
	groups = {}
	var fry := {"name": FRY, "mem": 0.0, "count": 0, "pids": [], "fry": true}
	for i in all.size():
		var g: Dictionary = all[i]
		if i < FISH_COUNT and g.mem >= FISH_MIN:
			groups[g.name] = g
		else:
			fry.mem += g.mem
			fry.count += 1
	if fry.count > 0:
		groups[FRY] = fry
	tank.set_data(groups.values(), snap.total, _used(), snap.nonpaged)
	_update_hover()


func _used() -> float:
	return float(snap.total) - float(snap.avail)


func _update_hover() -> void:
	hover = ""
	if snap.is_empty() or panel.visible or mouse.y >= TANK_H:
		return
	var p := mouse / PX
	var f: String = tank.fish_at(p)
	if f != "" and groups.has(f):
		hover = f
		return
	var r: String = tank.region_at(p)
	if r != "":
		hover = "@" + r


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		if hover != "" and not hover.begins_with("@"):
			_open_panel(hover)


# --- the reel-it-in panel -----------------------------------------------------------

func _build_panel() -> void:
	panel = PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = PAPER
	sb.border_color = PAPER_EDGE
	sb.set_border_width_all(3)
	sb.set_corner_radius_all(10)
	sb.set_content_margin_all(18)
	panel.add_theme_stylebox_override("panel", sb)
	panel.custom_minimum_size = Vector2(440, 0)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	panel.add_child(box)
	panel_title = _label(22, font_bold)
	panel_body = _label(15, font)
	panel_body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	panel_body.custom_minimum_size = Vector2(380, 0)
	box.add_child(panel_title)
	box.add_child(panel_body)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_END
	row.add_theme_constant_override("separation", 10)
	box.add_child(row)
	btn_no = _button("Leave it")
	btn_yes = _button("Reel it in")
	btn_no.pressed.connect(func(): panel.hide())
	btn_yes.pressed.connect(_confirm_reel)
	row.add_child(btn_no)
	row.add_child(btn_yes)
	panel.hide()
	add_child(panel)


func _label(size: int, f: Font) -> Label:
	var l := Label.new()
	l.add_theme_font_override("font", f)
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", INK)
	return l


func _button(text: String) -> Button:
	var b := Button.new()
	b.text = text
	b.add_theme_font_override("font", font_bold)
	b.add_theme_font_size_override("font_size", 15)
	b.custom_minimum_size = Vector2(110, 36)
	return b


func _open_panel(n: String) -> void:
	var g: Dictionary = groups[n]
	pending = n
	panel_title.text = _display(n)
	var size := "%d process%s, %s of private memory (%.1f%% of your RAM)." % [g.count, "" if g.count == 1 else "es", _gb(g.mem), 100.0 * g.mem / snap.total]
	btn_yes.visible = true
	btn_no.text = "Leave it"
	if g.fry:
		panel_body.text = "%d little apps under %d MB each, %s between them. Too many to catch one by one." % [g.count, int(FISH_MIN / 1048576.0), _gb(g.mem)]
		btn_yes.visible = false
		btn_no.text = "Fair enough"
	elif _protected(g):
		panel_body.text = size + "\n\nWindows can't live without this one, so it stays in the tank."
		btn_yes.visible = false
		btn_no.text = "Fair enough"
	else:
		var warn := "Reeling it in ends every one of them, and anything unsaved in them is lost."
		if n.to_lower() == "claude":
			warn += " That includes every Claude Code session, possibly the one you're talking to."
		elif n.to_lower() == "chrome":
			warn += " Chrome will offer to restore your tabs next time."
		panel_body.text = size + "\n\n" + warn
	panel.position = Vector2((TankArt.W * PX - panel.custom_minimum_size.x) * 0.5, 190)
	panel.show()
	hover = ""


func _confirm_reel() -> void:
	panel.hide()
	tank.start_hook(pending)


func _on_reeled_in(n: String) -> void:
	if not groups.has(n):
		return
	var g: Dictionary = groups[n]
	var ok := 0
	var tried := 0
	for pid in g.pids:
		if pid == OS.get_process_id() or pid == sampler_pid:
			continue
		tried += 1
		if OS.kill(pid) == OK:
			ok += 1
	var msg := "Reeled in %s: %d of %d processes ended." % [_display(n), ok, tried]
	if ok < tried:
		msg += " %d slipped off the hook (Windows said no)." % (tried - ok)
	_show_toast(msg, 8.0)
	poll = 0.0


func _protected(g: Dictionary) -> bool:
	if g.name in PROTECTED:
		return true
	return OS.get_process_id() in g.pids or sampler_pid in g.pids


func _display(n: String) -> String:
	if not groups.has(n):
		return n
	var g: Dictionary = groups[n]
	if OS.get_process_id() in g.pids:
		return n + " (this aquarium)"
	if sampler_pid in g.pids:
		return n + " (incl. the aquarium's sampler)"
	return n


func _show_toast(text: String, secs: float) -> void:
	toast = text
	toast_until = Time.get_ticks_msec() / 1000.0 + secs


# --- overlay: headline, fish name tags, tooltip, bottom strip -----------------------

func _draw_overlay() -> void:
	var o := overlay
	var w := float(TankArt.W * PX)
	_text(o, Vector2(42, 44), "Memory Aquarium", 28, font_bold, INK)
	if snap.is_empty():
		_text(o, Vector2(42, 74), "Filling the tank...", 16, font, INK)
	else:
		var used := _used()
		_text(o, Vector2(42, 74), _mood(used / snap.total), 16, font, INK)
		var head := "%s of %s in use" % [_gb(used), _gb(snap.total)]
		var sub := "%s free" % _gb(snap.avail)
		_text_right(o, Vector2(w - 42, 44), head, 22, font_bold, INK)
		_text_right(o, Vector2(w - 42, 72), sub, 16, font, INK)
		var tags: Array = tank.labels()
		tags.sort_custom(func(a, b): return a.mem > b.mem)
		var taken := []
		for l in tags:
			var p: Vector2 = l.pos * PX
			var label := "%s  %s" % [l.name, _gb(l.mem)]
			var lw := font_bold.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, 13).x
			p.x = clampf(p.x, lw * 0.5 + 8.0, TankArt.W * PX - lw * 0.5 - 8.0)
			var box := Rect2(p + Vector2(-lw * 0.5 - 4, 0), Vector2(lw + 8, 16))
			if taken.any(func(r): return r.intersects(box)):
				continue  # the bigger fish keeps its tag; hover shows the rest
			taken.append(box)
			o.draw_string_outline(font_bold, p + Vector2(-lw * 0.5, 12), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, 4, Color(0.05, 0.1, 0.2, 0.85))
			o.draw_string(font_bold, p + Vector2(-lw * 0.5, 12), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color.WHITE)
	_bottom_strip(o, w)
	if hover != "":
		_tooltip(o, _hover_lines())


func _bottom_strip(o: Node2D, w: float) -> void:
	var y0 := float(TANK_H)
	o.draw_rect(Rect2(0, y0, w, 60), Color("3b2410"))
	if snap.is_empty():
		return
	var commit := float(snap.commit)
	var limit := float(snap.commit_limit)
	var bar := Rect2(42, y0 + 12, 260, 12)
	o.draw_rect(bar, Color("1f130a"))
	o.draw_rect(Rect2(bar.position, Vector2(bar.size.x * clampf(commit / limit, 0, 1), bar.size.y)), Color("e8b531"))
	var phys_x := bar.position.x + bar.size.x * clampf(float(snap.total) / limit, 0, 1)
	o.draw_line(Vector2(phys_x, bar.position.y - 3), Vector2(phys_x, bar.end.y + 3), Color.WHITE, 2.0)
	var promise := "Promised to apps: %s (the white tick is your real RAM)" % _gb(commit)
	_text(o, Vector2(318, y0 + 23), promise, 14, font, Color("f3e2c3"))
	var line2 := "Hover a fish to see who it is. Click one to reel it in."
	if Time.get_ticks_msec() / 1000.0 < toast_until:
		line2 = toast
	elif float(snap.nonpaged) > TankArt.SLUDGE_ALARM:
		line2 = "The bottom is thick with driver sludge (%s). Hover it for what that means." % _gb(snap.nonpaged)
	_text(o, Vector2(42, y0 + 48), line2, 14, font_bold, Color("fbe39a"))


func _hover_lines() -> Array:
	var used := _used()
	match hover:
		"@air":
			return ["Free room: %s" % _gb(snap.avail), "Includes file cache Windows can drop the", "moment an app asks for memory."]
		"@sludge":
			var np := float(snap.nonpaged)
			var sludge := ["Driver sludge: %s" % _gb(np), "Kernel non-paged pool: memory drivers lock", "in RAM. It can't be paged out or reclaimed."]
			if np > TankArt.SLUDGE_ALARM:
				sludge += ["Healthy is under about 0.8 GB. This much", "points to a leaking driver."]
			return sludge
		"@water":
			var shared := maxf(0.0, used - private_sum - float(snap.nonpaged))
			return ["Water: %s in use" % _gb(used), "Fish (apps' own memory): %s" % _gb(private_sum),
					"Sludge (driver pool): %s" % _gb(snap.nonpaged), "Murk (shared files, kernel, the rest): %s" % _gb(shared)]
	var g: Dictionary = groups[hover]
	if g.fry:
		return ["Small fry", "%d little apps, %s between them" % [g.count, _gb(g.mem)]]
	var lines := [_display(hover), "%d process%s, %s" % [g.count, "" if g.count == 1 else "es", _gb(g.mem)],
			"%.1f%% of your RAM" % (100.0 * g.mem / snap.total)]
	lines.append("Windows needs this one." if _protected(g) else "Click to reel it in.")
	return lines


func _tooltip(o: Node2D, lines: Array) -> void:
	var fs := 14
	var lh := 19.0
	var tw := 0.0
	for i in lines.size():
		var f: Font = font_bold if i == 0 else font
		tw = maxf(tw, f.get_string_size(lines[i], HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x)
	var size := Vector2(tw + 24, lines.size() * lh + 14)
	var p := mouse + Vector2(18, 18)
	var view := Vector2(TankArt.W * PX, TANK_H + 60)
	if p.x + size.x > view.x - 6:
		p.x = mouse.x - size.x - 12
	if p.y + size.y > view.y - 6:
		p.y = mouse.y - size.y - 12
	var r := Rect2(p, size)
	o.draw_rect(r, PAPER)
	o.draw_rect(r, PAPER_EDGE, false, 2.0)
	for i in lines.size():
		var f: Font = font_bold if i == 0 else font
		o.draw_string(f, p + Vector2(12, 22 + i * lh), lines[i], HORIZONTAL_ALIGNMENT_LEFT, -1, fs, INK)


func _mood(frac: float) -> String:
	if frac < 0.5:
		return "Plenty of room to swim."
	if frac < 0.7:
		return "Getting cosy in here."
	if frac < 0.85:
		return "Sardine mode."
	if frac < 0.93:
		return "The fish are holding their breath."
	return "The tank is overflowing!"


func _text(o: Node2D, p: Vector2, s: String, size: int, f: Font, col: Color) -> void:
	o.draw_string(f, p, s, HORIZONTAL_ALIGNMENT_LEFT, -1, size, col)


func _text_right(o: Node2D, p: Vector2, s: String, size: int, f: Font, col: Color) -> void:
	var sw := f.get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	o.draw_string(f, p - Vector2(sw, 0), s, HORIZONTAL_ALIGNMENT_LEFT, -1, size, col)


func _gb(bytes) -> String:
	var b := float(bytes)
	if b < GB:
		return "%d MB" % int(b / 1048576.0)
	return "%.1f GB" % (b / GB)
