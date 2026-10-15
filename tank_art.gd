extends Node2D
## The aquarium, drawn with primitives into a low-res SubViewport and scaled up with
## nearest filtering, so it reads as pixel art. The water level is the RAM in use, every
## app is a fish sized by its private memory, and the kernel's non-paged pool settles on
## the bottom as sludge.

signal reeled_in(name: String)

const W := 320
const H := 200
const TANK := Rect2(14, 32, 292, 152)   # inside of the glass
const SHARE_OF_TANK := 0.55             # fish area per byte of RAM, as a share of the tank
const SLUDGE_ALARM := 1.5 * 1024.0 * 1024.0 * 1024.0

const OUTLINE := Color("10163f")
const WALL := Color("f1dfbf")
const WALL_STRIPE := Color("e8d1a8")
const WOOD := Color("8a5a2b")
const WOOD_DARK := Color("5e3a17")
const WOOD_LIGHT := Color("b07a3f")
const GLASS := Color(0.86, 0.95, 1.0, 0.35)
const GLASS_EDGE := Color("2d4a6b")
const SLUDGE := Color("4d4a1f")
const SLUDGE_DARK := Color("332f12")
const SLUDGE_TOXIC := Color("7fae2a")
const BRANDS := {
	"chrome": [Color("db4437"), Color("f4b400")],
	"claude": [Color("d97757"), Color("f3c9b4")],
	"msedgewebview2": [Color("1e88e5"), Color("43d17a")],
	"msedge": [Color("1e88e5"), Color("43d17a")],
	"Spotify": [Color("1db954"), Color("191414")],
	"vmmemWSL": [Color("e95420"), Color("f6f6f6")],
	"Docker Desktop": [Color("2496ed"), Color("dff1ff")],
	"node": [Color("68a063"), Color("303030")],
	"python": [Color("3776ab"), Color("ffd43b")],
	"pythonw": [Color("3776ab"), Color("ffd43b")],
	"Code": [Color("007acc"), Color("e6f3fb")],
	"steamwebhelper": [Color("1b2838"), Color("66c0f4")],
	"Memory Compression": [Color("8e8e9a"), Color("c9c9d4")],
	"svchost": [Color("5b6b7f"), Color("aab8c8")],
}

var t := 0.0
var used_frac := 0.0
var sludge_frac := 0.0
var sludge_bytes := 0.0
var shown_level := 0.0          # eased water surface, in tank pixels from the bottom
var shown_sludge := 0.0
var fish := {}                  # name -> state dictionary, see _new_fish
var bubbles := []               # {p, v, r, skull}
var drops := []                 # overflow drips {p, v}
var splashes := []              # {p, v, life}
var hook := {}                  # {name, t}


func set_data(groups: Array, total: float, used: float, nonpaged: float) -> void:
	used_frac = clampf(used / total, 0.0, 1.0)
	sludge_frac = clampf(nonpaged / total, 0.0, 1.0)
	sludge_bytes = nonpaged
	var seen := {}
	for g in groups:
		var n: String = g.name
		seen[n] = true
		if not fish.has(n):
			fish[n] = _new_fish(n, g.get("fry", false))
		var f: Dictionary = fish[n]
		f.mem = g.mem
		f.count = g.count
		f.share = g.mem / total
		f.dead = false
		var area: float = f.share * TANK.get_area() * SHARE_OF_TANK
		f.trx = clampf(sqrt(area / (PI * 0.6)), 4.0, 70.0)
	for n in fish:
		if not seen.has(n) and not fish[n].dead:
			fish[n].dead = true
			fish[n].dead_t = 0.0


func level_y() -> float:
	return TANK.end.y - shown_level


func sludge_y() -> float:
	return TANK.end.y - shown_sludge


func region_at(p: Vector2) -> String:
	if not TANK.has_point(p):
		return ""
	if p.y >= sludge_y() - 1.0:
		return "sludge"
	if p.y >= level_y():
		return "water"
	return "air"


func fish_at(p: Vector2) -> String:
	var best := ""
	var best_r := INF
	for n in fish:
		var f: Dictionary = fish[n]
		if f.dead or f.alpha < 0.5:
			continue
		if f.fry:
			for m in f.school:
				if p.distance_to(f.pos + m) < 5.0:
					return n
			continue
		var d: Vector2 = (p - f.pos) / Vector2(f.rx * 1.25, f.rx * 0.75)
		if d.length() < 1.0 and f.rx < best_r:  # smaller fish win where they overlap
			best = n
			best_r = f.rx
	return best


func labels() -> Array:
	var out := []
	for n in fish:
		var f: Dictionary = fish[n]
		if not f.dead and not f.fry and f.rx >= 9.0 and f.alpha > 0.8:
			out.append({"name": n, "pos": f.pos + Vector2(0, f.rx * 0.6 + 3.0), "mem": f.mem})
	return out


func start_hook(n: String) -> void:
	if fish.has(n):
		hook = {"name": n, "t": 0.0}


func _new_fish(n: String, fry: bool) -> Dictionary:
	var h := absi(n.hash())
	var cols: Array = BRANDS.get(n, [])
	if cols.is_empty():
		var base := Color.from_hsv(float(h % 360) / 360.0, 0.55 + float(h % 7) * 0.04, 0.85)
		cols = [base, Color.from_hsv(fmod(float(h % 360) / 360.0 + 0.5, 1.0), 0.45, 0.95)]
	var school := []
	if fry:
		for i in 9:
			school.append(Vector2(randf_range(-22, 22), randf_range(-9, 9)))
	var lo := level_y()
	return {
		"name": n, "fry": fry, "mem": 0.0, "count": 0, "share": 0.0,
		"rx": 3.0, "trx": 3.0, "alpha": 0.0, "dead": false, "dead_t": 0.0,
		"pos": Vector2(randf_range(TANK.position.x + 30, TANK.end.x - 30), lo + 6.0),
		"vel": Vector2(randf_range(6, 14) * (1 if h % 2 else -1), 0),
		"face": 1.0 if h % 2 else -1.0,
		"phase": randf() * TAU,
		"c1": cols[0], "c2": cols[1],
		"pattern": h % 3,          # 0 plain, 1 stripes, 2 spots
		"lane": float(h % 1000) / 1000.0,  # preferred depth, so fish spread through the water
		"school": school,
	}


func _process(delta: float) -> void:
	t += delta
	var water_h := TANK.size.y - 2.0
	shown_level = lerpf(shown_level, used_frac * water_h, minf(1.0, delta * 1.5))
	shown_sludge = lerpf(shown_sludge, maxf(2.0, sludge_frac * water_h), minf(1.0, delta * 1.5))
	_move_fish(delta)
	_move_hook(delta)
	_move_bits(delta)
	queue_redraw()


func _move_fish(delta: float) -> void:
	var gone := []
	var top := level_y()
	var floor_y := sludge_y()
	var crowded := used_frac > 0.85
	for n in fish:
		var f: Dictionary = fish[n]
		f.phase += delta * (9.0 if crowded else 6.0)
		f.rx = lerpf(f.rx, f.trx, minf(1.0, delta * 2.0))
		var ry: float = f.rx * 0.6
		if f.dead:
			f.dead_t += delta
			f.pos.y = lerpf(f.pos.y, top + ry * 0.3, minf(1.0, delta * 1.2))
			f.alpha = clampf(1.0 - (f.dead_t - 2.5) / 2.0, 0.0, 1.0)
			if f.alpha <= 0.0:
				gone.append(n)
			continue
		if not hook.is_empty() and hook.name == n:
			continue
		f.alpha = minf(1.0, f.alpha + delta)
		f.pos.x += f.vel.x * delta
		var tail: float = f.rx * 1.4 if not f.fry else 26.0
		var lo_x := TANK.position.x + tail
		var hi_x := TANK.end.x - tail
		if f.pos.x < lo_x:
			f.vel.x = absf(f.vel.x)
		elif f.pos.x > hi_x:
			f.vel.x = -absf(f.vel.x)
		if lo_x > hi_x:
			f.pos.x = TANK.get_center().x
		f.face = signf(f.vel.x)
		var pad := ry + 3.0 if not f.fry else 12.0
		var lo_y := top + pad
		var hi_y := floor_y - pad
		var want := lerpf(lo_y, hi_y, clampf(f.lane + 0.12 * sin(f.phase * 0.05), 0.0, 1.0))
		if lo_y > hi_y:
			want = (top + floor_y) * 0.5
		f.pos.y = lerpf(f.pos.y, want + sin(f.phase * 0.5) * 1.5, minf(1.0, delta * 0.8))
		if randf() < delta * 0.05:
			f.vel.x = -f.vel.x
		if randf() < delta * 0.4 and f.pos.y > top + 4:
			bubbles.append({"p": f.pos + Vector2(f.face * f.rx, -2), "v": -12.0, "r": 1.0, "skull": false})
	for n in gone:
		fish.erase(n)


func _move_hook(delta: float) -> void:
	if hook.is_empty():
		return
	if not fish.has(hook.name):
		hook = {}
		return
	hook.t += delta
	var f: Dictionary = fish[hook.name]
	if hook.t > 0.7:
		var before: float = f.pos.y
		f.pos.y -= delta * (40.0 + (hook.t - 0.7) * 160.0)
		f.pos.x += sin(hook.t * 30.0) * 0.6
		if before >= level_y() and f.pos.y < level_y():
			for i in 10:
				splashes.append({"p": Vector2(f.pos.x, level_y()), "v": Vector2(randf_range(-40, 40), randf_range(-70, -30)), "life": 0.8})
		if f.pos.y < -f.rx * 2.0:
			var n: String = hook.name
			fish.erase(n)
			hook = {}
			reeled_in.emit(n)


func _move_bits(delta: float) -> void:
	var top := level_y()
	var sludge_top := sludge_y()
	if randf() < delta * 1.5:
		bubbles.append({"p": Vector2(randf_range(TANK.position.x + 6, TANK.end.x - 6), sludge_top), "v": -8.0, "r": 1.0, "skull": false})
	if sludge_bytes > SLUDGE_ALARM and randf() < delta * 0.5:
		bubbles.append({"p": Vector2(randf_range(TANK.position.x + 10, TANK.end.x - 10), sludge_top - 2), "v": -6.0, "r": 0.0, "skull": true})
	for b in bubbles:
		b.p.y += b.v * delta
		b.p.x += sin(t * 3.0 + b.p.y * 0.2) * 0.15
	bubbles = bubbles.filter(func(b): return b.p.y > top + 1.0)
	if used_frac > 0.92 and randf() < delta * 6.0:
		var side := TANK.position.x - 3.0 if randf() < 0.5 else TANK.end.x + 3.0
		drops.append({"p": Vector2(side, TANK.position.y - 2.0), "v": 0.0})
	for d in drops:
		d.v += 200.0 * delta
		d.p.y += d.v * delta
	drops = drops.filter(func(d): return d.p.y < H - 4.0)
	for s in splashes:
		s.v.y += 220.0 * delta
		s.p += s.v * delta
		s.life -= delta
	splashes = splashes.filter(func(s): return s.life > 0.0)


func _draw() -> void:
	_room()
	var top := level_y()
	var sludge_top := sludge_y()
	# air inside the glass
	draw_rect(TANK, Color("eaf6ff"))
	# water, darker with depth and murkier as it fills
	var murk := clampf((used_frac - 0.6) / 0.35, 0.0, 1.0)
	var shallow := Color("5cb8e6").lerp(Color("4fa38f"), murk)
	var deep := Color("1d5a9e").lerp(Color("1f5a4c"), murk)
	var bands := 12
	var water_h := TANK.end.y - top
	for i in bands:
		var y0 := top + water_h * i / bands
		draw_rect(Rect2(TANK.position.x, y0, TANK.size.x, water_h / bands + 1.0), shallow.lerp(deep, float(i) / bands))
	_light_rays(top)
	_sludge(sludge_top)
	for b in bubbles:
		_bubble(b)
	var order := fish.keys()
	order.sort_custom(func(a, b): return fish[a].rx > fish[b].rx)
	for n in order:
		var f: Dictionary = fish[n]
		if f.fry:
			_school(f)
		else:
			_fish(f)
	_surface(top)
	_hook_line()
	for s in splashes:
		draw_rect(Rect2(s.p.round(), Vector2.ONE * 2), Color(0.85, 0.95, 1.0, clampf(s.life * 2.0, 0.0, 1.0)))
	_glass()
	for d in drops:
		draw_rect(Rect2(d.p.round(), Vector2(1, 3)), Color("5cb8e6"))


func _room() -> void:
	draw_rect(Rect2(0, 0, W, H), WALL)
	for x in range(0, W, 16):
		draw_rect(Rect2(x, 0, 6, H), WALL_STRIPE)
	draw_rect(Rect2(0, H - 14, W, 14), WOOD_DARK)
	draw_rect(Rect2(4, TANK.end.y + 2, W - 8, 8), WOOD)
	draw_rect(Rect2(4, TANK.end.y + 2, W - 8, 2), WOOD_LIGHT)
	draw_rect(Rect2(4, TANK.end.y + 10, W - 8, 1), OUTLINE)
	if used_frac > 0.92:  # puddle where the overflow lands
		var w := 20.0 + 10.0 * sin(t)
		draw_rect(Rect2(TANK.position.x - 12 - w * 0.5, TANK.end.y + 2, w, 2), Color("5cb8e6"))
		draw_rect(Rect2(TANK.end.x + 12 - w * 0.5, TANK.end.y + 2, w, 2), Color("5cb8e6"))


func _light_rays(top: float) -> void:
	for i in 4:
		var x := TANK.position.x + 40 + i * 70 + sin(t * 0.3 + i) * 8
		var pts := PackedVector2Array([Vector2(x, top), Vector2(x + 14, top), Vector2(x + 44, TANK.end.y), Vector2(x + 22, TANK.end.y)])
		draw_colored_polygon(pts, Color(1, 1, 1, 0.05))


func _surface(top: float) -> void:
	var pts := PackedVector2Array()
	var x := TANK.position.x
	while x <= TANK.end.x:
		pts.append(Vector2(x, roundf(top + sin(t * 2.0 + x * 0.12) * 0.8)))
		x += 2.0
	draw_polyline(pts, Color(0.92, 0.98, 1.0, 0.9), 1.0)


func _sludge(sludge_top: float) -> void:
	var pts := PackedVector2Array([Vector2(TANK.position.x, TANK.end.y)])
	var x := TANK.position.x
	while x <= TANK.end.x:
		pts.append(Vector2(x, minf(TANK.end.y - 1.0, sludge_top + sin(x * 0.21 + t * 0.6) * 1.5 + sin(x * 0.07) * 1.0)))
		x += 3.0
	pts[pts.size() - 1].x = TANK.end.x - 0.5
	pts.append(Vector2(TANK.end.x, TANK.end.y))
	var col := SLUDGE.lerp(SLUDGE_TOXIC, 0.35 if sludge_bytes > SLUDGE_ALARM else 0.0)
	draw_colored_polygon(pts, col)
	for i in 14:
		var px := TANK.position.x + 8 + (i * 37) % int(TANK.size.x - 16)
		var py := lerpf(sludge_top + 3, TANK.end.y - 2, float((i * 13) % 7) / 7.0)
		if py < TANK.end.y - 1:
			draw_rect(Rect2(px, py, 2, 1), SLUDGE_DARK)
	# seaweed growing out of it
	for i in 5:
		var bx := TANK.position.x + 24 + i * 60
		var prev := Vector2(bx, TANK.end.y)
		for s in 7:
			var p := Vector2(bx + sin(t * 1.4 + s * 0.6 + i) * (s * 0.5), TANK.end.y - (s + 1) * 4.0)
			draw_line(prev, p, Color("2e7d32"), 2.0)
			prev = p


func _bubble(b: Dictionary) -> void:
	if b.skull:
		var p: Vector2 = b.p.round()
		draw_rect(Rect2(p + Vector2(-2, -2), Vector2(5, 4)), Color("e9edd8"))
		draw_rect(Rect2(p + Vector2(-1, 2), Vector2(3, 1)), Color("e9edd8"))
		draw_rect(Rect2(p + Vector2(-1, -1), Vector2.ONE), OUTLINE)
		draw_rect(Rect2(p + Vector2(1, -1), Vector2.ONE), OUTLINE)
		return
	draw_arc(b.p.round(), b.r + 0.5, 0, TAU, 8, Color(1, 1, 1, 0.7), 1.0)


func _fish(f: Dictionary) -> void:
	var rx: float = f.rx
	var ry: float = rx * 0.6
	var dead: bool = f.dead
	var hooked: bool = not hook.is_empty() and hook.name == f.name
	var squeeze := 1.0 + (0.06 * sin(f.phase * 1.3) if used_frac > 0.85 else 0.0)
	draw_set_transform(f.pos.round(), 0.0, Vector2(f.face, -1.0 if dead else 1.0) * Vector2(1.0, squeeze))
	var a: float = f.alpha
	var c1: Color = f.c1
	var c2: Color = f.c2
	var ol := Color(OUTLINE, a)
	c1.a = a
	c2.a = a
	var wig := sin(f.phase * (3.0 if hooked else 1.0)) * ry * (0.6 if hooked else 0.25)
	var tail := PackedVector2Array([Vector2(-rx * 0.85, 0), Vector2(-rx * 1.45, -ry * 0.85 + wig), Vector2(-rx * 1.3, wig), Vector2(-rx * 1.45, ry * 0.85 + wig)])
	var fin := PackedVector2Array([Vector2(-rx * 0.45, -ry * 0.8), Vector2(rx * 0.15, -ry * 0.92), Vector2(-rx * 0.55, -ry * 1.45)])
	# outline pass then fill pass, like the genie
	for o in [1.0, 0.0]:
		var col_body := ol if o else c1
		draw_colored_polygon(_grow(tail, o), ol if o else c2)
		draw_colored_polygon(_grow(fin, o), ol if o else c2)
		_ellipse(Vector2.ZERO, rx + o, ry + o, col_body)
	if f.share > 0.08 and not dead:  # puffed up hogs get spikes
		for i in 14:
			var ang := TAU * i / 14.0
			var p0 := Vector2(cos(ang) * rx, sin(ang) * ry)
			draw_line(p0, p0 * 1.18, ol, 1.0)
	_ellipse(Vector2(rx * 0.05, ry * 0.4), rx * 0.75, ry * 0.42, Color(c1.lightened(0.35), a))
	match int(f.pattern):
		1:
			for k in 3:
				var sx := -rx * 0.45 + k * rx * 0.4
				var hh := ry * sqrt(maxf(0.0, 1.0 - pow(sx / rx, 2)))
				draw_rect(Rect2(sx, -hh, maxf(1.0, rx * 0.12), hh * 2.0), c2)
		2:
			for k in 4:
				var sp := Vector2(-rx * 0.5 + (k % 2) * rx * 0.45 + k * rx * 0.08, -ry * 0.35 + (k / 2) * ry * 0.45)
				draw_circle(sp, maxf(1.0, rx * 0.09), c2, true, -1.0, false)
	# face
	var eye := Vector2(rx * 0.55, -ry * 0.22)
	var er := maxf(1.5, ry * 0.2)
	if dead:
		draw_line(eye + Vector2(-er, -er), eye + Vector2(er, er), ol, 1.0)
		draw_line(eye + Vector2(-er, er), eye + Vector2(er, -er), ol, 1.0)
	else:
		draw_circle(eye, er, Color(1, 1, 1, a), true, -1.0, false)
		var look := Vector2(er * 0.35, -er * 0.4 if used_frac > 0.85 or hooked else 0.0)
		draw_circle(eye + look, maxf(0.8, er * 0.5), ol, true, -1.0, false)
	var mouth := Vector2(rx * 0.92, ry * 0.2)
	if hooked or used_frac > 0.85:
		draw_circle(mouth, maxf(1.0, ry * 0.1), ol, true, -1.0, false)
	else:
		draw_line(mouth + Vector2(-rx * 0.12, 0), mouth, ol, 1.0)
	if used_frac > 0.85 and not dead and rx > 6.0:  # sweat drop
		var sd := Vector2(rx * 0.25, -ry * 1.05 - fmod(t * 6.0, 4.0))
		draw_circle(sd, 1.2, Color(0.75, 0.9, 1.0, a), true, -1.0, false)
	draw_set_transform(Vector2.ZERO)


func _school(f: Dictionary) -> void:
	var c1: Color = f.c1
	c1.a = f.alpha
	for i in f.school.size():
		var m: Vector2 = f.school[i]
		var p: Vector2 = (f.pos + m + Vector2(sin(t * 2.0 + i) * 2.0, cos(t * 1.7 + i) * 1.5)).round()
		var s: float = f.face
		draw_rect(Rect2(p + Vector2(-2, -1), Vector2(4, 3)), Color(OUTLINE, f.alpha))
		draw_rect(Rect2(p + Vector2(-1, 0), Vector2(3, 1)), c1)
		draw_rect(Rect2(p + Vector2(-3.0 * s - (1 if s < 0 else 0), -1), Vector2(1, 3)), Color(OUTLINE, f.alpha))
		draw_rect(Rect2(p + Vector2(1.0 * s, -1), Vector2.ONE), Color.WHITE)


func _hook_line() -> void:
	if hook.is_empty() or not fish.has(hook.name):
		return
	var f: Dictionary = fish[hook.name]
	var mouth: Vector2 = f.pos + Vector2(f.face * f.rx * 0.92, f.rx * 0.12)
	var tip := mouth
	if hook.t < 0.7:
		tip = Vector2(mouth.x, lerpf(-4.0, mouth.y, hook.t / 0.7))
	draw_line(Vector2(tip.x, -4), tip.round(), Color("2a2a2a"), 1.0)
	draw_arc(tip.round() + Vector2(0, 2), 2.0, 0.0, PI, 6, Color("c0c0c8"), 1.0)


func _glass() -> void:
	var r := TANK.grow(2.0)
	draw_rect(r, GLASS_EDGE, false, 2.0)
	draw_rect(Rect2(r.position.x - 2, r.position.y - 3, r.size.x + 4, 3), Color("1f3550"))
	draw_rect(Rect2(TANK.position.x + 6, TANK.position.y + 6, 2, TANK.size.y - 24), GLASS)
	draw_rect(Rect2(TANK.position.x + 10, TANK.position.y + 6, 1, TANK.size.y * 0.4), GLASS)


func _ellipse(c: Vector2, rx: float, ry: float, col: Color) -> void:
	var pts := PackedVector2Array()
	for i in 20:
		var a := TAU * i / 20.0
		pts.append(c + Vector2(cos(a) * rx, sin(a) * ry))
	draw_colored_polygon(pts, col)


func _grow(poly: PackedVector2Array, o: float) -> PackedVector2Array:
	if o == 0.0:
		return poly
	var c := Vector2.ZERO
	for p in poly:
		c += p
	c /= poly.size()
	var out := PackedVector2Array()
	for p in poly:
		out.append(p + (p - c).normalized() * o)
	return out
