--!nocheck
-- Run: sh tests/run-flow.sh   (bundles the modules: the luau CLI won't let a script define the global `tern`)
-- Drives the real host.luau against a fake `tern` runtime (clock, timers, fetch, process, kv)
-- and a scripted Spotify, to exercise sign-in, refresh, polling, controls, search and errors.

-- Fake runtime ---------------------------------------------------------------------------------

local clock = 0
local timers = {}
local reads = {} -- path -> how many times the plugin read it
local queue = {} -- completed async work (fetch/process callbacks) waiting to run
local fetch_log = {}
local routes = {} -- "METHOD host/path" -> function(req) -> { status, headers?, body? }
local kv = {}
local pending_nc = nil
local nc_port = nil -- the port the latest `nc` listener was asked for
local opened = {}
local copied = nil -- the last text sent to the clipboard
local blob_log = {} -- every cx:blob call: { bytes, mime }
local files, dirs = {}, {} -- the fake file system: path -> text, and the directories made
local env = { HOME = "/Users/test" }
local proc_log = {} -- every tern.process.run: { argv, opts }
local proc_handler = nil -- (argv, opts) -> result table | "hold" | nil (default behaviour)
local proc_held = {} -- runs a handler asked to "hold": { argv, cb }, finished by the test
local rand = string.rep("A", 86) .. string.rep("B", 22)

local function jenc(v)
	local t = type(v)
	if t == "nil" then
		return "null"
	elseif t == "boolean" or t == "number" then
		return tostring(v)
	elseif t == "string" then
		return '"' .. (string.gsub(v, '[%c"\\]', function(c)
			return string.format("\\u%04x", string.byte(c))
		end)) .. '"'
	end
	if #v > 0 or next(v) == nil then
		local out = {}
		for i, x in v do
			out[i] = jenc(x)
		end
		return "[" .. table.concat(out, ",") .. "]"
	end
	local out = {}
	for k, x in v do
		table.insert(out, jenc(tostring(k)) .. ":" .. jenc(x))
	end
	table.sort(out)
	return "{" .. table.concat(out, ",") .. "}"
end

local function jdec(s)
	local i = 1
	local function ws()
		i = string.find(s, "[^ \n\r\t]", i) or #s + 1
	end
	local value
	local function str()
		local out = {}
		i += 1
		while true do
			local c = string.sub(s, i, i)
			if c == '"' then
				i += 1
				return table.concat(out)
			elseif c == "\\" then
				local e = string.sub(s, i + 1, i + 1)
				if e == "u" then
					table.insert(out, utf8.char(tonumber(string.sub(s, i + 2, i + 5), 16)))
					i += 6
				else
					table.insert(out, ({ n = "\n", t = "\t", r = "\r" })[e] or e)
					i += 2
				end
			else
				table.insert(out, c)
				i += 1
			end
		end
	end
	function value()
		ws()
		local c = string.sub(s, i, i)
		if c == "{" then
			local obj = {}
			i += 1
			ws()
			if string.sub(s, i, i) == "}" then
				i += 1
				return obj
			end
			while true do
				ws()
				local k = str()
				ws()
				i += 1 -- :
				obj[k] = value()
				ws()
				local d = string.sub(s, i, i)
				i += 1
				if d == "}" then
					return obj
				end
			end
		elseif c == "[" then
			local arr = {}
			i += 1
			ws()
			if string.sub(s, i, i) == "]" then
				i += 1
				return arr
			end
			while true do
				table.insert(arr, value())
				ws()
				local d = string.sub(s, i, i)
				i += 1
				if d == "]" then
					return arr
				end
			end
		elseif c == '"' then
			return str()
		elseif string.sub(s, i, i + 3) == "true" then
			i += 4
			return true
		elseif string.sub(s, i, i + 4) == "false" then
			i += 5
			return false
		elseif string.sub(s, i, i + 3) == "null" then
			i += 4
			return nil
		end
		local num = string.match(s, "^-?[%d.eE+-]+", i)
		i += #num
		return tonumber(num)
	end
	return value()
end

local function form(body)
	local out = {}
	for k, v in string.gmatch(body or "", "([^&=]+)=([^&]*)") do
		out[k] = (string.gsub(v, "%%(%x%x)", function(h)
			return string.char(tonumber(h, 16))
		end))
	end
	return out
end

local function span(t, s)
	return { t = t, s = s }
end
local function node(k, p, c)
	return { k = k, p = p, c = c }
end

local ui = {
	span = span,
	link = function(t, href, s)
		return { t = t, s = s, href = href }
	end,
	text = function(spans)
		return node("text", { spans = spans })
	end,
	col = function(c)
		return node("col", { gap = "sm" }, c)
	end,
	row = function(c)
		return node("row", { gap = "sm" }, c)
	end,
	card = function(head, c)
		return node("card", { head = head }, c)
	end,
	badge = function(t, tone)
		return node("badge", { text = t, tone = tone })
	end,
	list = function(items)
		local c = {}
		for i, it in items do
			c[i] = node("item", it)
		end
		return node("list", {}, c)
	end,
	node = node,
	el = function(tag, p, c)
		local props = { tag = tag }
		for k, v in p or {} do
			props[k] = v
		end
		return node("el", props, c)
	end,
}

local blocks = {}
local panes = { { pane = 1 } }
local pane_lists = 0 -- how many times the plugin listed the panes (`alive` does, on every timer wakeup)

local warnings = {}
local tern = {
	log = {
		debug = function() end,
		info = function() end,
		warn = function(...)
			table.insert(warnings, table.concat({ ... }, " "))
		end,
		error = function() end,
	},
	ui = ui,
	json = {
		encode = jenc,
		decode = jdec,
		null = setmetatable({}, { __tostring = function() return "null" end }),
	},
	now = function()
		return clock
	end,
	getenv = function(k)
		return env[k]
	end,
	plugin = { data = "/tmp/spotify-test-data" },
	runtime = { os = "macos", jit = false },
	fs = {
		list = function(dir)
			local prefix, seen, out = dir .. "/", {}, {}
			local function add(k)
				if string.sub(k, 1, #prefix) == prefix then
					local name = string.match(string.sub(k, #prefix + 1), "^[^/]+")
					if name and not seen[name] then
						seen[name] = true
						table.insert(out, name)
					end
				end
			end
			for k in files do
				add(k)
			end
			for k in dirs do
				add(k)
			end
			if not dirs[dir] and #out == 0 then
				error("no such directory: " .. dir)
			end
			table.sort(out)
			return out
		end,
		exists = function(p)
			if files[p] ~= nil or dirs[p] ~= nil then
				return true
			end
			for k in files do
				if string.sub(k, 1, #p + 1) == p .. "/" then
					return true -- a directory exists when something is in it
				end
			end
			return false
		end,
		read = function(p)
			if files[p] == nil then
				error("no such file: " .. p)
			end
			reads[p] = (reads[p] or 0) + 1
			return files[p]
		end,
		write = function(p, text)
			files[p] = text
		end,
		mkdir = function(p)
			dirs[p] = true
		end,
		remove = function(p)
			files[p], dirs[p] = nil, nil
			for k in files do
				if string.sub(k, 1, #p + 1) == p .. "/" then
					files[k] = nil
				end
			end
			for k in dirs do
				if string.sub(k, 1, #p + 1) == p .. "/" then
					dirs[k] = nil
				end
			end
		end,
	},
	kv = {
		get = function(k)
			return kv[k]
		end,
		set = function(k, v)
			kv[k] = v
		end,
	},
	pane = {
		list = function()
			pane_lists += 1
			return panes
		end,
	},
	block = {
		define = function(id, def)
			blocks[id] = def
		end,
	},
	timer = function(ms, fn)
		local t = { at = clock + math.max(0, ms), fn = fn, live = true }
		table.insert(timers, t)
		return {
			cancel = function()
				t.live = false
			end,
		}
	end,
	fetch = function(url, opts, cb)
		local host, path, query = string.match(url, "^https?://([^/?]+)([^?]*)%??(.*)$")
		local req = {
			method = string.upper(opts.method or "GET"),
			url = url,
			host = host,
			path = path,
			query = form(query),
			headers = opts.headers or {},
			body = opts.body,
		}
		table.insert(fetch_log, req)
		local handler = routes[req.method .. " " .. host .. path]
		local res = handler and handler(req) or { status = 599, body = "no route" }
		table.insert(queue, function()
			cb({ status = res.status or 200, headers = res.headers or {}, body = res.body or "", error = res.error, timed_out = false })
		end)
	end,
	process = {
		run = function(argv, opts, cb)
			if type(opts) == "function" then
				cb, opts = opts, {}
			end
			table.insert(proc_log, { argv = argv, opts = opts })
			if proc_handler then
				local r = proc_handler(argv, opts)
				if r == "hold" then
					table.insert(proc_held, { argv = argv, cb = cb })
					return
				elseif r then
					table.insert(queue, function()
						cb({ status = r.status or 0, stdout = r.stdout or "", stderr = r.stderr or "", timed_out = r.timed_out or false })
					end)
					return
				end
			end
			if argv[1] == "sh" then
				table.insert(queue, function()
					cb({ status = 0, stdout = rand, stderr = "", timed_out = false })
				end)
			elseif argv[1] == "nc" then
				pending_nc = cb
				nc_port = argv[4]
			else
				table.insert(queue, function()
					cb({ status = 0, stdout = "", stderr = "", timed_out = false })
				end)
			end
		end,
	},
}

local function settle()
	local guard = 0
	while #queue > 0 do
		guard += 1
		assert(guard < 1000, "async loop did not settle")
		table.remove(queue, 1)()
	end
end

local function advance(ms)
	local target = clock + ms
	while true do
		local best
		for _, t in timers do
			if t.live and t.at <= target and (not best or t.at < best.at) then
				best = t
			end
		end
		if not best then
			break
		end
		best.live = false
		clock = math.max(clock, best.at)
		best.fn()
		settle()
	end
	clock = target
end

-- Harness --------------------------------------------------------------------------------------

local failures = 0
local function check(name, ok, detail)
	if not ok then
		failures += 1
		print(`FAIL {name}{if detail then ": " .. tostring(detail) else ""}`)
	end
end

local renders = 0 -- how many times the block asked for a render
local frame_log = {} -- the ops the block sent to the pane (focus, mostly)

local cx = {
	pane = 1,
	cols = 80,
	rows = 24,
	render = function()
		renders += 1
	end,
	save = function() end,
	exit = function() end,
	frame = function(_, ops)
		table.insert(frame_log, ops)
	end,
	blob = function(_, bytes, mime)
		table.insert(blob_log, { bytes = bytes, mime = mime })
		return "blob:" .. #blob_log .. ":" .. mime
	end,
	toast = function() end,
	open = function(_, target)
		table.insert(opened, target)
	end,
	copy = function(_, text)
		copied = text
	end,
}

local function strings(n, out)
	out = out or {}
	if type(n) == "string" then
		table.insert(out, n)
	elseif type(n) == "table" then
		for _, v in n do
			strings(v, out)
		end
	end
	return out
end

local function find_key(n, key)
	if type(n) ~= "table" then
		return nil
	end
	if n.p and n.p.key == key then
		return n
	end
	for _, v in n do
		local r = find_key(v, key)
		if r then
			return r
		end
	end
	return nil
end

local function view_text(def, state)
	local v = def.view(state, cx) -- must never raise, in any phase
	return table.concat(strings(v), " | ")
end

local function K(name, text)
	return { name = name, text = text, ctrl = false, alt = false, shift = text ~= nil and text ~= string.lower(text), meta = false }
end

local function calls(method, path)
	local out = {}
	for _, r in fetch_log do
		if r.method == method and r.path == path then
			table.insert(out, r)
		end
	end
	return out
end

local function reset()
	clock, timers, queue, fetch_log, kv, pending_nc, opened = 0, {}, {}, {}, {}, nil, {}
	blob_log = {}
	copied = nil
	files, dirs, proc_log, proc_handler, proc_held = {}, {}, {}, nil, {}
	env = { HOME = "/Users/test" }
	routes = {}
end

--@modules
local pkce = require("../pkce")
local spotify = require("../spotify")
require("../host")
local def = blocks["web-player"]
assert(def, "host.luau did not define block `web-player`")

local CLIENT_ID = string.rep("ab12", 8)
local KEYMASTER_ID = "65b708073fc0480ea92a077233ca87bd"
-- The redirect each client id has registered: the token endpoint refuses any other.
local REDIRECT_OF = {
	[CLIENT_ID] = "http://127.0.0.1:43821/callback",
	[KEYMASTER_ID] = "http://127.0.0.1:8000/login",
}
local token_n = 0

local function playback(over)
	local p = {
		device = { id = "dev1", name = "MacBook", type = "Computer", is_active = true, volume_percent = 40, supports_volume = true },
		repeat_state = "off",
		shuffle_state = false,
		is_playing = true,
		progress_ms = 30000,
		item = {
			type = "track",
			uri = "spotify:track:t1",
			name = "Song",
			duration_ms = 200000,
			artists = { { name = "A" }, { name = "B" } },
			album = { name = "Album", images = { { url = "https://img.test/640", width = 640 }, { url = "https://img.test/300", width = 300 } } },
			external_urls = { spotify = "https://open.spotify.com/track/t1" },
		},
	}
	for k, v in over or {} do
		p[k] = v
	end
	return p
end

local function ok(status, body, headers)
	return { status = status, body = body and jenc(body) or "", headers = headers }
end

-- A scripted Spotify: token endpoint (checks PKCE), player state, image.
local current = playback()
local current_at = 0
local function set_current(p)
	current, current_at = p, clock
end
local token_scope = "user-read-playback-state user-modify-playback-state" -- what the token replies say was granted
local function spotify_routes()
	routes["POST accounts.spotify.com/api/token"] = function(req)
		local f = form(req.body)
		token_n += 1
		if f.grant_type == "authorization_code" then
			if f.code ~= "CODE1" or pkce.challenge(f.code_verifier) == nil or REDIRECT_OF[f.client_id] ~= f.redirect_uri then
				return ok(400, { error = "invalid_grant" })
			end
			return ok(200, { access_token = "AT" .. token_n, expires_in = 3600, refresh_token = "RT1", scope = token_scope })
		elseif f.grant_type == "refresh_token" then
			if f.refresh_token ~= "RT1" then
				return ok(400, { error = "invalid_grant", error_description = "Refresh token revoked" })
			end
			return ok(200, { access_token = "AT" .. token_n, expires_in = 3600, scope = token_scope })
		end
		return ok(400, { error = "unsupported_grant_type" })
	end
	routes["GET api.spotify.com/v1/me/player"] = function(req)
		if not string.find(req.headers.Authorization or "", "^Bearer AT") then
			return ok(401, { error = { status = 401, message = "The access token expired" } })
		end
		if current == nil then
			return { status = 204 }
		end
		local snapshot = {}
		for k, v in current do
			snapshot[k] = v
		end
		if snapshot.is_playing then -- the server's playhead moves with the clock
			snapshot.progress_ms += clock - current_at
		end
		return ok(200, snapshot)
	end
	routes["GET img.test/300"] = function()
		return { status = 200, body = "IMGBYTES", headers = { ["content-type"] = "image/jpeg; charset=x" } }
	end
	for _, p in { "/v1/me/player/pause", "/v1/me/player/play", "/v1/me/player/next", "/v1/me/player/previous", "/v1/me/player/seek", "/v1/me/player/volume", "/v1/me/player/shuffle", "/v1/me/player/repeat", "/v1/me/player" } do
		routes["PUT api.spotify.com" .. p] = function()
			return { status = 204 }
		end
		routes["POST api.spotify.com" .. p] = routes["PUT api.spotify.com" .. p]
	end
end

local function signed_in_player()
	reset()
	spotify_routes()
	set_current(playback())
	kv.client_id, kv.refresh_token = CLIENT_ID, "RT1"
	local state = def.init(cx, {}, nil)
	settle()
	return state
end

-- 1. First run: the choice of how to sign in, then the user's own Client ID -> login prompt.
do
	reset()
	local state = def.init(cx, {}, nil)
	local text = view_text(def, state)
	check("first run: offers the choice", state.phase == "setup" and state.setup == "choose")
	check("first run: says Premium is required", string.find(text, "Requires Spotify Premium", 1, true) ~= nil, text)
	check("first run: both ways offered", string.find(text, "Your own Client ID", 1, true) ~= nil and string.find(text, "Keymaster", 1, true) ~= nil)
	check("first run: nothing stored yet", kv.auth_mode == nil and kv.client_id == nil)
	def.event(state, { ev = "action", act = "copy" }, cx)
	local opened_before = #opened
	def.key(state, K("f", "f"), cx)
	check("first run: the copy click and the window keys do nothing before Spotify is connected", copied == nil and #opened == opened_before)
	def.key(state, K("1", "1"), cx)
	text = view_text(def, state)
	check("own: setup screen", state.setup == "own" and state.phase == "setup")
	check("own: shows redirect uri", string.find(text, "http://127.0.0.1:43821/callback", 1, true) ~= nil)
	def.event(state, { ev = "action", act = "copy" }, cx)
	check("own: a click on the redirect uri copies it", copied == "http://127.0.0.1:43821/callback", copied)
	advance(40) -- the focus op runs after the render that mounts the field
	local setup_box = find_key(def.view(state, cx), "setup_box")
	local on_box = false
	for _, c in if setup_box then setup_box.c or {} else {} do
		on_box = on_box or (c.p ~= nil and c.p.key == "client")
	end
	local focus = frame_log[#frame_log]
	check("own: the Client ID input hangs from the keyed panel, and choosing the screen focuses it by that id", on_box and focus ~= nil and focus[1][1] == "focus" and focus[1][2] == "main.setup_box.client", focus and focus[1][2])
	def.event(state, { ev = "action", act = "back" }, cx)
	check("own: there is no back badge while setting up, a stray back does nothing", state.phase == "setup" and state.setup == "own")
	check("own: says Premium is required", string.find(text, "Requires Spotify Premium", 1, true) ~= nil)
	def.key(state, K("enter"), cx)
	check("own: empty id rejected", state.phase == "setup" and state.err ~= nil)
	def.key(state, { name = "paste", text = " " .. string.upper(CLIENT_ID) .. "\n", ctrl = false, alt = false, shift = false, meta = false }, cx)
	def.key(state, K("enter"), cx)
	check("own: valid id moves to login", state.phase == "login" and state.auth == "own", state.phase)
	check("own: id persisted lowercased", kv.client_id == CLIENT_ID, kv.client_id)
	check("own: mode persisted", kv.auth_mode == "own")
	text = view_text(def, state)
	check("login view mentions client id", string.find(text, CLIENT_ID, 1, true) ~= nil)
	check("login view says Premium is required", string.find(text, "Requires Spotify Premium", 1, true) ~= nil)
end

-- 1b. Keymaster: the warning comes first and nothing is stored until it is accepted; then the sign-in
-- uses Spotify's desktop client id, its own redirect, and only the two playback scopes.
do
	reset()
	spotify_routes()
	local state = def.init(cx, {}, nil)
	def.key(state, K("2", "2"), cx)
	local text = view_text(def, state)
	check("keymaster: warning first", state.setup == "keymaster" and state.client == nil and string.find(text, "Read this first", 1, true) ~= nil, text)
	check("keymaster: warning says what it is", string.find(text, "Spotify's own desktop app", 1, true) ~= nil and string.find(text, "breaches Spotify's terms", 1, true) ~= nil)
	check("keymaster: warning says Premium is required", string.find(text, "Requires Spotify Premium", 1, true) ~= nil)
	check("keymaster: nothing stored before accepting", kv.auth_mode == nil and kv.keymaster_ack == nil)
	def.key(state, K("escape"), cx)
	check("keymaster: esc goes back to the choice", state.setup == "choose" and state.phase == "setup")

	-- The same path by clicks.
	def.event(state, { ev = "action", act = "mode_keymaster" }, cx)
	check("keymaster: click opens the warning", state.setup == "keymaster")
	def.event(state, { ev = "action", act = "keymaster_ok" }, cx)
	check("keymaster: accepted -> login with the desktop client id", state.phase == "login" and state.auth == "keymaster" and state.client_id == KEYMASTER_ID, state.phase)
	check("keymaster: choice remembered", kv.auth_mode == "keymaster" and kv.keymaster_ack == true and kv.client_id == nil)
	check("keymaster: login view names it", string.find(view_text(def, state), "Keymaster", 1, true) ~= nil)

	def.key(state, K("enter"), cx)
	settle()
	local url = opened[1] or ""
	check("keymaster: its client id", string.find(url, "client_id=" .. KEYMASTER_ID, 1, true) ~= nil, url)
	check("keymaster: its redirect", string.find(url, "redirect_uri=http%3A%2F%2F127.0.0.1%3A8000%2Flogin", 1, true) ~= nil, url)
	check("keymaster: only the playback scopes", string.find(url, "scope=user-read-playback-state", 1, true) ~= nil and string.find(url, "playlist", 1, true) == nil and string.find(url, "library", 1, true) == nil, url)
	check("keymaster: listens on its port", nc_port == "8000", nc_port)
	local good = pending_nc
	pending_nc = nil
	good({ status = 0, stdout = "GET /login?code=CODE1&state=" .. string.sub(rand, 87, 108) .. " HTTP/1.1\r\n", stderr = "", timed_out = false })
	settle()
	local exchange = calls("POST", "/api/token")[1]
	local sent = exchange and form(exchange.body) or {}
	check("keymaster: exchanged with its id and redirect", sent.client_id == KEYMASTER_ID and sent.redirect_uri == "http://127.0.0.1:8000/login", exchange and exchange.body)
	check("keymaster: signed in", state.phase == "ready" and kv.refresh_token == "RT1", state.phase .. " / " .. tostring(state.err))
end

-- 1c. Restarting keeps the way chosen, but never skips the warning, and an old install keeps working.
do
	reset()
	spotify_routes()
	set_current(playback())
	kv.auth_mode, kv.keymaster_ack, kv.refresh_token = "keymaster", true, "RT1"
	local state = def.init(cx, {}, nil)
	settle()
	check("restart: keymaster resumes", state.auth == "keymaster" and state.phase == "ready", state.phase)

	reset()
	kv.auth_mode = "keymaster" -- chosen, but the warning was never accepted
	state = def.init(cx, {}, nil)
	check("restart: no acceptance -> the choice again", state.phase == "setup" and state.setup == "choose" and state.client == nil)

	reset()
	spotify_routes()
	set_current(playback())
	kv.client_id, kv.refresh_token = CLIENT_ID, "RT1" -- what versions before the choice stored
	state = def.init(cx, {}, nil)
	settle()
	check("restart: an earlier install stays on its own Client ID", state.auth == "own" and state.phase == "ready", state.phase)
end

-- 1d. Changing the way in drops the token of the other one instead of refreshing it with the wrong id.
do
	reset()
	spotify_routes()
	kv.auth_mode, kv.keymaster_ack = "keymaster", true
	local state = def.init(cx, {}, nil)
	check("switch: starts on keymaster, signed out", state.phase == "login" and state.auth == "keymaster")
	kv.refresh_token, kv.scope = "STALE", "x"
	def.key(state, K("e", "e"), cx)
	check("switch: e opens the choice", state.phase == "setup" and state.setup == "choose")
	def.key(state, K("1", "1"), cx)
	def.key(state, { name = "paste", text = CLIENT_ID, ctrl = false, alt = false, shift = false, meta = false }, cx)
	def.key(state, K("enter"), cx)
	check("switch: now on its own id", state.auth == "own" and state.phase == "login" and kv.auth_mode == "own" and kv.client_id == CLIENT_ID, state.phase)
	check("switch: the other token is gone", kv.refresh_token == nil and kv.scope == nil)
end

-- 2. Full sign-in: PKCE challenge matches the verifier, state is checked, tokens stored, player loads.
do
	reset()
	spotify_routes()
	kv.client_id = CLIENT_ID
	local state = def.init(cx, {}, nil)
	check("signin: no token -> login", state.phase == "login")
	def.key(state, K("enter"), cx)
	settle()
	check("signin: opened browser once", #opened == 1)
	local url = opened[1] or ""
	check("signin: authorize url", string.find(url, "^https://accounts%.spotify%.com/authorize%?") ~= nil, url)
	check("signin: S256", string.find(url, "code_challenge_method=S256", 1, true) ~= nil)
	check("signin: redirect uri encoded", string.find(url, "redirect_uri=http%3A%2F%2F127.0.0.1%3A43821%2Fcallback", 1, true) ~= nil, url)
	check("signin: challenge is sha256(verifier)", string.find(url, "code_challenge=" .. pkce.challenge(string.sub(rand, 1, 86)), 1, true) ~= nil, url)
	check("signin: waiting for callback", state.waiting and pending_nc ~= nil)

	-- A stray request (favicon) must not end the wait; a second listener takes over.
	local stray = pending_nc
	pending_nc = nil
	stray({ status = 0, stdout = "GET /favicon.ico HTTP/1.1\r\n", stderr = "", timed_out = false })
	settle()
	check("signin: stray request re-listens", state.waiting and pending_nc ~= nil)

	local good = pending_nc
	pending_nc = nil
	good({ status = 0, stdout = "GET /callback?code=CODE1&state=" .. string.sub(rand, 87, 108) .. " HTTP/1.1\r\n", stderr = "", timed_out = false })
	settle()
	check("signin: reached ready", state.phase == "ready", state.phase .. " / " .. tostring(state.err))
	check("signin: refresh token stored", kv.refresh_token == "RT1")
	check("signin: not waiting", not state.waiting)
	check("signin: cover art loaded", state.art ~= nil and state.art.blob ~= nil and blob_log[1] ~= nil and blob_log[1].mime == "image/jpeg" and #blob_log[1].bytes == 8, state.art and state.art.blob)
	check("signin: art url is the 300px image", state.art and state.art.url == "https://img.test/300")
	local text = view_text(def, state)
	check("player view: track, artists, album", string.find(text, "Song") and string.find(text, "A, B") and string.find(text, "Album"))
	check("player view: progress", string.find(text, "0:30", 1, true) and string.find(text, "3:20", 1, true))
end

-- 3. A callback with the wrong state is refused and never exchanged.
do
	reset()
	spotify_routes()
	kv.client_id = CLIENT_ID
	local state = def.init(cx, {}, nil)
	def.key(state, K("enter"), cx)
	settle()
	pending_nc({ status = 0, stdout = "GET /callback?code=CODE1&state=forged HTTP/1.1\r\n", stderr = "", timed_out = false })
	settle()
	check("state mismatch: back to login with error", state.phase == "login" and state.err ~= nil and #calls("POST", "/api/token") == 0, state.err)
end

-- 4. Pasting the redirect URL works when the listener can't be reached.
do
	reset()
	spotify_routes()
	kv.client_id = CLIENT_ID
	local state = def.init(cx, {}, nil)
	def.key(state, K("enter"), cx)
	settle()
	pending_nc({ status = 1, stdout = "", stderr = "nc: Address already in use", timed_out = false })
	settle()
	check("listener failure surfaces a hint", not state.waiting and string.find(state.err or "", "Paste", 1, true) ~= nil, state.err)
	def.key(state, K("enter"), cx) -- start again so a login exists to paste into
	settle()
	def.key(state, { name = "paste", text = "http://127.0.0.1:43821/callback?code=CODE1&state=" .. string.sub(rand, 87, 108), ctrl = false, alt = false, shift = false, meta = false }, cx)
	settle()
	check("pasted redirect completes sign-in", state.phase == "ready", state.phase .. " / " .. tostring(state.err))
end

-- 5. Token lifecycle: refresh before expiry, retry once on 401, sign out on a revoked refresh token.
do
	local state = signed_in_player()
	check("lifecycle: ready from stored refresh token", state.phase == "ready", state.phase .. " / " .. tostring(state.err))
	local before = #calls("POST", "/api/token")
	advance(61 * 60 * 1000 - 5000) -- past the token's life (minus the 60s margin), polls keep running
	check("lifecycle: token refreshed after expiry", #calls("POST", "/api/token") > before)
	check("lifecycle: still ready", state.phase == "ready", state.err)

	state.client.token = "stale" -- the server says 401: one refresh, then the retry succeeds
	state.err = nil
	local polls, tokens = #calls("GET", "/v1/me/player"), #calls("POST", "/api/token")
	advance(6000)
	check("lifecycle: 401 refreshes exactly once", #calls("POST", "/api/token") == tokens + 1, #calls("POST", "/api/token") - tokens)
	check("lifecycle: 401 retried with the fresh token", #calls("GET", "/v1/me/player") >= polls + 2 and state.phase == "ready" and state.err == nil, state.err)

	kv.refresh_token = "revoked"
	state.client.token = nil
	advance(15000)
	check("lifecycle: revoked refresh token signs out", state.phase == "login" and kv.refresh_token == nil, state.phase)
	check("lifecycle: sign-out view renders", #view_text(def, state) > 0)
end

-- 6. Controls: optimistic state, correct endpoint, empty body on bodiless writes.
do
	local state = signed_in_player()
	def.key(state, K("space"), cx)
	check("pause: optimistic", state.playback.playing == false)
	settle()
	local pause = calls("PUT", "/v1/me/player/pause")
	check("pause: request sent with empty body", #pause == 1 and pause[1].body == "", pause[1] and tostring(pause[1].body))
	set_current(playback({ is_playing = false, progress_ms = 30000 }))
	advance(800)
	check("pause: reconciled from server", state.playback.playing == false)

	def.key(state, K("right"), cx)
	settle()
	local seek = calls("PUT", "/v1/me/player/seek")
	check("seek: +10s from interpolated position", #seek == 1 and seek[1].query.position_ms == "40000", seek[1] and seek[1].query.position_ms)

	def.key(state, K("+"), cx)
	settle()
	check("volume: +5", calls("PUT", "/v1/me/player/volume")[1].query.volume_percent == "45")
	def.key(state, K("m"), cx)
	settle()
	check("mute: sets 0", calls("PUT", "/v1/me/player/volume")[2].query.volume_percent == "0")
	def.key(state, K("m"), cx)
	settle()
	check("mute: restores", calls("PUT", "/v1/me/player/volume")[3].query.volume_percent == "45")

	def.key(state, K("s"), cx)
	settle()
	check("shuffle on", calls("PUT", "/v1/me/player/shuffle")[1].query.state == "true")
	def.key(state, K("r"), cx)
	def.key(state, K("r"), cx)
	def.key(state, K("r"), cx)
	settle()
	local reps = calls("PUT", "/v1/me/player/repeat")
	check("repeat cycles context,track,off", #reps == 3 and reps[1].query.state == "context" and reps[2].query.state == "track" and reps[3].query.state == "off")

	def.key(state, K("n"), cx)
	def.key(state, K("p"), cx)
	settle()
	check("next/previous use POST", #calls("POST", "/v1/me/player/next") == 1 and #calls("POST", "/v1/me/player/previous") == 1)

	def.key(state, K("o"), cx)
	check("o opens the track link", opened[#opened] == "https://open.spotify.com/track/t1")
	check("unbound key changes nothing", def.key(state, K("q"), cx) == false)

	local before = #opened
	check("z asks the window to park, without re-rendering", def.key(state, K("z", "z"), cx) == false and opened[#opened] == "tern-spotify://park" and #opened == before + 1)
	check("f asks the window to float", def.key(state, K("f", "f"), cx) == false and opened[#opened] == "tern-spotify://float")
	check("F asks the window to dock", def.key(state, K("f", "F"), cx) == false and opened[#opened] == "tern-spotify://dock")
	local ctrl_z = K("z", "z")
	ctrl_z.ctrl = true
	def.key(state, ctrl_z, cx)
	check("ctrl+z is not the park key", #opened == before + 3)
end

-- 7. Progress follows the clock and the end of a track triggers a re-read.
do
	local state = signed_in_player()
	local text0 = view_text(def, state)
	advance(10000)
	check("progress advances with time", text0 ~= view_text(def, state))
	set_current(playback({ progress_ms = 1000, item = { type = "track", uri = "spotify:track:t2", name = "Next Song", duration_ms = 100000, artists = { { name = "C" } }, album = { name = "Alb2", images = {} } } }))
	local polls = #calls("GET", "/v1/me/player")
	advance(180000) -- past the end of the 200s track
	check("end of track: state re-read", #calls("GET", "/v1/me/player") > polls)
	check("end of track: next track shown", state.playback.track.name == "Next Song", state.playback.track.name)
end

-- Types a search for "a" and runs it.
local function search_for_a(state)
	def.key(state, K("/"), cx)
	def.key(state, K("a", "a"), cx)
	def.key(state, K("enter"), cx)
	settle()
end

-- 7b. The player draws SVG controls; clicking each one does the equivalent of its key (volume steps are 10 by
-- click, 5 by key), and a blob is sent once per picture, not once per render.
do
	local function svg_of(n)
		return blob_log[tonumber(string.match(n.p.blob, "^blob:(%d+):"))].bytes
	end
	local function act_of(n)
		return n.p.actions and n.p.actions.click
	end

	local state = signed_in_player()
	local v = def.view(state, cx)
	local want = { search = "search", shuffle = "shuffle", prev = "prev", play = "toggle", next = "next", repeat_all = "repeat", help = "help", vol = "mute", minus = "vol_down", plus = "vol_up" }
	for key, act in want do
		local n = find_key(v, key)
		check(`icon {key}: shown and wired to {act}`, n ~= nil and act_of(n) == act, n and act_of(n))
	end
	local function transport_keys(n: any): { string }?
		if type(n) ~= "table" then
			return nil
		end
		if n.p and n.p.class == "sp-transport" then
			local keys = {}
			for _, c in n.c do
				table.insert(keys, c.p.key)
			end
			return keys
		end
		for _, child in n do
			local found = transport_keys(child)
			if found then
				return found
			end
		end
		return nil
	end
	check("controls in order, play in the middle: search, shuffle, prev, play, next, repeat, ?", table.concat(transport_keys(v) or {}, ",") == "search,shuffle,prev,play,next,repeat_all,help", table.concat(transport_keys(v) or {}, ","))
	check("the player screen has no key-hint line in the dock", v.dock ~= nil and #(v.dock.c or {}) == 0)
	check("the volume meter is not a button: its click does nothing", act_of(find_key(v, "volbar")) == "inert")
	local api_calls = #fetch_log
	def.event(state, { ev = "action", act = "inert" }, cx)
	settle()
	check("inert click sends nothing", #fetch_log == api_calls and state.mode == "player")
	local text = view_text(def, state)
	check("player: time, volume, device and the link back to Spotify", string.find(text, "0:30", 1, true) and string.find(text, "40%", 1, true) and string.find(text, "MacBook (Computer)", 1, true) and string.find(text, "OPEN SPOTIFY", 1, true), text)
	check("icons say what they are for screen readers", find_key(v, "play").p.alt == "Pause" and find_key(v, "shuffle").p.alt == "Shuffle off" and find_key(v, "repeat_all").p.alt == "Repeat off")

	-- Nothing is re-sent while the picture is unchanged.
	local sent = #blob_log
	for _ = 1, 20 do
		def.view(state, cx)
	end
	check("re-rendering the same moment sends no blob", #blob_log == sent, `{#blob_log - sent} sent`)

	-- The icons are sent once; the playhead moves the native progress bar, not a picture.
	for _ = 1, 60 do
		advance(1000)
		def.view(state, cx)
	end
	check("a minute of playing sends no blob: the progress bar is not a picture", #blob_log == sent, #blob_log - sent)
	local bar = find_key(def.view(state, cx), "progress")
	check("progress follows the clock: 90s of 200s", math.abs(bar.p.value - 0.45) < 0.01, bar.p.value)
	set_current(playback())
	advance(6000)


	-- Clicks do what the keys do.
	local function click(act)
		def.event(state, { ev = "action", act = act }, cx)
		settle()
	end
	click("vol_up")
	click("vol_down")
	local vols = calls("PUT", "/v1/me/player/volume")
	check("click +/-: volume steps of 10", #vols == 2 and vols[1].query.volume_percent == "50" and vols[2].query.volume_percent == "40", #vols)
	click("mute")
	vols = calls("PUT", "/v1/me/player/volume")
	check("click speaker: mute", vols[3] and vols[3].query.volume_percent == "0")
	check("muted shows the unmute icon", find_key(def.view(state, cx), "vol").p.alt == "Unmute")
	click("seek_fwd")
	click("seek_back")
	local seeks = calls("PUT", "/v1/me/player/seek")
	check("click -10s/+10s seek by exactly 10s", #seeks == 2 and tonumber(seeks[1].query.position_ms) - tonumber(seeks[2].query.position_ms) == 10000, #seeks)
	click("shuffle")
	local on = find_key(def.view(state, cx), "shuffle")
	check("shuffle on: the icon is marked with the hi class and dotted", on.p.alt == "Shuffle on" and string.find(svg_of(on), 'class="hi"', 1, true) ~= nil and string.find(svg_of(on), "<circle", 1, true) ~= nil)
	click("repeat")
	click("repeat")
	check("repeat one: its own icon", find_key(def.view(state, cx), "repeat_one") ~= nil and find_key(def.view(state, cx), "repeat_all") == nil)
	click("toggle")
	check("pause click reaches the API and flips the button", #calls("PUT", "/v1/me/player/pause") == 1 and find_key(def.view(state, cx), "play").p.alt == "Play")
	click("open")
	check("OPEN SPOTIFY opens the track", opened[#opened] == "https://open.spotify.com/track/t1")
	check("the cover links back to Spotify too", act_of(find_key(def.view(state, cx), "art")) == "open")
	def.key(state, K("/", "/"), cx) -- search mode: a late click on a player control must be ignored
	local before_calls = #fetch_log
	click("vol_up")
	click("seek_fwd")
	click("devices")
	check("player clicks are ignored outside the player", #fetch_log == before_calls and state.mode == "search")
	state.mode = "player"
	click("devices")
	check("device label opens the picker", state.mode == "devices")

	-- A device that cannot set its volume gets no volume controls.
	state.mode = "player"
	state.playback.device.volume_ok = false
	v = def.view(state, cx)
	check("no volume support: no speaker or meter, says so", find_key(v, "vol") == nil and find_key(v, "volbar") == nil and string.find(view_text(def, state), "volume n/a", 1, true) ~= nil)
end

-- 7c. The once-a-second tick runs only while a track plays, and whatever starts a track starts it again. Its
-- renders are counted: with no poll in the window, a second without one means the tick is not running.
do
	local function renders_in(ms)
		local before = renders
		advance(ms)
		return renders - before
	end
	local state = signed_in_player()
	set_current(playback({ is_playing = false }))
	advance(10000) -- a poll sees it paused
	local lists = pane_lists
	local n0 = renders_in(3000)
	check("paused: no renders and no wakeups between polls", state.playback ~= nil and state.playback.playing == false and n0 == 0 and pane_lists == lists, `{n0} {pane_lists - lists}`)
	routes["GET api.spotify.com/v1/me/player"] = function()
		return ok(500, { error = { status = 500, message = "boom" } })
	end
	def.key(state, K("space"), cx) -- resume; every poll fails, so only the key can start the tick
	settle()
	local n = renders_in(4000)
	check("resume: the tick starts with the key alone", n >= 4, n)

	state = signed_in_player()
	set_current(playback({ is_playing = false }))
	advance(10000)
	set_current(playback({ is_playing = true })) -- started on another device
	advance(10000) -- a poll sees it playing
	n = renders_in(4000)
	check("started elsewhere: the poll that sees it starts the tick", n >= 3, n)

	-- The end of a track that falls between two polls: the tick re-reads right then, it doesn't wait for the poll.
	state = signed_in_player()
	set_current(playback({ progress_ms = 193500 })) -- the poll at 5 s reads 198.5 s of 200: the end is 1.5 s later
	advance(5000)
	set_current(playback({ progress_ms = 1000, item = { type = "track", uri = "spotify:track:t2", name = "Next Song", duration_ms = 100000, artists = { { name = "C" } }, album = { name = "Alb2", images = {} } } }))
	advance(3000) -- the tick notices the end at 7 s and re-reads 0.7 s later; the next regular poll is at 10 s
	check("end of track between polls: re-read by the tick, not the next poll", state.playback ~= nil and state.playback.track.name == "Next Song", state.playback and state.playback.track.name)
end

-- 8. Errors: no device, premium, rate limit, nothing playing.
do
	local state = signed_in_player()
	routes["PUT api.spotify.com/v1/me/player/play"] = function()
		return ok(404, { error = { status = 404, message = "Player command failed: No active device found", reason = "NO_ACTIVE_DEVICE" } })
	end
	routes["GET api.spotify.com/v1/me/player/devices"] = function()
		return ok(200, { devices = { { id = "d9", name = "Kitchen", type = "Speaker", is_active = false, supports_volume = true }, { id = "dev1", name = "MacBook", type = "Computer", is_active = true, volume_percent = 40 } } })
	end
	state.playback.playing = false
	def.key(state, K("space"), cx)
	settle()
	check("no device: opens device picker", state.mode == "devices" and #state.devices == 2, state.mode)
	check("no device: selects the active one", state.dsel == 2)
	local picker = find_key(def.view(state, cx), "devices")
	state.dsel = 1
	def.event(state, { ev = "select", item = picker.p.selected }, cx) -- the path the list names for its selected row
	check("no device: a select on the picker's selected-row path lands on that row", state.dsel == 2 and "main.devices_box.devices." .. picker.c[2].p.key == picker.p.selected, `{state.dsel} {picker.p.selected}`)
	def.key(state, K("k"), cx)
	def.key(state, K("enter"), cx)
	settle()
	local tr = calls("PUT", "/v1/me/player")
	check("transfer: device_ids sent", #tr == 1 and string.find(tr[1].body, '"device_ids":["d9"]', 1, true) ~= nil, tr[1] and tr[1].body)
	check("transfer: back to player", state.mode == "player")

	routes["POST api.spotify.com/v1/me/player/next"] = function()
		return ok(403, { error = { status = 403, message = "Player command failed: Premium required", reason = "PREMIUM_REQUIRED" } })
	end
	def.key(state, K("n"), cx)
	settle()
	check("premium: clear message", string.find(state.err or "", "Premium", 1, true) ~= nil, state.err)

	routes["GET api.spotify.com/v1/me/player"] = function()
		return { status = 429, headers = { ["retry-after"] = "20" }, body = jenc({ error = { status = 429, message = "Too many requests" } }) }
	end
	advance(15000)
	local n = #calls("GET", "/v1/me/player")
	advance(10000)
	check("429: polling backs off for Retry-After", #calls("GET", "/v1/me/player") - n <= 2, #calls("GET", "/v1/me/player") - n)
	check("429: message shown", string.find(state.err or "", "Rate limited", 1, true) ~= nil, state.err)

	routes["GET api.spotify.com/v1/me/player"] = function()
		return { status = 204 }
	end
	advance(60000)
	check("204: nothing playing", state.playback == nil and string.find(view_text(def, state), "Nothing playing", 1, true) ~= nil)
end

-- 9. Search: type, submit, navigate, play.
do
	local state = signed_in_player()
	routes["GET api.spotify.com/v1/search"] = function()
		return ok(200, { tracks = { items = {
			{ uri = "spotify:track:s1", name = "First", duration_ms = 1000, artists = { { name = "X" } }, album = { name = "AA", images = {} } },
			{ uri = "spotify:track:s2", name = "Second", duration_ms = 2000, artists = { { name = "Y" } }, album = { name = "BB", images = {} } },
		} } })
	end
	def.key(state, K("/"), cx)
	check("search: mode switched", state.mode == "search" and state.focus == "input")
	for _, c in { "a", "b", " ", "é" } do
		def.key(state, K(c == " " and "space" or c, c), cx)
	end
	check("search: typed text, keys not treated as commands", state.query.text == "ab é", state.query.text)
	check("search: no player commands fired while typing", #calls("PUT", "/v1/me/player/pause") == 0)
	local links = #opened
	def.key(state, K("z", "z"), cx)
	def.key(state, K("f", "f"), cx)
	check("search: z/f type into the query instead of parking", state.query.text == "ab éz" .. "f" and #opened == links, state.query.text)
	def.key(state, K("backspace"), cx)
	def.key(state, K("backspace"), cx)
	def.key(state, K("enter"), cx)
	settle()
	local s = calls("GET", "/v1/search")
	check("search: request shape", #s == 1 and s[1].query.type == "track" and s[1].query.limit == "10" and s[1].query.q == "ab é", s[1] and s[1].query.q)
	check("no user-read-private granted: no market on search or poll", s[1].query.market == nil and calls("GET", "/v1/me/player")[1].query.market == nil and kv.scope == token_scope, kv.scope)
	check("search: results listed", #state.results == 2 and state.focus == "list")
	check("search: results rendered", string.find(view_text(def, state), "Second", 1, true) ~= nil)
	def.key(state, K("j"), cx)
	def.key(state, K("enter"), cx)
	settle()
	local play = calls("PUT", "/v1/me/player/play")
	check("search: enter plays the selected track", #play == 1 and play[1].body == '{"uris":["spotify:track:s2"]}', play[1] and play[1].body)
	check("search: returns to player", state.mode == "player")
end

-- 9b. Spotify applies a track change asynchronously: right after `play` it reports nothing active, then
-- the old track paused. The player must keep showing the chosen track as playing until Spotify catches up.
do
	local state = signed_in_player()
	local chosen = { type = "track", uri = "spotify:track:s2", name = "Second", duration_ms = 2000000, artists = { { name = "Y" } }, album = { name = "BB", images = {} } }
	routes["GET api.spotify.com/v1/search"] = function()
		return ok(200, { tracks = { items = { chosen } } })
	end
	routes["PUT api.spotify.com/v1/me/player/play"] = function()
		set_current(nil) -- mid-switch: GET /me/player answers 204
		return { status = 204 }
	end
	def.key(state, K("/"), cx)
	for _, c in { "s", "e", "c" } do
		def.key(state, K(c, c), cx)
	end
	def.key(state, K("enter"), cx)
	settle()
	def.key(state, K("enter"), cx)
	settle()
	check("lag: chosen track shown at once", state.playback ~= nil and state.playback.playing and state.playback.track.name == "Second")
	advance(800) -- settle poll: 204
	check("lag: 204 does not blank the player", state.playback ~= nil and state.playback.playing and state.playback.track.name == "Second" and string.find(view_text(def, state), "Nothing playing", 1, true) == nil)
	set_current(playback({ is_playing = false })) -- then the old track, paused
	advance(1200)
	check("lag: stale paused state does not stop it", state.playback ~= nil and state.playback.playing and state.playback.track.name == "Second")
	set_current(playback({ progress_ms = 500, item = chosen }))
	advance(1200)
	check("lag: server state adopted once it matches", state.playback.track.uri == chosen.uri and state.playback.progress_ms >= 500, state.playback.progress_ms)
	set_current(playback({ is_playing = false, progress_ms = 9000, item = chosen })) -- paused by the user elsewhere
	advance(5200)
	check("lag: later server changes are not masked", state.playback.playing == false)
end

-- 9c. The player never pretends: a rejected play command, or a server that never starts the track.
do
	local state = signed_in_player()
	routes["GET api.spotify.com/v1/search"] = function()
		return ok(200, { tracks = { items = { { uri = "spotify:track:s9", name = "Nine", duration_ms = 1000, artists = { { name = "Z" } }, album = { name = "CC", images = {} } } } } })
	end
	local verdict = { status = 403, body = { error = { status = 403, message = "Restriction violated", reason = "UNKNOWN" } } }
	routes["PUT api.spotify.com/v1/me/player/play"] = function()
		return ok(verdict.status, verdict.body)
	end
	def.key(state, K("/"), cx)
	def.key(state, K("n", "n"), cx)
	def.key(state, K("enter"), cx)
	settle()
	def.key(state, K("enter"), cx)
	settle()
	advance(800)
	check("reject: server truth restored", state.playback.track.name == "Song" and state.playback.playing, state.playback.track and state.playback.track.name)
	check("reject: error shown", state.err ~= nil and string.find(state.err, "Restriction violated", 1, true) ~= nil, state.err)
	local function logged(needle)
		for _, w in warnings do
			if string.find(w, needle, 1, true) then
				return true
			end
		end
		return false
	end
	check("reject: failure is logged", logged("spotify PUT /me/player/play 403"), warnings[#warnings])
	verdict.status, verdict.body = 204, nil
	def.key(state, K("/"), cx)
	def.key(state, K("enter"), cx)
	settle()
	def.key(state, K("enter"), cx)
	settle()
	advance(7000) -- accepted, but Spotify keeps playing the old track: the optimism expires
	check("expire: server truth wins after the grace period", state.playback.track.name == "Song", state.playback.track.name)
end

-- 9d. Nothing is active (no device): the chosen track must survive the device picker and start on the
-- device picked, not be dropped in favour of a bare transfer.
do
	local state = signed_in_player()
	local track = { type = "track", uri = "spotify:track:s5", name = "Fifth", duration_ms = 200000, artists = { { name = "W" } }, album = { name = "EE", images = {} } }
	set_current(nil)
	advance(11000)
	check("no device: nothing playing before the search", state.playback == nil)
	routes["GET api.spotify.com/v1/search"] = function()
		return ok(200, { tracks = { items = { track } } })
	end
	routes["GET api.spotify.com/v1/me/player/devices"] = function()
		return ok(200, { devices = { { id = "d9", name = "Kitchen", type = "Speaker", is_active = false, supports_volume = true } } })
	end
	routes["PUT api.spotify.com/v1/me/player/play"] = function(req)
		if req.query.device_id == nil then
			return ok(404, { error = { status = 404, message = "Player command failed: No active device found", reason = "NO_ACTIVE_DEVICE" } })
		end
		set_current(playback({ item = track, progress_ms = 0, device = { id = req.query.device_id, name = "Kitchen", type = "Speaker", is_active = true, volume_percent = 30 } }))
		return { status = 204 }
	end
	def.key(state, K("/"), cx)
	def.key(state, K("f", "f"), cx)
	def.key(state, K("enter"), cx)
	settle()
	def.key(state, K("enter"), cx)
	settle()
	check("no device: picker opened", state.mode == "devices" and #state.devices == 1, state.mode)
	check("no device: the optimistic track is withdrawn", state.playback == nil)
	def.key(state, K("enter"), cx)
	settle()
	local play = calls("PUT", "/v1/me/player/play")
	local last = play[#play]
	check("no device: track played on the picked device", #play == 2 and last.query.device_id == "d9" and last.body == '{"uris":["spotify:track:s5"]}', last and last.body)
	check("no device: not a bare transfer", #calls("PUT", "/v1/me/player") == 0)
	advance(1500)
	check("no device: player shows the track playing", state.mode == "player" and state.playback ~= nil and state.playback.playing and state.playback.track.name == "Fifth")
	check("no device: pending track consumed", state.pending == nil)

	-- Backing out of the picker forgets the track: a later pick is a plain transfer.
	state.mode, state.pending = "devices", { uri = "spotify:track:s5", name = "Fifth", artists = "W", album = "EE", duration_ms = 1 }
	def.key(state, K("escape"), cx)
	check("no device: escape drops the pending track", state.pending == nil and state.mode == "player")
end

-- 9f. market=from_token needs the user-read-private scope, which Spotify lists in its token replies: ask
-- only when it was granted, and if Spotify still answers 400, carry on without it.
do
	local WITH_PRIVATE = "user-read-playback-state user-modify-playback-state user-read-private"
	local NO_PRIVATE = token_scope
	local item = { uri = "spotify:track:s1", name = "First", duration_ms = 1000, artists = { { name = "X" } }, album = { name = "AA", images = {} } }
	local function boot(search)
		reset()
		spotify_routes()
		routes["GET api.spotify.com/v1/search"] = search
		set_current(playback())
		kv.client_id, kv.refresh_token, kv.scope = CLIENT_ID, "RT1", token_scope -- scope as stored by an earlier token reply
		local state = def.init(cx, {}, nil)
		settle()
		return state
	end

	token_scope = WITH_PRIVATE
	local state = boot(function()
		return ok(200, { tracks = { items = { item } } })
	end)
	search_for_a(state)
	check("scope granted: poll and search carry the market", calls("GET", "/v1/me/player")[1].query.market == "from_token" and calls("GET", "/v1/search")[1].query.market == "from_token")

	-- Spotify refuses it anyway (400): both go on without it, silently.
	reset()
	spotify_routes()
	local base = routes["GET api.spotify.com/v1/me/player"]
	routes["GET api.spotify.com/v1/me/player"] = function(req)
		if req.query.market then
			return ok(400, { error = { status = 400, message = "Invalid market code" } })
		end
		return base(req)
	end
	routes["GET api.spotify.com/v1/search"] = function(req)
		if req.query.market then
			return ok(400, { error = { status = 400, message = "Invalid market code" } })
		end
		return ok(200, { tracks = { items = { item } } })
	end
	set_current(playback())
	kv.client_id, kv.refresh_token, kv.scope = CLIENT_ID, "RT1", token_scope
	state = def.init(cx, {}, nil)
	settle()
	advance(1000)
	local polls = calls("GET", "/v1/me/player")
	check("market 400: polling carries on without it", state.market == false and state.playback ~= nil and state.err == nil and polls[#polls].query.market == nil, state.err)
	state.market = true -- a search that still sends it
	search_for_a(state)
	local s = calls("GET", "/v1/search")
	check("market 400: search retried without it", #s == 2 and s[1].query.market == "from_token" and s[2].query.market == nil and #state.results == 1 and state.err == nil, #s)

	-- Any other refusal is a real error and leaves the market alone.
	state = boot(function()
		return ok(403, { error = { status = 403, message = "User not registered in the Developer Dashboard" } })
	end)
	search_for_a(state)
	check("other 403: still an error, market stays on", state.market == true and #calls("GET", "/v1/search") == 1 and state.err == "User not registered in the Developer Dashboard", state.err)
	token_scope = NO_PRIVATE
end

-- 9f2. Chosen tracks are started by their album as context: a bare `uris` makes the desktop app drop
-- whatever it had and load nothing (204, then item=none with every action disallowed).
do
	local state = signed_in_player()
	routes["GET api.spotify.com/v1/search"] = function()
		return ok(200, { tracks = { items = { { uri = "spotify:track:c1", name = "InAlbum", duration_ms = 1000, artists = { { name = "X" } }, album = { name = "AA", uri = "spotify:album:al1", images = {} } } } } })
	end
	search_for_a(state)
	def.key(state, K("enter"), cx)
	settle()
	local play = calls("PUT", "/v1/me/player/play")
	local body = play[1] and jdec(play[1].body)
	check("play: album context with the track as offset", #play == 1 and body.context_uri == "spotify:album:al1" and body.offset.uri == "spotify:track:c1" and body.uris == nil, play[1] and play[1].body)
end

-- 9g. A result Spotify marks unplayable (is_playable=false) is flagged and never sent: Spotify would
-- answer 204 and then sit on it with every action disallowed.
do
	local state = signed_in_player()
	routes["GET api.spotify.com/v1/search"] = function()
		return ok(200, { tracks = { items = { { uri = "spotify:track:u1", name = "Blocked", duration_ms = 1000, artists = { { name = "X" } }, album = { name = "AA", images = {} }, is_playable = false, restrictions = { reason = "market" } } } } })
	end
	search_for_a(state)
	check("unplayable: flagged in the list", string.find(view_text(def, state), "unavailable", 1, true) ~= nil)
	local rows = find_key(def.view(state, cx), "results")
	check("results: the selected row is named like the first row's key", rows ~= nil and rows.p.selected == "main.search_box.results." .. rows.c[1].p.key, rows and rows.p.selected)
	local box = find_key(def.view(state, cx), "search_box")
	local kids = if box then box.c or {} else {}
	check("search: the query input and the results are direct children of the keyed panel the ids and the focus name", #kids == 2 and kids[1].p.key == "query" and kids[2].p.key == "results")
	state.sel = 5
	check("results: a selection past the end names no row", find_key(def.view(state, cx), "results").p.selected == nil)
	def.event(state, { ev = "select", item = rows.p.selected }, cx)
	check("results: a select on a row's path lands on that row", state.sel == 1, state.sel)
	def.key(state, K("enter"), cx)
	settle()
	check("unplayable: no play sent, search stays open", #calls("PUT", "/v1/me/player/play") == 0 and state.mode == "search" and state.playback.track.name == "Song")
	check("unplayable: says why", state.err == "Blocked can't be played (market).", state.err)
end

-- 9h. A relinked track comes back under another uri with linked_from.uri = the one we asked for.
do
	local state = signed_in_player()
	local asked = { uri = "spotify:track:a1", name = "Original", duration_ms = 200000, artists = { { name = "X" } }, album = { name = "AA", images = {} }, is_playable = true }
	local relinked = { type = "track", uri = "spotify:track:r1", name = "Original", duration_ms = 200000, artists = { { name = "X" } }, album = { name = "AA", images = {} }, is_playable = true, linked_from = { uri = asked.uri } }
	routes["GET api.spotify.com/v1/search"] = function()
		return ok(200, { tracks = { items = { asked } } })
	end
	routes["PUT api.spotify.com/v1/me/player/play"] = function()
		set_current(playback({ item = relinked, progress_ms = 0 }))
		return { status = 204 }
	end
	search_for_a(state)
	def.key(state, K("enter"), cx)
	settle()
	advance(1500)
	check("relinked: counts as arrived", state.expect == nil and state.playback.track.uri == "spotify:track:r1", state.playback.track.uri)
	set_current(playback({ item = relinked, is_playing = false, progress_ms = 5000 })) -- paused elsewhere
	advance(5200)
	check("relinked: later pause is not masked", state.playback.playing == false)
end

-- 10. Sign out clears credentials and stops polling.
do
	local state = signed_in_player()
	def.key(state, K("l", "L"), cx)
	check("sign out: credentials gone", kv.refresh_token == nil and state.phase == "login")
	local n = #calls("GET", "/v1/me/player")
	advance(60000)
	check("sign out: polling stopped", #calls("GET", "/v1/me/player") == n)
end

-- 10b. Spotify keeps refusing (429) while the block is still "Connecting": there is a way out to another method.
do
	reset()
	spotify_routes()
	kv.client_id, kv.refresh_token, kv.auth_mode, kv.keymaster_ack = "65b708073fc0480ea92a077233ca87bd", "RT1", "keymaster", true
	routes["GET api.spotify.com/v1/me/player"] = function()
		return { status = 429, headers = { ["retry-after"] = "5" }, body = jenc({ error = { status = 429, message = "API rate limit exceeded" } }) }
	end
	local state = def.init(cx, {}, nil)
	settle()
	advance(20000)
	local text = view_text(def, state)
	check("429 on first poll: still Connecting, with the reason and the way out", state.phase == "loading" and string.find(text, "Connecting to Spotify", 1, true) ~= nil and string.find(text, "Rate limited", 1, true) ~= nil and string.find(text, "other sign-in method", 1, true) ~= nil, text)
	def.key(state, K("escape"), cx)
	check("esc from Connecting: the choice of method, still signed in", state.phase == "setup" and state.setup == "choose" and kv.refresh_token == "RT1")
	local n = #calls("GET", "/v1/me/player")
	advance(60000)
	check("esc from Connecting: polling paused while you choose", #calls("GET", "/v1/me/player") == n and state.phase == "setup")
	def.key(state, K("escape"), cx)
	check("esc from the choice: back to Connecting, trying again", state.phase == "loading" and #calls("GET", "/v1/me/player") == n + 1, #calls("GET", "/v1/me/player") - n)
	def.key(state, K("e", "e"), cx)
	def.key(state, K("1", "1"), cx)
	check("...and your own Client ID can be picked", state.setup == "own")
	def.key(state, { name = "paste", text = CLIENT_ID, ctrl = false, alt = false, shift = false, meta = false }, cx)
	def.key(state, K("enter"), cx)
	check("a different method drops the Keymaster sign-in", kv.refresh_token == nil and kv.auth_mode == "own" and state.phase == "login", state.phase)

	-- e while a poll is in flight: its answer must not drag you out of the choice
	reset()
	spotify_routes()
	set_current(playback())
	kv.client_id, kv.refresh_token, kv.auth_mode, kv.keymaster_ack = "65b708073fc0480ea92a077233ca87bd", "RT1", "keymaster", true
	state = def.init(cx, {}, nil)
	check("poll in flight: Connecting", state.phase == "loading")
	def.key(state, K("e", "e"), cx)
	settle()
	check("e with a poll in flight: stays on the choice when it answers", state.phase == "setup" and state.setup == "choose" and state.playback == nil, state.phase)

	-- A long wait imposed on the Keymaster client must not delay the first poll of the user's own one.
	reset()
	spotify_routes()
	kv.client_id, kv.refresh_token, kv.auth_mode, kv.keymaster_ack = "65b708073fc0480ea92a077233ca87bd", "RT1", "keymaster", true
	routes["GET api.spotify.com/v1/me/player"] = function()
		return { status = 429, headers = { ["retry-after"] = "600" }, body = jenc({ error = { status = 429, message = "API rate limit exceeded" } }) }
	end
	state = def.init(cx, {}, nil)
	settle()
	check("long Retry-After: waiting", spotify.retry_in(state.client) > 500000, spotify.retry_in(state.client))
	def.key(state, K("e", "e"), cx)
	def.key(state, K("1", "1"), cx)
	def.key(state, { name = "paste", text = CLIENT_ID, ctrl = false, alt = false, shift = false, meta = false }, cx)
	def.key(state, K("enter"), cx)
	check("another method: the old wait is dropped", spotify.retry_in(state.client) == 0 and kv.refresh_token == nil, spotify.retry_in(state.client))

	-- Choosing the SAME client again keeps the wait: Spotify limits per client id.
	reset()
	spotify_routes()
	kv.client_id, kv.refresh_token, kv.auth_mode, kv.keymaster_ack = "65b708073fc0480ea92a077233ca87bd", "RT1", "keymaster", true
	routes["GET api.spotify.com/v1/me/player"] = function()
		return { status = 429, headers = { ["retry-after"] = "600" }, body = jenc({ error = { status = 429, message = "API rate limit exceeded" } }) }
	end
	state = def.init(cx, {}, nil)
	settle()
	local sent = #calls("GET", "/v1/me/player")
	def.key(state, K("e", "e"), cx)
	def.key(state, K("2", "2"), cx)
	def.key(state, K("y", "y"), cx)
	advance(10000)
	check("same client again: the wait stays and nothing is sent", spotify.retry_in(state.client) > 500000 and #calls("GET", "/v1/me/player") == sent and kv.refresh_token == "RT1", #calls("GET", "/v1/me/player") - sent)

	-- During a wait nothing goes out, whatever asks: the caller gets a 429 of its own, with the time left.
	state = signed_in_player()
	routes["GET api.spotify.com/v1/me/player"] = function()
		return { status = 429, headers = { ["retry-after"] = "600" }, body = jenc({ error = { status = 429, message = "API rate limit exceeded" } }) }
	end
	advance(10000)
	check("wait: the poll's 429 sets it", spotify.retry_in(state.client) > 500000, spotify.retry_in(state.client))
	local sent_all = #fetch_log
	def.key(state, K("space"), cx)
	advance(0)
	settle()
	check("wait: a command sends nothing and says why, with the time left", #fetch_log == sent_all and string.find(state.err or "", "Rate limited by Spotify; retrying in 595s.", 1, true) ~= nil, `{#fetch_log - sent_all} {state.err}`)
	def.key(state, K("d"), cx)
	advance(0)
	settle()
	check("wait: the device list sends nothing", #fetch_log == sent_all and state.mode == "devices", #fetch_log - sent_all)
	def.key(state, K("escape"), cx)
	search_for_a(state)
	advance(0)
	settle()
	check("wait: a search sends nothing", #fetch_log == sent_all and #calls("GET", "/v1/search") == 0, #fetch_log - sent_all)

	-- A quota 429 keeps its own wording on the answers the plugin makes itself.
	state = signed_in_player()
	routes["GET api.spotify.com/v1/me/player"] = function()
		return { status = 429, headers = { ["retry-after"] = "600" }, body = jenc({ error = { status = 429, message = "quota", reason = "QUOTA_EXCEEDED" } }) }
	end
	advance(10000)
	def.key(state, K("d"), cx)
	advance(0)
	settle()
	check("wait: a quota 429 keeps the quota wording", state.err == "Spotify developer-mode quota exceeded; try again later.", state.err)

	-- Once the wait has passed, commands go out again.
	state = signed_in_player()
	routes["GET api.spotify.com/v1/me/player"] = function()
		return { status = 429, headers = { ["retry-after"] = "20" }, body = jenc({ error = { status = 429, message = "API rate limit exceeded" } }) }
	end
	advance(6000)
	def.key(state, K("space"), cx)
	advance(0)
	settle()
	check("wait: blocked while it lasts", #calls("PUT", "/v1/me/player/pause") == 0)
	spotify_routes()
	advance(25000)
	def.key(state, K("space"), cx)
	settle()
	check("wait over: the command goes out", #calls("PUT", "/v1/me/player/pause") == 1, #calls("PUT", "/v1/me/player/pause"))

	-- The poll goes out right when the wait ends, not a poll interval later.
	state = signed_in_player()
	routes["GET api.spotify.com/v1/me/player"] = function()
		return { status = 429, headers = { ["retry-after"] = "22" }, body = jenc({ error = { status = 429, message = "API rate limit exceeded" } }) }
	end
	advance(5000) -- the poll at 5 s is refused: the wait runs to 27 s
	spotify_routes()
	local before_poll = #calls("GET", "/v1/me/player")
	advance(22500)
	check("wait over: the poll goes out when it ends", #calls("GET", "/v1/me/player") == before_poll + 1, #calls("GET", "/v1/me/player") - before_poll)

	-- Re-entering a DIFFERENT own Client ID: the token of the old one is no use to it.
	reset()
	spotify_routes()
	set_current(playback())
	kv.client_id, kv.refresh_token, kv.auth_mode = CLIENT_ID, "RT1", "own"
	state = def.init(cx, {}, nil)
	settle()
	check("own id: signed in", state.phase == "ready")
	state.phase = "loading" -- as when Spotify keeps refusing
	def.key(state, K("e", "e"), cx)
	def.key(state, K("1", "1"), cx)
	state.id_field.text, state.id_field.cursor = "", 0 -- "1" pre-fills the id in use; this one starts from scratch
	def.key(state, { name = "paste", text = string.rep("b", 32), ctrl = false, alt = false, shift = false, meta = false }, cx)
	def.key(state, K("enter"), cx)
	check("another own Client ID drops the old token", kv.refresh_token == nil and state.phase == "login" and kv.client_id == string.rep("b", 32), tostring(kv.refresh_token))
	def.key(state, K("e", "e"), cx)
	def.key(state, K("1", "1"), cx)
	-- "1" pre-fills the id in use: confirming it unchanged is the same client again
	kv.refresh_token = "RT1"
	def.key(state, K("enter"), cx)
	check("the same own Client ID again keeps its token", kv.refresh_token == "RT1" and state.phase == "loading", tostring(kv.refresh_token))

	-- The old client's answer arrives after the user picked a method again: it is not applied to the new session.
	reset()
	spotify_routes()
	kv.client_id, kv.refresh_token, kv.auth_mode, kv.keymaster_ack = "65b708073fc0480ea92a077233ca87bd", "RT1", "keymaster", true
	local answers = 0
	routes["GET api.spotify.com/v1/me/player"] = function()
		answers += 1
		if answers == 1 then
			return { status = 429, headers = { ["retry-after"] = "600" }, body = jenc({ error = { status = 429, message = "old client" } }) }
		end
		return { status = 204 }
	end
	state = def.init(cx, {}, nil) -- the first poll is in flight
	def.key(state, K("e", "e"), cx)
	def.key(state, K("2", "2"), cx)
	def.key(state, K("y", "y"), cx) -- Keymaster again: same id, the token stays, a new client polls
	settle()
	advance(10000)
	check("old answer dropped: the new client polls and is ready", state.phase == "ready" and spotify.retry_in(state.client) == 0, state.phase)

	-- A sign-in exchange that fails after you went to the choice does not pull you out of it.
	reset()
	spotify_routes()
	kv.auth_mode, kv.keymaster_ack = "keymaster", true
	state = def.init(cx, {}, nil)
	def.key(state, K("enter"), cx)
	settle()
	local nc = pending_nc
	pending_nc = nil
	nc({ status = 0, stdout = "GET /login?code=BAD&state=" .. string.sub(rand, 87, 108) .. " HTTP/1.1\r\n", stderr = "", timed_out = false })
	check("exchange started: Connecting", state.phase == "loading", state.phase)
	def.key(state, K("e", "e"), cx)
	settle()
	check("failed exchange after e: stays on the choice", state.phase == "setup" and state.setup == "choose", state.phase)
end

-- 10c. Shapes: the window half tells the block which view to draw, as a shape action. Docked is the wide card; a
-- floating card that has the focus is the glass card with its controls; parked, or floating without focus, is the
-- glass card with the song and its progress only.
do
	local bridge = require("../bridge")
	check("shape: docked with or without focus", bridge.shape({}, false) == "docked" and bridge.shape({}, true) == "docked" and bridge.shape({ floating = false, parked = false }, false) == "docked")
	check("shape: floating WITH focus is float", bridge.shape({ floating = true }, true) == "float")
	check("shape: floating without focus is compact", bridge.shape({ floating = true }, false) == "compact")
	check("shape: parked is compact, focus or not, even if it also floats", bridge.shape({ parked = true }, false) == "compact" and bridge.shape({ parked = true }, true) == "compact" and bridge.shape({ parked = true, floating = true }, true) == "compact")
	for _, s in { "docked", "float", "compact" } do
		check(`shape: {s} survives its action name`, bridge.parse_shape(bridge.shape_event(s).act) == s)
	end
	check("shape: nothing else is a shape", bridge.parse_shape("signin") == nil and bridge.parse_shape(nil) == nil and bridge.parse_shape("mode=full") == nil)
	do -- which panes this window tells, and when
		local KIND = "spotify-api.web-player"
		local panes = {
			{ pane = 1, block = "terminal" }, -- not a player: never told
			{ pane = 4, block = KIND, floating = true },
			{ pane = 5, block = KIND, parked = true },
			{ pane = 6, block = KIND }, -- docked
		}
		local sent: { [number]: bridge.Shape } = {}
		local function by_pane(list: { { pane: number, shape: bridge.Shape } }): { [number]: bridge.Shape }
			local out = {}
			for _, c in list do
				out[c.pane] = c.shape
			end
			return out
		end
		local first = by_pane(bridge.changes(panes, KIND, 1, sent))
		check("changes: only players are told, each with its shape (floating w/o focus and parked: compact; docked: docked)", first[1] == nil and first[4] == "compact" and first[5] == "compact" and first[6] == "docked")
		for pane, shape in first do
			sent[pane] = shape -- what the window does after a successful send
		end
		check("changes: nothing to say when nothing changed (no send every second)", #bridge.changes(panes, KIND, 1, sent) == 0)
		local focus_card = by_pane(bridge.changes(panes, KIND, 4, sent))
		check("changes: the floating card getting the focus is the only one told, and goes float", focus_card[4] == "float" and focus_card[5] == nil and focus_card[6] == nil)
		check("changes: a failed send is retried (sent not updated)", by_pane(bridge.changes(panes, KIND, 4, sent))[4] == "float")
		-- two windows on one session: B has another pane focused. After A told the card "float", B's own record is empty
		-- of changes while ITS view matches what it last sent, so it stays quiet instead of overriding A every tick.
		local sent_b: { [number]: bridge.Shape } = { [4] = "compact", [5] = "compact", [6] = "docked" }
		check("changes: a window whose own view did not change says nothing, whatever the other window sent", #bridge.changes(panes, KIND, 1, sent_b) == 0)
	end
	local function has_key(n: any, key: string): boolean
		return find_key(n, key) ~= nil
	end
	-- Whether a click on something in `n` does `act` (the -10s and +10s badges have no key of their own).
	local function has_act(n: any, act: string): boolean
		if type(n) ~= "table" then
			return false
		end
		if n.p and n.p.actions and n.p.actions.click == act then
			return true
		end
		for _, v in n do
			if has_act(v, act) then
				return true
			end
		end
		return false
	end
	local state = signed_in_player()
	local name = state.playback.track.name
	local artists = state.playback.track.artists
	local function view()
		return def.view(state, cx)
	end
	local function shape(s: bridge.Shape)
		def.event(state, bridge.shape_event(s), cx) -- what the window half sends on a change
	end

	shape("docked")
	local docked = view_text(def, state)
	check("docked: cover, bar and controls are there", has_key(view(), "art") and has_key(view(), "progress") and has_key(view(), "play") and has_key(view(), "volbar"))
	check("docked: the cover is square", find_key(view(), "art").p.w == find_key(view(), "art").p.h)
	check("docked: seek badges and the link back to Spotify are there", has_act(view(), "seek_back") and has_act(view(), "seek_fwd") and string.find(docked, "OPEN SPOTIFY", 1, true) ~= nil, docked)
	check("docked: the bar sits at the playhead (30s of 200s)", math.abs(find_key(view(), "progress").p.value - 0.15) < 0.01, find_key(view(), "progress").p.value)
	-- A cover is drawn only while it is this track's and has downloaded: a previous track's, a failed one or a pending one is not.
	local art = state.art
	local art_url = state.playback.track.art_url or ""
	state.art = { url = "https://img.test/other", blob = "blob:9:x" }
	check("cover: a previous track's cover is not drawn", not has_key(view(), "art") and has_key(view(), "progress"))
	state.art = { url = art_url, blob = nil }
	check("cover: a failed download is not drawn", not has_key(view(), "art") and has_key(view(), "progress"))
	state.art = nil
	check("cover: a download still pending is not drawn", not has_key(view(), "art") and has_key(view(), "progress"))
	state.art = art
	check("cover: drawn once it is this track's", has_key(view(), "art"))

	shape("float") -- the card gets the focus
	local float = view_text(def, state)
	check("float: song, cover, bar, times and the transport are there", string.find(float, name, 1, true) ~= nil and string.find(float, artists, 1, true) ~= nil and has_key(view(), "art") and has_key(view(), "progress") and has_key(view(), "play") and has_key(view(), "shuffle") and has_key(view(), "repeat_all"), float)
	check("float: the volume and the device are there and clickable, no seek badges", has_key(view(), "volbar") and has_act(view(), "mute") and has_act(view(), "vol_down") and has_act(view(), "vol_up") and has_act(view(), "devices") and string.find(float, "MacBook (Computer)", 1, true) ~= nil and not has_act(view(), "seek_back") and not has_act(view(), "seek_fwd"), float)
	check("float: no device or link badges", string.find(float, "OPEN SPOTIFY", 1, true) == nil and string.find(float, "LOCAL PLAYER", 1, true) == nil, float)

	shape("compact") -- parked, or floating without focus
	local compact = view_text(def, state)
	check("compact: song, cover and bar are still shown", string.find(compact, name, 1, true) ~= nil and has_key(view(), "art") and has_key(view(), "progress"), compact)
	check("compact: no buttons and no seek badges", not has_key(view(), "play") and not has_key(view(), "shuffle") and not has_key(view(), "search") and not has_key(view(), "help") and not has_act(view(), "seek_back"), compact)
	check("compact: the volume and the device are shown but can't be clicked", has_key(view(), "volbar") and string.find(compact, "40%", 1, true) ~= nil and string.find(compact, "MacBook (Computer)", 1, true) ~= nil and not has_act(view(), "mute") and not has_act(view(), "vol_down") and not has_act(view(), "vol_up") and not has_act(view(), "devices"), compact)

	def.key(state, K("d", "d"), cx) -- the devices screen
	check("devices screen is open", state.mode == "devices")
	shape("float")
	shape("docked")
	check("shape events never change the screen: devices stays open", state.mode == "devices" and state.shape == "docked", state.mode)
	def.key(state, K("escape"), cx)
	check("esc back to the player after shape events, docked again", state.mode == "player" and has_key(view(), "play") and has_key(view(), "volbar"))

	-- The shortcuts screen. `?` is shift+/, which may reach the block as the key "/" typing "?": it must open the
	-- shortcuts, not the search.
	check("docked and float have the search and shortcuts buttons", has_key(view(), "search") and has_key(view(), "help"))
	def.key(state, K("/", "?"), cx)
	check("? typed on the / key opens the shortcuts, not the search", state.mode == "help")
	local function kbds(n: any, out: { any }): { any }
		if type(n) ~= "table" then
			return out
		end
		if n.k == "kbd" then
			table.insert(out, n)
		end
		for _, v in n do
			kbds(v, out)
		end
		return out
	end
	local caps = kbds(view(), {})
	check("shortcuts: keys are listed as keycaps", #caps >= 15, #caps)
	local documented: { [string]: boolean } = { ["="] = true } -- the quiet alias of +
	local lower_ok, plain_p, shift_p = true, false, false
	for _, c in caps do
		local ks = c.p.keys
		documented[ks[#ks]] = true
		lower_ok = lower_ok and not string.match(ks[#ks], "^%u$") -- kbd upper-cases a bare letter: a capital must be a shift chord
		plain_p = plain_p or (#ks == 1 and ks[1] == "p")
		shift_p = shift_p or (#ks == 2 and ks[1] == "shift" and ks[2] == "p")
	end
	check("shortcuts: letters are lowercase, and P (local player) is told from p (previous) by shift", lower_ok and plain_p and shift_p)
	local function answers(name: string, text: string?): boolean
		local fresh = signed_in_player()
		local links = #opened
		local handled = def.key(fresh, K(name, text), cx)
		return handled == true or #opened > links
	end
	local dead: { string } = {}
	for _, c in caps do
		local ks = c.p.keys
		local last = ks[#ks]
		if last ~= "esc" and last ~= "?" then
			local shifted = #ks == 2
			local text: string? = if shifted then string.upper(last) elseif #last == 1 then last else nil
			if not answers(last, text) then
				table.insert(dead, last)
			end
		end
	end
	check("shortcuts: every listed key does something", #dead == 0, table.concat(dead, ","))
	local unlisted: { string } = {}
	for _, n in { "a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m", "n", "o", "p", "q", "r", "s", "t", "u", "v", "w", "x", "y", "z", "0", "1", "2", "3", "4", "5", "6", "7", "8", "9", "+", "-", "=", ".", ",", "space", "left", "right", "up", "down", "enter", "tab", "backspace" } do
		local capital = string.upper(n)
		if not documented[n] and (answers(n, if #n == 1 then n else nil) or (#n == 1 and capital ~= n and answers(n, capital))) then
			table.insert(unlisted, n)
		end
	end
	check("shortcuts: every key the player answers is listed", #unlisted == 0, table.concat(unlisted, ","))
	def.key(state, K("escape"), cx)
	check("esc closes the shortcuts", state.mode == "player" and has_key(view(), "play"))
	def.key(state, K("?", "?"), cx)
	check("? also opens them when it arrives as its own key", state.mode == "help")
	def.key(state, K("?", "?"), cx)
	check("? closes them", state.mode == "player")
	local shift_slash = K("/")
	shift_slash.shift = true -- some senders give the key and the modifier, not the typed "?"
	def.key(state, shift_slash, cx)
	check("shift held on the / key opens the shortcuts too", state.mode == "help")
	def.key(state, shift_slash, cx)
	check("and closes them", state.mode == "player")
	def.key(state, K("/"), cx)
	check("a plain / is still the search", state.mode == "search")
	def.key(state, K("escape"), cx)
	local fresh = signed_in_player()
	def.event(fresh, { ev = "action", act = "search" }, cx)
	check("the search button does what / does", fresh.mode == "search" and fresh.focus == "input")
	advance(40)
	local focus_op = frame_log[#frame_log]
	check("the search field is focused by the id of the keyed panel it hangs from", focus_op ~= nil and focus_op[1][1] == "focus" and focus_op[1][2] == "main.search_box.query", focus_op and focus_op[1][2])
	local fresh2 = signed_in_player()
	def.event(fresh2, { ev = "action", act = "help" }, cx)
	check("the ? button opens the shortcuts", fresh2.mode == "help" and #kbds(def.view(fresh2, cx), {}) >= 15)
	def.event(fresh2, bridge.shape_event("compact"), cx)
	check("a parked or unfocused pane shows the song, not the shortcuts", #kbds(def.view(fresh2, cx), {}) == 0 and has_key(def.view(fresh2, cx), "progress") and fresh2.mode == "help")
	def.event(fresh2, { ev = "action", act = "open" }, cx)
	check("that pane's cover still links back to Spotify", opened[#opened] == "https://open.spotify.com/track/t1", opened[#opened])
	def.event(fresh2, bridge.shape_event("docked"), cx)
	def.event(fresh2, { ev = "action", act = "toggle" }, cx)
	check("player buttons are ignored while the shortcuts are open", fresh2.mode == "help")
	def.event(fresh2, { ev = "action", act = "back" }, cx)
	check("the badge closes the shortcuts", fresh2.mode == "player")
	-- The back badge of the other screens does what esc does there.
	local s = signed_in_player()
	def.event(s, { ev = "action", act = "search" }, cx)
	check("search has a back badge", has_act(def.view(s, cx), "back"))
	def.event(s, { ev = "action", act = "back" }, cx)
	check("back leaves the search", s.mode == "player")
	local d = signed_in_player()
	d.mode, d.pending = "devices", { kind = "play" } :: any
	check("devices has a back badge", has_act(def.view(d, cx), "back"))
	def.event(d, { ev = "action", act = "back" }, cx)
	check("back leaves the devices and drops what waited for one", d.mode == "player" and d.pending == nil)
	local l = signed_in_player()
	def.event(l, { ev = "action", act = "local_open" }, cx)
	check("the local player has a back badge", l.mode == "localplayer" and has_act(def.view(l, cx), "back"))
	l.sd.step = "pairing"
	def.event(l, { ev = "action", act = "back" }, cx)
	check("back mid-pairing cancels it and stays", l.mode == "localplayer" and l.sd.step == "menu")
	def.event(l, { ev = "action", act = "back" }, cx)
	check("back from the menu leaves the local player", l.mode == "player")
	local p = signed_in_player()
	def.event(p, { ev = "action", act = "back" }, cx)
	check("back on the player does nothing", p.mode == "player")
end

-- 11. Local player (spotifyd): install, both ways to sign in, the LaunchAgent, and what counts as "up".
do
	local spotifyd = require("../spotifyd")
	local BIN = "/opt/homebrew/opt/spotifyd/bin/spotifyd"
	local BREW = "/opt/homebrew/bin/brew"
	local PLIST = "/Users/test/Library/LaunchAgents/so.tern-spotify.spotifyd.plist"
	local CACHE = "/tmp/spotify-test-data/spotifyd-cache"
	local STAGING = CACHE .. ".new"
	local STAGING_PAT = "/tmp/spotify-test-data/spotifyd-cache\\.new" -- the regular expression `pkill -f` is given

	-- A fake launchd and spotifyd. `w` is what the test can steer; `w.cmds` is what the plugin did.
	local function world(opts)
		local w = { loaded = false, running = true, listed = false, cmds = {}, brewed = 0 }
		if opts.installed then
			files[BIN] = "bin"
		end
		if opts.brew then
			files[BREW] = "brew"
		end
		proc_handler = function(argv, o)
			local a1 = argv[1]
			if a1 == "id" then
				return { stdout = "501\n" }
			elseif a1 == "launchctl" then
				local verb = argv[2]
				table.insert(w.cmds, verb)
				if verb == "print" then
					if w.print_hangs then
						return { status = -1, stderr = "", timed_out = true }
					end
					if w.unloading and w.unloading > 0 then
						w.unloading -= 1 -- launchd takes a few answers to finish removing the job
						if w.unloading == 0 then
							w.loaded = false
						end
					end
					if not w.loaded then
						return { status = 113, stderr = "Could not find service" }
					end
					return { stdout = `gui/501/so.tern-spotify.spotifyd = \{\n\tstate = {if w.running then "running" else "waiting"}\n\tpid = 4242\n\}` }
				elseif verb == "bootstrap" then
					if w.unloading and w.unloading > 0 then
						w.loaded, w.unloading = false, 0 -- what the real race did: accepted, then removed with the old job
						return {}
					end
					if w.loaded then
						return { status = 5, stderr = "Bootstrap failed: 5: Input/output error" } -- what launchd really answers (checked by hand)
					end
					if files[PLIST] == nil then
						return { status = 5, stderr = "Bootstrap failed: 5: Input/output error" }
					end
					if w.vanishes then
						return {} -- accepted, yet launchd keeps nothing
					end
					w.loaded = true
					return {}
				elseif verb == "bootout" then
					if w.slow_unload and w.loaded then
						w.unloading = 3 -- still loaded for the next two `print`s
					else
						w.loaded = false
					end
					return {}
				end
				return {}
			elseif a1 == BIN then
				if argv[2] == "--version" then
					return { stdout = "spotifyd 0.4.2\n" }
				end
				if w.pair_raises then
					error("spawn failed") -- tern.process.run raises when it can't start the program
				end
				return "hold"
			elseif a1 == "sh" and argv[2] == "-c" then
				if string.find(argv[3], "authenticate", 1, true) then
					w.auth = { argv = argv }
					return "hold"
				elseif string.find(argv[3], "mv", 1, true) then -- spotifyd.commit: move CACHE aside, move STAGING in, drop the old one
					local cache, staging = argv[5], argv[6]
					if w.hold_commit then
						return "hold"
					end
					if w.commit_fails then
						return { status = 1, stderr = "mv: could not move into place" } -- the real script puts the old login back
					end
					table.insert(w.cmds, "commit")
					local moved = {}
					for k, v in files do
						if k == cache or string.sub(k, 1, #cache + 1) == cache .. "/" then
							files[k] = nil
						elseif string.sub(k, 1, #staging + 1) == staging .. "/" then
							moved[cache .. string.sub(k, #staging + 1)] = v
							files[k] = nil
						end
					end
					for k, v in moved do
						files[k] = v
					end
					dirs[staging], dirs[cache] = nil, true
					return {}
				end
				return nil
			elseif a1 == "pkill" then
				table.insert(w.cmds, "pkill " .. argv[4])
				if w.hold_pkill then
					return "hold"
				end
				if w.pkill_reports_first then -- the killed pairing run reports back before pkill's own result
					for _, h in proc_held do
						if h.argv[2] == "--no-daemon" and not h.reported then
							h.reported = true
							local cb = h.cb
							table.insert(queue, function()
								cb({ status = -1, stdout = "", stderr = "", timed_out = false })
							end)
						end
					end
				end
				return {}
			elseif a1 == BREW then
				w.brewed += 1
				files[BIN] = "bin"
				return {}
			end
			return nil
		end
		routes["GET api.spotify.com/v1/me/player/devices"] = function()
			local list = { { id = "d1", name = "MacBook", type = "Computer", is_active = false, volume_percent = 40, supports_volume = true } }
			if w.listed then
				table.insert(list, { id = "tern1", name = "Tern", type = "Computer", is_active = false, supports_volume = true })
			end
			return ok(200, { devices = list })
		end
		return w
	end
	local function held(pattern) -- the latest run whose argv mentions `pattern`
		local found = nil
		for _, h in proc_held do
			for _, a in h.argv do
				if string.find(a, pattern, 1, true) then
					found = h
					break
				end
			end
		end
		return found
	end
	local function finish(h, result)
		table.insert(queue, function()
			h.cb({ status = result.status or 0, stdout = "", stderr = result.stderr or "", timed_out = result.timed_out or false })
		end)
		settle()
	end
	local function count(list, what)
		local n = 0
		for _, c in list do
			if c == what then
				n += 1
			end
		end
		return n
	end
	local function open_screen(state)
		def.key(state, K("p", "P"), cx)
		settle()
	end
	-- A signed-in player on a Mac with spotifyd installed; the screen is not open yet.
	local function scene()
		return signed_in_player(), world({ installed = true })
	end

	-- The generated files: spaces and markup in a path can't break the plist; the agent never has discovery.
	local p = { home = "/Users/a b", cache = "/d & <x>/spotifyd-cache", staging = "/d & <x>/spotifyd-cache.new", log = "/d & <x>/l.log", oauth_log = "o", plist_dir = "p", plist = "q" }
	local plist = spotifyd.plist("/bin/spotifyd", p)
	check("plist: paths are XML-escaped", string.find(plist, "/d &amp; &lt;x&gt;/spotifyd-cache", 1, true) ~= nil and string.find(plist, "<x>", 1, true) == nil, plist)
	check("plist: runs on the working login, not the staging one", string.find(plist, "<string>/d &amp; &lt;x&gt;/spotifyd-cache</string>", 1, true) ~= nil and string.find(plist, "cache.new", 1, true) == nil)
	check("plist: one argument per <string>, device Tern, discovery off", string.find(plist, "<string>--device-name</string>\n\t\t<string>Tern</string>", 1, true) ~= nil and string.find(plist, "--disable-discovery=true", 1, true) ~= nil and string.find(plist, "--disable-discovery=false", 1, true) == nil)
	check("plist: starts at login", string.find(plist, "<key>RunAtLoad</key>\n\t<true/>", 1, true) ~= nil)
	check("plist: restarts only after a crash, never in a tight loop", string.find(plist, "<key>KeepAlive</key>\n\t<dict>\n\t\t<key>SuccessfulExit</key>\n\t\t<false/>", 1, true) ~= nil and string.find(plist, "<key>ThrottleInterval</key>\n\t<integer>30</integer>", 1, true) ~= nil)
	check("pairing is the only run with discovery", table.find(spotifyd.args("/b", "/c", true), "--disable-discovery=false") ~= nil and table.find(spotifyd.args("/b", "/c", false), "--disable-discovery=true") ~= nil and table.find(spotifyd.args("/b", "/c", true), "/c") ~= nil)

	-- The screen and the key.
	do
		local state, w = scene()
		open_screen(state)
		check("P opens the local player screen", state.mode == "localplayer")
		local text = view_text(def, state)
		check("screen: installed version and device state", string.find(text, "installed 0.4.2", 1, true) ~= nil and string.find(text, "off", 1, true) ~= nil and string.find(text, "isn't listed", 1, true) ~= nil, text)
		check("screen: both ways to sign in are offered", string.find(text, "pair from phone", 1, true) ~= nil and string.find(text, "sign in with browser", 1, true) ~= nil)
		def.key(state, K("escape"), cx)
		check("esc goes back to the player", state.mode == "player")
		env.HOME = nil
		check("no HOME: nothing to write", spotifyd.paths() == nil)
		env.HOME = "/Users/test"
		tern.runtime.os = "linux"
		def.key(state, K("p", "P"), cx)
		check("not macOS: the screen doesn't open and says why", state.mode == "player" and state.err == "The local player needs macOS.", state.err)
		check("not macOS: no LOCAL PLAYER badge", string.find(view_text(def, state), "LOCAL PLAYER", 1, true) == nil)
		tern.runtime.os = "macos"
		check("macOS: the badge is there", string.find(view_text(def, state), "LOCAL PLAYER", 1, true) ~= nil)
		def.event(state, { ev = "action", act = "local_open" }, cx)
		settle()
		check("the badge opens the screen", state.mode == "localplayer")
	end

	-- Install: Homebrew's own copy, nothing downloaded, and no second install.
	do
		local state = signed_in_player()
		local w = world({ brew = true })
		open_screen(state)
		check("not installed: says so", string.find(view_text(def, state), "not installed", 1, true) ~= nil)
		def.key(state, K("i", "i"), cx)
		check("install: busy while brew runs", state.sd.step == "installing")
		settle()
		check("install: ran brew install spotifyd", w.brewed == 1 and state.sd.step == "menu" and state.sd.err == nil, state.sd.err)
		local brew_run
		for _, r in proc_log do
			if r.argv[1] == BREW then
				brew_run = r
			end
		end
		check("install: argv and environment", brew_run ~= nil and brew_run.argv[2] == "install" and brew_run.argv[3] == "spotifyd" and brew_run.opts.env.HOMEBREW_NO_AUTO_UPDATE == "1", brew_run and table.concat(brew_run.argv, " "))
		check("install: now shown as installed", string.find(view_text(def, state), "installed 0.4.2", 1, true) ~= nil)
		def.key(state, K("i", "i"), cx)
		settle()
		check("install: already installed means no second brew", w.brewed == 1)

		state = signed_in_player()
		w = world({})
		open_screen(state)
		def.key(state, K("i", "i"), cx)
		settle()
		check("install without Homebrew: explains, runs nothing", w.brewed == 0 and state.sd.step == "menu" and string.find(state.sd.err or "", "Homebrew isn't installed", 1, true) ~= nil, state.sd.err)
		check("install error is shown", string.find(view_text(def, state), "Homebrew isn't installed", 1, true) ~= nil)
	end

	-- Start: the plist is written before launchd is asked, and "up" needs launchd AND the account.
	local function login(dir, text)
		dirs[dir] = true
		files[dir .. "/credentials.json"] = text or "login"
	end
	do
		local state, w = scene()
		login(CACHE)
		open_screen(state)
		def.key(state, K("s", "s"), cx)
		settle()
		check("start: LaunchAgent written and loaded", files[PLIST] ~= nil and w.loaded and state.sd.step == "starting", state.sd.step)
		check("start: unloads before loading (error 5 on a loaded job)", w.cmds[1] == "bootout" or w.cmds[2] == "bootout")
		check("start: the log is truncated", files["/tmp/spotify-test-data/spotifyd.log"] == "")
		advance(3000)
		check("start: launchd runs it but Spotify doesn't list Tern: not up", state.sd.step == "starting")
		w.listed = true
		advance(3000)
		check("start: running and listed: up", state.sd.step == "menu" and state.sd.visible == true and state.sd.err == nil, state.sd.step)
		local text = view_text(def, state)
		check("screen: running with its pid, listed in the account", string.find(text, "running (pid 4242)", 1, true) ~= nil and string.find(text, "is in your device list", 1, true) ~= nil, text)
	end
	do
		local state, w = scene()
		open_screen(state)
		def.key(state, K("s", "s"), cx)
		settle()
		check("start with no login: refused, nothing written or loaded", files[PLIST] == nil and count(w.cmds, "bootstrap") == 0 and state.sd.step == "menu" and string.find(state.sd.err or "", "sign in first", 1, true) ~= nil, state.sd.err)
		dirs[CACHE] = true -- an empty folder is no login either
		def.key(state, K("s", "s"), cx)
		settle()
		check("start with an empty login folder: refused too", files[PLIST] == nil and state.sd.step == "menu")
	end
	do
		local state, w = scene()
		login(CACHE)
		w.listed, w.running = true, false -- Tern is listed (a stale entry) but launchd has no process
		open_screen(state)
		def.key(state, K("s", "s"), cx)
		advance(50000)
		check("start: a listed device without a running process is not 'up'", state.sd.step == "menu" and string.find(state.sd.err or "", "didn't show up", 1, true) ~= nil, state.sd.err)
	end
	do
		local state, w = scene()
		login(CACHE)
		open_screen(state)
		files[BIN] = nil
		def.key(state, K("s", "s"), cx)
		settle()
		check("start without spotifyd: no plist, no launchctl load", files[PLIST] == nil and count(w.cmds, "bootstrap") == 0 and string.find(state.sd.err or "", "isn't installed", 1, true) ~= nil, state.sd.err)
	end

	-- Pairing from the phone: into staging, and only a login that is BOTH on disk and in this account counts.
	do
		local state, w = scene()
		login(CACHE, "old")
		open_screen(state)
		files[PLIST], w.loaded = "old", true -- an agent from before
		def.key(state, K("1", "1"), cx)
		settle()
		check("pair: the old agent is unloaded first (never two Terns)", state.sd.step == "pairing" and not w.loaded and files[PLIST] == nil)
		local pair = held("--no-daemon")
		check("pair: one bounded spotifyd with discovery on, in STAGING (the working login is not touched)", pair ~= nil and table.find(pair.argv, "--disable-discovery=false") ~= nil and table.find(pair.argv, STAGING) ~= nil and table.find(pair.argv, CACHE) == nil and table.find(pair.argv, "Tern") ~= nil)
		check("pair: a plain argv, no shell", pair ~= nil and pair.argv[1] == BIN and table.find(pair.argv, "-c") == nil and table.find(pair.argv, "sh") == nil)
		local run
		for _, r in proc_log do
			if r.argv[1] == BIN and r.argv[2] == "--no-daemon" then
				run = r
			end
		end
		check("pair: the run has a timeout of 3 minutes", run ~= nil and run.opts.timeout_ms == 180000, run and run.opts.timeout_ms)
		check("pair: tells you what to do on the phone", string.find(view_text(def, state), "choose Tern", 1, true) ~= nil)
		advance(9000)
		check("pair: nothing is installed while nobody paired", files[PLIST] == nil and count(w.cmds, "bootstrap") == 0 and state.sd.step == "pairing")
		files[STAGING .. "/zeroconf/credentials.json"] = "new" -- where a pairing from the phone leaves its login
		dirs[STAGING] = true
		w.listed = true
		advance(3000)
		check("pair: once the login is on disk and Tern is in YOUR account, the pairing run is stopped (by our own path)", count(w.cmds, "pkill " .. STAGING_PAT) == 1, table.concat(w.cmds, ","))
		check("pair: the new login replaces the old one", count(w.cmds, "commit") == 1 and files[CACHE .. "/zeroconf/credentials.json"] == "new" and files[STAGING .. "/zeroconf/credentials.json"] == nil and dirs[STAGING] == nil)
		check("pair: and the agent, without discovery, takes over", files[PLIST] ~= nil and string.find(files[PLIST], "--disable-discovery=true", 1, true) ~= nil and string.find(files[PLIST], "--disable-discovery=false", 1, true) == nil and w.loaded)
		advance(3000)
		check("pair: done", state.sd.step == "menu" and state.sd.visible == true and state.sd.err == nil, state.sd.step)
		finish(pair, { status = -1 }) -- the killed pairing run reports back late
		check("pair: the late report of the killed run changes nothing", state.sd.step == "menu" and state.sd.err == nil and files[PLIST] ~= nil)
	end
	do -- a Tern is listed but it isn't this Mac's pairing (another Mac, a stale entry): keep waiting
		local state, w = scene()
		open_screen(state)
		def.key(state, K("1", "1"), cx)
		settle()
		w.listed = true
		advance(12000)
		check("pair: a listed Tern without a login written here is not a pairing", state.sd.step == "pairing" and count(w.cmds, "commit") == 0 and files[PLIST] == nil and count(w.cmds, "pkill " .. STAGING_PAT) == 0)
	end
	do -- nothing is asked of Spotify until a login has landed in staging
		local state, w = scene()
		open_screen(state)
		def.key(state, K("1", "1"), cx)
		settle()
		local asked = #calls("GET", "/v1/me/player/devices")
		advance(9000)
		check("pair: no device list is requested while nobody has paired", #calls("GET", "/v1/me/player/devices") == asked, `{asked} -> {#calls("GET", "/v1/me/player/devices")}`)
		files[STAGING .. "/credentials.json"] = "new"
		w.listed = true
		advance(3000)
		check("pair: once a login lands, the next check asks and adopts it", #calls("GET", "/v1/me/player/devices") > asked and count(w.cmds, "commit") == 1, `{#calls("GET", "/v1/me/player/devices") - asked} {count(w.cmds, "commit")}`)
	end
	do -- nobody pairs; the old login and agent survive
		local state, w = scene()
		login(CACHE, "old")
		files[PLIST] = "old"
		open_screen(state)
		def.key(state, K("1", "1"), cx)
		settle()
		local pair = held("--no-daemon")
		files[STAGING .. "/credentials.json"] = "someone else's"
		dirs[STAGING] = true
		advance(180000)
		finish(pair, { timed_out = true, status = -1 })
		check("pair timeout: says nobody paired", state.sd.step == "menu" and string.find(state.sd.err or "", "Nobody paired in time", 1, true) ~= nil, state.sd.err)
		check("pair timeout: the stranger's login is wiped", dirs[STAGING] == nil and files[STAGING .. "/credentials.json"] == nil)
		check("pair timeout: your old login is still there, and the agent is back", files[CACHE .. "/credentials.json"] == "old" and files[PLIST] ~= nil and w.loaded and count(w.cmds, "commit") == 0)
	end
	do -- nothing was running before: nothing is started after a failure
		local state, w = scene()
		login(CACHE, "old")
		open_screen(state)
		def.key(state, K("1", "1"), cx)
		settle()
		finish(held("--no-daemon"), { timed_out = true, status = -1 })
		check("pair timeout with no agent before: none is started", files[PLIST] == nil and count(w.cmds, "bootstrap") == 0 and files[CACHE .. "/credentials.json"] == "old")
	end
	do -- esc cancels
		local state, w = scene()
		login(CACHE, "old")
		open_screen(state)
		def.key(state, K("1", "1"), cx)
		settle()
		local pair = held("--no-daemon")
		files[STAGING .. "/credentials.json"] = "half"
		def.key(state, K("escape"), cx)
		settle()
		check("pair cancel: stops our spotifyd, back to the menu, staging wiped, old login kept", state.sd.step == "menu" and state.mode == "localplayer" and count(w.cmds, "pkill " .. STAGING_PAT) == 1 and files[STAGING .. "/credentials.json"] == nil and files[CACHE .. "/credentials.json"] == "old")
		finish(pair, { status = -1 })
		check("pair cancel: the run's late report is ignored", state.sd.err == nil)
		w.listed = true
		advance(9000)
		check("pair cancel: no polling goes on after it", files[PLIST] == nil)
	end
	do -- the pane is closed while pairing: the stranger's login still must not stay on disk
		local state = scene()
		open_screen(state)
		def.key(state, K("1", "1"), cx)
		settle()
		local pair = held("--no-daemon")
		files[STAGING .. "/credentials.json"] = "stranger"
		local pane = panes[1]
		panes[1] = nil
		finish(pair, { timed_out = true, status = -1 })
		panes[1] = pane
		check("pair, pane closed: staging wiped anyway", files[STAGING .. "/credentials.json"] == nil and dirs[STAGING] == nil)
	end
	do -- the new login can't be moved into place: the old one and its agent stay
		local state, w = scene()
		w.commit_fails = true
		login(CACHE, "old")
		files[PLIST] = "old"
		open_screen(state)
		def.key(state, K("1", "1"), cx)
		settle()
		files[STAGING .. "/credentials.json"] = "new"
		dirs[STAGING] = true
		w.listed = true
		advance(3000)
		check("commit fails: says so, old login kept, staging dropped, agent back", state.sd.step == "menu" and string.find(state.sd.err or "", "Could not keep the new login", 1, true) ~= nil and files[CACHE .. "/credentials.json"] == "old" and files[STAGING .. "/credentials.json"] == nil and files[PLIST] ~= nil and w.loaded, state.sd.err)
	end
	do -- the killed pairing run reports back before pkill returns: still exactly one clean adoption
		local state, w = scene()
		w.pkill_reports_first = true
		login(CACHE, "old")
		files[PLIST] = "old"
		open_screen(state)
		def.key(state, K("1", "1"), cx)
		settle()
		files[STAGING .. "/credentials.json"] = "new"
		dirs[STAGING] = true
		w.listed = true
		advance(3000)
		check("pair: the killed run's early report is not read as a failure", state.sd.err == nil and files[CACHE .. "/credentials.json"] == "new" and count(w.cmds, "commit") == 1, state.sd.err)
		check("pair: the agent is started once, not twice", count(w.cmds, "bootstrap") == 1, count(w.cmds, "bootstrap"))
	end
	do -- browser sign-in that "succeeds" but wrote no login: nothing replaces the old one
		local state, w = scene()
		login(CACHE, "old")
		open_screen(state)
		def.key(state, K("2", "2"), cx)
		settle()
		dirs[STAGING .. "/oauth"] = true -- what `authenticate` creates on starting, before anybody signs in
		finish(held("authenticate"), { status = 0 })
		check("oauth exit 0 with no login: refused, old login kept", count(w.cmds, "commit") == 0 and files[CACHE .. "/credentials.json"] == "old" and string.find(state.sd.err or "", "no login was saved", 1, true) ~= nil and state.sd.step == "menu", state.sd.err)
	end
	do -- a folder holding only `oauth` (empty) or only spotifyd's `volume` file is no login
		local state, w = scene()
		dirs[CACHE] = true
		dirs[CACHE .. "/oauth"] = true
		files[CACHE .. "/volume"] = "50"
		open_screen(state)
		def.key(state, K("s", "s"), cx)
		settle()
		check("start with no credentials.json anywhere: refused", files[PLIST] == nil and count(w.cmds, "bootstrap") == 0 and string.find(state.sd.err or "", "sign in first", 1, true) ~= nil)
	end
	do -- esc while the new login is being swapped in does nothing
		local state, w = scene()
		w.hold_commit = true
		login(CACHE, "old")
		open_screen(state)
		def.key(state, K("1", "1"), cx)
		settle()
		files[STAGING .. "/credentials.json"] = "new"
		dirs[STAGING] = true
		w.listed = true
		advance(3000)
		check("saving: the swap is in progress", state.sd.step == "saving", state.sd.step)
		local gen = state.sd.gen
		def.key(state, K("escape"), cx)
		check("saving: esc is ignored", state.sd.step == "saving" and state.sd.gen == gen)
		finish(held("mv"), { status = 0 })
		check("saving: when the swap ends the agent is started and, listed already, is up", state.sd.step == "menu" and state.sd.visible == true and files[PLIST] ~= nil and w.loaded, state.sd.step)
	end
	do -- esc between "Tern is listed" and pkill answering: not a half cancel
		local state, w = scene()
		w.hold_pkill = true
		login(CACHE, "old")
		files[PLIST] = "old"
		open_screen(state)
		def.key(state, K("1", "1"), cx)
		settle()
		files[STAGING .. "/credentials.json"] = "new"
		dirs[STAGING] = true
		w.listed = true
		advance(3000)
		local gen = state.sd.gen
		def.key(state, K("escape"), cx)
		check("esc while the pairing run is being stopped: ignored", state.sd.step == "saving" and state.sd.gen == gen, state.sd.step)
		w.hold_pkill = false
		finish(held("pkill"), { status = 0 })
		settle()
		check("...and the new login is adopted when pkill answers", files[CACHE .. "/credentials.json"] == "new" and files[STAGING .. "/credentials.json"] == nil, tostring(files[CACHE .. "/credentials.json"]))
	end
	do -- a helper that times out (hung pkill, hung swap) must not leave the screen stuck
		local state, w = scene()
		w.hold_pkill = true
		login(CACHE, "old")
		files[PLIST] = "old"
		open_screen(state)
		def.key(state, K("1", "1"), cx)
		settle()
		files[STAGING .. "/credentials.json"] = "new"
		dirs[STAGING] = true
		w.listed = true
		advance(3000)
		w.hold_pkill = false
		w.hold_commit = true
		finish(held("pkill"), { status = -1, timed_out = true })
		settle()
		check("pkill timed out: the swap goes ahead anyway", state.sd.step == "saving" and held("mv") ~= nil, state.sd.step)
		finish(held("mv"), { status = -1, timed_out = true, stderr = "" })
		settle()
		check("swap timed out: reported, old login kept, agent back, screen free", state.sd.step == "menu" and state.sd.restoring == false and string.find(state.sd.err or "", "Could not keep the new login", 1, true) ~= nil and files[CACHE .. "/credentials.json"] == "old" and w.loaded, state.sd.err)
		w.hold_commit = false
		def.key(state, K("1", "1"), cx)
		settle()
		check("...and a new pairing can start", state.sd.step == "pairing", state.sd.step)
	end
	do -- cancel, then straight into a new pairing: not until the old agent is back
		local state, w = scene()
		login(CACHE, "old")
		files[PLIST] = "old"
		open_screen(state)
		def.key(state, K("1", "1"), cx)
		settle()
		def.key(state, K("escape"), cx)
		def.key(state, K("1", "1"), cx) -- before the restore has finished
		check("cancel then 1 at once: ignored while restoring", state.sd.step == "menu" and state.sd.restoring == true)
		settle()
		local pairs_started = 0
		for _, h in proc_held do
			if h.argv[2] == "--no-daemon" then
				pairs_started += 1
			end
		end
		check("cancel then 1 at once: one pairing only, agent restored, free again", pairs_started == 1 and files[PLIST] ~= nil and w.loaded and state.sd.restoring == false, `{pairs_started} {tostring(state.sd.restoring)}`)
	end
	do -- spotifyd can't even be spawned: no polling goes on
		local state, w = scene()
		w.pair_raises = true
		login(CACHE, "old")
		files[PLIST], w.loaded = "old", true
		open_screen(state)
		def.key(state, K("1", "1"), cx)
		settle()
		check("pair spawn failure: reported", state.sd.step == "menu" and string.find(state.sd.err or "", "spawn failed", 1, true) ~= nil, state.sd.err)
		check("pair spawn failure: the agent that ran comes back", w.loaded and files[PLIST] ~= "old", tostring(files[PLIST]))
		local polls = #calls("GET", "/v1/me/player/devices")
		advance(12000)
		check("pair spawn failure: nothing keeps polling", #calls("GET", "/v1/me/player/devices") == polls, `{polls} -> {#calls("GET", "/v1/me/player/devices")}`)
	end
	do -- esc before the old agent is unloaded: the pairing never starts
		local state = scene()
		login(CACHE, "old")
		open_screen(state)
		def.key(state, K("1", "1"), cx)
		def.key(state, K("escape"), cx) -- the unload has not answered yet
		settle()
		check("esc before the unload answers: no pairing is spawned", held("--no-daemon") == nil and state.sd.step == "menu")
	end
	do -- a key or click for another action during a pairing is ignored
		local state = scene()
		login(CACHE, "old")
		open_screen(state)
		def.key(state, K("1", "1"), cx)
		settle()
		check("pairing: running", state.sd.step == "pairing" and held("--no-daemon") ~= nil)
		local before = #proc_log
		def.key(state, K("s", "s"), cx)
		def.key(state, K("u", "U"), cx)
		def.event(state, { ev = "action", act = "sd_remove" }, cx)
		settle()
		check("pairing: other keys and clicks do nothing", state.sd.step == "pairing" and #proc_log == before and files[CACHE .. "/credentials.json"] == "old")
	end
	do -- the pane closes while the old agent is being unloaded: it still comes back, and nothing starts
		local state, w = scene()
		login(CACHE, "old")
		files[PLIST], w.loaded = "old", true
		open_screen(state)
		def.key(state, K("1", "1"), cx)
		local pane = panes[1]
		panes[1] = nil
		settle()
		panes[1] = pane
		check("pane closed during the unload: no pairing starts, the agent is restored", held("--no-daemon") == nil and files[PLIST] ~= nil and files[PLIST] ~= "old" and w.loaded, tostring(files[PLIST]))
	end
	do -- spotifyd dies on its own
		local state = scene()
		open_screen(state)
		def.key(state, K("1", "1"), cx)
		settle()
		finish(held("--no-daemon"), { status = 1, stderr = "boom: audio device" })
		check("pair crash: shows spotifyd's message", string.find(state.sd.err or "", "boom: audio device", 1, true) ~= nil and state.sd.step == "menu", state.sd.err)
	end

	-- Browser sign-in.
	do
		local state, w = scene()
		login(CACHE, "old")
		open_screen(state)
		def.key(state, K("2", "2"), cx)
		settle()
		local auth = w.auth
		check("oauth: one bounded spotifyd authenticate, into staging", auth ~= nil and auth.argv[3]:find("authenticate --oauth-port", 1, true) ~= nil and auth.argv[5] == BIN and auth.argv[6] == "8000" and auth.argv[7] == STAGING, auth and table.concat(auth.argv, "|"))
		local run
		for _, r in proc_log do
			if r.argv[1] == "sh" and r.argv[2] == "-c" then
				run = r
			end
		end
		check("oauth: 3 minute timeout", run ~= nil and run.opts.timeout_ms == 180000)
		check("oauth: waiting, no address yet", state.sd.step == "oauth" and state.sd.url == nil)
		files["/tmp/spotify-test-data/spotifyd-oauth.log"] = "[INFO] x\nBrowse to: https://accounts.spotify.com/authorize?client_id=abc&state=s\n[INFO] OAuth server listening on 127.0.0.1:8000\n"
		advance(1000)
		check("oauth: the address is read from the log and opened", state.sd.url == "https://accounts.spotify.com/authorize?client_id=abc&state=s" and opened[#opened] == state.sd.url, state.sd.url)
		check("oauth: the address is on screen", string.find(view_text(def, state), "accounts.spotify.com/authorize", 1, true) ~= nil)
		local n = #opened
		local log_reads = reads["/tmp/spotify-test-data/spotifyd-oauth.log"]
		advance(3000)
		check("oauth: the address is opened once", #opened == n)
		check("oauth: once the address is out, the log is not read again", reads["/tmp/spotify-test-data/spotifyd-oauth.log"] == log_reads, `{log_reads} -> {reads["/tmp/spotify-test-data/spotifyd-oauth.log"]}`)
		check("oauth: nothing installed before the login finishes", files[PLIST] == nil and files[CACHE .. "/credentials.json"] == "old")
		files[STAGING .. "/oauth/credentials.json"] = "fresh" -- where `spotifyd authenticate` leaves its login
		dirs[STAGING] = true
		finish(held("authenticate"), { status = 0 })
		check("oauth: login done: it replaces the old one and the agent starts", files[CACHE .. "/oauth/credentials.json"] == "fresh" and files[PLIST] ~= nil and w.loaded and state.sd.step == "starting" and state.sd.url == nil)
		w.listed = true
		advance(3000)
		check("oauth: up", state.sd.step == "menu" and state.sd.visible == true and state.sd.err == nil)
	end
	do
		local state, w = scene()
		login(CACHE, "old")
		files[PLIST] = "old"
		open_screen(state)
		def.key(state, K("2", "2"), cx)
		settle()
		files["/tmp/spotify-test-data/spotifyd-oauth.log"] = "[ERROR] access_denied\n"
		files[STAGING .. "/junk"] = "x"
		finish(held("authenticate"), { status = 1 })
		check("oauth denied: error with the log, old login and agent kept", state.sd.step == "menu" and string.find(state.sd.err or "", "access_denied", 1, true) ~= nil and files[CACHE .. "/credentials.json"] == "old" and files[STAGING .. "/junk"] == nil and files[PLIST] ~= nil and w.loaded and count(w.cmds, "commit") == 0, state.sd.err)
		def.key(state, K("2", "2"), cx)
		settle()
		finish(held("authenticate"), { status = -1, timed_out = true })
		check("oauth timeout says so", string.find(state.sd.err or "", "timed out", 1, true) ~= nil, state.sd.err)
		def.key(state, K("2", "2"), cx)
		settle()
		def.key(state, K("escape"), cx)
		settle()
		check("oauth cancel: kills our authenticate (by its staging path) and goes back", count(w.cmds, "pkill " .. STAGING_PAT) == 1 and state.sd.step == "menu")

		-- The other direction of the port clash: a Keymaster sign-in while spotifyd authenticate listens.
		def.key(state, K("2", "2"), cx)
		settle()
		state.auth = "keymaster" -- it is the Keymaster redirect that shares spotifyd's port (8000)
		def.event(state, { ev = "action", act = "signin" }, cx)
		settle()
		check("a Keymaster sign-in is refused while the browser sign-in holds the port", not state.waiting and string.find(state.err or "", "same port", 1, true) ~= nil, state.err)
		state.auth, state.err = "own", nil -- your own Client ID listens on 43821: no clash
		def.event(state, { ev = "action", act = "signin" }, cx)
		settle()
		check("a sign-in with your own Client ID is not held back by it", state.waiting and state.err == nil, state.err)
	end
	do -- launchd removes the old job slowly: loading the new one right after bootout used to be lost
		local state, w = scene()
		login(CACHE)
		w.listed = true
		open_screen(state)
		def.key(state, K("s", "s"), cx)
		advance(3000)
		check("race: first start is up", state.sd.step == "menu" and w.loaded)
		w.slow_unload = true -- launchd needs a few answers to finish removing the old job
		def.key(state, K("s", "s"), cx)
		advance(3000)
		check("start with a slow unload: waits for launchd, then the agent is loaded and up", state.sd.step == "menu" and state.sd.err == nil and w.loaded, tostring(state.sd.err))
		w.slow_unload = false
		w.vanishes = true
		def.key(state, K("s", "s"), cx)
		advance(3000)
		check("a load that launchd drops: says so instead of waiting 45 s", state.sd.step == "menu" and string.find(state.sd.err or "", "did not keep", 1, true) ~= nil and not w.loaded, tostring(state.sd.err))
	end
	do -- esc during a slow start, then a pairing at once: the pairing waits until the agent is loaded
		local state, w = scene()
		login(CACHE, "old")
		w.listed = true
		open_screen(state)
		def.key(state, K("s", "s"), cx)
		advance(3000)
		check("slow start: first start is up", state.sd.step == "menu" and w.loaded)
		w.slow_unload = true
		def.key(state, K("s", "s"), cx)
		def.key(state, K("escape"), cx) -- abandon the start while launchd is still removing the old job
		def.key(state, K("1", "1"), cx)
		check("slow start, esc, 1: the pairing is not started while the agent is being loaded", held("--no-daemon") == nil and state.sd.step == "menu" and state.sd.restoring == true)
		advance(3000)
		check("slow start, esc: the agent ends up loaded once, and the screen is free again", w.loaded and state.sd.restoring == false and held("--no-daemon") == nil, tostring(state.sd.restoring))
	end
	do -- launchctl print hangs: that is no proof that the job is gone or missing
		local state, w = scene()
		login(CACHE)
		w.print_hangs = true
		open_screen(state)
		def.key(state, K("s", "s"), cx)
		advance(1000)
		check("hung print: no proof the old job is gone, so the load still waits", count(w.cmds, "bootstrap") == 0 and state.sd.step == "starting", tostring(count(w.cmds, "bootstrap")))
		advance(8000)
		check("hung print: the agent is still loaded, and no false 'did not keep'", w.loaded and count(w.cmds, "bootstrap") == 1 and string.find(state.sd.err or "", "did not keep", 1, true) == nil, tostring(state.sd.err))
	end
	do -- starting twice reloads cleanly; clicks that don't belong to the screen do nothing
		local state, w = scene()
		login(CACHE)
		w.listed = true
		open_screen(state)
		def.key(state, K("s", "s"), cx)
		advance(3000)
		check("start: up the first time", state.sd.step == "menu" and w.loaded)
		def.key(state, K("s", "s"), cx)
		advance(3000)
		check("start again: an agent that is already loaded is replaced, not an error", state.sd.step == "menu" and state.sd.err == nil and w.loaded, state.sd.err)
		local before = #proc_log
		for _, m in { "player", "search", "devices" } do
			state.mode = m
			def.event(state, { ev = "action", act = "sd_pair" }, cx)
			def.event(state, { ev = "action", act = "sd_remove" }, cx)
		end
		settle()
		check("sd clicks from any other screen do nothing", #proc_log == before and state.sd.step == "menu")
		state.mode = "localplayer"
		w.listed = false -- Tern isn't up yet, so the start stays in progress
		local unloads = count(w.cmds, "bootout")
		def.key(state, K("s", "s"), cx)
		check("busy: the step is running", state.sd.step == "starting")
		def.event(state, { ev = "action", act = "sd_remove" }, cx)
		settle()
		check("busy: a click on remove is ignored while a step runs (one unload, the start's own; plist kept)", state.sd.step == "starting" and count(w.cmds, "bootout") == unloads + 1 and files[PLIST] ~= nil, count(w.cmds, "bootout") - unloads)
		-- esc while the agent is starting: the start is abandoned, nothing else runs
		def.key(state, K("escape"), cx)
		settle()
		advance(10000)
		check("esc during the start leaves the step and stops waiting", state.sd.step == "menu" and state.sd.err == nil)
	end
	do
		local state = signed_in_player()
		world({}) -- not installed
		open_screen(state)
		def.key(state, K("1", "1"), cx)
		def.key(state, K("2", "2"), cx)
		settle()
		check("sign in before install: told to install first, nothing run", state.sd.step == "menu" and string.find(state.sd.err or "", "Install spotifyd first", 1, true) ~= nil and #proc_held == 0)
	end

	-- Stop and remove.
	do
		local state, w = scene()
		login(CACHE)
		open_screen(state)
		def.key(state, K("s", "s"), cx)
		w.listed = true
		advance(3000)
		def.key(state, K("x", "x"), cx)
		settle()
		check("stop: unloaded and no longer starts at login", not w.loaded and files[PLIST] == nil and state.sd.step == "menu" and files[CACHE .. "/credentials.json"] ~= nil)
		files["/tmp/spotify-test-data/kv.json"] = "{}"
		files[STAGING .. "/x"] = "leftover"
		files[CACHE .. ".old/credentials.json"] = "crashed swap"
		def.key(state, K("u", "u"), cx)
		settle()
		check("a lowercase u does not remove anything", files[CACHE .. "/credentials.json"] == "login")
		def.key(state, K("u", "U"), cx)
		settle()
		check("remove: credentials, staging and logs gone", files[CACHE .. "/credentials.json"] == nil and files[STAGING .. "/x"] == nil and files[CACHE .. ".old/credentials.json"] == nil and files["/tmp/spotify-test-data/spotifyd.log"] == nil and not w.loaded)
		check("remove: keeps Homebrew's spotifyd and the plugin's own data", files[BIN] == "bin" and files["/tmp/spotify-test-data/kv.json"] == "{}")
	end
	do -- cancel, then a CLICK on pair at once: ignored like the key is
		local state, w = scene()
		login(CACHE, "old")
		files[PLIST] = "old"
		open_screen(state)
		def.key(state, K("1", "1"), cx)
		settle()
		def.key(state, K("escape"), cx)
		def.event(state, { ev = "action", act = "sd_pair" }, cx)
		settle()
		local pairs_started = 0
		for _, h in proc_held do
			if h.argv[2] == "--no-daemon" then
				pairs_started += 1
			end
		end
		check("cancel then a click on pair: ignored while restoring", pairs_started == 1 and state.sd.step == "menu", pairs_started)
	end
end

-- 11b. With the local player registered in the account, "no active device" starts on it instead of asking.
do
	local TERN = { id = "tern1", name = "Tern", type = "Computer", is_active = false, supports_volume = true }
	local MAC = { id = "d1", name = "MacBook", type = "Computer", is_active = false, supports_volume = true }
	local track = { type = "track", uri = "spotify:track:s9", name = "Ninth", duration_ms = 200000, artists = { { name = "W" } }, album = { name = "EE", uri = "spotify:album:e", images = {} } }
	-- Spotify: 404 NO_ACTIVE_DEVICE unless the play names a device; `works_with_id` false keeps failing.
	local function scenario(devices, works_with_id)
		local state = signed_in_player()
		set_current(nil)
		advance(11000)
		routes["GET api.spotify.com/v1/search"] = function()
			return ok(200, { tracks = { items = { track } } })
		end
		routes["GET api.spotify.com/v1/me/player/devices"] = function()
			return ok(200, { devices = devices })
		end
		routes["PUT api.spotify.com/v1/me/player/play"] = function(req)
			if req.query.device_id == nil or not works_with_id then
				return ok(404, { error = { status = 404, message = "Player command failed: No active device found", reason = "NO_ACTIVE_DEVICE" } })
			end
			set_current(playback({ item = track, progress_ms = 0, device = { id = req.query.device_id, name = "Tern", type = "Computer", is_active = true, volume_percent = 30 } }))
			return { status = 204 }
		end
		return state
	end
	local function choose_first(state)
		def.key(state, K("/"), cx)
		def.key(state, K("f", "f"), cx)
		def.key(state, K("enter"), cx)
		settle()
		def.key(state, K("enter"), cx)
		settle()
	end

	do -- a chosen track starts on Tern, no picker
		local state = scenario({ MAC, TERN }, true)
		choose_first(state)
		local play = calls("PUT", "/v1/me/player/play")
		check("auto device: the track is retried on Tern", #play == 2 and play[2].query.device_id == "tern1" and play[1].query.device_id == nil, #play)
		check("auto device: by album context, as every chosen track", string.find(play[2] and play[2].body or "", '"context_uri":"spotify:album:e"', 1, true) ~= nil, play[2] and play[2].body)
		check("auto device: no picker, no error", state.mode == "player" and state.err == nil and state.pending == nil, `{state.mode} {tostring(state.err)}`)
		advance(1500)
		check("auto device: it shows as playing", state.playback ~= nil and state.playback.playing and state.playback.track.name == "Ninth")
	end
	do -- resume with nothing active: a transfer to Tern that plays
		local state = scenario({ MAC, TERN }, true)
		def.key(state, K("space"), cx)
		settle()
		local transfers = calls("PUT", "/v1/me/player")
		check("auto device: resume transfers to Tern and plays", #transfers == 1 and string.find(transfers[1].body, '"tern1"', 1, true) ~= nil and string.find(transfers[1].body, '"play":true', 1, true) ~= nil, transfers[1] and transfers[1].body)
		check("auto device: resume doesn't open the picker", state.mode == "player")
	end
	do -- two devices called Tern: don't guess
		local state = scenario({ MAC, TERN, { id = "tern2", name = "Tern", type = "Computer", is_active = false } }, true)
		choose_first(state)
		check("auto device: ambiguous: the picker, track kept", state.mode == "devices" and state.pending ~= nil and state.pending.name == "Ninth" and #calls("PUT", "/v1/me/player/play") == 1, state.mode)
		check("auto device: ambiguous: the list it already has fills the picker, no second request", #calls("GET", "/v1/me/player/devices") == 1 and #state.devices == 3, `{#calls("GET", "/v1/me/player/devices")} {#state.devices}`)
	end
	do -- the device list can't be read: the picker asks again, as it always did
		local state = scenario({ MAC, TERN }, true)
		routes["GET api.spotify.com/v1/me/player/devices"] = function()
			return ok(500, { error = { status = 500, message = "boom" } })
		end
		choose_first(state)
		check("auto device: unreadable list: the picker asks for it once more", state.mode == "devices" and #calls("GET", "/v1/me/player/devices") == 2, `{state.mode} {#calls("GET", "/v1/me/player/devices")}`)
	end
	do -- Tern is listed but still refuses: ask once, never loop
		local state = scenario({ MAC, TERN }, false)
		choose_first(state)
		advance(3000)
		check("auto device: a second refusal falls back to the picker", state.mode == "devices" and #calls("PUT", "/v1/me/player/play") == 2, `{state.mode} {#calls("PUT", "/v1/me/player/play")}`)
		check("auto device: and says so", state.err == "No active device: pick one to play on.", state.err)
		state.mode = "player"
		def.key(state, K("space"), cx)
		settle()
		check("auto device: a later refusal tries Tern again (the track kept for it)", #calls("PUT", "/v1/me/player/play") == 4, #calls("PUT", "/v1/me/player/play"))
	end
	do -- without macOS there is no local player to try
		local state = scenario({ MAC, TERN }, true)
		tern.runtime.os = "linux"
		choose_first(state)
		tern.runtime.os = "macos"
		check("auto device: not macOS: the picker, as before", state.mode == "devices" and #calls("PUT", "/v1/me/player/play") == 1, state.mode)
	end
	do -- only a play or a resume is redirected: volume, shuffle... still ask
		local state = signed_in_player()
		routes["GET api.spotify.com/v1/me/player/devices"] = function()
			return ok(200, { devices = { MAC, TERN } })
		end
		routes["PUT api.spotify.com/v1/me/player/shuffle"] = function()
			return ok(404, { error = { status = 404, message = "No active device found", reason = "NO_ACTIVE_DEVICE" } })
		end
		def.key(state, K("s", "s"), cx)
		settle()
		check("auto device: shuffle with no device asks, it doesn't start music on Tern", state.mode == "devices" and #calls("PUT", "/v1/me/player") == 0 and #calls("PUT", "/v1/me/player/play") == 0 and #calls("GET", "/v1/me/player/devices") == 1, `{state.mode} {#calls("GET", "/v1/me/player/devices")}`)
	end
end

if failures > 0 then
	error(`{failures} failure(s)`)
end
print("flow: ok")
